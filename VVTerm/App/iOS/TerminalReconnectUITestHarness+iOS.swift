#if os(iOS) && DEBUG
import SwiftUI
import UIKit

/// Boots the production server route against a loopback SSH fixture. Only the
/// app's root data is seeded here; terminal, reconnect, responder, and SSH work
/// all run through the same types used by the normal iOS route.
struct TerminalReconnectUITestHarness: View {
    private enum FixtureState {
        case preparing
        case ready(Server)
        case failed(String)
    }

    private enum FixtureError: LocalizedError {
        case missingUsername
        case invalidPrivateKey

        var errorDescription: String? {
            switch self {
            case .missingUsername:
                "Missing loopback SSH username"
            case .invalidPrivateKey:
                "Invalid loopback SSH private key"
            }
        }
    }

    private static let serverId = UUID(uuidString: "D3A03FD5-453E-43AC-8BB5-838E5D5D1990")!
    private static let workspaceId = UUID(uuidString: "B51203C0-15B5-47E3-9322-D4D7E8A51990")!
    private static let sshHost = "127.0.0.1"
    private static let sshPort = 22_229
    private static let fixtureDefaults = UserDefaults(suiteName: "app.vivy.vvterm.dev199-ui-test")!
    private static let fixturePrivateKeyDefaultsKey = "sshPrivateKeyBase64"
    private static let fixtureUsernameDefaultsKey = "sshUsername"

    @ObservedObject private var tabManager = TerminalTabManager.shared
    @ObservedObject private var serverManager = ServerManager.shared
    @StateObject private var fileTabs: RemoteFileTabManager
    @StateObject private var fileBrowser: RemoteFileBrowserStore
    @State private var fixtureState = FixtureState.preparing

    init() {
        _fileTabs = StateObject(
            wrappedValue: RemoteFileTabManager(defaults: Self.fixtureDefaults)
        )
        _fileBrowser = StateObject(
            wrappedValue: RemoteFileBrowserStore(defaults: Self.fixtureDefaults)
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            NavigationStack {
                switch fixtureState {
                case .preparing:
                    ProgressView()
                case .ready(let server):
                    ServerTerminalRoute(
                        tabManager: tabManager,
                        serverManager: serverManager,
                        fileTabs: fileTabs,
                        fileBrowser: fileBrowser,
                        requestedServerId: server.id,
                        connectingServer: server,
                        isConnecting: false,
                        onBack: {}
                    )
                case .failed(let message):
                    Text(message)
                }
            }

            TerminalReconnectDiagnosticsLabel(
                serverId: activeServer?.id,
                fallback: fixtureDiagnosticFallback
            )
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
        }
        .task {
            await prepareFixture()
        }
    }

    private var activeServer: Server? {
        guard case .ready(let server) = fixtureState else { return nil }
        return server
    }

    private var fixtureDiagnosticFallback: String {
        switch fixtureState {
        case .preparing:
            "setup=preparing"
        case .ready:
            "setup=ready pane=missing"
        case .failed(let error):
            "setup=failed error=\(error)"
        }
    }

    private func prepareFixture() async {
        guard case .preparing = fixtureState else { return }

        do {
            let username = try fixtureUsername()
            let privateKey = try fixturePrivateKey()
            let server = Server(
                id: Self.serverId,
                workspaceId: Self.workspaceId,
                environment: .development,
                name: "DEV-199 Loopback",
                host: Self.sshHost,
                port: Self.sshPort,
                username: username,
                connectionMode: .standard,
                authMethod: .sshKey,
                tmuxEnabledOverride: false
            )

            await tabManager.resetForTesting()
            KnownHostsManager.shared.remove(host: Self.sshHost, port: Self.sshPort)
            try KeychainManager.shared.deleteCredentials(for: server.id)
            try KeychainManager.shared.storeSSHKey(
                for: server.id,
                privateKey: privateKey,
                passphrase: nil
            )
            serverManager.servers = [server]

            let tab = try await tabManager.openTab(for: server)
            tabManager.selectedTabByServer[server.id] = tab.id
            tabManager.selectedViewByServer[server.id] = ConnectionViewTab.terminal.id
            fixtureState = .ready(server)
        } catch {
            fixtureState = .failed(error.localizedDescription)
        }
    }

    private func fixtureUsername() throws -> String {
        guard let username = Self.fixtureDefaults.string(forKey: Self.fixtureUsernameDefaultsKey),
              !username.isEmpty else { throw FixtureError.missingUsername }
        return username
    }

    private func fixturePrivateKey() throws -> Data {
        guard let encoded = Self.fixtureDefaults.string(forKey: Self.fixturePrivateKeyDefaultsKey),
              let data = Data(base64Encoded: encoded),
              !data.isEmpty else {
            throw FixtureError.invalidPrivateKey
        }
        return data
    }

}

private struct TerminalReconnectDiagnosticsLabel: UIViewRepresentable {
    let serverId: UUID?
    let fallback: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = "vvterm.reconnectTest.diagnostics"
        label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        label.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        label.isUserInteractionEnabled = false
        label.numberOfLines = 12
        label.textColor = .white
        context.coordinator.install(label)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        context.coordinator.update(serverId: serverId, fallback: fallback)
    }

    static func dismantleUIView(_ label: UILabel, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Coordinator {
        private weak var label: UILabel?
        private weak var configuredTerminal: GhosttyTerminalView?
        private var serverId: UUID?
        private var fallback = "setup=preparing"
        private var timer: Timer?

        func install(_ label: UILabel) {
            self.label = label
            let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            refresh()
        }

        func update(serverId: UUID?, fallback: String) {
            self.serverId = serverId
            self.fallback = fallback
            refresh()
        }

        func invalidate() {
            timer?.invalidate()
            timer = nil
        }

        private func refresh() {
            let tabManager = TerminalTabManager.shared
            guard let serverId,
                  let paneId = tabManager.selectedTab(for: serverId)?.focusedPaneId else {
                publish(fallback)
                return
            }

            let state = tabManager.paneStates[paneId]?.connectionState ?? .idle
            let title = tabManager.runtimeTitleByPane[paneId] ?? "none"
            let workingDirectory = tabManager.paneStates[paneId]?.workingDirectory ?? "none"
            guard let terminal = tabManager.getTerminal(for: paneId) else {
                publish("setup=ready state=\(connectionToken(state)) title=\(title) terminal=missing")
                return
            }

            if configuredTerminal !== terminal {
                terminal.keyboardUITestSetHardwareKeyboardAttached(false)
                configuredTerminal = terminal
            }
            terminal.isAccessibilityElement = true
            terminal.accessibilityIdentifier = "vvterm.reconnectTest.terminalSurface"
            let keyboard = tabManager.keyboardCoordinator
            let keyboardHeight = keyboard.softwareKeyboardEndFrame?.height ?? 0
            let shellId = tabManager.shellId(for: paneId)
            let terminalDiagnostics = terminal.keyboardUITestDiagnostics(
                keyboardVisible: keyboard.isSoftwareKeyboardVisible,
                keyboardHeight: keyboardHeight
            )
            publish([
                "setup=ready",
                "state=\(connectionToken(state))",
                "title=\(title)",
                "cwd=\(workingDirectory)",
                "shell=\(shellId != nil)",
                "shellId=\(shellId?.uuidString ?? "none")",
                terminalDiagnostics,
            ].joined(separator: " "))
        }

        private func publish(_ diagnostics: String) {
            label?.text = diagnostics
            label?.accessibilityLabel = diagnostics
        }

        private func connectionToken(_ state: ConnectionState) -> String {
            switch state {
            case .disconnected:
                "disconnected"
            case .connecting:
                "connecting"
            case .connected:
                "connected"
            case .reconnecting(let attempt):
                "reconnecting\(attempt)"
            case .failed:
                "failed"
            case .idle:
                "idle"
            }
        }
    }
}
#endif
