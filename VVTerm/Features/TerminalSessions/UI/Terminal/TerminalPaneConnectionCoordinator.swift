import CoreGraphics
import Foundation

/// Selects one transport coordinator once per pane. Transport state itself is
/// retained by TerminalTabManager so SwiftUI view reconstruction cannot replace
/// a live ET session.
@MainActor
final class TerminalPaneConnectionCoordinator {
    private enum Backend {
        case ssh(TerminalPaneSSHCoordinator)
        case eternalTerminal(EternalTerminalPaneCoordinator)
    }

    private let backend: Backend

    init(
        paneId: UUID,
        server: Server,
        credentials: ServerCredentials,
        richPasteUIModel: TerminalRichPasteUIModel
    ) {
        if server.connectionMode == .eternalTerminal {
            backend = .eternalTerminal(EternalTerminalPaneCoordinator(
                paneId: paneId,
                server: server,
                credentials: credentials
            ))
        } else {
            backend = .ssh(TerminalPaneSSHCoordinator(
                paneId: paneId,
                server: server,
                credentials: credentials,
                sshClient: SSHClient(),
                richPasteUIModel: richPasteUIModel
            ))
        }
    }

    var paneId: UUID {
        switch backend {
        case .ssh(let coordinator): coordinator.paneId
        case .eternalTerminal(let coordinator): coordinator.paneId
        }
    }

    var terminal: GhosttyTerminalView? {
        get {
            switch backend {
            case .ssh(let coordinator): coordinator.terminal
            case .eternalTerminal(let coordinator): coordinator.terminal
            }
        }
        set {
            switch backend {
            case .ssh(let coordinator): coordinator.terminal = newValue
            case .eternalTerminal(let coordinator): coordinator.terminal = newValue
            }
        }
    }

    var isTerminalReady: Bool {
        get {
            switch backend {
            case .ssh(let coordinator): coordinator.isTerminalReady
            case .eternalTerminal(let coordinator): coordinator.isTerminalReady
            }
        }
        set {
            switch backend {
            case .ssh(let coordinator): coordinator.isTerminalReady = newValue
            case .eternalTerminal(let coordinator): coordinator.isTerminalReady = newValue
            }
        }
    }

    var preservePane: Bool {
        get {
            switch backend {
            case .ssh(let coordinator): coordinator.preservePane
            case .eternalTerminal(let coordinator): coordinator.preservePane
            }
        }
        set {
            switch backend {
            case .ssh(let coordinator): coordinator.preservePane = newValue
            case .eternalTerminal(let coordinator): coordinator.preservePane = newValue
            }
        }
    }

    var lastReportedSize: CGSize {
        get {
            switch backend {
            case .ssh(let coordinator): coordinator.lastReportedSize
            case .eternalTerminal(let coordinator): coordinator.lastReportedSize
            }
        }
        set {
            switch backend {
            case .ssh(let coordinator): coordinator.lastReportedSize = newValue
            case .eternalTerminal(let coordinator): coordinator.lastReportedSize = newValue
            }
        }
    }

    var hasLiveConnection: Bool {
        switch backend {
        case .ssh:
            TerminalTabManager.shared.shellId(for: paneId) != nil
        case .eternalTerminal:
            TerminalTabManager.shared.existingEternalTerminalRuntime(for: paneId) != nil
        }
    }

    var isConnectionStartInFlight: Bool {
        switch backend {
        case .ssh(let coordinator):
            coordinator.shellTask != nil || TerminalTabManager.shared.isShellStartInFlight(for: paneId)
        case .eternalTerminal:
            TerminalTabManager.shared.existingEternalTerminalRuntime(for: paneId)?.isStartInFlight == true
        }
    }

    func installRichPasteInterception(on terminal: GhosttyTerminalView) {
        guard case .ssh(let coordinator) = backend else { return }
        coordinator.installRichPasteInterception(on: terminal)
    }

    func sendToTransport(_ data: Data) {
        switch backend {
        case .ssh(let coordinator): coordinator.sendToSSH(data)
        case .eternalTerminal(let coordinator): coordinator.send(data)
        }
    }

    func handleResize(cols: Int, rows: Int) {
        switch backend {
        case .ssh(let coordinator): coordinator.handleResize(cols: cols, rows: rows)
        case .eternalTerminal(let coordinator): coordinator.handleResize(cols: cols, rows: rows)
        }
    }

    func startConnection(terminal: GhosttyTerminalView) {
        switch backend {
        case .ssh(let coordinator): coordinator.startSSHConnection(terminal: terminal)
        case .eternalTerminal(let coordinator): coordinator.start(terminal: terminal)
        }
    }

    func cancelConnection() {
        switch backend {
        case .ssh(let coordinator): coordinator.cancelShell()
        case .eternalTerminal(let coordinator): coordinator.cancel()
        }
    }
}

@MainActor
private final class EternalTerminalPaneCoordinator {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    weak var terminal: GhosttyTerminalView?
    var isTerminalReady = false
    var preservePane = false
    var lastReportedSize: CGSize = .zero

    init(paneId: UUID, server: Server, credentials: ServerCredentials) {
        self.paneId = paneId
        self.server = server
        self.credentials = credentials
    }

    func start(terminal: GhosttyTerminalView) {
        self.terminal = terminal
        let runtime = TerminalTabManager.shared.eternalTerminalRuntime(
            for: paneId,
            server: server,
            credentials: credentials
        )
        runtime.attach(to: terminal)
        guard let size = terminal.currentTerminalGridSize else { return }
        runtime.resize(cols: size.cols, rows: size.rows)
        runtime.startIfNeeded()
    }

    func send(_ data: Data) {
        TerminalTabManager.shared.existingEternalTerminalRuntime(for: paneId)?.send(data)
    }

    func handleResize(cols: Int, rows: Int) {
        guard let runtime = TerminalTabManager.shared.existingEternalTerminalRuntime(for: paneId) else {
            return
        }
        runtime.resize(cols: cols, rows: rows)
        runtime.startIfNeeded()
    }

    func cancel() {
        guard TerminalTabManager.shared.paneStates[paneId] == nil else { return }
        Task { await TerminalTabManager.shared.unregisterEternalTerminalRuntime(for: paneId) }
    }
}
