#if os(macOS)
import Foundation
import SwiftUI
import AppKit

extension View {
    func terminalCommandFocusValues(
        activeServerId: UUID?,
        activePaneId: UUID?,
        splitActions: TerminalSplitActions?
    ) -> some View {
        self
            .focusedValue(\.activeServerId, activeServerId)
            .focusedValue(\.activePaneId, activePaneId)
            .focusedSceneValue(\.terminalSplitActions, splitActions)
    }

    func terminalKeyboardAvoidance(
        focusedPaneId: UUID?,
        paneIds: [UUID],
        terminalRegistryVersion: Int,
        terminalProvider: @escaping (UUID) -> GhosttyTerminalView?
    ) -> some View {
        self
    }
}

// MARK: - SSH Terminal Pane Wrapper

/// Wraps SSH connection and Ghostty terminal for a pane
struct SSHTerminalPaneWrapper: NSViewRepresentable {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    let isActive: Bool
    let terminalContextMenuActions: TerminalContextMenuActions
    let onProcessExit: () -> Void
    let onReady: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeNSView(context: Context) -> NSView {
        // Ensure Ghostty app is ready
        guard let app = ghosttyApp.app else {
            return NSView(frame: .zero)
        }

        let coordinator = context.coordinator

        // Check if terminal already exists for this pane (reuse to save memory)
        if let existingTerminal = TerminalTabManager.shared.getTerminal(for: paneId) {
            coordinator.preservePane = true
            coordinator.terminal = existingTerminal

            // Update resize callback to use tab manager's registered SSH client
            existingTerminal.onResize = { [weak coordinator] cols, rows in
                coordinator?.handleResize(cols: cols, rows: rows)
            }
            existingTerminal.onPwdChange = { [paneId] rawDirectory in
                TerminalTabManager.shared.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
            }
            existingTerminal.onTitleChange = { [paneId] title in
                TerminalTabManager.shared.updatePaneTitle(paneId, rawTitle: title)
            }
            existingTerminal.onZoomAction = { [paneId] action in
                TerminalTabManager.shared.handleTerminalZoom(action, for: paneId)
            }
            existingTerminal.terminalContextMenuActions = terminalContextMenuActions
            existingTerminal.applyPresentationOverrides(TerminalTabManager.shared.presentationOverrides(for: paneId))
            existingTerminal.writeCallback = { [weak coordinator] data in
                coordinator?.sendToSSH(data)
            }
            coordinator.installRichPasteInterception(on: existingTerminal)

            // Re-wrap in scroll view
            let scrollView = TerminalScrollView(
                contentSize: NSSize(width: 800, height: 600),
                surfaceView: existingTerminal
            )

            DispatchQueue.main.async {
                onReady()
                if TerminalTabManager.shared.shellId(for: paneId) == nil {
                    coordinator.startSSHConnection(terminal: existingTerminal)
                }
            }

            return scrollView
        }

        // Create Ghostty terminal with custom I/O for SSH
        let terminalView = GhosttyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: paneId.uuidString,
            useCustomIO: true
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            onReady()
            if let terminalView = terminalView {
                coordinator?.startSSHConnection(terminal: terminalView)
            }
        }
        terminalView.onProcessExit = onProcessExit
        terminalView.onPwdChange = { [paneId] rawDirectory in
            TerminalTabManager.shared.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
        }
        terminalView.onTitleChange = { [paneId] title in
            TerminalTabManager.shared.updatePaneTitle(paneId, rawTitle: title)
        }
        terminalView.onZoomAction = { [paneId] action in
            TerminalTabManager.shared.handleTerminalZoom(action, for: paneId)
        }
        terminalView.terminalContextMenuActions = terminalContextMenuActions
        terminalView.applyPresentationOverrides(TerminalTabManager.shared.presentationOverrides(for: paneId))

        // Store terminal reference
        coordinator.terminal = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        TerminalTabManager.shared.registerTerminal(terminalView, for: paneId)

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
        if let scrollView = nsView as? TerminalScrollView {
            scrollView.shouldOwnFirstResponder = isActive
            let terminalView = scrollView.surfaceView
            terminalView.terminalContextMenuActions = terminalContextMenuActions
            if terminalView.surfacePresentationOverrides != TerminalTabManager.shared.presentationOverrides(for: paneId) {
                terminalView.applyPresentationOverrides(TerminalTabManager.shared.presentationOverrides(for: paneId))
            }
        }
    }

    func makeCoordinator() -> TerminalPaneSSHCoordinator {
        // Use a dedicated SSH client per pane to avoid channel contention
        // and startup races when many panes/tabs are opened quickly.
        let client = SSHClient()
        return TerminalPaneSSHCoordinator(
            paneId: paneId,
            server: server,
            credentials: credentials,
            sshClient: client,
            richPasteUIModel: richPasteUIModel
        )
    }
}
#endif
