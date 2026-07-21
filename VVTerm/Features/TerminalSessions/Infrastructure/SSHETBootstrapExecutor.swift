import ETBootstrap
import Foundation

/// Runs swift-et's SSH bootstrap and auxiliary remote operations through VVTerm's SSH stack.
actor SSHETBootstrapExecutor: ETBootstrapExecutor {
    private let client: SSHClient
    private let connection: Connection?
    private let startupPlanProvider: (@Sendable (SSHClient) async throws -> TerminalShellStartupPlan)?
    private var startupPlan: TerminalShellStartupPlan = .plainShell

    private struct Connection: Sendable {
        let server: Server
        let credentials: ServerCredentials
    }

    init(
        server: Server,
        credentials: ServerCredentials,
        startupPlanProvider: (@Sendable (SSHClient) async throws -> TerminalShellStartupPlan)? = nil
    ) {
        client = SSHClient()
        connection = Connection(server: server, credentials: credentials)
        self.startupPlanProvider = startupPlanProvider
    }

    /// Used while a caller already owns the temporary SSH connection lifecycle.
    init(connectedClient: SSHClient) {
        client = connectedClient
        connection = nil
        startupPlanProvider = nil
    }

    func preparedStartupPlan() -> TerminalShellStartupPlan {
        startupPlan
    }

    func run(command: String) async throws -> String {
        let command = Self.commandCapturingCombinedOutput(command)
        guard let connection else {
            return try await client.execute(command, timeout: .seconds(20))
        }

        do {
            _ = try await client.connect(
                to: connection.server,
                credentials: connection.credentials
            )
            if let startupPlanProvider {
                startupPlan = try await startupPlanProvider(client)
            }
            let output = try await client.execute(command, timeout: .seconds(20))
            await client.disconnect()
            return output
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// ETBootstrap parses credentials written by etterminal's logging stream.
    /// SSHClient intentionally returns stdout only, so merge stderr for this command.
    nonisolated static func commandCapturingCombinedOutput(_ command: String) -> String {
        "(\(command)) 2>&1"
    }

    func withConnectedClient<Result: Sendable>(
        _ operation: @Sendable (SSHClient) async throws -> Result
    ) async throws -> Result {
        guard let connection else {
            return try await operation(client)
        }
        return try await withConnectedClient(connection: connection, operation)
    }

    private func withConnectedClient<Result: Sendable>(
        connection: Connection,
        _ operation: @Sendable (SSHClient) async throws -> Result
    ) async throws -> Result {
        do {
            _ = try await client.connect(
                to: connection.server,
                credentials: connection.credentials
            )
            let result = try await operation(client)
            await client.disconnect()
            return result
        } catch {
            await client.disconnect()
            throw error
        }
    }
}
