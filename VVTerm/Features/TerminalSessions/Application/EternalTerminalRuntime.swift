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
        if error is EternalTerminalResumeCredentialError {
            return error.localizedDescription
        }
        if let bootstrapError = error as? ETBootstrapError {
            return message(for: bootstrapError, host: host, port: port)
        }

        if let clientError = error as? ETClientError {
            return message(for: clientError, host: host, port: port)
        }

        return String(localized: "Eternal Terminal could not connect. Verify etserver is running and the configured ET port is reachable.")
    }

    static func message(for bootstrapError: ETBootstrapError, host: String, port: Int) -> String {
        switch bootstrapError {
        case .sshFailed:
            return String(localized: "Eternal Terminal could not start through SSH. Verify the SSH credentials and that etterminal is installed on the host.")
        case .markerNotFound(let excerpt):
            let excerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            if excerpt.contains("VVTERM_ET_UNSUPPORTED_NATIVE_WINDOWS") {
                return String(localized: "Eternal Terminal does not run as a native Windows PowerShell or Command Prompt service. Configure this SSH connection to open inside WSL with Eternal Terminal installed, or use SSH with psmux instead.")
            }
            if excerpt.contains("VVTERM_ET_REQUIRES_POSIX_SHELL") {
                return String(localized: "Eternal Terminal requires a POSIX login shell with /bin/sh. Configure this SSH connection to open a supported Linux, macOS, BSD, or WSL environment, then try again.")
            }
            if excerpt.localizedCaseInsensitiveContains("communicating with et daemon") {
                return String(localized: "Eternal Terminal is installed, but its server daemon is not running or uses a different socket. On Linux, run “sudo systemctl enable --now et”. On macOS with Homebrew, run “brew services start et”. Then try again. If it still fails, ensure etterminal and etserver use the same server FIFO.")
            }
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

    static func message(for clientError: ETClientError, host: String, port: Int) -> String {
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
        case .applicationSuspended:
            return String(localized: "Eternal Terminal input is paused while VVTerm is in the background.")
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
        return analyticsCategory(for: clientError)
    }

    static func analyticsCategory(for clientError: ETClientError) -> String {
        switch clientError {
        case .transportFailure: return "network"
        case .invalidKey: return "authentication"
        case .mismatchedProtocol: return "protocol"
        case .disconnectedBufferFull: return "buffer"
        case .connectionInProgress, .connectionClosed, .applicationSuspended: return "lifecycle"
        case .sessionUnrecoverable: return "recovery"
        case .invalidPasskeyLength, .unexpectedConnectStatus, .initializationFailed,
             .malformedFrame, .invalidTerminalSize, .invalidTerminalPixels,
             .invalidTunnelSpecification, .forwardingFailure:
            return "client"
        }
    }
}

nonisolated enum EternalTerminalStartupCommand {
    static func remoteScriptPath(token: UUID) -> String {
        "/tmp/vvterm-et-start-\(token.uuidString.lowercased()).sh"
    }

    static func script(command: String, remotePath: String) -> String {
        """
        rm -f -- \(RemoteTerminalBootstrap.shellQuoted(remotePath))
        \(command)
        """
    }

    static func invocation(remotePath: String) -> String {
        "/bin/sh \(RemoteTerminalBootstrap.shellQuoted(remotePath))"
    }
}

nonisolated enum EternalTerminalResumePolicy {
    static func shouldDiscardCredentials(after error: Error) -> Bool {
        guard let clientError = error as? ETClientError else { return false }
        return shouldDiscardCredentials(after: clientError)
    }

    static func shouldDiscardCredentials(after clientError: ETClientError) -> Bool {
        return switch clientError {
        case .invalidKey, .connectionClosed, .sessionUnrecoverable:
            true
        case .invalidPasskeyLength, .mismatchedProtocol, .unexpectedConnectStatus,
             .initializationFailed, .malformedFrame, .transportFailure,
             .disconnectedBufferFull, .connectionInProgress, .applicationSuspended,
             .invalidTerminalSize,
             .invalidTerminalPixels, .invalidTunnelSpecification, .forwardingFailure:
            false
        }
    }
}

private enum EternalTerminalSessionOrigin: Equatable {
    case bootstrapped
    case resumed
}

private struct PreparedEternalTerminalSession {
    let session: ETTerminalSession
    let origin: EternalTerminalSessionOrigin
}

@MainActor
final class EternalTerminalRuntime {
    let paneId: UUID
    let identityToken = UUID()

    private let server: Server
    private let bootstrapExecutor: SSHETBootstrapExecutor
    private let resumeStore: any EternalTerminalResumeStoring
    private var session: ETTerminalSession?
    private weak var terminal: GhosttyTerminalView?
    private var outputTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var reconnectEventActive = false
    private var failureReported = false
    private var startupApplied = false
    private var tmuxLifecycle: EternalTerminalTmuxResumeContext?
    private var tmuxLifecycleParser: TmuxLifecycleStreamParser?
    private var lastTerminalSize: (cols: Int, rows: Int, pixels: TerminalPixelSize?) = (0, 0, nil)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VVTerm",
        category: "EternalTerminal"
    )

    init(
        paneId: UUID,
        server: Server,
        credentials: ServerCredentials,
        resumeStore: any EternalTerminalResumeStoring
    ) {
        self.paneId = paneId
        self.server = server
        self.resumeStore = resumeStore
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
    }

    var isStartInFlight: Bool { connectTask != nil }

    func attach(to terminal: GhosttyTerminalView) {
        self.terminal = terminal
    }

    func startIfNeeded() {
        guard connectTask == nil, stateTask == nil else { return }

        let paneId = paneId
        let host = server.host
        let port = server.eternalTerminalPort

        AnalyticsTracker.shared.trackConnectionAttempted(transport: ShellTransport.eternalTerminal.rawValue)

        connectTask = Task { [weak self] in
            do {
                guard let self else { return }
                let prepared = try await self.prepareSession()
                guard !Task.isCancelled else {
                    await prepared.session.close()
                    return
                }
                self.session = prepared.session
                self.configureLifecycle(for: prepared.origin)
                self.observe(prepared.session, host: host, port: port)
                try await prepared.session.connect()
                await self.persistCheckpoint()
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
        guard let session else { return }
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
        guard let session else { throw ETClientError.connectionClosed }
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

    func resize(cols: Int, rows: Int, pixelSize: TerminalPixelSize?) {
        guard cols > 0, rows > 0 else { return }
        guard cols != lastTerminalSize.cols
                || rows != lastTerminalSize.rows
                || pixelSize != lastTerminalSize.pixels else { return }
        lastTerminalSize = (cols, rows, pixelSize)
        guard let session else { return }
        Task(priority: .userInitiated) { [logger] in
            do {
                try await session.resize(
                    rows: rows,
                    cols: cols,
                    pixelWidth: pixelSize?.width,
                    pixelHeight: pixelSize?.height
                )
            } catch {
                logger.debug("Failed to send ET terminal size: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func notifyNetworkPathChanged() {
        guard let session else { return }
        Task { await session.notifyNetworkPathChanged() }
    }

    func persistCheckpoint() async {
        guard let session else { return }
        do {
            let checkpoint = try await session.checkpoint()
            try resumeStore.save(checkpoint, for: paneId)
        } catch ETClientError.connectionClosed {
            return
        } catch {
            logger.warning("Failed to save ET recovery checkpoint: \(error.localizedDescription, privacy: .public)")
        }
    }

    func prepareForApplicationBackground() async {
        guard let session else { return }
        do {
            let checkpoint = try await session.prepareForApplicationBackground()
            try resumeStore.save(checkpoint, for: paneId)
        } catch ETClientError.connectionClosed {
            return
        } catch {
            logger.warning("Failed to save ET background checkpoint: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resumeFromApplicationBackground() async {
        await session?.resumeFromApplicationBackground()
    }

    func close() async {
        connectTask?.cancel()
        outputTask?.cancel()
        stateTask?.cancel()
        connectTask = nil
        outputTask = nil
        stateTask = nil
        terminal = nil
        if let session {
            await session.close()
            self.session = nil
        }
    }

    private func prepareSession() async throws -> PreparedEternalTerminalSession {
        let port = UInt16(exactly: server.eternalTerminalPort) ?? 2022
        do {
            if let credentials = try resumeStore.credentials(for: paneId) {
                if let checkpoint = try resumeStore.checkpoint(for: paneId) {
                    let session = try ETTerminalSession(
                        host: server.host,
                        port: port,
                        clientID: credentials.clientID,
                        passkey: credentials.passkey,
                        checkpoint: checkpoint
                    )
                    return PreparedEternalTerminalSession(session: session, origin: .resumed)
                }
                // Versions before protocol checkpointing saved credentials that cannot
                // safely resume a returning ET stream. Migrate by bootstrapping once.
                try resumeStore.deleteResumeState(for: paneId)
            }
        } catch let error as EternalTerminalResumeCredentialError {
            if error.shouldDeleteStoredCredentials {
                try? resumeStore.deleteResumeState(for: paneId)
            }
            throw error
        }

        let credentials = try await ETBootstrap(
            options: SSHETBootstrapExecutor.bootstrapOptions
        ).run(using: bootstrapExecutor)
        let resumeCredentials = try EternalTerminalResumeCredentials(credentials)
        try resumeStore.save(resumeCredentials, for: paneId)
        let terminalType = await bootstrapExecutor.preparedTerminalType()
        let session = try ETTerminalSession(
            host: server.host,
            port: port,
            clientID: resumeCredentials.clientID,
            passkey: resumeCredentials.passkey,
            environmentVariables: RemoteTerminalBootstrap.terminalEnvironmentDictionary(
                terminalType: terminalType,
                transport: .eternalTerminal
            )
        )
        return PreparedEternalTerminalSession(session: session, origin: .bootstrapped)
    }

    private func observe(_ session: ETTerminalSession, host: String, port: Int) {
        outputTask = Task { [weak self] in
            for await data in session.output {
                guard !Task.isCancelled else { return }
                self?.consumeOutput(data)
            }
        }

        stateTask = Task { [weak self] in
            for await state in session.stateChanges {
                guard !Task.isCancelled, let self else { return }
                await self.handle(state, session: session, host: host, port: port)
            }
        }
    }

    private func configureLifecycle(for origin: EternalTerminalSessionOrigin) {
        guard origin == .resumed else { return }
        startupApplied = true
        let context = TerminalTabManager.shared.eternalTerminalTmuxResumeContext(for: paneId)
        tmuxLifecycle = context
        tmuxLifecycleParser = context.map {
            TmuxLifecycleStreamParser(markerToken: $0.markerToken)
        }
    }

    private func handle(
        _ state: ETConnectionState,
        session: ETTerminalSession,
        host: String,
        port: Int
    ) async {
        if state == .reconnecting || state == .disconnected {
            if !reconnectEventActive {
                reconnectEventActive = true
                AnalyticsTracker.shared.trackConnectionReconnecting(
                    transport: ShellTransport.eternalTerminal.rawValue
                )
            }
        } else if state == .connected {
            reconnectEventActive = false
            do {
                if lastTerminalSize.cols > 0, lastTerminalSize.rows > 0 {
                    try await session.resize(
                        rows: lastTerminalSize.rows,
                        cols: lastTerminalSize.cols,
                        pixelWidth: lastTerminalSize.pixels?.width,
                        pixelHeight: lastTerminalSize.pixels?.height
                    )
                    applyStartupPlanIfNeeded()
                } else {
                    logger.error("ET connected without a valid Ghostty terminal grid")
                    return
                }
            } catch {
                publishFailure(error, host: host, port: port)
                return
            }
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
        guard let session else { return }
        Task { [weak self] in
            let plan = await executor.preparedStartupPlan()
            guard let self else { return }
            let resumeContext = plan.tmuxLifecycle.map {
                EternalTerminalTmuxResumeContext(
                    ownership: $0.ownership,
                    markerToken: $0.markerToken
                )
            }
            tmuxLifecycle = resumeContext
            tmuxLifecycleParser = resumeContext.map {
                TmuxLifecycleStreamParser(markerToken: $0.markerToken)
            }
            TerminalTabManager.shared.setEternalTerminalTmuxResumeContext(
                resumeContext,
                for: paneId
            )
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
        if EternalTerminalResumePolicy.shouldDiscardCredentials(after: error) {
            do {
                try resumeStore.deleteResumeState(for: paneId)
            } catch {
                logger.error("Failed to invalidate ET resume credentials: \(error.localizedDescription, privacy: .public)")
            }
        }
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
