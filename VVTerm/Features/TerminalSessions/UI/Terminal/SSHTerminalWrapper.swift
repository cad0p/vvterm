//
//  SSHTerminalWrapper.swift
//  VVTerm
//
//  SwiftUI wrapper for Ghostty terminal with SSH connections
//

import SwiftUI
import Foundation
import os.log

enum SSHConnectionRunner {
    static func run(
        server: Server,
        credentials: ServerCredentials,
        sshClient: SSHClient,
        terminal: GhosttyTerminalView,
        logger: Logger,
        onAttempt: @MainActor @escaping (_ attempt: Int) -> Void,
        startupPlan: @MainActor @escaping () async -> (command: String?, skipTmuxLifecycle: Bool),
        registerShell: @MainActor @escaping (_ shell: ShellHandle, _ skipTmuxLifecycle: Bool) async -> Void,
        onBeforeShellStart: @MainActor @escaping (_ cols: Int, _ rows: Int) async -> Void,
        onShellStarted: @MainActor @escaping (_ terminal: GhosttyTerminalView, _ shellId: UUID) async -> Void,
        onTitleChange: @MainActor @escaping (_ title: String) -> Void,
        shouldContinueStreaming: @MainActor @escaping (_ data: Data, _ terminal: GhosttyTerminalView) -> Bool,
        shouldResetClient: @escaping (_ error: SSHError) async -> Bool,
        onProcessExit: @MainActor @escaping () -> Void,
        onFailure: @MainActor @escaping (_ error: Error, _ terminal: GhosttyTerminalView) -> Void
    ) async {
        let maxAttempts = 3
        var lastError: Error?
        var titleParser = TerminalTitleSequenceParser()

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }
            await onAttempt(attempt)

            do {
                logger.info("Connecting to \(server.host)... (attempt \(attempt))")
                _ = try await sshClient.connect(to: server, credentials: credentials)
                guard !Task.isCancelled else { return }

                let size = terminal.terminalSize()
                let cols = Int(size?.columns ?? 80)
                let rows = Int(size?.rows ?? 24)

                await onBeforeShellStart(cols, rows)
                let startup = await startupPlan()
                let shell = try await sshClient.startShell(
                    cols: cols,
                    rows: rows,
                    startupCommand: startup.command
                )

                guard !Task.isCancelled else {
                    await sshClient.closeShell(shell.id)
                    return
                }

                await registerShell(shell, startup.skipTmuxLifecycle)
                await onShellStarted(terminal, shell.id)

                guard !Task.isCancelled else { return }
                for await data in shell.stream {
                    guard !Task.isCancelled else { break }
                    for title in titleParser.parse(data) {
                        await onTitleChange(title)
                    }
                    let shouldContinue = await shouldContinueStreaming(data, terminal)
                    if !shouldContinue { break }
                }

                guard !Task.isCancelled else { return }
                logger.info("SSH shell ended")
                await onProcessExit()
                return
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error
                logger.error("SSH connection failed (attempt \(attempt)): \(error.localizedDescription)")

                if attempt < maxAttempts, let sshError = error as? SSHError {
                    let shouldReset = await shouldResetClient(sshError)
                    if shouldReset {
                        logger.warning("Resetting SSH client before retrying connection")
                        await sshClient.disconnect()
                    }
                }

                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1))
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
            }
        }

        if let lastError {
            await onFailure(lastError, terminal)
        }
    }
}

// MARK: - SSH Terminal Coordinator Protocol

/// Protocol for shared SSH terminal coordinator functionality across platforms
protocol SSHTerminalCoordinator: AnyObject {
    var server: Server { get }
    var credentials: ServerCredentials { get }
    var sessionId: UUID { get }
    var onProcessExit: () -> Void { get }
    var terminalView: GhosttyTerminalView? { get set }
    var sshClient: SSHClient { get }
    var shellId: UUID? { get set }
    var shellTask: Task<Void, Never>? { get set }
    var logger: Logger { get }

    /// Platform-specific hook called after shell starts (before reading output)
    func onShellStarted(terminal: GhosttyTerminalView) async

    /// Platform-specific hook called before starting shell (after connect, after registering client)
    func onBeforeShellStart(cols: Int, rows: Int) async

    /// Fallback route when local shellId is temporarily unavailable.
    func fallbackRoute() -> (client: SSHClient, shellId: UUID)?
}

extension SSHTerminalCoordinator {
    func sendToSSH(_ data: Data) {
        if let shellId {
            // Preserve task ordering from the caller to avoid input reordering under high throughput.
            Task(priority: .userInitiated) { [sshClient, logger, shellId] in
                do {
                    try await sshClient.write(data, to: shellId)
                } catch {
                    logger.error("Failed to send to SSH: \(error.localizedDescription)")
                }
            }
            return
        }

        // Coordinator can be recreated while an existing shell is still registered.
        // Fall back to the manager registry so input keeps working after view reattachment.
        Task(priority: .userInitiated) { [logger] in
            let route = await MainActor.run {
                self.fallbackRoute()
            }

            guard let route else { return }
            do {
                try await route.client.write(data, to: route.shellId)
            } catch {
                logger.error("Failed to send to SSH: \(error.localizedDescription)")
            }
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

        // Cleanup terminal to break retain cycles and release resources
        if let terminal = terminalView {
            terminal.cleanup()
        }
        terminalView = nil
    }

    func suspendShell() {
        // Cancel in-flight SSH work but keep the terminal surface for reuse
        shellTask?.cancel()
        shellTask = nil
        self.shellId = nil
    }

    func startSSHConnection(terminal: GhosttyTerminalView) {
        if shellTask != nil {
            logger.debug("Ignoring duplicate start request for session \(self.sessionId)")
            return
        }

        if let existingShellId = ConnectionSessionManager.shared.shellId(for: sessionId) {
            shellId = existingShellId
            deferSessionStateUpdate(.connected)
            logger.debug("Reusing existing shell for session \(self.sessionId)")
            return
        }

        if shellId != nil {
            deferSessionStateUpdate(.connected)
            return
        }

        guard ConnectionSessionManager.shared.tryBeginShellStart(
            for: sessionId,
            client: sshClient
        ) else {
            if ConnectionSessionManager.shared.shellId(for: sessionId) != nil {
                deferSessionStateUpdate(.connected)
            }
            logger.debug("Shell start already in progress for session \(self.sessionId)")
            return
        }

        // Capture all values needed in the detached task before creating it
        // to avoid accessing main actor-isolated properties from detached context
        let sshClient = self.sshClient
        let server = self.server
        let credentials = self.credentials
        let sessionId = self.sessionId
        let onProcessExit = self.onProcessExit
        let logger = self.logger

        shellTask = Task.detached(priority: .userInitiated) { [weak self, weak terminal] in
            defer {
                Task { @MainActor [weak self] in
                    ConnectionSessionManager.shared.finishShellStart(for: sessionId, client: sshClient)
                    self?.shellTask = nil
                }
            }

            guard let self = self, let terminal = terminal else { return }
            await SSHConnectionRunner.run(
                server: server,
                credentials: credentials,
                sshClient: sshClient,
                terminal: terminal,
                logger: logger,
                onAttempt: { attempt in
                    if attempt == 1 {
                        ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connecting)
                    } else {
                        ConnectionSessionManager.shared.updateSessionState(sessionId, to: .reconnecting(attempt: attempt))
                    }
                },
                startupPlan: {
                    await ConnectionSessionManager.shared.tmuxStartupPlan(
                        for: sessionId,
                        serverId: server.id,
                        client: sshClient
                    )
                },
                registerShell: { shell, skipTmuxLifecycle in
                    ConnectionSessionManager.shared.registerSSHClient(
                        sshClient,
                        shellId: shell.id,
                        for: sessionId,
                        serverId: server.id,
                        transport: shell.transport,
                        fallbackReason: shell.fallbackReason,
                        skipTmuxLifecycle: skipTmuxLifecycle
                    )
                    ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connected)
                    self.shellId = shell.id
                },
                onBeforeShellStart: { cols, rows in
                    await self.onBeforeShellStart(cols: cols, rows: rows)
                },
                onShellStarted: { terminal, _ in
                    await self.onShellStarted(terminal: terminal)
                },
                onTitleChange: { title in
                    ConnectionSessionManager.shared.updateSessionTitle(sessionId, rawTitle: title)
                },
                shouldContinueStreaming: { data, terminal in
                    let sessionExists = ConnectionSessionManager.shared.sessions.contains { $0.id == sessionId }
                    guard sessionExists else { return false }
                    terminal.feedData(data)
                    return true
                },
                shouldResetClient: { sshError in
                    switch sshError {
                    case .notConnected, .connectionFailed, .socketError, .timeout:
                        return true
                    case .channelOpenFailed, .shellRequestFailed:
                        let hasOtherRegistrations = await ConnectionSessionManager.shared.hasOtherRegistrations(
                            using: sshClient,
                            excluding: sessionId
                        )
                        return !hasOtherRegistrations
                    case .authenticationFailed, .tailscaleAuthenticationNotAccepted, .cloudflareConfigurationRequired, .cloudflareAuthenticationFailed, .cloudflareTunnelFailed, .hostKeyVerificationFailed, .moshServerMissing, .moshBootstrapFailed, .moshSessionFailed, .unknown:
                        return false
                    }
                },
                onProcessExit: {
                    onProcessExit()
                },
                onFailure: { error, terminal in
                    let errorMsg = "\r\n\u{001B}[31mSSH Error: \(error.localizedDescription)\u{001B}[0m\r\n"
                    if let data = errorMsg.data(using: .utf8) {
                        terminal.feedData(data)
                    }
                    ConnectionSessionManager.shared.updateSessionState(sessionId, to: .failed(error.localizedDescription))
                }
            )
        }
    }

    private func deferSessionStateUpdate(_ state: ConnectionState) {
        Task { @MainActor [self] in
            ConnectionSessionManager.shared.updateSessionState(sessionId, to: state)
        }
    }

    // Default no-op implementations for hooks
    func onShellStarted(terminal: GhosttyTerminalView) async {}
    func onBeforeShellStart(cols: Int, rows: Int) async {}
    func fallbackRoute() -> (client: SSHClient, shellId: UUID)? {
        guard let session = ConnectionSessionManager.shared.sessions.first(where: { $0.id == sessionId }),
              let client = ConnectionSessionManager.shared.sshClient(for: session),
              let shellId = ConnectionSessionManager.shared.shellId(for: session) else {
            return nil
        }
        return (client: client, shellId: shellId)
    }
}
