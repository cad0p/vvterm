import ETBootstrap
import Foundation

nonisolated enum EternalTerminalHostCompatibility: Equatable {
    case supported
    case unsupportedNativeWindows
    case unsupportedShell

    init(environment: RemoteEnvironment) {
        if environment.platform == .windows {
            self = .unsupportedNativeWindows
        } else if environment.shellProfile.supportsPOSIXExecWrapper {
            self = .supported
        } else {
            self = .unsupportedShell
        }
    }

    var bootstrapDiagnostic: String? {
        switch self {
        case .supported:
            nil
        case .unsupportedNativeWindows:
            "VVTERM_ET_UNSUPPORTED_NATIVE_WINDOWS"
        case .unsupportedShell:
            "VVTERM_ET_REQUIRES_POSIX_SHELL"
        }
    }
}

/// Runs swift-et's SSH bootstrap and auxiliary remote operations through VVTerm's SSH stack.
actor SSHETBootstrapExecutor: ETBootstrapExecutor {
    nonisolated static var bootstrapOptions: ETBootstrapOptions {
        ETBootstrapOptions(etterminalPath: "etterminal --logtostdout")
    }

    private let client: SSHClient
    private let connection: Connection?
    private let startupPlanProvider: (@Sendable (SSHClient) async throws -> TerminalShellStartupPlan)?
    private var startupPlan: TerminalShellStartupPlan = .plainShell
    private var terminalType = RemoteTerminalBootstrap.defaultTerminalType
    /// The SSH error behind the most recent failed bootstrap attempt, paired
    /// with the attempt generation that produced it.
    ///
    /// `ETBootstrap.run` collapses executor failures into
    /// `ETBootstrapError.sshFailed`, so the runtime cannot tell a transport
    /// failure from a host-key trust failure from the rethrown error alone.
    /// Retained here (and consumed by the failure path) to keep the
    /// classification and the user-facing trust affordance intact.
    private var lastBootstrapSSHError: (attempt: Int, error: SSHError)?
    /// Incremented once per `run(command:)` before the first suspension.
    ///
    /// `ETBootstrap.run` drives one executor for one bootstrap attempt, so a
    /// second concurrent `run` is not expected. The generation guards the
    /// retained-cause slot against actor reentrancy at the awaits inside
    /// `run(command:)` anyway: a failure from a superseded attempt is never
    /// reported as the cause of a newer one, and the newest failure is never
    /// masked by an older one.
    private var bootstrapAttempt = 0

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

    func preparedTerminalType() -> RemoteTerminalType {
        terminalType
    }

    func run(command: String) async throws -> String {
        bootstrapAttempt += 1
        let attempt = bootstrapAttempt
        lastBootstrapSSHError = nil
        let command = Self.remoteBootstrapCommand(command)
        guard let connection else {
            return try await client.execute(command, timeout: .seconds(20))
        }

        do {
            _ = try await client.connect(
                to: connection.server,
                credentials: connection.credentials
            )
            let compatibility = EternalTerminalHostCompatibility(
                environment: await client.remoteEnvironment()
            )
            if let diagnostic = compatibility.bootstrapDiagnostic {
                await client.disconnect()
                return diagnostic
            }
            terminalType = await client.remoteTerminalType()
            if let startupPlanProvider {
                startupPlan = try await startupPlanProvider(client)
            }
            let output = try await client.execute(command, timeout: .seconds(20))
            await client.disconnect()
            return output
        } catch {
            // Only retain the cause for the attempt that is still current: a
            // reentrant second run would otherwise leave this failure to be
            // consumed by the newer attempt's failure report.
            if bootstrapAttempt == attempt, let sshError = error as? SSHError {
                lastBootstrapSSHError = (attempt, sshError)
            }
            await client.disconnect()
            throw error
        }
    }

    /// Consume the SSH error retained from the most recent bootstrap failure
    /// (nil when the failure was not an SSH error, or when a newer attempt
    /// has started since). One-shot: the next `run(command:)` clears it.
    ///
    /// Retention happens on the fresh-bootstrap path (`connection != nil`),
    /// which is the one the ET runtime uses; a `connectedClient` session that
    /// fails surfaces its `SSHError` directly and is not retained. The
    /// preference for this cause lives in
    /// `EternalTerminalRuntime.classifiedConnectionError` (unit-tested);
    /// exercising `run(command:)` itself needs a live connect, so the
    /// retention path stays covered only by the runtime integration.
    func consumeLastBootstrapSSHError() -> SSHError? {
        defer { lastBootstrapSSHError = nil }
        guard let lastBootstrapSSHError, lastBootstrapSSHError.attempt == bootstrapAttempt else {
            return nil
        }
        return lastBootstrapSSHError.error
    }

    /// Use a known POSIX shell even when the account's login shell is fish, and
    /// make common package-manager locations available to non-interactive SSH.
    nonisolated static func remoteBootstrapCommand(_ command: String) -> String {
        let script = """
        \(RemoteTerminalBootstrap.shellPathExport());
        if ! command -v etterminal >/dev/null 2>&1; then
          printf 'etterminal was not found in the remote PATH';
          exit 127;
        fi;
        \(command)
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
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
