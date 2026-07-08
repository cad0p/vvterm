//
//  iOSContentView.swift
//  VVTerm
//

import SwiftUI
import StoreKit
#if os(iOS)
struct iOSContentView: View {
    let fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var tabManager = TerminalTabManager.shared
    @StateObject private var viewTabConfig = ViewTabConfigurationManager.shared
    @StateObject private var engagementTracker = EngagementTracker.shared
    @Environment(\.requestReview) private var requestReview

    @State private var selectedWorkspace: Workspace?
    @State private var selectedServer: Server?
    @State private var selectedEnvironment: ServerEnvironment?
    @State private var showingTerminal = false
    @State private var showingTabLimitAlert = false
    @State private var lockedServerName: String?
    @State private var connectingServer: Server?
    @State private var isConnecting = false

    private var hasTerminalNavigationContext: Bool {
        isConnecting
            || connectingServer != nil
            || tabManager.tabsByServer.values.contains { !$0.isEmpty }
            || fileTabs.tabsByServer.values.contains { !$0.isEmpty }
    }

    private var preferredConnectViewId: String {
        viewTabConfig.effectiveDefaultTab()
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
                selectedServer: $selectedServer,
                showingTerminal: $showingTerminal,
                onServerSelected: { server in
                    Task {
                        await MainActor.run {
                            selectedServer = server
                            connectingServer = server
                            isConnecting = true
                            showingTerminal = true
                            tabManager.selectedViewByServer[server.id] = preferredConnectViewId
                        }

                        do {
                            let tab = try await tabManager.openTab(for: server)
                            await MainActor.run {
                                tabManager.selectedViewByServer[server.id] = preferredConnectViewId
                                tabManager.selectedTabByServer[server.id] = tab.id
                                isConnecting = false
                                connectingServer = nil
                            }
                        } catch let error as VVTermError {
                            await MainActor.run {
                                isConnecting = false
                                connectingServer = nil
                                showingTerminal = false

                                switch error {
                                case .proRequired:
                                    showingTabLimitAlert = true
                                case .serverLocked(let name):
                                    lockedServerName = name
                                default:
                                    break
                                }
                            }
                        } catch {
                            await MainActor.run {
                                isConnecting = false
                                connectingServer = nil
                                showingTerminal = false
                            }
                        }
                    }
                }
            )
            .navigationDestination(isPresented: $showingTerminal) {
                ServerTerminalRoute(
                    tabManager: tabManager,
                    serverManager: serverManager,
                    fileTabs: fileTabs,
                    fileBrowser: fileBrowser,
                    requestedServerId: selectedServer?.id,
                    connectingServer: connectingServer,
                    isConnecting: isConnecting,
                    onBack: { showingTerminal = false }
                )
            }
        }
        .navigationBarAppearance(backgroundColor: .clear, isTranslucent: true, shadowColor: .clear)
        .adaptiveSoftScrollEdges()
        .onAppear {
            // Select first workspace on appear
            if selectedWorkspace == nil {
                selectedWorkspace = serverManager.workspaces.first
            }
            if showingTerminal && !hasTerminalNavigationContext {
                showingTerminal = false
            }
        }
        .onChange(of: serverManager.workspaces) { workspaces in
            if selectedWorkspace == nil {
                selectedWorkspace = workspaces.first
            }
        }
        // Sync navigation state with tab state - dismiss terminal if all tabs are gone
        .onChangeCompat(of: tabManager.tabsByServer) { _ in
            if showingTerminal && !hasTerminalNavigationContext {
                showingTerminal = false
            }
            if let connectingServer,
               !tabManager.tabs(for: connectingServer.id).isEmpty {
                isConnecting = false
                self.connectingServer = nil
            }
        }
        .onChangeCompat(of: fileTabs.tabsByServer) { _ in
            if showingTerminal && !hasTerminalNavigationContext {
                showingTerminal = false
            }
        }
        .onChange(of: tabManager.selectedTabByServer) { _ in
            if showingTerminal && !hasTerminalNavigationContext {
                showingTerminal = false
            }
        }
        .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
        .proUpgradePresentation(isPresented: $engagementTracker.shouldShowProIntro, source: .postFirstConnection)
        .onChange(of: showingTerminal) { isShowing in
            if !isShowing {
                engagementTracker.noteTerminalSessionEnded(
                    otherTerminalsActive: false,
                    isPro: StoreManager.shared.isPro
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
}

#endif
