#if os(iOS)
import SwiftUI
import Foundation
import os.log
import UIKit

// MARK: - iOS SSH Terminal Wrapper

/// SwiftUI wrapper that uses GeometryReader to get proper size (matches official Ghostty pattern)
struct SSHTerminalWrapper: View {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    var isActive: Bool = true
    var shouldPreserveKeyboardDuringReconnect: Bool = false
    let onProcessExit: () -> Void
    let onReady: () -> Void
    var onVoiceTrigger: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            SSHTerminalRepresentable(
                session: session,
                server: server,
                credentials: credentials,
                richPasteUIModel: richPasteUIModel,
                size: geo.size,
                isActive: isActive,
                shouldPreserveKeyboardDuringReconnect: shouldPreserveKeyboardDuringReconnect,
                onProcessExit: onProcessExit,
                onReady: onReady,
                onVoiceTrigger: onVoiceTrigger
            )
        }
    }
}

/// The actual UIViewRepresentable that receives size from GeometryReader
private struct SSHTerminalRepresentable: UIViewRepresentable {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    let size: CGSize
    var isActive: Bool = true
    var shouldPreserveKeyboardDuringReconnect: Bool = false
    let onProcessExit: () -> Void
    let onReady: () -> Void
    var onVoiceTrigger: (() -> Void)? = nil

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.scenePhase) private var scenePhase

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

    func makeUIView(context: Context) -> UIView {
        guard let app = ghosttyApp.app else {
            return UIView(frame: .zero)
        }

        let coordinator = context.coordinator

        // Check if terminal already exists for this session (reuse to save memory)
        if let existingTerminal = ConnectionSessionManager.shared.peekTerminal(for: session.id) {
            ConnectionSessionManager.shared.markTerminalUsed(for: session.id)
            coordinator.terminalView = existingTerminal
            coordinator.isTerminalReady = true
            coordinator.preserveSession = true
            existingTerminal.onVoiceButtonTapped = onVoiceTrigger
            existingTerminal.onProcessExit = onProcessExit
            existingTerminal.onPwdChange = { [sessionId = session.id] rawDirectory in
                DispatchQueue.main.async {
                    ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
                }
            }
            existingTerminal.onTitleChange = { [sessionId = session.id] title in
                ConnectionSessionManager.shared.updateSessionTitle(sessionId, rawTitle: title)
            }
            existingTerminal.onZoomAction = { [sessionId = session.id] action in
                ConnectionSessionManager.shared.handleTerminalZoom(action, for: sessionId)
            }
            existingTerminal.applyPresentationOverrides(ConnectionSessionManager.shared.presentationOverrides(for: session.id))

            // Route through coordinator to preserve write ordering and transport behavior.
            existingTerminal.writeCallback = { [weak coordinator] data in
                coordinator?.sendToSSH(data)
            }
            coordinator.installRichPasteInterception(on: existingTerminal)
            existingTerminal.onResize = { [session] cols, rows in
                guard cols > 0 && rows > 0 else { return }
                Task {
                    if let sshClient = ConnectionSessionManager.shared.sshClient(for: session),
                       let shellId = ConnectionSessionManager.shared.shellId(for: session) {
                        try? await sshClient.resize(cols: cols, rows: rows, for: shellId)
                    }
                }
            }

            if existingTerminal.superview != nil {
                existingTerminal.removeFromSuperview()
            }
            if size.width > 0 && size.height > 0 {
                coordinator.lastReportedSize = size
                existingTerminal.frame = CGRect(origin: .zero, size: size)
                existingTerminal.sizeDidChange(size)
            }

            DispatchQueue.main.async {
                onReady()
                let shellMissing = ConnectionSessionManager.shared.shellId(for: session) == nil
                let shellStartInFlight = ConnectionSessionManager.shared.isShellStartInFlight(for: session.id)
                if shellMissing,
                   !shellStartInFlight,
                   UIApplication.shared.applicationState == .active,
                   !ConnectionSessionManager.shared.isSuspendingForBackground {
                    if ConnectionSessionManager.shared.consumeTerminalReconnectReset(for: session.id) {
                        existingTerminal.resetTerminalForReconnect()
                    }
                    coordinator.startSSHConnection(terminal: existingTerminal)
                }
            }
            return existingTerminal
        }

        let initialSize = (size.width > 0 && size.height > 0) ? size : CGSize(width: 800, height: 600)
        let terminalView = GhosttyTerminalView(
            frame: CGRect(origin: .zero, size: initialSize),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: session.id.uuidString,
            useCustomIO: true
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            coordinator?.isTerminalReady = true
            DispatchQueue.main.async {
                onReady()
                if let terminalView = terminalView,
                   UIApplication.shared.applicationState == .active,
                   !ConnectionSessionManager.shared.isSuspendingForBackground {
                    coordinator?.startSSHConnection(terminal: terminalView)
                }
            }
        }
        terminalView.onProcessExit = onProcessExit
        terminalView.onVoiceButtonTapped = onVoiceTrigger
        terminalView.onPwdChange = { [sessionId = session.id] rawDirectory in
            DispatchQueue.main.async {
                ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
            }
        }
        terminalView.onTitleChange = { [sessionId = session.id] title in
            ConnectionSessionManager.shared.updateSessionTitle(sessionId, rawTitle: title)
        }
        terminalView.onZoomAction = { [sessionId = session.id] action in
            ConnectionSessionManager.shared.handleTerminalZoom(action, for: sessionId)
        }
        terminalView.applyPresentationOverrides(ConnectionSessionManager.shared.presentationOverrides(for: session.id))

        coordinator.terminalView = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        ConnectionSessionManager.shared.registerTerminal(terminalView, for: session.id)
        ConnectionSessionManager.shared.registerShellCancelHandler({ [weak coordinator] in
            coordinator?.cancelShell()
        }, for: session.id)
        ConnectionSessionManager.shared.registerShellSuspendHandler({ [weak coordinator] in
            coordinator?.suspendShell()
        }, for: session.id)

        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToSSH(data)
        }
        terminalView.setupWriteCallback()
        terminalView.onResize = { [session] cols, rows in
            guard cols > 0 && rows > 0 else { return }
            Task {
                if let sshClient = ConnectionSessionManager.shared.sshClient(for: session),
                   let shellId = ConnectionSessionManager.shared.shellId(for: session) {
                    try? await sshClient.resize(cols: cols, rows: rows, for: shellId)
                }
            }
        }

        coordinator.lastReportedSize = initialSize
        if size.width > 0 && size.height > 0 {
            terminalView.sizeDidChange(size)
        }
        if !isActive {
            terminalView.pauseRendering()
        }

        return terminalView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let terminalView = uiView as? GhosttyTerminalView else {
            return
        }

        // Check if session still exists - if not, cleanup and return
        let sessionExists = ConnectionSessionManager.shared.sessions.contains { $0.id == session.id }
        if !sessionExists {
            // Session was closed externally, cleanup terminal
            context.coordinator.cancelShell()
            terminalView.writeCallback = nil
            terminalView.onReady = nil
            terminalView.onProcessExit = nil
            return
        }

        let wasActive = context.coordinator.wasActive
        let shouldRenderTerminal = isActive && scenePhase == .active

        terminalView.onVoiceButtonTapped = onVoiceTrigger
        if terminalView.surfacePresentationOverrides != ConnectionSessionManager.shared.presentationOverrides(for: session.id) {
            terminalView.applyPresentationOverrides(ConnectionSessionManager.shared.presentationOverrides(for: session.id))
        }
        if size.width > 0, size.height > 0, size != context.coordinator.lastReportedSize {
            context.coordinator.lastReportedSize = size
            terminalView.sizeDidChange(size)
        }

        if context.coordinator.isTerminalReady {
            if shouldRenderTerminal && !wasActive {
                terminalView.resumeRendering()
                terminalView.forceRefresh()
            } else if !shouldRenderTerminal && wasActive {
                terminalView.pauseRendering()
            }
        }
        context.coordinator.wasActive = shouldRenderTerminal

        let autoReconnectEnabled = (UserDefaults.standard.object(forKey: "sshAutoReconnect") as? Bool) ?? true
        let shellMissing = ConnectionSessionManager.shared.shellId(for: session) == nil
        let shellStartInFlight = ConnectionSessionManager.shared.isShellStartInFlight(for: session.id)
        let shouldRestoreKeyboardFocus =
            shouldPreserveKeyboardDuringReconnect
            && session.connectionState.isConnecting
            && terminalView.shouldRestoreKeyboardFocusOnReconnect
        let shouldKeepExistingKeyboardFocus = terminalView.isFirstResponder && shouldRestoreKeyboardFocus
        terminalView.acceptsTerminalInput = session.connectionState.isConnected
        let shouldStartSSHConnection: Bool = {
            switch session.connectionState {
            case .connecting, .reconnecting, .connected:
                return true
            case .disconnected:
                return isActive && autoReconnectEnabled
            case .failed, .idle:
                return false
            }
        }()
        if context.coordinator.isTerminalReady
            && shellMissing
            && context.coordinator.shellTask == nil
            && !shellStartInFlight
            && shouldStartSSHConnection
            && scenePhase == .active
            && !ConnectionSessionManager.shared.isSuspendingForBackground {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak terminalView] in
                guard let terminalView else { return }
                guard ConnectionSessionManager.shared.sessions.contains(where: { $0.id == session.id }) else { return }
                guard ConnectionSessionManager.shared.shellId(for: session) == nil else { return }
                guard !ConnectionSessionManager.shared.isShellStartInFlight(for: session.id) else { return }
                if ConnectionSessionManager.shared.consumeTerminalReconnectReset(for: session.id) {
                    terminalView.resetTerminalForReconnect()
                }
                coordinator.startSSHConnection(terminal: terminalView)
            }
        }

        // Keep the terminal from reclaiming focus while an overlay (for example
        // the disconnected card) should be interactive above it.
        if shouldRenderTerminal && context.coordinator.isTerminalReady {
            let focusReason: TerminalKeyboardFocusReason?
            if shouldRestoreKeyboardFocus {
                focusReason = .reconnectRestore
            } else if session.connectionState.isConnected && terminalView.allowsAutomaticKeyboardFocus {
                focusReason = .initialActivation
            } else {
                focusReason = nil
            }

            if let focusReason, terminalView.window != nil && !terminalView.isFirstResponder {
                terminalView.requestKeyboardFocus(for: focusReason)
            }
        } else if scenePhase == .active
            && terminalView.isFirstResponder
            && !shouldKeepExistingKeyboardFocus {
            _ = terminalView.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        guard let terminalView = uiView as? GhosttyTerminalView else { return }

        // Check if session still exists - if it does, user just navigated away
        // Keep terminal alive for when they come back
        let sessionStillExists = ConnectionSessionManager.shared.sessions.contains { $0.id == coordinator.sessionId }

        if sessionStillExists {
            // Session still active - user just navigated away
            // Pause rendering but keep everything alive
            terminalView.pauseRendering()
            _ = terminalView.resignFirstResponder()

            // Mark coordinator to not cleanup in deinit
            // IMPORTANT: Do NOT set terminalView = nil here!
            // The SSH output loop checks terminalView != nil to continue running.
            // Setting it to nil would break the loop and close the connection.
            coordinator.preserveSession = true
            return
        }

        // Session was closed - full cleanup
        ConnectionSessionManager.shared.unregisterShellCancelHandler(for: coordinator.sessionId)
        ConnectionSessionManager.shared.unregisterShellSuspendHandler(for: coordinator.sessionId)
        coordinator.terminalView = nil
        ConnectionSessionManager.shared.unregisterTerminal(for: coordinator.sessionId)
        coordinator.cancelShell()
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

        /// Tracks whether the terminal surface has been created and is ready for interaction
        var isTerminalReady = false

        /// If true, session is still active and we shouldn't cleanup on deinit (user just navigated away)
        var preserveSession = false
        var wasActive = false
        var lastReportedSize: CGSize = .zero

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

        // MARK: - SSHTerminalCoordinator hooks

        func onShellStarted(terminal: GhosttyTerminalView) async {
            await applyWorkingDirectoryIfNeeded()
            await MainActor.run {
                terminal.forceRefresh()
            }
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
            // Don't cleanup if session is still active (user just navigated away)
            guard !preserveSession else { return }
            cancelShell()
        }
    }
}
#endif
