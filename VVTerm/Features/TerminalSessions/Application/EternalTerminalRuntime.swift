import ETBootstrap
import ETSession
import Foundation
import os.log

nonisolated enum EternalTerminalStatePolicy {
    static func connectionState(
        for state: ETConnectionState,
        host: String,
        port: Int
    ) -> ConnectionState? {
        switch state {
        case .idle:
            return nil
        case .bootstrapping, .connecting:
            return .connecting
        case .connected:
            return .connected
        case .disconnected, .reconnecting:
            // swift-et owns recovery. Publishing `.disconnected` here would make
            // VVTerm replace a session that is already reconnecting itself.
            return .reconnecting(attempt: 1)
        case .failed(let error):
            return .failed(EternalTerminalErrorPresentation.message(
                for: error,
                host: host,
                port: port
            ))
        case .closed:
            return .disconnected
        }
    }
}

nonisolated enum EternalTerminalErrorPresentation {
    static func message(for error: Error, host: String, port: Int) -> String {
        if let bootstrapError = error as? ETBootstrapError {
            switch bootstrapError {
            case .sshFailed:
                return String(localized: "Eternal Terminal could not start through SSH. Verify the SSH credentials and that etterminal is installed on the host.")
            case .markerNotFound(let excerpt):
                let excerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !excerpt.isEmpty else {
                    return String(localized: "etterminal did not return valid connection details. Verify the Eternal Terminal installation on the host.")
                }
                return String(
                    format: String(localized: "etterminal did not return valid connection details. Host response: %@"),
                    excerpt
                )
            case .malformedCredentials:
                return String(localized: "etterminal returned malformed connection details. Update Eternal Terminal on the host and try again.")
            }
        }

        guard let clientError = error as? ETClientError else {
            return String(localized: "Eternal Terminal could not connect. Verify etserver is running and the configured ET port is reachable.")
        }

        switch clientError {
        case .transportFailure:
            return String(
                format: String(localized: "Could not reach etserver at %@:%d. Verify etserver is running and TCP port %d is open."),
                host,
                port,
                port
            )
        case .invalidKey:
            return String(localized: "etserver rejected the session key. Reconnect to start a new Eternal Terminal session.")
        case .mismatchedProtocol:
            return String(localized: "The Eternal Terminal client and server protocol versions do not match. Update Eternal Terminal on the host.")
        case .disconnectedBufferFull:
            return String(localized: "Eternal Terminal could not buffer more input while offline. Reconnect and try again.")
        case .connectionInProgress:
            return String(localized: "An Eternal Terminal connection is already starting.")
        case .connectionClosed:
            return String(localized: "The Eternal Terminal session closed. Reconnect to start a new session.")
        case .sessionUnrecoverable:
            return String(localized: "The Eternal Terminal session can no longer recover. Reconnect to start a new session.")
        case .invalidPasskeyLength, .unexpectedConnectStatus, .initializationFailed,
             .malformedFrame, .invalidTerminalSize, .invalidTerminalPixels,
             .invalidTunnelSpecification, .forwardingFailure:
            return String(localized: "Eternal Terminal could not establish the session. Verify the server installation and try again.")
        }
    }

    static func analyticsCategory(for error: Error) -> String {
        if error is ETBootstrapError { return "bootstrap" }
        guard let clientError = error as? ETClientError else { return "unknown" }
        switch clientError {
        case .transportFailure: return "network"
        case .invalidKey: return "authentication"
        case .mismatchedProtocol: return "protocol"
        case .disconnectedBufferFull: return "buffer"
        case .connectionInProgress, .connectionClosed: return "lifecycle"
        case .sessionUnrecoverable: return "recovery"
        case .invalidPasskeyLength, .unexpectedConnectStatus, .initializationFailed,
             .malformedFrame, .invalidTerminalSize, .invalidTerminalPixels,
             .invalidTunnelSpecification, .forwardingFailure:
            return "client"
        }
    }
}

@MainActor
final class EternalTerminalRuntime {
    let paneId: UUID
    let identityToken = UUID()

    private let server: Server
    private let bootstrapExecutor: SSHETBootstrapExecutor
    private let session: ETTerminalSession
    private weak var terminal: GhosttyTerminalView?
    private var outputTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var reconnectEventActive = false
    private var failureReported = false
    private var hasTrackedSuccess = false
    private var startupApplied = false
    private var tmuxLifecycle: TmuxShellLifecycleContext?
    private var tmuxLifecycleParser: TmuxLifecycleStreamParser?
    private var lastTerminalSize: (cols: Int, rows: Int) = (0, 0)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VVTerm",
        category: "EternalTerminal"
    )

    init(paneId: UUID, server: Server, credentials: ServerCredentials) {
        self.paneId = paneId
        self.server = server
        let runtimeToken = identityToken
        let executor = SSHETBootstrapExecutor(
            server: server,
            credentials: credentials,
            startupPlanProvider: { client in
                try await TerminalTabManager.shared.eternalTerminalTmuxStartupPlan(
                    for: paneId,
                    serverId: server.id,
                    client: client,
                    runtimeToken: runtimeToken
                )
            }
        )
        bootstrapExecutor = executor
        session = ETTerminalSession(
            host: server.host,
            port: UInt16(exactly: server.eternalTerminalPort) ?? 2022,
            bootstrapExecutor: executor
        )
    }

    var isStartInFlight: Bool { connectTask != nil }

    func attach(to terminal: GhosttyTerminalView) {
        self.terminal = terminal
    }

    func startIfNeeded() {
        guard connectTask == nil, stateTask == nil else { return }

        let paneId = paneId
        let session = session
        let host = server.host
        let port = server.eternalTerminalPort

        AnalyticsTracker.shared.trackConnectionAttempted(transport: ShellTransport.eternalTerminal.rawValue)

        outputTask = Task { [weak self] in
            for await data in session.output {
                guard !Task.isCancelled else { return }
                self?.consumeOutput(data)
            }
        }

        stateTask = Task { [weak self] in
            for await state in session.stateChanges {
                guard !Task.isCancelled, let self else { return }
                self.handle(state, host: host, port: port)
            }
        }

        connectTask = Task { [weak self] in
            do {
                try await session.connect()
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.publishFailure(error, host: host, port: port)
            }
            self?.connectTask = nil
        }

        TerminalTabManager.shared.markEternalTerminalTransport(for: paneId)
    }

    func send(_ data: Data) {
        let session = session
        Task(priority: .userInitiated) { [logger] in
            do {
                try await session.send(data)
            } catch {
                logger.warning("Failed to send ET input: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func sendInteractiveScript(_ script: String) async throws {
        let payload = script.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        try await session.send(data)
    }

    func withBootstrapSSHClient<Result: Sendable>(
        _ operation: @Sendable (SSHClient) async throws -> Result
    ) async throws -> Result {
        try await bootstrapExecutor.withConnectedClient(operation)
    }

    func killManagedTmuxSession(named sessionName: String) async {
        do {
            try await withBootstrapSSHClient { client in
                await RemoteTmuxManager.shared.killSession(named: sessionName, using: client)
            }
        } catch {
            logger.warning("Failed to clean up ET tmux session: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard (cols, rows) != lastTerminalSize else { return }
        lastTerminalSize = (cols, rows)
        let session = session
        Task(priority: .userInitiated) { [logger] in
            do {
                try await session.resize(rows: rows, cols: cols)
            } catch {
                logger.debug("Ignored ET resize before connection: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func notifyNetworkPathChanged() {
        let session = session
        Task { await session.notifyNetworkPathChanged() }
    }

    func close() async {
        connectTask?.cancel()
        outputTask?.cancel()
        stateTask?.cancel()
        connectTask = nil
        outputTask = nil
        stateTask = nil
        terminal = nil
        await session.close()
    }

    private func handle(_ state: ETConnectionState, host: String, port: Int) {
        if state == .reconnecting || state == .disconnected {
            if !reconnectEventActive {
                reconnectEventActive = true
                AnalyticsTracker.shared.trackConnectionReconnecting(
                    transport: ShellTransport.eternalTerminal.rawValue
                )
            }
        } else if state == .connected {
            reconnectEventActive = false
            if !hasTrackedSuccess {
                hasTrackedSuccess = true
                AnalyticsTracker.shared.trackConnectionSucceeded(
                    transport: ShellTransport.eternalTerminal.rawValue
                )
            }
            applyStartupPlanIfNeeded()
        }

        if case .failed(let error) = state {
            publishFailure(error, host: host, port: port)
            return
        }

        guard let connectionState = EternalTerminalStatePolicy.connectionState(
            for: state,
            host: host,
            port: port
        ) else { return }
        TerminalTabManager.shared.updatePaneState(paneId, connectionState: connectionState)
        TerminalTabManager.shared.markEternalTerminalTransport(for: paneId)
    }

    private func applyStartupPlanIfNeeded() {
        guard !startupApplied else { return }
        startupApplied = true
        let executor = bootstrapExecutor
        let session = session
        Task { [weak self] in
            let plan = await executor.preparedStartupPlan()
            guard let self else { return }
            tmuxLifecycle = plan.tmuxLifecycle
            tmuxLifecycleParser = plan.tmuxLifecycle.map {
                TmuxLifecycleStreamParser(markerToken: $0.markerToken)
            }
            guard let command = plan.command,
                  let data = "\(command)\r".data(using: .utf8) else { return }
            do {
                try await session.send(data)
            } catch {
                publishFailure(error, host: server.host, port: server.eternalTerminalPort)
            }
        }
    }

    private func consumeOutput(_ data: Data) {
        guard var parser = tmuxLifecycleParser else {
            terminal?.feedData(data)
            return
        }
        let result = parser.consume(data)
        tmuxLifecycleParser = parser
        if !result.output.isEmpty {
            terminal?.feedData(result.output)
        }
        guard let event = result.events.last, let tmuxLifecycle else { return }
        let reason: TerminalShellEndReason
        switch event {
        case .detached:
            reason = .tmuxDetached(tmuxLifecycle.ownership)
        case .ended:
            reason = .tmuxEnded(tmuxLifecycle.ownership)
        case .creationFailed:
            reason = .tmuxCreationFailed
        }
        TerminalTabManager.shared.handleShellEnd(for: paneId, reason: reason)
        Task { await TerminalTabManager.shared.unregisterEternalTerminalRuntime(for: paneId) }
    }

    private func publishFailure(_ error: Error, host: String, port: Int) {
        if !failureReported {
            failureReported = true
            AnalyticsTracker.shared.trackConnectionFailed(
                transport: ShellTransport.eternalTerminal.rawValue,
                reason: EternalTerminalErrorPresentation.analyticsCategory(for: error)
            )
        }
        TerminalTabManager.shared.updatePaneState(
            paneId,
            connectionState: .failed(EternalTerminalErrorPresentation.message(
                for: error,
                host: host,
                port: port
            ))
        )
        TerminalTabManager.shared.markEternalTerminalTransport(for: paneId)
    }
}
