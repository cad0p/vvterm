#if os(macOS)
import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
struct SSHStartupIntegrationTests {
    private struct Configuration {
        let host: String
        let port: Int
        let username: String
        let privateKey: Data

        static func fromEnvironment() throws -> Configuration? {
            let environment = ProcessInfo.processInfo.environment
            guard environment["VVTERM_SSH_INTEGRATION"] == "1" else { return nil }
            guard let keyPath = environment["VVTERM_SSH_PRIVATE_KEY_PATH"] else {
                throw IntegrationError.missingEnvironment("VVTERM_SSH_PRIVATE_KEY_PATH")
            }
            guard let port = Int(environment["VVTERM_SSH_PORT"] ?? "22"),
                  (1...65_535).contains(port) else {
                throw IntegrationError.invalidPort
            }
            return try Configuration(
                host: environment["VVTERM_SSH_HOST"] ?? "127.0.0.1",
                port: port,
                username: environment["VVTERM_SSH_USERNAME"] ?? NSUserName(),
                privateKey: Data(contentsOf: URL(fileURLWithPath: keyPath))
            )
        }

        func withPort(_ port: Int) -> Configuration {
            Configuration(host: host, port: port, username: username, privateKey: privateKey)
        }
    }

    private struct StartupResult {
        let transport: ShellTransport
        let fallbackReason: MoshFallbackReason?
        let elapsedMilliseconds: Int
    }

    private enum IntegrationError: Error {
        case invalidPort
        case missingEnvironment(String)
        case noTerminalData
    }

    @Test
    func sshAndMoshReachFirstTerminalByte() async throws {
        guard let configuration = try Configuration.fromEnvironment() else { return }

        let ssh = try await measureStartups(
            count: 6,
            configuration: configuration,
            mode: .standard
        )
        reportBenchmark(name: "ssh", results: ssh)
        #expect(ssh.allSatisfy { $0.transport == .ssh })

        let mosh = try await measureStartups(
            count: 6,
            configuration: configuration,
            mode: .mosh
        )
        reportBenchmark(name: "mosh", results: mosh)
        #expect(mosh.allSatisfy { $0.transport == .mosh })
    }

    @Test
    func missingMoshServerFallsBackWithExactReason() async throws {
        guard let configuration = try Configuration.fromEnvironment(),
              let port = integrationPort(named: "VVTERM_SSH_MISSING_MOSH_PORT") else { return }

        let result = try await measureStartup(
            configuration: configuration.withPort(port),
            mode: .mosh
        )
        #expect(result.transport == .sshFallback)
        #expect(result.fallbackReason == .serverMissing)
    }

    @Test
    func blockedMoshUDPFallsBackWithExactReason() async throws {
        guard let configuration = try Configuration.fromEnvironment(),
              let port = integrationPort(named: "VVTERM_SSH_BLOCKED_UDP_PORT") else { return }

        let result = try await measureStartup(
            configuration: configuration.withPort(port),
            mode: .mosh
        )
        #expect(result.transport == .sshFallback)
        #expect(result.fallbackReason == .udpTimeout)
    }

    private func measureStartup(
        configuration: Configuration,
        mode: SSHConnectionMode
    ) async throws -> StartupResult {
        let server = Server(
            workspaceId: UUID(),
            name: "DEV-209 integration",
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            connectionMode: mode,
            authMethod: .sshKey
        )
        let credentials = ServerCredentials(
            serverId: server.id,
            privateKey: configuration.privateKey
        )
        let client = SSHClient()
        let startedAt = ContinuousClock.now

        do {
            _ = try await client.connect(to: server, credentials: credentials)
            let shell = try await client.startShell(
                cols: 80,
                rows: 24,
                startupCommand: "printf '__VVTERM_DEV209_READY__\\n'; exec /bin/sh -l"
            )
            try await awaitFirstData(from: shell.stream)
            let elapsed = milliseconds(startedAt.duration(to: .now))
            await client.disconnect()
            return StartupResult(
                transport: shell.transport,
                fallbackReason: shell.fallbackReason,
                elapsedMilliseconds: elapsed
            )
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func measureStartups(
        count: Int,
        configuration: Configuration,
        mode: SSHConnectionMode
    ) async throws -> [StartupResult] {
        var results: [StartupResult] = []
        results.reserveCapacity(count)
        for _ in 0..<count {
            results.append(
                try await measureStartup(configuration: configuration, mode: mode)
            )
        }
        return results
    }

    private func reportBenchmark(name: String, results: [StartupResult]) {
        guard let cold = results.first else { return }
        let warm = results.dropFirst().map(\.elapsedMilliseconds).sorted()
        guard let slowTail = warm.last else { return }
        let median = warm[warm.count / 2]
        print(
            "DEV209 benchmark transport=\(name) coldMs=\(cold.elapsedMilliseconds) warmMedianMs=\(median) warmSlowTailMs=\(slowTail)"
        )
    }

    private func awaitFirstData(from stream: AsyncStream<Data>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await data in stream where !data.isEmpty {
                    return
                }
                throw IntegrationError.noTerminalData
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                throw SSHError.timeout
            }
            guard try await group.next() != nil else {
                throw IntegrationError.noTerminalData
            }
            group.cancelAll()
        }
    }

    private func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let value = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        guard value.isFinite, value > 0 else { return 0 }
        let rounded = value.rounded()
        guard rounded < Double(Int.max) else { return Int.max }
        return Int(rounded)
    }

    private func integrationPort(named name: String) -> Int? {
        guard let rawValue = ProcessInfo.processInfo.environment[name],
              let port = Int(rawValue),
              (1...65_535).contains(port) else { return nil }
        return port
    }
}
#endif
