import Foundation
import CoreGraphics
import os.log

final class TerminalPaneSSHCoordinator {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    weak var terminal: GhosttyTerminalView?
    let sshClient: SSHClient
    var shellId: UUID?
    var shellTask: Task<Void, Never>?
    var isTerminalReady = false
    var preservePane = false
    var lastReportedSize: CGSize = .zero

    private let richPasteRuntime: TerminalRichPasteRuntime
    private let transportWriteQueue = TerminalTransportWriteQueue()
    private var lastTerminalSize: (cols: Int, rows: Int, pixels: TerminalPixelSize?) = (0, 0, nil)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHPane")

    init(
        paneId: UUID,
        server: Server,
        credentials: ServerCredentials,
        sshClient: SSHClient,
        richPasteUIModel: TerminalRichPasteUIModel
    ) {
        self.paneId = paneId
        self.server = server
        self.credentials = credentials
        self.sshClient = sshClient
        self.richPasteRuntime = .terminalPane(
            paneId: paneId,
            sshClient: sshClient,
            uiModel: richPasteUIModel
        )
    }

    @MainActor
    func installRichPasteInterception(on terminal: GhosttyTerminalView) {
        richPasteRuntime.install(on: terminal)
    }

    @MainActor
    func sendToSSH(_ data: Data) {
        guard let route = Self.sshRoute(
            paneId: paneId,
            fallbackClient: sshClient,
            shellId: shellId
        ) else {
            return
        }
        let logger = logger
        transportWriteQueue.enqueue {
            do {
                try await route.client.write(data, to: route.shellId)
            } catch {
                logger.error("Failed to send to SSH: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    func handleResize(cols: Int, rows: Int, pixelSize: TerminalPixelSize?) {
        guard cols > 0 && rows > 0 else { return }
        guard let route = Self.sshRoute(
            paneId: paneId,
            fallbackClient: sshClient,
            shellId: shellId
        ) else { return }
        guard cols != lastTerminalSize.cols
                || rows != lastTerminalSize.rows
                || pixelSize != lastTerminalSize.pixels else { return }
        lastTerminalSize = (cols, rows, pixelSize)

        Task(priority: .userInitiated) { [logger] in
            do {
                try await route.client.resize(
                    cols: cols,
                    rows: rows,
                    pixelSize: pixelSize,
                    for: route.shellId
                )
            } catch {
                logger.warning("Failed to resize PTY: \(error.localizedDescription)")
            }
        }
    }

    private static func sshRoute(
        paneId: UUID,
        fallbackClient: SSHClient,
        shellId: UUID?
    ) -> (client: SSHClient, shellId: UUID)? {
        if let shellId {
            return (client: fallbackClient, shellId: shellId)
        }

        guard let client = TerminalTabManager.shared.getSSHClient(for: paneId),
              let shellId = TerminalTabManager.shared.shellId(for: paneId) else {
            return nil
        }

        return (client: client, shellId: shellId)
    }

    func startSSHConnection(terminal: GhosttyTerminalView) {
        if shellTask != nil {
            logger.debug("Ignoring duplicate start request for pane")
            return
        }

        let paneId = self.paneId
        if let existingShellId = TerminalTabManager.shared.shellId(for: paneId) {
            shellId = existingShellId
            TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
            logger.debug("Reusing existing shell for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        if shellId != nil {
            TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
            return
        }

        guard let startToken = TerminalTabManager.shared.beginShellStart(
            for: paneId,
            client: sshClient
        ) else {
            if TerminalTabManager.shared.shellId(for: paneId) != nil {
                TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
            }
            logger.debug("Shell start already in progress for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        let sshClient = self.sshClient
        let server = self.server
        let credentials = self.credentials
        let logger = self.logger
        let hasEstablishedConnection = TerminalTabManager.shared.paneStates[paneId]?.hasEstablishedConnection == true

        shellTask = Task.detached(priority: .userInitiated) { [weak self, weak terminal, sshClient, server, credentials, paneId, startToken, logger] in
            defer {
                Task { @MainActor [weak self] in
                    TerminalTabManager.shared.finishShellStart(
                        for: paneId,
                        client: sshClient,
                        startToken: startToken
                    )
                    self?.shellTask = nil
                }
            }

            guard let self, let terminal else { return }
            await SSHConnectionRunner.run(
                server: server,
                credentials: credentials,
                sshClient: sshClient,
                terminal: terminal,
                logger: logger,
                shouldContinueConnection: {
                    TerminalTabManager.shared.isCurrentShellOwner(
                        for: paneId,
                        client: sshClient,
                        startToken: startToken
                    )
                },
                onAttempt: { attempt in
                    TerminalTabManager.shared.updatePaneState(
                        paneId,
                        connectionState: TerminalConnectionAttemptPolicy.state(
                            attempt: attempt,
                            hasEstablishedConnection: hasEstablishedConnection
                        )
                    )
                },
                startupPlan: {
                    try await TerminalTabManager.shared.tmuxStartupPlan(
                        for: paneId,
                        serverId: server.id,
                        client: sshClient,
                        startToken: startToken
                    )
                },
                restoreMoshShell: { cols, rows in
                    guard server.connectionMode == .mosh else { return nil }
                    return await TerminalTabManager.shared.restoreMoshShell(
                        for: paneId,
                        using: sshClient,
                        cols: cols,
                        rows: rows
                    )
                },
                registerShell: { shell in
                    guard await TerminalTabManager.shared.registerSSHClient(
                        sshClient,
                        shellId: shell.id,
                        startToken: startToken,
                        for: paneId,
                        serverId: server.id,
                        transport: shell.transport,
                        fallbackReason: shell.fallbackReason,
                        fallbackDiagnostics: shell.fallbackDiagnostics
                    ) else {
                        return false
                    }
                    TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
                    self.shellId = shell.id
                    if let size = terminal.currentTerminalGridSize {
                        self.handleResize(
                            cols: size.cols,
                            rows: size.rows,
                            pixelSize: terminal.currentTerminalPixelSize
                        )
                    }
                    if shell.origin == .fresh {
                        await self.applyWorkingDirectoryIfNeeded(
                            paneId: paneId,
                            shellId: shell.id,
                            sshClient: sshClient
                        )
                    }
                    if shell.transport == .mosh {
                        await TerminalTabManager.shared.persistMoshSnapshot(
                            for: paneId,
                            client: sshClient,
                            shellId: shell.id
                        )
                    }
                    return true
                },
                onBeforeShellStart: { cols, rows in
                    self.lastTerminalSize = (
                        cols,
                        rows,
                        terminal.currentTerminalPixelSize
                    )
                },
                onTitleChange: { title in
                    TerminalTabManager.shared.updatePaneTitle(paneId, rawTitle: title)
                },
                shouldContinueStreaming: { data, terminal in
                    guard TerminalTabManager.shared.isCurrentShellOwner(
                        for: paneId,
                        client: sshClient,
                        startToken: startToken
                    ) else {
                        return false
                    }
                    guard self.terminal === terminal else {
                        return false
                    }
                    terminal.feedData(data)
                    return true
                },
                shouldResetClient: { sshError in
                    switch sshError {
                    case .notConnected, .connectionFailed, .socketError, .timeout:
                        return true
                    case .channelOpenFailed, .shellRequestFailed:
                        let hasOtherRegistrations = await TerminalTabManager.shared.hasOtherRegistrations(
                            using: sshClient,
                            excluding: paneId
                        )
                        return !hasOtherRegistrations
                    case .authenticationFailed, .tailscaleAuthenticationNotAccepted, .cloudflareConfigurationRequired, .cloudflareAuthenticationFailed, .cloudflareTunnelFailed, .hostKeyVerificationFailed, .moshServerMissing, .moshServerRuntimeBroken, .moshBootstrapFailed, .moshSessionFailed, .moshInvalidEndpoint, .moshUDPTimeout, .moshClientSessionFailed, .unknown:
                        return false
                    }
                },
                onProcessExit: { shellId, reason in
                    TerminalTabManager.shared.handleShellEnd(
                        for: paneId,
                        client: sshClient,
                        shellId: shellId,
                        reason: reason
                    )
                },
                onFailure: { error, terminal in
                    let errorMsg = "\r\n\u{001B}[31mSSH Error: \(error.localizedDescription)\u{001B}[0m\r\n"
                    if let data = errorMsg.data(using: .utf8) {
                        terminal.feedData(data)
                    }
                    TerminalTabManager.shared.handleConnectionFailure(for: paneId, error: error)
                }
            )
        }
    }

    func cancelShell() {
        shellTask?.cancel()
        shellTask = nil

        if let shellId {
            Task.detached(priority: .high) { [sshClient, shellId] in
                await sshClient.closeShell(shellId)
            }
        }
        self.shellId = nil

        terminal?.cleanup()
        terminal = nil
    }

    private func applyWorkingDirectoryIfNeeded(paneId: UUID, shellId: UUID, sshClient: SSHClient) async {
        guard await MainActor.run(body: { TerminalTabManager.shared.shouldApplyWorkingDirectory(for: paneId) }) else { return }
        guard let cwd = await MainActor.run(body: { TerminalTabManager.shared.workingDirectory(for: paneId) }) else { return }
        let environment = await sshClient.remoteEnvironment()
        guard environment.shellProfile.family != .unknown else { return }
        guard let payload = RemoteTerminalBootstrap.directoryChangeCommand(for: cwd, environment: environment).data(using: .utf8) else { return }
        try? await sshClient.write(payload, to: shellId)
    }

    deinit {
        guard !preservePane else { return }
        guard terminal == nil else { return }
        cancelShell()
    }
}
