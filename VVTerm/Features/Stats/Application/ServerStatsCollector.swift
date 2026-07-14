import Foundation
import Combine
import os.log

// MARK: - Server Stats Collector

/// Main stats collector that uses a shared SSH connection when available
@MainActor
final class ServerStatsCollector: ObservableObject {
    @Published var stats = ServerStats()
    @Published var cpuHistory: [StatsPoint] = []
    @Published var memoryHistory: [StatsPoint] = []
    @Published var networkRxHistory: [StatsPoint] = []
    @Published var networkTxHistory: [StatsPoint] = []
    @Published var gpuUtilizationHistoryByDeviceID: [String: [StatsPoint]] = [:]
    @Published var dockerCPUHistory: [StatsPoint] = []
    @Published var dockerMemoryHistory: [StatsPoint] = []
    @Published var isCollecting = false
    @Published var connectionError: String?

    private var collectTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "Stats")

    // Own SSH client for stats collection
    private var sshClient: SSHClient?
    private var ownsClient = false

    // Platform detection and collector
    private var remotePlatform: RemotePlatform = .unknown
    private var platformCollector: PlatformStatsCollector?
    private let dockerCollector = DockerStatsCollector()
    private let context = StatsCollectionContext()
    private var hardwareProfile: HardwareProfile = .empty
    private var isDockerCollectionEnabled = false

    // MARK: - Collection Control

    func startCollecting(
        for server: Server,
        using sharedClient: SSHClient? = nil,
        collectDocker: Bool = false
    ) async {
        guard !isCollecting else {
            isDockerCollectionEnabled = collectDocker
            return
        }
        isCollecting = true
        isDockerCollectionEnabled = collectDocker
        connectionError = nil
        resetCollectionState()

        // Use shared client if available, otherwise create one
        let client: SSHClient
        let ownsClient: Bool
        if let sharedClient {
            client = sharedClient
            ownsClient = false
        } else {
            client = SSHClient()
            ownsClient = true
        }
        configureConnectionState(client: client, ownsClient: ownsClient)

        // Get credentials
        let credentials: ServerCredentials
        do {
            credentials = try KeychainManager.shared.getCredentials(for: server)
        } catch {
            finishCollection(withError: "No credentials found")
            return
        }

        // Connect in background
        collectTask = Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }

            do {
                try await SSHConnectionOperationService.shared.runWithConnection(
                    using: client,
                    server: server,
                    credentials: credentials,
                    disconnectWhenDone: ownsClient
                ) { connectedClient in
                    await MainActor.run {
                        self.connectionError = nil
                    }

                    while !Task.isCancelled {
                        let shouldContinue = await MainActor.run { self.isCollecting }
                        guard shouldContinue else { break }

                        await self.collectStats(client: connectedClient)
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            } catch {
                await MainActor.run {
                    self.finishCollection(withError: error.localizedDescription)
                }
            }
            await MainActor.run { [weak self] in
                self?.finishCollection()
            }
        }
    }

    func stopCollecting() {
        isCollecting = false
        collectTask?.cancel()
        collectTask = nil

        // Disconnect SSH only if we own the connection
        if ownsClient, let client = sshClient {
            Task.detached {
                await client.disconnect()
            }
        }
        clearConnectionState()
    }

    func terminateProcess(_ process: ProcessInfo) async throws {
        guard process.pid > 1 else {
            throw ProcessControlError.protectedProcess
        }

        guard let client = sshClient else {
            throw ProcessControlError.notConnected
        }

        let command: String
        switch remotePlatform {
        case .windows:
            command = "taskkill /PID \(process.pid) /T /F"
        case .linux, .darwin, .freebsd, .openbsd, .netbsd, .unknown:
            command = "kill -TERM \(process.pid)"
        }

        _ = try await client.execute(command, timeout: .seconds(5))
        await collectStats(client: client)
    }

    func loadProcesses() async throws -> [ProcessInfo] {
        guard let client = sshClient else {
            throw ProcessControlError.notConnected
        }
        guard let platformCollector else {
            return stats.topProcesses
        }

        let processes = try await platformCollector.collectProcesses(client: client, context: context)
        return processes.isEmpty ? stats.topProcesses : processes
    }

    func loadDockerStats() async throws -> DockerStats {
        guard let client = sshClient else {
            throw ProcessControlError.notConnected
        }
        let dockerStats = await dockerCollector.collect(
            client: client,
            platform: remotePlatform,
            limit: nil,
            fallback: stats.docker
        )
        context.updateDockerStats(dockerStats, timestamp: dockerStats.timestamp)
        stats.docker = dockerStats
        return dockerStats
    }

    func performDockerAction(_ action: DockerContainerAction, on container: DockerContainer) async throws -> DockerStats {
        guard let client = sshClient else {
            throw ProcessControlError.notConnected
        }

        try await dockerCollector.perform(action, container: container, client: client, platform: remotePlatform)
        try? await Task.sleep(for: .milliseconds(500))
        let dockerStats = await dockerCollector.collect(
            client: client,
            platform: remotePlatform,
            limit: nil,
            fallback: stats.docker
        )
        context.updateDockerStats(dockerStats, timestamp: dockerStats.timestamp)
        stats.docker = dockerStats
        return dockerStats
    }

    // MARK: - Stats Collection

    private func collectStats(client: SSHClient) async {
        do {
            // Detect platform and create collector on first run
            if remotePlatform == .unknown {
                remotePlatform = await client.remotePlatform()
                platformCollector = remotePlatform.createCollector()

                logger.info("Detected remote platform: \(self.remotePlatform.rawValue)")

                // Get initial hardware profile. Individual platform collectors return
                // partial profiles when optional probes are unavailable.
                let profile = await self.collectInitialProfile(client: client)
                await MainActor.run {
                    self.applyProfile(profile)
                }
            }

            // Collect stats using platform-specific collector
            guard let collector = platformCollector else { return }

            var newStats = try await collector.collectStats(client: client, context: context)

            // Preserve system info
            let existingStats = await MainActor.run { self.stats }
            let collectedCpuCores = newStats.cpuCores
            newStats.hostname = existingStats.hostname
            newStats.osInfo = existingStats.osInfo
            newStats.cpuCores = Self.resolvedCPUCoreCount(
                existing: existingStats.cpuCores,
                collected: collectedCpuCores
            )
            newStats.hardware = existingStats.hardware
            if newStats.gpuSamples.isEmpty, !existingStats.gpuSamples.isEmpty {
                newStats.gpuSamples = existingStats.gpuSamples
            }
            if isDockerCollectionEnabled {
                newStats.docker = await self.collectDockerStatsIfNeeded(client: client, timestamp: newStats.timestamp)
            }

            // Update on main thread
            await MainActor.run {
                self.applyCollectedStats(newStats)
            }

        } catch {
            logger.error("Failed to collect stats: \(error.localizedDescription)")
            await MainActor.run {
                self.finishCollection(withError: error.localizedDescription)
            }
        }
    }

    private func resetCollectionState() {
        context.reset()
        remotePlatform = .unknown
        platformCollector = nil
        hardwareProfile = .empty
        cpuHistory = []
        memoryHistory = []
        networkRxHistory = []
        networkTxHistory = []
        gpuUtilizationHistoryByDeviceID = [:]
        dockerCPUHistory = []
        dockerMemoryHistory = []
    }

    private func collectInitialProfile(client: SSHClient) async -> HardwareProfile? {
        guard let platformCollector else { return nil }

        if let profile = try? await platformCollector.collectProfile(client: client) {
            return profile
        }

        if let systemInfo = try? await platformCollector.getSystemInfo(client: client) {
            return HardwareProfile(
                hostname: systemInfo.hostname,
                osInfo: systemInfo.osInfo,
                architecture: "",
                kernelVersion: "",
                cpuModel: "",
                cpuVendor: "",
                cpuCores: systemInfo.cpuCores,
                cpuThreads: systemInfo.cpuCores,
                memoryTotal: 0,
                gpus: [],
                collectedAt: Date()
            )
        }

        return nil
    }

    private func configureConnectionState(client: SSHClient, ownsClient: Bool) {
        self.sshClient = client
        self.ownsClient = ownsClient
    }

    private func clearConnectionState() {
        sshClient = nil
        ownsClient = false
    }

    private func finishCollection(withError error: String? = nil) {
        connectionError = error
        isCollecting = false
        clearConnectionState()
    }

    private func applyProfile(_ profile: HardwareProfile?) {
        hardwareProfile = profile ?? .empty
        stats.hardware = hardwareProfile
        stats.hostname = hardwareProfile.hostname
        stats.osInfo = hardwareProfile.osInfo
        let profileCPUCount = hardwareProfile.cpuThreads > 0 ? hardwareProfile.cpuThreads : hardwareProfile.cpuCores
        if profileCPUCount > 0 {
            stats.cpuCores = profileCPUCount
        }
        if stats.memoryTotal == 0 {
            stats.memoryTotal = hardwareProfile.memoryTotal
        }
    }

    private func applyCollectedStats(_ newStats: ServerStats) {
        stats = newStats

        cpuHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.cpuUsage))
        memoryHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.memoryPercent))
        networkRxHistory.append(StatsPoint(timestamp: newStats.timestamp, value: Double(newStats.networkRxSpeed)))
        networkTxHistory.append(StatsPoint(timestamp: newStats.timestamp, value: Double(newStats.networkTxSpeed)))
        dockerCPUHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.docker.aggregateCPUPercent))
        dockerMemoryHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.docker.memoryPercent))
        appendGPUHistory(from: newStats)

        if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        if memoryHistory.count > 60 { memoryHistory.removeFirst() }
        if networkRxHistory.count > 60 { networkRxHistory.removeFirst() }
        if networkTxHistory.count > 60 { networkTxHistory.removeFirst() }
        if dockerCPUHistory.count > 60 { dockerCPUHistory.removeFirst() }
        if dockerMemoryHistory.count > 60 { dockerMemoryHistory.removeFirst() }
    }

    private func collectDockerStatsIfNeeded(client: SSHClient, timestamp: Date) async -> DockerStats {
        guard context.shouldCollectDocker(now: timestamp) else {
            return context.getDockerStats()
        }

        let dockerStats = await dockerCollector.collect(
            client: client,
            platform: remotePlatform,
            limit: DockerStatsCollector.periodicContainerLimit,
            fallback: context.getDockerStats()
        )
        context.updateDockerStats(dockerStats, timestamp: timestamp)
        return dockerStats
    }

    private func appendGPUHistory(from newStats: ServerStats) {
        for sample in newStats.gpuSamples {
            guard let utilization = sample.utilizationPercent else { continue }
            var history = gpuUtilizationHistoryByDeviceID[sample.deviceID] ?? []
            history.append(StatsPoint(timestamp: newStats.timestamp, value: utilization))
            if history.count > 60 {
                history.removeFirst(history.count - 60)
            }
            gpuUtilizationHistoryByDeviceID[sample.deviceID] = history
        }
    }

    nonisolated static func resolvedCPUCoreCount(existing: Int, collected: Int) -> Int {
        if existing > 0, collected > 0 {
            return max(existing, collected)
        }
        if existing > 0 {
            return existing
        }
        return max(collected, 0)
    }
}

private enum ProcessControlError: LocalizedError {
    case notConnected
    case protectedProcess

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Stats is not connected to the server.")
        case .protectedProcess:
            return String(localized: "This process cannot be killed from Stats.")
        }
    }
}
