import Foundation

struct DockerStatsCollector: Sendable {
    nonisolated static let periodicContainerLimit = 24

    private let collectionTimeout: Duration = .seconds(8)
    private let actionTimeout: Duration = .seconds(120)

    func collect(
        client: SSHClient,
        platform: RemotePlatform,
        limit: Int? = periodicContainerLimit,
        fallback: DockerStats? = nil
    ) async -> DockerStats {
        let timestamp = Date()
        let environment = await client.remoteEnvironment()

        do {
            let psOutput = try await collectContainerList(
                client: client,
                platform: platform,
                environment: environment,
                limit: limit
            )
            if let availability = unavailableState(from: psOutput) {
                return DockerStats(availability: availability, containers: [], timestamp: timestamp)
            }

            let listedContainers = parseContainers(psOutput: psOutput, statsOutput: "", timestamp: timestamp).containers
            let runningIDs = listedContainers
                .filter(\.isRunning)
                .map(\.id)
                .filter { !$0.isEmpty }

            guard !runningIDs.isEmpty else {
                return DockerStats(availability: .available, containers: listedContainers, timestamp: timestamp)
            }

            let statsOutput = try await executeDockerCommand(
                statsCommand(platform: platform, environment: environment, containerIDs: runningIDs),
                client: client,
                platform: platform,
                environment: environment,
                timeout: collectionTimeout
            )

            if let availability = unavailableState(from: statsOutput) {
                if listedContainers.isEmpty {
                    return DockerStats(availability: availability, containers: [], timestamp: timestamp)
                }
                return DockerStats(availability: .available, containers: listedContainers, timestamp: timestamp)
            }

            return parseContainers(psOutput: psOutput, statsOutput: statsOutput, timestamp: timestamp)
        } catch {
            if isCancellation(error) {
                var stats = fallback ?? DockerStats()
                stats.timestamp = timestamp
                return stats
            }
            return DockerStats(
                availability: .unavailable(error.localizedDescription),
                containers: [],
                timestamp: timestamp
            )
        }
    }

    func parseContainers(psOutput: String, statsOutput: String, timestamp: Date = Date()) -> DockerStats {
        let psRows = parseJSONLines(psOutput, as: DockerPSRow.self)
        let statsRows = parseJSONLines(statsOutput, as: DockerStatsRow.self)
        let statsByKey = makeStatsLookup(statsRows)

        var seenPSKeys = Set<String>()
        var containers: [DockerContainer] = []
        for row in psRows {
            let keys = containerKeys(for: row)
            guard keys.allSatisfy({ !seenPSKeys.contains($0) }) else { continue }
            seenPSKeys.formUnion(keys)
            containers.append(makeContainer(row: row, stats: stats(for: row, in: statsByKey)))
        }

        var existingKeys = Set(containers.flatMap { container in
            [
                container.id.lowercased(),
                container.shortID.lowercased(),
                container.name.lowercased()
            ]
        })

        for row in statsRows {
            let candidateKeys = [row.container, row.id, row.name]
                .compactMap { $0?.trimmedNonEmpty?.lowercased() }
            guard candidateKeys.allSatisfy({ !existingKeys.contains($0) }) else { continue }
            let container = makeContainer(stats: row)
            containers.append(container)
            existingKeys.formUnion(candidateKeys)
            existingKeys.insert(container.id.lowercased())
            existingKeys.insert(container.shortID.lowercased())
            existingKeys.insert(container.name.lowercased())
        }

        return DockerStats(
            availability: .available,
            containers: containers.sorted { lhs, rhs in
                if lhs.isRunning == rhs.isRunning {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.isRunning && !rhs.isRunning
            },
            timestamp: timestamp
        )
    }

    func parseSize(_ rawValue: String) -> UInt64? {
        let cleaned = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }

        let numberPrefix = cleaned.prefix { character in
            character.isNumber || character == "."
        }
        guard let value = Double(numberPrefix), value.isFinite else { return nil }

        let unit = cleaned.dropFirst(numberPrefix.count).lowercased()
        let multiplier: Double
        switch unit {
        case "b", "byte", "bytes", "":
            multiplier = 1
        case "kb":
            multiplier = 1_000
        case "kib", "k":
            multiplier = 1_024
        case "mb":
            multiplier = 1_000_000
        case "mib", "m":
            multiplier = 1_048_576
        case "gb":
            multiplier = 1_000_000_000
        case "gib", "g":
            multiplier = 1_073_741_824
        case "tb":
            multiplier = 1_000_000_000_000
        case "tib", "t":
            multiplier = 1_099_511_627_776
        default:
            return nil
        }

        return UInt64(max(value * multiplier, 0))
    }

    func psCommands(platform: RemotePlatform, environment: RemoteEnvironment, limit: Int?) -> [String] {
        if let limit {
            return [
                psCommand(platform: platform, environment: environment, limit: nil, allContainers: false),
                psCommand(platform: platform, environment: environment, limit: limit, allContainers: true)
            ]
        }
        return [
            psCommand(platform: platform, environment: environment, limit: nil, allContainers: true)
        ]
    }

    func psCommand(
        platform: RemotePlatform,
        environment: RemoteEnvironment,
        limit: Int?,
        allContainers: Bool
    ) -> String {
        var parts = ["docker", "ps"]
        if allContainers {
            parts.append("-a")
        }
        parts.append("--no-trunc")
        if let limit {
            parts.append(contentsOf: ["--last", "\(limit)"])
        }
        parts.append(contentsOf: ["--format", dockerFormatArgument(platform: platform, environment: environment), "2>&1"])
        return parts.joined(separator: " ")
    }

    func statsCommand(platform: RemotePlatform, environment: RemoteEnvironment, containerIDs: [String]) -> String {
        let ids = containerIDs.map(safeContainerArgument).joined(separator: " ")
        return "docker stats --no-stream --format \(dockerFormatArgument(platform: platform, environment: environment)) \(ids) 2>&1"
    }

    func actionCommand(_ action: DockerContainerAction, container: DockerContainer) throws -> String {
        let id = safeContainerArgument(container.id)
        guard !id.isEmpty else {
            throw DockerControlError.missingContainerID
        }
        switch action {
        case .start:
            return "docker start \(id) 2>&1"
        case .stop:
            return "docker stop \(id) 2>&1"
        case .restart:
            return "docker restart \(id) 2>&1"
        }
    }

    func perform(
        _ action: DockerContainerAction,
        container: DockerContainer,
        client: SSHClient,
        platform: RemotePlatform
    ) async throws {
        let environment = await client.remoteEnvironment()
        let command = try actionCommand(action, container: container)
        let output: String
        do {
            output = try await executeDockerCommand(
                command,
                client: client,
                platform: platform,
                environment: environment,
                timeout: actionTimeout
            )
        } catch {
            if isCancellation(error) {
                throw CancellationError()
            }
            throw error
        }

        if let availability = unavailableState(from: output) {
            throw DockerControlError.commandFailed(availability.message)
        }

        let lowercased = output.lowercased()
        if lowercased.contains("error response from daemon")
            || lowercased.hasPrefix("error:")
            || lowercased.contains("no such container") {
            throw DockerControlError.commandFailed(output.firstLine)
        }
    }

    func shellCommand(
        for dockerCommand: String,
        platform: RemotePlatform,
        environment: RemoteEnvironment
    ) -> String {
        switch dockerShell(platform: platform, environment: environment) {
        case .cmd:
            return RemoteTerminalBootstrap.wrapCmdExecCommand(dockerCommand)
        case .posix, .powershell:
            return dockerCommand
        }
    }

    private func collectContainerList(
        client: SSHClient,
        platform: RemotePlatform,
        environment: RemoteEnvironment,
        limit: Int?
    ) async throws -> String {
        var outputs: [String] = []
        var lastError: Error?

        for command in psCommands(platform: platform, environment: environment, limit: limit) {
            do {
                let output = try await executeDockerCommand(
                    command,
                    client: client,
                    platform: platform,
                    environment: environment,
                    timeout: collectionTimeout
                )
                outputs.append(output)
            } catch {
                if isCancellation(error) {
                    throw CancellationError()
                }
                lastError = error
            }
        }

        if outputs.isEmpty, let lastError {
            throw lastError
        }
        return outputs.joined(separator: "\n")
    }

    private func executeDockerCommand(
        _ command: String,
        client: SSHClient,
        platform: RemotePlatform,
        environment: RemoteEnvironment,
        timeout: Duration
    ) async throws -> String {
        try await client.execute(
            shellCommand(for: command, platform: platform, environment: environment),
            timeout: timeout
        )
    }

    private func dockerFormatArgument(platform: RemotePlatform, environment: RemoteEnvironment) -> String {
        switch dockerShell(platform: platform, environment: environment) {
        case .cmd:
            return "\"{{json .}}\""
        case .posix, .powershell:
            return "'{{json .}}'"
        }
    }

    private func dockerShell(platform: RemotePlatform, environment: RemoteEnvironment) -> DockerShell {
        guard platform == .windows || environment.platform == .windows else {
            return .posix
        }

        switch environment.shellProfile.family {
        case .cmd, .unknown:
            return .cmd
        case .powershell:
            return .powershell
        case .posix:
            return .posix
        }
    }

    private func safeContainerArgument(_ id: String) -> String {
        id.filter { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as NSError).domain == "Swift.CancellationError"
    }

    private func unavailableState(from output: String) -> DockerAvailability? {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let lowercased = cleaned.lowercased()
        if lowercased.contains("command not found")
            || lowercased.contains("not recognized as")
            || lowercased.contains("the term 'docker' is not recognized")
            || lowercased.contains("the term \"docker\" is not recognized")
            || lowercased.contains("no such file or directory") {
            return .commandMissing
        }

        if lowercased.contains("permission denied")
            || lowercased.contains("got permission denied")
            || lowercased.contains("access is denied") {
            return .permissionDenied(cleaned.firstLine)
        }

        if lowercased.contains("cannot connect to the docker daemon")
            || lowercased.contains("is the docker daemon running")
            || lowercased.contains("error during connect")
            || lowercased.contains("docker daemon is not running") {
            return .daemonUnavailable(cleaned.firstLine)
        }

        if lowercased.hasPrefix("error response from daemon")
            || lowercased.hasPrefix("error:") {
            return .unavailable(cleaned.firstLine)
        }

        return nil
    }

    private func containerKeys(for row: DockerPSRow) -> Set<String> {
        Set([
            row.id,
            row.id.map { String($0.prefix(12)) },
            row.names
        ].compactMap { $0?.trimmedNonEmpty?.lowercased() })
    }

    private func parseJSONLines<T: Decodable>(_ output: String, as type: T.Type) -> [T] {
        let decoder = JSONDecoder()
        return output
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
                return try? decoder.decode(T.self, from: Data(trimmed.utf8))
            }
    }

    private func makeStatsLookup(_ rows: [DockerStatsRow]) -> [String: DockerStatsRow] {
        var result: [String: DockerStatsRow] = [:]
        for row in rows {
            for key in [row.container, row.id, row.name] {
                if let key = key?.trimmedNonEmpty?.lowercased() {
                    result[key] = row
                }
            }
        }
        return result
    }

    private func stats(for row: DockerPSRow, in lookup: [String: DockerStatsRow]) -> DockerStatsRow? {
        let keys = [
            row.id,
            row.id.map { String($0.prefix(12)) },
            row.names
        ]

        for key in keys.compactMap({ $0?.trimmedNonEmpty?.lowercased() }) {
            if let stats = lookup[key] {
                return stats
            }
        }

        return nil
    }

    private func makeContainer(row: DockerPSRow, stats: DockerStatsRow?) -> DockerContainer {
        let memory = parsePair(stats?.memoryUsage)
        let network = parsePair(stats?.networkIO)
        let block = parsePair(stats?.blockIO)

        return DockerContainer(
            id: row.id?.trimmedNonEmpty ?? stats?.container?.trimmedNonEmpty ?? UUID().uuidString,
            name: normalizedName(row.names ?? stats?.name ?? ""),
            image: row.image?.trimmedNonEmpty ?? "",
            command: row.command?.trimmedNonEmpty ?? "",
            state: DockerContainerState(rawState: row.state ?? ""),
            status: row.status?.trimmedNonEmpty ?? "",
            health: DockerHealthStatus(statusText: row.status ?? ""),
            createdAt: row.createdAt?.trimmedNonEmpty ?? "",
            runningFor: row.runningFor?.trimmedNonEmpty ?? "",
            ports: row.ports?.trimmedNonEmpty ?? "",
            cpuPercent: parsePercent(stats?.cpuPercent) ?? 0,
            memoryPercent: parsePercent(stats?.memoryPercent) ?? 0,
            memoryUsed: memory?.0,
            memoryLimit: memory?.1,
            networkRx: network?.0,
            networkTx: network?.1,
            blockRead: block?.0,
            blockWrite: block?.1,
            pids: Int(stats?.pids?.trimmedNonEmpty ?? "")
        )
    }

    private func makeContainer(stats row: DockerStatsRow) -> DockerContainer {
        let memory = parsePair(row.memoryUsage)
        let network = parsePair(row.networkIO)
        let block = parsePair(row.blockIO)
        let id = row.container?.trimmedNonEmpty ?? row.id?.trimmedNonEmpty ?? UUID().uuidString

        return DockerContainer(
            id: id,
            name: normalizedName(row.name ?? id),
            image: "",
            command: "",
            state: .running,
            status: String(localized: "Running"),
            health: .none,
            createdAt: "",
            runningFor: "",
            ports: "",
            cpuPercent: parsePercent(row.cpuPercent) ?? 0,
            memoryPercent: parsePercent(row.memoryPercent) ?? 0,
            memoryUsed: memory?.0,
            memoryLimit: memory?.1,
            networkRx: network?.0,
            networkTx: network?.1,
            blockRead: block?.0,
            blockWrite: block?.1,
            pids: Int(row.pids?.trimmedNonEmpty ?? "")
        )
    }

    private func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
    }

    private func parsePercent(_ value: String?) -> Double? {
        guard let value else { return nil }
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Double(cleaned)
    }

    private func parsePair(_ value: String?) -> (UInt64, UInt64)? {
        guard let value else { return nil }
        let parts = value.components(separatedBy: "/")
        guard parts.count >= 2,
              let first = parseSize(parts[0]),
              let second = parseSize(parts[1]) else {
            return nil
        }
        return (first, second)
    }
}

private enum DockerShell {
    case posix
    case powershell
    case cmd
}

private enum DockerControlError: LocalizedError {
    case missingContainerID
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingContainerID:
            return String(localized: "Container ID is missing.")
        case .commandFailed(let message):
            return message.isEmpty ? String(localized: "Docker command failed.") : message
        }
    }
}

private struct DockerPSRow: Decodable {
    let id: String?
    let names: String?
    let image: String?
    let command: String?
    let createdAt: String?
    let runningFor: String?
    let ports: String?
    let status: String?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case names = "Names"
        case image = "Image"
        case command = "Command"
        case createdAt = "CreatedAt"
        case runningFor = "RunningFor"
        case ports = "Ports"
        case status = "Status"
        case state = "State"
    }
}

private struct DockerStatsRow: Decodable {
    let blockIO: String?
    let container: String?
    let cpuPercent: String?
    let id: String?
    let memoryPercent: String?
    let memoryUsage: String?
    let name: String?
    let networkIO: String?
    let pids: String?

    enum CodingKeys: String, CodingKey {
        case blockIO = "BlockIO"
        case container = "Container"
        case cpuPercent = "CPUPerc"
        case id = "ID"
        case memoryPercent = "MemPerc"
        case memoryUsage = "MemUsage"
        case name = "Name"
        case networkIO = "NetIO"
        case pids = "PIDs"
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var firstLine: String {
        components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? self
    }
}
