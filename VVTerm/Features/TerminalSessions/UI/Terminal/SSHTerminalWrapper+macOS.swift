#if os(macOS)
import SwiftUI
import Foundation
import os.log
import AppKit

// MARK: - SSH Terminal Wrapper

struct SSHTerminalWrapper: NSViewRepresentable {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    var isActive: Bool = true
    let onProcessExit: () -> Void
    let onReady: () -> Void
    var onVoiceTrigger: (() -> Void)? = nil

    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeCoordinator() -> Coordinator {
        // Use a dedicated SSH client per tab/session to avoid channel contention
        // and startup races when many tabs are opened quickly.
        let client = SSHClient()
        return Coordinator(
            server: server,
            credentials: credentials,
            sessionId: session.id,
            onProcessExit: onProcessExit,
            sshClient: client,
            richPasteUIModel: richPasteUIModel
        )
    }

    func makeNSView(context: Context) -> NSView {
        // Ensure Ghostty app is ready
        guard let app = ghosttyApp.app else {
            return NSView(frame: .zero)
        }

        let coordinator = context.coordinator

        // Check if terminal already exists for this session (reuse to save memory)
        // Each Ghostty surface uses ~50-100MB (font atlas, Metal textures, scrollback)
        if let existingTerminal = ConnectionSessionManager.shared.getTerminal(for: session.id) {
            // Mark coordinator as reusing existing terminal - don't cleanup on deinit
            coordinator.isReusingTerminal = true
            coordinator.terminalView = existingTerminal

            // Update resize callback to use session manager's registered SSH client
            // (the old coordinator that created the connection is being deallocated)
            existingTerminal.onResize = { [session] cols, rows in
                guard cols > 0 && rows > 0 else { return }
                Task {
                    if let client = ConnectionSessionManager.shared.sshClient(for: session),
                       let shellId = ConnectionSessionManager.shared.shellId(for: session) {
                        try? await client.resize(cols: cols, rows: rows, for: shellId)
                    }
                }
            }
            existingTerminal.onPwdChange = { [sessionId = session.id] rawDirectory in
                ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
            }
            existingTerminal.onTitleChange = { [sessionId = session.id] title in
                ConnectionSessionManager.shared.updateSessionTitle(sessionId, rawTitle: title)
            }
            existingTerminal.onZoomAction = { [sessionId = session.id] action in
                ConnectionSessionManager.shared.handleTerminalZoom(action, for: sessionId)
            }
            existingTerminal.applyPresentationOverrides(ConnectionSessionManager.shared.presentationOverrides(for: session.id))
            existingTerminal.writeCallback = { [weak coordinator] data in
                coordinator?.sendToSSH(data)
            }
            coordinator.installRichPasteInterception(on: existingTerminal)

            // Re-wrap in scroll view
            let scrollView = TerminalScrollView(
                contentSize: NSSize(width: 800, height: 600),
                surfaceView: existingTerminal
            )

            // Terminal is already ready - call onReady immediately
            // Use async to avoid calling during view construction
            DispatchQueue.main.async {
                onReady()
                let shellMissing = ConnectionSessionManager.shared.shellId(for: session) == nil
                let shellStartInFlight = ConnectionSessionManager.shared.isShellStartInFlight(for: session.id)
                if shellMissing && !shellStartInFlight {
                    if ConnectionSessionManager.shared.consumeTerminalReconnectReset(for: session.id) {
                        existingTerminal.resetTerminalForReconnect()
                    }
                    coordinator.startSSHConnection(terminal: existingTerminal)
                }
            }

            return scrollView
        }

        // Create Ghostty terminal with custom I/O for SSH
        // Using useCustomIO: true means the terminal won't spawn a subprocess
        // Instead, it will use callbacks for I/O (for SSH via libssh2)
        let terminalView = GhosttyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: session.id.uuidString,
            useCustomIO: true  // Use callback backend for SSH
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            onReady()
            // Start SSH connection after terminal is ready
            if let terminalView = terminalView {
                coordinator?.startSSHConnection(terminal: terminalView)
            }
        }
        terminalView.onProcessExit = onProcessExit
        terminalView.onPwdChange = { [sessionId = session.id] rawDirectory in
            ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
        }
        terminalView.onTitleChange = { [sessionId = session.id] title in
            ConnectionSessionManager.shared.updateSessionTitle(sessionId, rawTitle: title)
        }
        terminalView.onZoomAction = { [sessionId = session.id] action in
            ConnectionSessionManager.shared.handleTerminalZoom(action, for: sessionId)
        }
        terminalView.applyPresentationOverrides(ConnectionSessionManager.shared.presentationOverrides(for: session.id))

        // Store terminal reference in coordinator and register with session manager
        coordinator.terminalView = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        ConnectionSessionManager.shared.registerTerminal(terminalView, for: session.id)

        // Register shell cancel handler so closeSession can cancel the shell task
        ConnectionSessionManager.shared.registerShellCancelHandler({ [weak coordinator] in
            coordinator?.cancelShell()
        }, for: session.id)
        ConnectionSessionManager.shared.registerShellSuspendHandler({ [weak coordinator] in
            coordinator?.suspendShell()
        }, for: session.id)

        // Setup write callback to send keyboard input to SSH
        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToSSH(data)
        }
        terminalView.setupWriteCallback()

        // Setup resize callback to notify SSH of terminal size changes
        terminalView.onResize = { [weak coordinator] cols, rows in
            coordinator?.handleResize(cols: cols, rows: rows)
        }

        // Wrap in scroll view
        let scrollView = TerminalScrollView(
            contentSize: NSSize(width: 800, height: 600),
            surfaceView: terminalView
        )

        return scrollView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Check if session still exists - if not, cleanup and return
        let sessionExists = ConnectionSessionManager.shared.sessions.contains { $0.id == session.id }
        if !sessionExists {
            context.coordinator.cancelShell()
            return
        }

        if let scrollView = nsView as? TerminalScrollView {
            scrollView.shouldOwnFirstResponder = isActive
            let terminalView = scrollView.surfaceView
            if terminalView.surfacePresentationOverrides != ConnectionSessionManager.shared.presentationOverrides(for: session.id) {
                terminalView.applyPresentationOverrides(ConnectionSessionManager.shared.presentationOverrides(for: session.id))
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: SSHTerminalCoordinator {
        let server: Server
        let credentials: ServerCredentials
        let sessionId: UUID
        let onProcessExit: () -> Void
        weak var terminalView: GhosttyTerminalView?

        let sshClient: SSHClient
        var shellId: UUID?
        var shellTask: Task<Void, Never>?
        private let richPasteRuntime: TerminalRichPasteRuntime
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHTerminal")

        /// Last known terminal size to detect changes
        private var lastSize: (cols: Int, rows: Int) = (0, 0)

        /// If true, this coordinator is reusing an existing terminal and should NOT cleanup on deinit
        var isReusingTerminal = false

        init(
            server: Server,
            credentials: ServerCredentials,
            sessionId: UUID,
            onProcessExit: @escaping () -> Void,
            sshClient: SSHClient,
            richPasteUIModel: TerminalRichPasteUIModel
        ) {
            self.server = server
            self.credentials = credentials
            self.sessionId = sessionId
            self.onProcessExit = onProcessExit
            self.sshClient = sshClient
            self.richPasteRuntime = .connectionSession(
                sessionId: sessionId,
                sshClient: sshClient,
                uiModel: richPasteUIModel
            )
        }

        @MainActor
        func installRichPasteInterception(on terminal: GhosttyTerminalView) {
            richPasteRuntime.install(on: terminal)
        }

        /// Handle terminal resize notification from GhosttyTerminalView
        func handleResize(cols: Int, rows: Int) {
            guard cols > 0 && rows > 0 else { return }
            guard cols != lastSize.cols || rows != lastSize.rows else { return }
            guard let shellId else { return }

            lastSize = (cols, rows)
            logger.info("Terminal resized to \(cols)x\(rows)")

            Task {
                do {
                    try await sshClient.resize(cols: cols, rows: rows, for: shellId)
                } catch {
                    logger.warning("Failed to resize PTY: \(error.localizedDescription)")
                }
            }
        }

        // MARK: - SSHTerminalCoordinator hooks

        func onBeforeShellStart(cols: Int, rows: Int) async {
            // Store initial size to avoid redundant resize on first update
            await MainActor.run {
                self.lastSize = (cols, rows)
            }
        }

        func onShellStarted(terminal: GhosttyTerminalView) async {
            await applyWorkingDirectoryIfNeeded()
        }

        private func applyWorkingDirectoryIfNeeded() async {
            guard ConnectionSessionManager.shared.shouldApplyWorkingDirectory(for: sessionId) else { return }
            guard let cwd = ConnectionSessionManager.shared.workingDirectory(for: sessionId) else { return }
            let environment = await sshClient.remoteEnvironment()
            guard environment.shellProfile.family != .unknown else { return }
            guard let payload = RemoteTerminalBootstrap.directoryChangeCommand(for: cwd, environment: environment).data(using: .utf8) else { return }
            if let shellId {
                try? await sshClient.write(payload, to: shellId)
            }
        }

        deinit {
            // Don't cleanup if we're just reusing an existing terminal (e.g., switching to split view)
            // isReusingTerminal is set when we find an existing terminal in makeNSView
            guard !isReusingTerminal else { return }

            // Check if terminal view is still alive (session manager holds strong reference)
            // If it is, the terminal is being reused by another view (e.g., split view)
            guard terminalView == nil else { return }

            cancelShell()
        }
    }
}
#endif
