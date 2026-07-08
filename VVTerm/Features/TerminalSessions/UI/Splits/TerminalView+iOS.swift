#if os(iOS)
import Foundation
import SwiftUI
import UIKit

extension View {
    func terminalCommandFocusValues(
        activeServerId: UUID?,
        activePaneId: UUID?,
        splitActions: TerminalSplitActions?
    ) -> some View {
        self
    }
}

/// Wraps SSH connection and Ghostty terminal for a pane on iOS/iPadOS.
struct SSHTerminalPaneWrapper: View {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    let isActive: Bool
    let terminalContextMenuActions: TerminalContextMenuActions
    let onProcessExit: () -> Void
    let onReady: () -> Void
    let onVoiceTrigger: (() -> Void)?

    var body: some View {
        GeometryReader { geometry in
            SSHTerminalPaneRepresentable(
                paneId: paneId,
                server: server,
                credentials: credentials,
                richPasteUIModel: richPasteUIModel,
                size: geometry.size,
                isActive: isActive,
                terminalContextMenuActions: terminalContextMenuActions,
                onProcessExit: onProcessExit,
                onReady: onReady,
                onVoiceTrigger: onVoiceTrigger
            )
        }
    }
}

private struct SSHTerminalPaneRepresentable: UIViewRepresentable {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    let size: CGSize
    let isActive: Bool
    let terminalContextMenuActions: TerminalContextMenuActions
    let onProcessExit: () -> Void
    let onReady: () -> Void
    let onVoiceTrigger: (() -> Void)?

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.scenePhase) private var scenePhase

    func makeCoordinator() -> TerminalPaneSSHCoordinator {
        TerminalPaneSSHCoordinator(
            paneId: paneId,
            server: server,
            credentials: credentials,
            onProcessExit: onProcessExit,
            sshClient: SSHClient(),
            richPasteUIModel: richPasteUIModel
        )
    }

    func makeUIView(context: Context) -> UIView {
        guard let app = ghosttyApp.app else {
            return UIView(frame: .zero)
        }

        let coordinator = context.coordinator

        if let existingTerminal = TerminalTabManager.shared.getTerminal(for: paneId) {
            coordinator.terminal = existingTerminal
            coordinator.isTerminalReady = true
            coordinator.preservePane = true
            configureExistingTerminal(existingTerminal, coordinator: coordinator)

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
                startSSHConnectionIfNeeded(
                    terminal: existingTerminal,
                    coordinator: coordinator,
                    state: TerminalTabManager.shared.paneStates[paneId]?.connectionState ?? .idle
                )
            }
            return existingTerminal
        }

        let initialSize = (size.width > 0 && size.height > 0) ? size : CGSize(width: 800, height: 600)
        let terminalView = GhosttyTerminalView(
            frame: CGRect(origin: .zero, size: initialSize),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: paneId.uuidString,
            useCustomIO: true
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            guard let coordinator else { return }
            DispatchQueue.main.async {
                coordinator.isTerminalReady = true
                onReady()
                if let terminalView {
                    startSSHConnectionIfNeeded(
                        terminal: terminalView,
                        coordinator: coordinator,
                        state: TerminalTabManager.shared.paneStates[paneId]?.connectionState ?? .idle
                    )
                }
            }
        }
        terminalView.onProcessExit = onProcessExit
        terminalView.onVoiceButtonTapped = onVoiceTrigger
        terminalView.onPwdChange = { [paneId] rawDirectory in
            DispatchQueue.main.async {
                TerminalTabManager.shared.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
            }
        }
        terminalView.onTitleChange = { [paneId] title in
            TerminalTabManager.shared.updatePaneTitle(paneId, rawTitle: title)
        }
        terminalView.onZoomAction = { [paneId] action in
            TerminalTabManager.shared.handleTerminalZoom(action, for: paneId)
        }
        terminalView.applyPresentationOverrides(TerminalTabManager.shared.presentationOverrides(for: paneId))

        coordinator.terminal = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        TerminalTabManager.shared.registerTerminal(terminalView, for: paneId)

        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToSSH(data)
        }
        terminalView.setupWriteCallback()
        terminalView.onResize = { [weak coordinator] cols, rows in
            coordinator?.handleResize(cols: cols, rows: rows)
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

        guard TerminalTabManager.shared.paneStates[paneId] != nil else {
            context.coordinator.cancelShell()
            terminalView.writeCallback = nil
            terminalView.onReady = nil
            terminalView.onProcessExit = nil
            terminalView.onVoiceButtonTapped = nil
            return
        }

        let wasActive = context.coordinator.wasActive
        let shouldRenderTerminal = isActive && scenePhase == .active

        if terminalView.surfacePresentationOverrides != TerminalTabManager.shared.presentationOverrides(for: paneId) {
            terminalView.applyPresentationOverrides(TerminalTabManager.shared.presentationOverrides(for: paneId))
        }
        terminalView.onVoiceButtonTapped = onVoiceTrigger
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

        let state = TerminalTabManager.shared.paneStates[paneId]?.connectionState ?? .idle
        terminalView.acceptsTerminalInput = state.isConnected

        let autoReconnectEnabled = TerminalDefaults.sshAutoReconnectEnabled()
        let shouldStartSSHConnection: Bool = {
            switch state {
            case .connecting, .reconnecting, .connected:
                return true
            case .disconnected:
                return isActive && autoReconnectEnabled
            case .failed, .idle:
                return false
            }
        }()

        if shouldStartSSHConnection, context.coordinator.lastStartRequestState != state {
            let coordinator = context.coordinator
            coordinator.lastStartRequestState = state
            DispatchQueue.main.async { [weak terminalView] in
                guard let terminalView else { return }
                startSSHConnectionIfNeeded(
                    terminal: terminalView,
                    coordinator: coordinator,
                    state: TerminalTabManager.shared.paneStates[paneId]?.connectionState ?? .idle
                )
            }
        } else if !shouldStartSSHConnection {
            context.coordinator.lastStartRequestState = nil
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        guard let terminalView = uiView as? GhosttyTerminalView else { return }

        let paneStillExists = TerminalTabManager.shared.paneStates[coordinator.paneId] != nil
        if paneStillExists {
            terminalView.pauseRendering()
            TerminalTabManager.shared.keyboardCoordinator.setWindowAttached(false, for: coordinator.paneId)
            coordinator.preservePane = true
            return
        }

        coordinator.terminal = nil
        TerminalTabManager.shared.unregisterTerminal(for: coordinator.paneId)
        coordinator.cancelShell()
    }

    private func configureExistingTerminal(_ terminal: GhosttyTerminalView, coordinator: TerminalPaneSSHCoordinator) {
        terminal.onProcessExit = onProcessExit
        terminal.onVoiceButtonTapped = onVoiceTrigger
        terminal.onPwdChange = { [paneId] rawDirectory in
            DispatchQueue.main.async {
                TerminalTabManager.shared.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
            }
        }
        terminal.onTitleChange = { [paneId] title in
            TerminalTabManager.shared.updatePaneTitle(paneId, rawTitle: title)
        }
        terminal.onZoomAction = { [paneId] action in
            TerminalTabManager.shared.handleTerminalZoom(action, for: paneId)
        }
        terminal.applyPresentationOverrides(TerminalTabManager.shared.presentationOverrides(for: paneId))
        terminal.writeCallback = { [weak coordinator] data in
            coordinator?.sendToSSH(data)
        }
        coordinator.installRichPasteInterception(on: terminal)
        terminal.onResize = { [weak coordinator] cols, rows in
            coordinator?.handleResize(cols: cols, rows: rows)
        }
    }

    private func startSSHConnectionIfNeeded(
        terminal: GhosttyTerminalView,
        coordinator: TerminalPaneSSHCoordinator,
        state: ConnectionState
    ) {
        guard TerminalTabManager.shared.paneStates[paneId] != nil else { return }
        guard TerminalTabManager.shared.shellId(for: paneId) == nil else { return }
        guard coordinator.shellTask == nil else { return }
        guard !TerminalTabManager.shared.isShellStartInFlight(for: paneId) else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        guard !TerminalTabManager.shared.isSuspendingForBackground else { return }

        let autoReconnectEnabled = TerminalDefaults.sshAutoReconnectEnabled()
        switch state {
        case .connecting, .reconnecting, .connected:
            break
        case .disconnected:
            guard isActive && autoReconnectEnabled else { return }
            TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connecting)
        case .failed, .idle:
            return
        }

        coordinator.startSSHConnection(terminal: terminal)
    }
}
#endif
