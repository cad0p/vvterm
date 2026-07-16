//
//  iOSContentView.swift
//  VVTerm
//

import SwiftUI
import StoreKit
#if os(iOS)
struct iOSContentView: View {
    /// Keeps one tab-open operation alive if its navigation route is popped and retried.
    private struct PendingConnection {
        let operationID: UUID
        let task: Task<TerminalTab, Error>
    }

    let fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var tabManager = TerminalTabManager.shared
    @StateObject private var viewTabConfig = ViewTabConfigurationManager.shared
    @StateObject private var engagementTracker = EngagementTracker.shared
    @Environment(\.requestReview) private var requestReview

    @State private var selectedWorkspace: Workspace?
    @State private var selectedEnvironment: ServerEnvironment?
    @State private var terminalRoute: ServerTerminalNavigationRoute?
    @State private var pendingConnections: [UUID: PendingConnection] = [:]
    @State private var showingTabLimitAlert = false
    @State private var lockedServerName: String?

    private var preferredConnectViewId: String {
        viewTabConfig.effectiveDefaultTab()
    }

    private var terminalPresentation: Binding<Bool> {
        Binding(
            get: { terminalRoute != nil },
            set: { isPresented in
                if !isPresented {
                    terminalRoute = nil
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ServerListScreen(
                serverManager: serverManager,
                tabManager: tabManager,
                fileTabs: fileTabs,
                fileBrowser: fileBrowser,
                selectedWorkspace: $selectedWorkspace,
                selectedEnvironment: $selectedEnvironment,
                onServerSelected: { server in
                    beginConnection(to: server)
                },
                onActiveConnectionSelected: { server in
                    terminalRoute = .active(serverId: server.id)
                }
            )
            .navigationDestination(isPresented: terminalPresentation) {
                if let terminalRoute {
                    ServerTerminalRoute(
                        tabManager: tabManager,
                        serverManager: serverManager,
                        fileTabs: fileTabs,
                        fileBrowser: fileBrowser,
                        route: terminalRoute,
                        onBack: { self.terminalRoute = nil }
                    )
                }
            }
        }
        .navigationBarAppearance(backgroundColor: .clear, isTranslucent: true, shadowColor: .clear)
        .adaptiveSoftScrollEdges()
        .onAppear {
            // Select first workspace on appear
            if selectedWorkspace == nil {
                selectedWorkspace = serverManager.workspaces.first
            }
        }
        .onChange(of: serverManager.workspaces) { workspaces in
            if selectedWorkspace == nil {
                selectedWorkspace = workspaces.first
            }
        }
        .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
        .onChange(of: terminalRoute?.serverId) { serverId in
            if serverId == nil {
                engagementTracker.noteTerminalSessionEnded(
                    otherTerminalsActive: false
                )
            }
        }
        .onChange(of: engagementTracker.reviewRequestToken) { _ in
            requestReview()
        }
        .lockedItemAlert(
            .server,
            itemName: lockedServerName ?? "",
            isPresented: Binding(
                get: { lockedServerName != nil },
                set: { if !$0 { lockedServerName = nil } }
            )
        )
    }

    private func beginConnection(to server: Server) {
        guard terminalRoute == nil else { return }

        let attemptID = UUID()
        terminalRoute = .connecting(server: server, attemptID: attemptID)
        tabManager.selectedViewByServer[server.id] = preferredConnectViewId
        let pendingConnection = pendingConnection(for: server)

        Task {
            defer {
                finishPendingConnection(pendingConnection, for: server.id)
            }

            do {
                let tab = try await pendingConnection.task.value
                guard resolveConnection(for: attemptID, as: .succeeded) else {
                    return
                }
                tabManager.selectedViewByServer[server.id] = preferredConnectViewId
                tabManager.selectedTabByServer[server.id] = tab.id
            } catch {
                guard resolveConnection(for: attemptID, as: .failed) else { return }
                guard let error = error as? VVTermError else { return }
                switch error {
                case .proRequired:
                    showingTabLimitAlert = true
                case .serverLocked(let name):
                    lockedServerName = name
                default:
                    break
                }
            }
        }
    }

    @discardableResult
    private func resolveConnection(
        for attemptID: UUID,
        as resolution: ServerTerminalNavigationRoute.ConnectionResolution
    ) -> Bool {
        guard let terminalRoute,
              terminalRoute.connectionAttemptID == attemptID else {
            return false
        }
        self.terminalRoute = terminalRoute.resolvingConnection(
            for: attemptID,
            as: resolution
        )
        return true
    }

    private func pendingConnection(for server: Server) -> PendingConnection {
        if let pendingConnection = pendingConnections[server.id] {
            return pendingConnection
        }

        let pendingConnection = PendingConnection(
            operationID: UUID(),
            task: Task {
                try await tabManager.openTab(for: server)
            }
        )
        pendingConnections[server.id] = pendingConnection
        return pendingConnection
    }

    private func finishPendingConnection(
        _ pendingConnection: PendingConnection,
        for serverID: UUID
    ) {
        guard let currentConnection = pendingConnections[serverID],
              currentConnection.operationID == pendingConnection.operationID else {
            return
        }
        pendingConnections.removeValue(forKey: serverID)
    }
}

#endif
