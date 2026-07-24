//
//  iOSContentView.swift
//  VVTerm
//

import SwiftUI
import StoreKit
#if os(iOS)
import UIKit
#endif

#if os(iOS)
struct iOSContentView: View {
    let fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var sessionManager = ConnectionSessionManager.shared
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
        isConnecting || connectingServer != nil || !sessionManager.sessions.isEmpty
    }

    private var preferredConnectViewId: String {
        viewTabConfig.isTabVisible(ConnectionViewTab.terminal.id)
            ? ConnectionViewTab.terminal.id
            : viewTabConfig.effectiveDefaultTab()
    }

    var body: some View {
        NavigationStack {
            iOSServerListView(
                serverManager: serverManager,
                sessionManager: sessionManager,
                fileBrowser: fileBrowser,
                selectedWorkspace: $selectedWorkspace,
                selectedEnvironment: $selectedEnvironment,
                showingTerminal: $showingTerminal,
                onServerSelected: { server in
                    Task {
                        await MainActor.run {
                            selectedServer = server
                            connectingServer = server
                            isConnecting = true
                            showingTerminal = true
                            sessionManager.selectedViewByServer[server.id] = preferredConnectViewId
                        }

                        do {
                            let session = try await sessionManager.openConnection(to: server)
                            await MainActor.run {
                                sessionManager.selectedViewByServer[server.id] = preferredConnectViewId
                                sessionManager.selectedSessionId = session.id
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
                iOSTerminalView(
                    sessionManager: sessionManager,
                    serverManager: serverManager,
                    fileTabs: fileTabs,
                    fileBrowser: fileBrowser,
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
        // Sync navigation state with session state - dismiss terminal if session is gone
        .onChangeCompat(of: sessionManager.sessions) { _ in
            if showingTerminal && !hasTerminalNavigationContext {
                showingTerminal = false
            }
            if let connectingServer,
               sessionManager.sessions.contains(where: { $0.serverId == connectingServer.id }) {
                isConnecting = false
                self.connectingServer = nil
            }
        }
        .onChange(of: sessionManager.selectedSessionId) { selectedId in
            if showingTerminal && selectedId == nil && !hasTerminalNavigationContext {
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

struct iOSServerListView: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var sessionManager: ConnectionSessionManager
    let fileBrowser: RemoteFileBrowserStore
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedEnvironment: ServerEnvironment?
    @Binding var showingTerminal: Bool
    let onServerSelected: (Server) -> Void

    @ObservedObject private var storeManager = StoreManager.shared
    @ObservedObject private var viewTabConfig = ViewTabConfigurationManager.shared
    @State private var showingAddServer = false
    @State private var showingAddWorkspace = false
    @State private var showingSettings = false
    @State private var showingWorkspacePicker = false
    @State private var showingCreateEnvironment = false
    @State private var editingEnvironment: ServerEnvironment?
    @State private var environmentToDelete: ServerEnvironment?
    @State private var searchText = ""
    @State private var serverToEdit: Server?
    @State private var serverToMove: Server?
    @State private var lockedServerAlert: Server?
    @State private var navigationBarAppearanceToken = UUID()
    @State private var showingCustomEnvironmentAlert = false
    @State private var addServerPrefill: ServerFormPrefill?
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue

    private var canAddServer: Bool {
        !serverManager.workspaces.isEmpty
    }

    private var preferredConnectViewId: String {
        viewTabConfig.isTabVisible(ConnectionViewTab.terminal.id)
            ? ConnectionViewTab.terminal.id
            : viewTabConfig.effectiveDefaultTab()
    }

    var body: some View {
        List {
            serversSection
            activeConnectionsSection
        }
        .id(listRefreshIdentity)
        .overlay(alignment: .center) {
            if filteredServers.isEmpty {
                NoServersEmptyState(
                    onAddServer: { presentAddServer() },
                    onAddWorkspace: { showingAddWorkspace = true },
                    requiresWorkspace: serverManager.workspaces.isEmpty
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search servers")
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .id(navigationBarAppearanceToken)
        .toolbar {
            ToolbarItem(placement: .principal) {
                workspaceToolbarButton
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentAddServer()
                } label: {
                    Image(systemName: "plus")
                }
            }

            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
        .onAppear {
            navigationBarAppearanceToken = UUID()
        }
        .sheet(isPresented: $showingAddServer) {
            NavigationStack {
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: selectedWorkspace,
                    prefill: addServerPrefill,
                    onSave: { _ in showingAddServer = false }
                )
            }
            .adaptiveSoftScrollEdges()
        }
        .sheet(isPresented: $showingAddWorkspace) {
            NavigationStack {
                WorkspaceFormSheet(
                    serverManager: serverManager,
                    onSave: { workspace in
                        selectedWorkspace = workspace
                        showingAddWorkspace = false
                    }
                )
            }
            .adaptiveSoftScrollEdges()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .modifier(AppearanceModifier())
                .adaptiveSoftScrollEdges()
        }
        .sheet(isPresented: $showingWorkspacePicker) {
            NavigationStack {
                iOSWorkspacePickerView(
                    serverManager: serverManager,
                    selectedWorkspace: $selectedWorkspace,
                    onDismiss: { showingWorkspacePicker = false }
                )
            }
            .adaptiveSoftScrollEdges()
        }
        .sheet(item: $serverToEdit) { server in
            NavigationStack {
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: selectedWorkspace,
                    server: server,
                    onSave: { updatedServer in
                        handleSavedServer(updatedServer, originalServer: server)
                        serverToEdit = nil
                    }
                )
            }
            .adaptiveSoftScrollEdges()
        }
        .sheet(item: $serverToMove) { server in
            NavigationStack {
                MoveServerSheet(
                    serverManager: serverManager,
                    server: server,
                    onMove: { updatedServer in
                        handleSavedServer(updatedServer, originalServer: server)
                        serverToMove = nil
                    }
                )
            }
            .adaptiveSoftScrollEdges()
        }
        .sheet(isPresented: $showingCreateEnvironment) {
            if let workspace = selectedWorkspace {
                EnvironmentFormSheet(
                    serverManager: serverManager,
                    workspace: workspace,
                    onSave: { updatedWorkspace, newEnvironment in
                        selectedWorkspace = updatedWorkspace
                        selectedEnvironment = newEnvironment
                        showingCreateEnvironment = false
                    }
                )
                .adaptiveSoftScrollEdges()
            }
        }
        .sheet(item: $editingEnvironment) { environment in
            if let workspace = selectedWorkspace {
                EnvironmentFormSheet(
                    serverManager: serverManager,
                    workspace: workspace,
                    environment: environment,
                    onSave: { updatedWorkspace, updatedEnvironment in
                        selectedWorkspace = updatedWorkspace
                        if selectedEnvironment?.id == updatedEnvironment.id {
                            selectedEnvironment = updatedEnvironment
                        }
                        editingEnvironment = nil
                    }
                )
                .adaptiveSoftScrollEdges()
            }
        }
        .alert(String(localized: "Delete Environment?"), isPresented: Binding(
            get: { environmentToDelete != nil },
            set: { if !$0 { environmentToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                guard let environment = environmentToDelete,
                      let workspace = selectedWorkspace else {
                    environmentToDelete = nil
                    return
                }
                Task {
                    let updatedWorkspace = try? await serverManager.deleteEnvironment(
                        environment,
                        in: workspace,
                        fallback: .production
                    )
                    await MainActor.run {
                        if let updatedWorkspace {
                            selectedWorkspace = updatedWorkspace
                        }
                        if selectedEnvironment?.id == environment.id {
                            selectedEnvironment = .production
                        }
                        environmentToDelete = nil
                    }
                }
            }
        } message: {
            let name = environmentToDelete?.displayName ?? String(localized: "Custom")
            Text(String(format: String(localized: "Servers in '%@' will be moved to Production."), name))
        }
        .lockedItemAlert(
            .server,
            itemName: lockedServerAlert?.name ?? "",
            isPresented: Binding(
                get: { lockedServerAlert != nil },
                set: { if !$0 { lockedServerAlert = nil } }
            )
        )
        .proFeatureAlert(
            title: String(localized: "Custom Environments"),
            message: String(localized: "Upgrade to Pro for custom environments"),
            source: .customEnvironment,
            isPresented: $showingCustomEnvironmentAlert
        )
        .onChange(of: showingAddWorkspace) { isPresented in
            guard !isPresented else { return }
            resumePendingPrefilledAddServerIfNeeded()
        }
        .onChange(of: showingAddServer) { isPresented in
            if !isPresented {
                addServerPrefill = nil
            }
        }
    }

    private func handleSavedServer(_ server: Server, originalServer: Server) {
        let movedAcrossWorkspaces = originalServer.workspaceId != server.workspaceId

        if movedAcrossWorkspaces,
           let destinationWorkspace = serverManager.workspace(withId: server.workspaceId) {
            selectedWorkspace = destinationWorkspace
            selectedEnvironment = nil
            return
        }

        if let selectedEnvironment,
           selectedEnvironment.id != server.environment.id {
            self.selectedEnvironment = nil
        }
    }

    private var environmentOptions: [ServerEnvironment] {
        selectedWorkspace?.environments ?? ServerEnvironment.builtInEnvironments
    }

    private var selectedWorkspaceName: String {
        selectedWorkspace?.name ?? String(localized: "Select Workspace")
    }

    private var selectedWorkspaceColorHex: String {
        selectedWorkspace?.colorHex ?? "#007AFF"
    }

    private var filteredServerCountText: String {
        let serverCount = filteredServers.count
        if serverCount == 1 {
            return String(format: String(localized: "%lld server"), Int64(serverCount))
        }
        return String(format: String(localized: "%lld servers"), Int64(serverCount))
    }

    private var workspaceToolbarButton: some View {
        Button {
            showingWorkspacePicker = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.fromHex(selectedWorkspaceColorHex))
                    .frame(width: 8, height: 8)

                Text(selectedWorkspaceName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 220)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selectedWorkspaceName)
        .accessibilityValue(filteredServerCountText)
        .accessibilityHint(String(localized: "Opens the workspace picker"))
    }

    @ViewBuilder
    private var serversSection: some View {
        Section {
            if filteredServers.isEmpty {
                Color.clear
                    .frame(height: 1)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredServers) { server in
                    iOSServerRow(
                        server: server,
                        onTap: { onServerSelected(server) },
                        onEdit: { serverToEdit = server },
                        onMove: { serverToMove = server },
                        onLockedTap: { lockedServerAlert = server }
                    )
                }
            }
        } header: {
            HStack {
                Text("Servers")

                Spacer()

                if selectedWorkspace != nil {
                    iOSEnvironmentFilterMenu(
                        selected: $selectedEnvironment,
                        environments: environmentOptions,
                        serverCounts: serverCountsByEnvironment,
                        onCreateCustom: {
                            if storeManager.isPro {
                                showingCreateEnvironment = true
                            } else {
                                showingCustomEnvironmentAlert = true
                            }
                        },
                        onEditCustom: { environment in
                            if storeManager.isPro {
                                editingEnvironment = environment
                            } else {
                                showingCustomEnvironmentAlert = true
                            }
                        },
                        onDeleteCustom: { environment in
                            if storeManager.isPro {
                                environmentToDelete = environment
                            } else {
                                showingCustomEnvironmentAlert = true
                            }
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var activeConnectionsSection: some View {
        if !activeConnections.isEmpty && !filteredServers.isEmpty {
            Section {
                ForEach(activeConnections) { connection in
                    iOSActiveConnectionRow(
                        session: connection.session,
                        title: sessionManager.displayTitle(for: connection.session),
                        tabCount: connection.tabCount,
                        onOpen: { openActiveConnection(connection) },
                        onDisconnect: { disconnectActiveConnection(connection) }
                    )
                }
            } header: {
                Text("Active Connections")
            }
        }
    }

    private struct ActiveConnection: Identifiable {
        let id: UUID
        let session: ConnectionSession
        let tabCount: Int
    }

    private var activeConnections: [ActiveConnection] {
        let grouped = Dictionary(grouping: sessionManager.sessions, by: { $0.serverId })
        return grouped.compactMap { serverId, sessions in
            guard let session = representativeSession(for: sessions) else { return nil }
            return ActiveConnection(id: serverId, session: session, tabCount: sessions.count)
        }
        .sorted { lhs, rhs in
            let lhsTitle = sessionManager.displayTitle(for: lhs.session)
            let rhsTitle = sessionManager.displayTitle(for: rhs.session)
            return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
        }
    }

    private func representativeSession(for sessions: [ConnectionSession]) -> ConnectionSession? {
        if let selectedId = sessionManager.selectedSessionId,
           let match = sessions.first(where: { $0.id == selectedId }) {
            return match
        }
        return sessions.first
    }

    private var filteredServers: [Server] {
        guard let workspace = selectedWorkspace else {
            // If no workspace selected, show all servers
            let allServers = serverManager.servers
            if searchText.isEmpty { return allServers }
            let lowercased = searchText.lowercased()
            return allServers.filter {
                $0.name.lowercased().contains(lowercased) ||
                $0.host.lowercased().contains(lowercased)
            }
        }

        var servers = serverManager.servers(in: workspace, environment: selectedEnvironment)

        if !searchText.isEmpty {
            let lowercased = searchText.lowercased()
            servers = servers.filter {
                $0.name.lowercased().contains(lowercased) ||
                $0.host.lowercased().contains(lowercased)
            }
        }

        return servers.sorted { $0.name < $1.name }
    }

    private var listRefreshIdentity: String {
        let workspaceID = selectedWorkspace?.id.uuidString ?? "all-workspaces"
        let environmentID = selectedEnvironment?.id.uuidString ?? "all-environments"
        let serverIDs = filteredServers.map { $0.id.uuidString }.joined(separator: ",")
        let activeConnectionIDs = activeConnections.map { $0.id.uuidString }.joined(separator: ",")
        return [workspaceID, environmentID, serverIDs, activeConnectionIDs].joined(separator: "|")
    }

    private var serverCountsByEnvironment: [UUID: Int] {
        guard let workspace = selectedWorkspace else { return [:] }

        var counts: [UUID: Int] = [:]
        let workspaceServers = serverManager.servers.filter { $0.workspaceId == workspace.id }

        for env in workspace.environments {
            counts[env.id] = workspaceServers.filter { $0.environment.id == env.id }.count
        }

        return counts
    }

    private func presentAddServer(prefill: ServerFormPrefill? = nil) {
        addServerPrefill = prefill
        guard canAddServer else {
            showingAddWorkspace = true
            return
        }
        showingAddServer = true
    }

    private func resumePendingPrefilledAddServerIfNeeded() {
        guard addServerPrefill != nil, canAddServer, !showingAddServer else { return }
        showingAddServer = true
    }

    private func openActiveConnection(_ connection: ActiveConnection) {
        let targetViewId = preferredConnectViewId
        Task {
            guard let server = server(for: connection.id) else { return }
            guard await AppLockManager.shared.ensureServerUnlocked(server) else { return }

            await MainActor.run {
                sessionManager.selectSession(connection.session)
                sessionManager.selectedViewByServer[server.id] = targetViewId
                showingTerminal = true
            }
        }
    }

    private func disconnectActiveConnection(_ connection: ActiveConnection) {
        fileBrowser.disconnect(serverId: connection.id)
        sessionManager.disconnectServer(connection.id)
    }

    private func server(for serverId: UUID) -> Server? {
        serverManager.servers.first { $0.id == serverId }
    }
}

// MARK: - iOS Environment Filter Menu

struct iOSEnvironmentFilterMenu: View {
    @Binding var selected: ServerEnvironment?
    let environments: [ServerEnvironment]
    let serverCounts: [UUID: Int]
    let onCreateCustom: () -> Void
    let onEditCustom: (ServerEnvironment) -> Void
    let onDeleteCustom: (ServerEnvironment) -> Void

    private var totalCount: Int {
        serverCounts.values.reduce(0, +)
    }

    var body: some View {
        Menu {
            // Built-in environments
            ForEach(ServerEnvironment.builtInEnvironments) { env in
                environmentButton(env)
            }

            // Custom environments
            let customEnvs = environments.filter { !$0.isBuiltIn }
            if !customEnvs.isEmpty {
                Divider()
                ForEach(customEnvs) { env in
                    environmentButton(env)
                }
            }

            Divider()

            Button {
                selected = nil
            } label: {
                HStack {
                    Text("All")
                    Spacer()
                    Text(String(format: String(localized: "(%lld)"), Int64(totalCount)))
                        .foregroundStyle(.secondary)
                    if selected == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            Button {
                onCreateCustom()
            } label: {
                Label(String(localized: "Custom..."), systemImage: "plus")
            }

            if let selectedEnvironment = selected, !selectedEnvironment.isBuiltIn {
                Divider()

                Button {
                    onEditCustom(selectedEnvironment)
                } label: {
                    Label(
                        String(format: String(localized: "Edit \"%@\"..."), selectedEnvironment.displayName),
                        systemImage: "pencil"
                    )
                }

                Button(role: .destructive) {
                    onDeleteCustom(selectedEnvironment)
                } label: {
                    Label(
                        String(format: String(localized: "Delete \"%@\"..."), selectedEnvironment.displayName),
                        systemImage: "trash"
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(selected?.color ?? .secondary)
                    .frame(width: 8, height: 8)
                Text(selected?.displayShortName ?? String(localized: "All"))
                    .font(.caption)
                    .fontWeight(.semibold)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private func environmentButton(_ env: ServerEnvironment) -> some View {
        Button {
            selected = env
        } label: {
            HStack {
                Circle()
                    .fill(env.color)
                    .frame(width: 8, height: 8)
                Text(env.displayName)
                Spacer()
                Text(String(format: String(localized: "(%lld)"), Int64(serverCounts[env.id] ?? 0)))
                    .foregroundStyle(.secondary)
                if selected?.id == env.id {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

// MARK: - iOS Terminal View

struct iOSTerminalView: View {
    @ObservedObject var sessionManager: ConnectionSessionManager
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    let connectingServer: Server?
    let isConnecting: Bool
    let onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var viewTabConfig = ViewTabConfigurationManager.shared

    /// Delayed flag to allow tab animation to complete before creating terminal
    @State private var shouldShowTerminalBySession: [UUID: Bool] = [:]
    /// Force terminal rebuilds to restart SSH on foreground reconnect
    @State private var reconnectTokenBySession: [UUID: UUID] = [:]
    @State private var showingTabLimitAlert = false
    @State private var showingFileTabLimitAlert = false
    @State private var serverToEdit: Server?
    @State private var showingSettings = false
    @State private var terminalBackgroundColor: Color = .black
    @State private var currentServerId: UUID?
    @State private var pendingCloseSession: ConnectionSession?
    @State private var showingZenPanel = false
    @State private var requestedTerminalDismissal = false
    @State private var voiceRecordingBySession: [UUID: Bool] = [:]
    @State private var pendingVoiceReturnBySession: [UUID: Bool] = [:]

    @SceneStorage("vvterm.zenMode.ios") private var isZenModeEnabled = false

    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true
    @AppStorage("sshAutoReconnect") private var autoReconnectEnabled = true
    @AppStorage("terminalVoiceButtonEnabled") private var terminalVoiceButtonEnabled = true
    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var serverSessions: [ConnectionSession] {
        guard let currentServerId else { return [] }
        return sessionManager.sessions.filter { $0.serverId == currentServerId }
    }

    private var selectedSession: ConnectionSession? {
        guard let resolvedId = effectiveSelectedSessionId else { return nil }
        return serverSessions.first { $0.id == resolvedId }
    }

    private var selectedServer: Server? {
        if let currentServerId {
            return serverManager.servers.first { $0.id == currentServerId }
        }
        return connectingServer
    }

    private var fileTabServerId: UUID? {
        currentServerId ?? selectedServer?.id ?? connectingServer?.id
    }

    private var serverFileTabs: [RemoteFileTab] {
        guard let fileTabServerId else { return [] }
        return fileTabs.tabs(for: fileTabServerId)
    }

    private var selectedFileTab: RemoteFileTab? {
        guard let fileTabServerId else { return nil }
        return fileTabs.selectedTab(for: fileTabServerId)
    }

    private var selectedFileTabIdBinding: Binding<UUID?> {
        Binding(
            get: { selectedFileTab?.id },
            set: { newValue in
                guard let newValue,
                      let tab = serverFileTabs.first(where: { $0.id == newValue }) else {
                    return
                }
                fileTabs.selectTab(tab)
            }
        )
    }

    private var selectedSessionIdBinding: Binding<UUID?> {
        Binding(
            get: { effectiveSelectedSessionId },
            set: { sessionManager.selectedSessionId = $0 }
        )
    }

    private var isCloseAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingCloseSession != nil },
            set: { newValue in
                if !newValue {
                    pendingCloseSession = nil
                }
            }
        )
    }

    private var effectiveSelectedSessionId: UUID? {
        if let selectedId = sessionManager.selectedSessionId,
           serverSessions.contains(where: { $0.id == selectedId }) {
            return selectedId
        }
        return serverSessions.first?.id
    }

    private var selectedView: String {
        guard let serverId = currentServerId ?? selectedSession?.serverId ?? selectedServer?.id ?? connectingServer?.id else {
            return viewTabConfig.effectiveDefaultTab()
        }
        return viewTabConfig.effectiveView(for: sessionManager.selectedViewByServer[serverId])
    }

    private var isSelectedTerminalInBrowseMode: Bool {
        guard let sessionId = effectiveSelectedSessionId else { return false }
        return sessionManager.terminalBrowseModeBySession[sessionId] ?? false
    }

    private var isSelectedTerminalFindNavigatorVisible: Bool {
        guard let sessionId = effectiveSelectedSessionId else { return false }
        return sessionManager.terminalFindNavigatorVisibleBySession[sessionId] ?? false
    }

    private var isSelectedTerminalVoiceRecording: Bool {
        guard let sessionId = effectiveSelectedSessionId else { return false }
        return voiceRecordingBySession[sessionId] ?? false
    }

    private var shouldShowFloatingTerminalControls: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
            && selectedView == ConnectionViewTab.terminal.id
            && isSelectedTerminalInBrowseMode
            && !isSelectedTerminalFindNavigatorVisible
            && !isSelectedTerminalVoiceRecording
    }

    private var shouldShowFloatingVoiceButton: Bool {
        shouldShowFloatingTerminalControls && terminalVoiceButtonEnabled
    }

    private var shouldShowFloatingReturnButton: Bool {
        guard let sessionId = effectiveSelectedSessionId else { return false }
        return shouldShowFloatingTerminalControls && pendingVoiceReturnBySession[sessionId] == true
    }

    private var canUseZenMode: Bool {
        isConnecting || selectedServer != nil || !serverSessions.isEmpty
    }

    private var effectiveZenModeEnabled: Bool {
        isZenModeEnabled && canUseZenMode
    }

    private var shouldShowViewSwitcher: Bool {
        viewTabConfig.currentVisibleTabs.count > 1
    }

    private var zenSelectedViewBinding: Binding<String> {
        guard let serverId = currentServerId ?? selectedSession?.serverId ?? selectedServer?.id ?? connectingServer?.id else {
            return .constant(viewTabConfig.effectiveDefaultTab())
        }
        return selectedViewBinding(for: serverId)
    }

    private func selectedViewBinding(for serverId: UUID) -> Binding<String> {
        Binding(
            get: { viewTabConfig.effectiveView(for: sessionManager.selectedViewByServer[serverId]) },
            set: { newValue in
                let current = viewTabConfig.effectiveView(for: sessionManager.selectedViewByServer[serverId])
                guard current != newValue else { return }
                sessionManager.selectedViewByServer[serverId] = viewTabConfig.isTabVisible(newValue)
                    ? newValue
                    : viewTabConfig.effectiveDefaultTab()
            }
        )
    }

    private func ensureInitialFileTabIfNeeded() {
        guard selectedView == ConnectionViewTab.files.id,
              let server = selectedServer else {
            return
        }

        let seedPath = selectedSession?.workingDirectory
        guard let fileTab = fileTabs.ensureInitialTab(for: server, seedPath: seedPath) else { return }
        fileBrowser.prepareNewTab(fileTab, duplicating: nil)
    }

    private func baseFileTabTitle(for tab: RemoteFileTab) -> String {
        let candidatePath = fileBrowser.lastVisitedPath(for: tab)
            ?? tab.lastKnownPath
            ?? tab.seedPath

        guard let candidatePath else {
            return selectedServer?.name.nonEmptyString ?? "/"
        }

        let normalizedPath = RemoteFilePath.normalize(candidatePath)
        guard normalizedPath != "/" else {
            return selectedServer?.name.nonEmptyString ?? "/"
        }

        return RemoteFilePath.breadcrumbs(for: normalizedPath).last?.title
            ?? (selectedServer?.name.nonEmptyString ?? "/")
    }

    private func displayedFileTabTitle(for tab: RemoteFileTab) -> String {
        let baseTitles = Dictionary(
            uniqueKeysWithValues: serverFileTabs.map { ($0.id, baseFileTabTitle(for: $0)) }
        )
        let titleCounts = Dictionary(grouping: baseTitles.values, by: { $0 }).mapValues(\.count)
        var seenCounts: [String: Int] = [:]
        var resolvedTitles: [UUID: String] = [:]

        for tab in serverFileTabs {
            let baseTitle = baseTitles[tab.id] ?? (selectedServer?.name.nonEmptyString ?? "/")
            guard (titleCounts[baseTitle] ?? 0) > 1 else {
                resolvedTitles[tab.id] = baseTitle
                continue
            }

            seenCounts[baseTitle, default: 0] += 1
            resolvedTitles[tab.id] = "\(baseTitle) (\(seenCounts[baseTitle, default: 0]))"
        }

        return resolvedTitles[tab.id] ?? baseFileTabTitle(for: tab)
    }

    private var tmuxAttachPromptBinding: Binding<TmuxAttachPrompt?> {
        Binding(
            get: {
                guard let prompt = sessionManager.tmuxAttachPrompt else { return nil }
                return serverSessions.contains(where: { $0.id == prompt.id }) ? prompt : nil
            },
            set: { newValue in
                guard newValue == nil, let prompt = sessionManager.tmuxAttachPrompt else { return }
                if serverSessions.contains(where: { $0.id == prompt.id }) {
                    sessionManager.cancelTmuxAttachPrompt(sessionId: prompt.id)
                }
            }
        )
    }

    private func updateTerminalBackgroundColor() {
        let themeName = effectiveThemeName
        let fallback = colorScheme == .dark ? Color.black : Color(UIColor.systemBackground)
        Task.detached(priority: .utility) {
            let resolved = ThemeColorParser.backgroundColor(for: themeName)
            await MainActor.run {
                let color = resolved ?? fallback
                terminalBackgroundColor = color

                let fallbackHex = colorScheme == .dark ? "#000000" : "#FFFFFF"
                let hex = resolved?.toHex() ?? fallbackHex
                UserDefaults.standard.set(hex, forKey: "terminalBackgroundColor")
            }
        }
    }

    private func attemptForegroundReconnectIfNeeded(refreshTerminal: Bool = false) {
        guard selectedView == "terminal" else { return }
        guard let session = selectedSession else { return }

        if refreshTerminal {
            activateTerminal(session)
        }

        guard autoReconnectEnabled else { return }
        guard !sessionManager.isSuspendingForBackground else { return }

        switch session.connectionState {
        case .disconnected, .failed:
            Task { try? await sessionManager.reconnect(session: session) }
            reconnectTokenBySession[session.id] = UUID()
            shouldShowTerminalBySession[session.id] = true
        default:
            break
        }
    }

    var body: some View {
        alertContent
            .onAppear {
                updateTerminalBackgroundColor()
                if currentServerId == nil {
                    currentServerId = connectingServer?.id ?? sessionManager.selectedSession?.serverId
                }
                if currentServerId != nil,
                   let selectedId = sessionManager.selectedSessionId,
                   !serverSessions.contains(where: { $0.id == selectedId }),
                   let fallbackId = serverSessions.first?.id {
                    sessionManager.selectedSessionId = fallbackId
                }
                synchronizeRecoveredTerminalState()
                ensureInitialFileTabIfNeeded()
                attemptForegroundReconnectIfNeeded(refreshTerminal: true)
            }
            .onChange(of: terminalThemeName) { _ in updateTerminalBackgroundColor() }
            .onChange(of: terminalThemeNameLight) { _ in updateTerminalBackgroundColor() }
            .onChange(of: usePerAppearanceTheme) { _ in updateTerminalBackgroundColor() }
            .onChange(of: colorScheme) { _ in updateTerminalBackgroundColor() }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    updateTerminalBackgroundColor()
                    attemptForegroundReconnectIfNeeded(refreshTerminal: true)
                }
            }
            .onChange(of: connectingServer?.id) { newValue in
                if let newValue {
                    currentServerId = newValue
                }
                synchronizeRecoveredTerminalState()
                ensureInitialFileTabIfNeeded()
            }
            .onChange(of: sessionManager.selectedSessionId) { newValue in
                if let newValue,
                   let session = sessionManager.sessions.first(where: { $0.id == newValue }),
                   currentServerId != session.serverId {
                    currentServerId = session.serverId
                }
                synchronizeRecoveredTerminalState()
                ensureInitialFileTabIfNeeded()
                attemptForegroundReconnectIfNeeded()
            }
            .onChange(of: isConnecting) { _ in
                synchronizeRecoveredTerminalState()
            }
            .onChange(of: selectedView) { newValue in
                if newValue != "terminal" {
                    clearPendingVoiceReturnForCurrentSession()
                    dismissKeyboardForCurrentSession()
                } else {
                    DispatchQueue.main.async {
                        attemptForegroundReconnectIfNeeded(refreshTerminal: true)
                    }
                }
                ensureInitialFileTabIfNeeded()
            }
            .onChange(of: sessionManager.isSuspendingForBackground) { isSuspending in
                guard !isSuspending, scenePhase == .active else { return }
                attemptForegroundReconnectIfNeeded(refreshTerminal: true)
            }
            .onChange(of: isZenModeEnabled) { newValue in
                if newValue && !canUseZenMode {
                    isZenModeEnabled = false
                    return
                }
                if !newValue {
                    showingZenPanel = false
                }
                refreshTerminalAfterChromeChange()
            }
            .onChange(of: sessionManager.sessions) { _ in
                if currentServerId == nil, let selected = sessionManager.selectedSession {
                    currentServerId = selected.serverId
                }
                let activeIds = Set(serverSessions.map { $0.id })
                shouldShowTerminalBySession = shouldShowTerminalBySession.filter { activeIds.contains($0.key) }
                reconnectTokenBySession = reconnectTokenBySession.filter { activeIds.contains($0.key) }
                voiceRecordingBySession = voiceRecordingBySession.filter { activeIds.contains($0.key) }
                pendingVoiceReturnBySession = pendingVoiceReturnBySession.filter { activeIds.contains($0.key) }
                if currentServerId != nil,
                   let selectedId = sessionManager.selectedSessionId,
                   !serverSessions.contains(where: { $0.id == selectedId }),
                   let fallbackId = serverSessions.first?.id {
                    sessionManager.selectedSessionId = fallbackId
                }
                if selectedView == "terminal",
                   let selectedId = effectiveSelectedSessionId,
                   let session = serverSessions.first(where: { $0.id == selectedId }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        refreshTerminal(for: session)
                        focusTerminal(for: session)
                    }
                }
                synchronizeRecoveredTerminalState()
                ensureInitialFileTabIfNeeded()
            }
    }

    private var baseContent: some View {
        mainContent
            .background(backgroundView)
            .overlay(alignment: .top) {
                if selectedView == "terminal" && !effectiveZenModeEnabled {
                    NavBarBackdrop(color: terminalBackgroundColor)
                }
            }
            .overlay(alignment: .topTrailing) {
                if effectiveZenModeEnabled {
                    zenModeOverlay
                }
            }
            .overlay(alignment: .bottom) {
                if shouldShowFloatingTerminalControls {
                    floatingTerminalControls
                        .padding(.bottom, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar { navigationToolbar }
            .toolbar(effectiveZenModeEnabled ? .hidden : .visible, for: .navigationBar)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: shouldShowFloatingTerminalControls)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: shouldShowFloatingReturnButton)
    }

    private var sheetContent: some View {
        baseContent
            .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
            .limitReachedAlert(.fileTabs, isPresented: $showingFileTabLimitAlert)
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .modifier(AppearanceModifier())
                    .adaptiveSoftScrollEdges()
            }
            .sheet(item: $serverToEdit) { server in
                NavigationStack {
                    ServerFormSheet(
                        serverManager: serverManager,
                        workspace: serverManager.workspaces.first { $0.id == server.workspaceId },
                        server: server,
                        onSave: { _ in serverToEdit = nil }
                    )
                }
                .adaptiveSoftScrollEdges()
            }
            .sheet(item: tmuxAttachPromptBinding) { prompt in
                TmuxAttachPromptSheet(
                    prompt: prompt,
                    onConfirm: { selection in
                        sessionManager.resolveTmuxAttachPrompt(sessionId: prompt.id, selection: selection)
                    }
                )
                .adaptiveSoftScrollEdges()
            }
    }

    private var alertContent: some View {
        sheetContent
            .alert(String(localized: "Close Tab?"), isPresented: isCloseAlertPresented, presenting: pendingCloseSession) { session in
                Button("Close", role: .destructive) {
                    sessionManager.closeSession(session)
                    pendingCloseSession = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingCloseSession = nil
                }
            } message: { session in
                Text(String(format: String(localized: "This will disconnect \"%@\"."), session.title))
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            headerTabsBar
            sessionContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var headerTabsBar: some View {
        if !effectiveZenModeEnabled {
            if selectedView == "terminal" && serverSessions.count > 1 {
                iOSTerminalTabsBar(
                    sessions: serverSessions,
                    selectedSessionId: selectedSessionIdBinding,
                    titleForSession: { sessionManager.displayTitle(for: $0) },
                    onClose: { pendingCloseSession = $0 }
                )
            }

            if selectedView == "files" && serverFileTabs.count > 1 {
                iOSRemoteFileTabsBar(
                    tabs: serverFileTabs,
                    selectedTabId: selectedFileTabIdBinding,
                    titleForTab: displayedFileTabTitle(for:),
                    onSelect: { fileTabs.selectTab($0) },
                    onClose: closeFileTab
                )
            }
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        if serverSessions.isEmpty {
            emptyStateContent
        } else {
            activeSessionsContent
        }
    }

    @ViewBuilder
    private var emptyStateContent: some View {
        if isConnecting, let serverName = (connectingServer ?? selectedServer)?.name {
            connectingStateView(serverName: serverName)
        } else if selectedView == "terminal" {
            TerminalEmptyStateView(server: selectedServer) {
                openNewTab()
            }
        } else if selectedView == "files", let server = selectedServer {
            if let selectedFileTab {
                RemoteFileBrowserScreen(
                    browser: fileBrowser,
                    server: server,
                    fileTab: selectedFileTab,
                    initialPath: selectedFileTab.seedPath
                ) { currentPath in
                    fileTabs.updateLastKnownPath(currentPath, for: selectedFileTab.id)
                }
                .id(selectedFileTab.id)
            } else {
                RemoteFileTabsEmptyState(server: server) {
                    openNewFileTab()
                }
            }
        } else if let server = selectedServer {
            ServerStatsView(
                server: server,
                isVisible: true,
                backgroundColor: Color(UIColor.systemGroupedBackground),
                sharedClientProvider: { sessionManager.sharedStatsClient(for: server.id) },
                statsCollector: ServerStatsCollector()
            )
        }
    }

    private var activeSessionsContent: some View {
        ZStack {
            if selectedView == "stats", let server = selectedServer {
                ServerStatsView(
                    server: server,
                    isVisible: true,
                    backgroundColor: Color(UIColor.systemGroupedBackground),
                    sharedClientProvider: { sessionManager.sharedStatsClient(for: server.id) },
                    statsCollector: ServerStatsCollector()
                )
                .zIndex(1)
            }

            if selectedView == "files" {
                if let server = selectedServer {
                    if let selectedFileTab {
                        RemoteFileBrowserScreen(
                            browser: fileBrowser,
                            server: server,
                            fileTab: selectedFileTab,
                            initialPath: selectedFileTab.seedPath
                        ) { currentPath in
                            fileTabs.updateLastKnownPath(currentPath, for: selectedFileTab.id)
                        }
                        .id(selectedFileTab.id)
                        .zIndex(1)
                    } else {
                        RemoteFileTabsEmptyState(server: server) {
                            openNewFileTab()
                        }
                        .zIndex(1)
                    }
                }
            }

            if selectedView == "terminal", let session = selectedSession ?? serverSessions.first {
                sessionPage(session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { transaction in
            transaction.animation = nil
        }
        .overlay(serverViewSwipeOverlay)
    }

    @ViewBuilder
    private var backgroundView: some View {
        if selectedView == "terminal" {
            terminalBackgroundColor
                .ignoresSafeArea(.all)
        } else {
            Color(UIColor.systemBackground)
                .ignoresSafeArea(.all)
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            navigationBackButton
        }

        if shouldShowViewSwitcher {
            ToolbarItem(placement: .principal) {
                if let serverId = currentServerId ?? selectedSession?.serverId ?? selectedServer?.id ?? connectingServer?.id {
                    iOSNativeSegmentedPicker(
                        selection: selectedViewBinding(for: serverId),
                        tabs: viewTabConfig.currentVisibleTabs
                    )
                    .fixedSize()
                }
            }
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if selectedView == "terminal" {
                Button {
                    openNewTab()
                } label: {
                    Image(systemName: "plus")
                }
            }

            if selectedView == "files" {
                Button {
                    openNewFileTab()
                } label: {
                    Image(systemName: "plus")
                }
            }

            Menu {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }

                if selectedView == "terminal" {
                    Button {
                        showFindNavigatorForCurrentSession()
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                }

                if let server = selectedServer {
                    Button {
                        serverToEdit = server
                    } label: {
                        Label("Edit Server", systemImage: "pencil")
                    }
                }

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        isZenModeEnabled = true
                    }
                } label: {
                    Label("Zen Mode", systemImage: "arrow.up.left.and.arrow.down.right")
                }

                Button(role: .destructive) {
                    disconnectCurrentServerSessions()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var navigationBackButton: some View {
        Button {
            dismissKeyboardForCurrentSession()
            onBack()
        } label: {
            Image(systemName: "chevron.left")
        }
    }

    private func dismissKeyboardForCurrentSession() {
        guard let selectedId = effectiveSelectedSessionId,
              let terminal = ConnectionSessionManager.shared.peekTerminal(for: selectedId) else { return }
        terminal.dismissKeyboardForUser()
    }

    private func showKeyboardForCurrentSession() {
        guard selectedView == ConnectionViewTab.terminal.id,
              let selectedId = effectiveSelectedSessionId,
              let terminal = ConnectionSessionManager.shared.peekTerminal(for: selectedId) else { return }
        clearPendingVoiceReturn(for: selectedId)
        terminal.requestKeyboardFocus(for: .explicitUserRequest)
    }

    private func startVoiceInputForCurrentSession() {
        guard selectedView == ConnectionViewTab.terminal.id,
              terminalVoiceButtonEnabled,
              !isSelectedTerminalVoiceRecording,
              let selectedId = effectiveSelectedSessionId,
              let terminal = ConnectionSessionManager.shared.peekTerminal(for: selectedId) else { return }
        clearPendingVoiceReturn(for: selectedId)
        if terminal.triggerVoiceInput() {
            voiceRecordingBySession[selectedId] = true
        }
    }

    private func sendReturnForCurrentSession() {
        guard selectedView == ConnectionViewTab.terminal.id,
              let selectedId = effectiveSelectedSessionId,
              let terminal = ConnectionSessionManager.shared.peekTerminal(for: selectedId) else { return }
        if terminal.sendReturnKey() {
            clearPendingVoiceReturn(for: selectedId)
        }
    }

    private func clearPendingVoiceReturnForCurrentSession() {
        guard let selectedId = effectiveSelectedSessionId else { return }
        clearPendingVoiceReturn(for: selectedId)
    }

    private func clearPendingVoiceReturn(for sessionId: UUID) {
        pendingVoiceReturnBySession[sessionId] = false
    }

    private func showFindNavigatorForCurrentSession() {
        guard selectedView == ConnectionViewTab.terminal.id,
              let selectedId = effectiveSelectedSessionId,
              let terminal = ConnectionSessionManager.shared.peekTerminal(for: selectedId) else { return }
        terminal.showFindNavigator()
    }

    @ViewBuilder
    private var floatingTerminalControls: some View {
        if shouldShowFloatingReturnButton {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    floatingKeyboardVoiceControls(showsTitle: true)
                    Spacer(minLength: 14)
                    floatingReturnControl()
                }

                HStack(spacing: 10) {
                    floatingKeyboardVoiceControls(showsTitle: false)
                    Spacer(minLength: 14)
                    floatingReturnControl()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    floatingKeyboardVoiceControls(showsTitle: true)
                }

                HStack(spacing: 10) {
                    floatingKeyboardVoiceControls(showsTitle: false)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func floatingKeyboardVoiceControls(showsTitle: Bool) -> some View {
        HStack(spacing: 10) {
            floatingKeyboardControl(showsTitle: showsTitle)
            if shouldShowFloatingVoiceButton {
                floatingVoiceControl(showsTitle: showsTitle)
            }
        }
    }

    @ViewBuilder
    private func floatingKeyboardControl(showsTitle: Bool) -> some View {
        floatingTerminalControlButton(
            title: "Keyboard",
            systemImage: "keyboard",
            accessibilityLabel: "Show Keyboard",
            showsTitle: showsTitle
        ) {
            showKeyboardForCurrentSession()
        }
    }

    @ViewBuilder
    private func floatingVoiceControl(showsTitle: Bool) -> some View {
        floatingTerminalControlButton(
            title: "Voice input",
            systemImage: "mic.fill",
            accessibilityLabel: "Voice input",
            showsTitle: showsTitle
        ) {
            startVoiceInputForCurrentSession()
        }
    }

    @ViewBuilder
    private func floatingReturnControl() -> some View {
        floatingTerminalControlButton(
            title: "Enter",
            systemImage: "arrow.turn.down.left",
            accessibilityLabel: "Enter",
            showsTitle: false,
            isPrimary: true
        ) {
            sendReturnForCurrentSession()
        }
    }

    @ViewBuilder
    private func floatingTerminalControlButton(
        title: LocalizedStringKey,
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        showsTitle: Bool,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            HStack(spacing: showsTitle ? 6 : 0) {
                Image(systemName: systemImage)
                if showsTitle {
                    Text(title)
                }
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(isPrimary ? Color.accentColor : Color.primary)
            .padding(.horizontal, showsTitle ? 2 : 0)
        }
        .accessibilityLabel(Text(accessibilityLabel))

        if #available(iOS 26, *) {
            if isPrimary {
                button
                    .tint(Color.accentColor)
                    .buttonStyle(SwiftUI.GlassButtonStyle())
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            } else {
                button
                    .buttonStyle(SwiftUI.GlassButtonStyle())
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
        } else {
            button
                .buttonStyle(.glass(tint: Color.accentColor.opacity(isPrimary ? 0.5 : (colorScheme == .dark ? 0.24 : 0.14))))
        }
    }

    @ViewBuilder
    private func connectingStateView(serverName: String) -> some View {
        BlockingStatusView(showsScrim: false) {
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.1)
                Text(String(format: String(localized: "Connecting to %@..."), serverName))
                    .font(.headline)
                Text(String(localized: "Preparing server details..."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sessionPage(_ session: ConnectionSession) -> some View {
        let server = serverManager.servers.first { $0.id == session.serverId }
        let viewSelection = sessionManager.selectedViewByServer[session.serverId] ?? viewTabConfig.effectiveDefaultTab()
        let effectiveViewSelection = viewTabConfig.effectiveView(for: viewSelection)
        let terminalAlreadyExists = ConnectionSessionManager.shared.hasTerminal(for: session.id)
        let shouldShowTerminal = shouldShowTerminalBySession[session.id] ?? false
        let reconnectToken = reconnectTokenBySession[session.id] ?? session.id

        ZStack {
            if shouldShowTerminal || terminalAlreadyExists {
                TerminalContainerView(
                    session: session,
                    server: server,
                    isActive: effectiveViewSelection == "terminal",
                    onVoiceRecordingChange: { isRecording in
                        if isRecording {
                            clearPendingVoiceReturn(for: session.id)
                        }
                        voiceRecordingBySession[session.id] = isRecording
                    },
                    onVoiceTranscriptionSent: {
                        if sessionManager.terminalBrowseModeBySession[session.id] == true {
                            pendingVoiceReturnBySession[session.id] = true
                        }
                    }
                )
                .id(reconnectToken)
            }

            if effectiveViewSelection == "files" {
                if let server, let selectedFileTab {
                    RemoteFileBrowserScreen(
                        browser: fileBrowser,
                        server: server,
                        fileTab: selectedFileTab,
                        initialPath: selectedFileTab.seedPath
                    ) { currentPath in
                        fileTabs.updateLastKnownPath(currentPath, for: selectedFileTab.id)
                    }
                    .id(selectedFileTab.id)
                }
            }

            if effectiveViewSelection == "terminal" && !shouldShowTerminal && !terminalAlreadyExists {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(session.id)
        .onAppear {
            prepareTerminal(session: session, viewSelection: effectiveViewSelection, terminalAlreadyExists: terminalAlreadyExists)
            if effectiveViewSelection == "terminal" {
                focusTerminal(for: session)
            }
        }
        .onChange(of: session.id) { _ in
            activateTerminal(session)
        }
        .onChange(of: viewSelection) { newValue in
            let effectiveSelection = viewTabConfig.effectiveView(for: newValue)
            if effectiveSelection == "terminal" {
                prepareTerminal(session: session, viewSelection: effectiveSelection, terminalAlreadyExists: terminalAlreadyExists)
                focusTerminal(for: session)
            }
            if effectiveSelection == ConnectionViewTab.files.id {
                ensureInitialFileTabIfNeeded()
            }
        }
    }

    private func prepareTerminal(session: ConnectionSession, viewSelection: String, terminalAlreadyExists: Bool) {
        guard viewSelection == "terminal" else { return }
        if terminalAlreadyExists {
            refreshTerminal(for: session)
            return
        }
        if shouldShowTerminalBySession[session.id] == true { return }
        shouldShowTerminalBySession[session.id] = true
    }

    private func activateTerminal(_ session: ConnectionSession) {
        let terminalAlreadyExists = ConnectionSessionManager.shared.hasTerminal(for: session.id)
        prepareTerminal(session: session, viewSelection: selectedView, terminalAlreadyExists: terminalAlreadyExists)
        guard selectedView == "terminal" else { return }
        focusTerminal(for: session)
    }

    private func refreshTerminalAfterChromeChange() {
        guard selectedView == "terminal",
              let session = selectedSession ?? serverSessions.first else {
            return
        }

        DispatchQueue.main.async {
            refreshTerminal(for: session)
            focusTerminal(for: session)
        }
    }

    private func openNewTab() {
        guard let server = selectedServer else { return }
        guard sessionManager.canOpenNewTab else {
            showingTabLimitAlert = true
            return
        }
        Task {
            do {
                let session = try await sessionManager.openConnection(to: server, forceNew: true)
                await MainActor.run {
                    sessionManager.selectedViewByServer[server.id] = viewTabConfig.isTabVisible(ConnectionViewTab.terminal.id)
                        ? ConnectionViewTab.terminal.id
                        : viewTabConfig.effectiveDefaultTab()
                    currentServerId = server.id
                    shouldShowTerminalBySession[session.id] = true
                    reconnectTokenBySession[session.id] = session.id
                    sessionManager.selectedSessionId = session.id
                }
            } catch {
                // No-op: user cancelled biometric auth or open failed.
            }
        }
    }

    private func openNewFileTab() {
        guard let server = selectedServer else { return }
        guard fileTabs.canOpenNewTab(for: server.id) else {
            showingFileTabLimitAlert = true
            return
        }

        let sourceTab = selectedFileTab
        let seedPath = sourceTab.flatMap { fileBrowser.lastVisitedPath(for: $0) }
            ?? selectedSession?.workingDirectory
        let newTab = sourceTab.flatMap { fileTabs.duplicateTab($0, seedPath: seedPath) }
            ?? fileTabs.openTab(for: server, seedPath: seedPath)

        guard let newTab else { return }
        fileBrowser.prepareNewTab(newTab, duplicating: sourceTab)
        sessionManager.selectedViewByServer[server.id] = viewTabConfig.isTabVisible(ConnectionViewTab.files.id)
            ? ConnectionViewTab.files.id
            : viewTabConfig.effectiveDefaultTab()
    }

    private func closeFileTab(_ tab: RemoteFileTab) {
        if let removedTab = fileTabs.closeTab(tab) {
            fileBrowser.removeState(for: removedTab.id)
        }
    }

    private func disconnectCurrentServerSessions() {
        guard let serverId = currentServerId ?? selectedSession?.serverId ?? selectedServer?.id ?? connectingServer?.id else {
            onBack()
            return
        }
        fileBrowser.disconnect(serverId: serverId)
        fileTabs.disconnect(serverId: serverId)
        sessionManager.disconnectServer(serverId)
        onBack()
    }

    private func synchronizeRecoveredTerminalState() {
        if !canUseZenMode {
            showingZenPanel = false
            isZenModeEnabled = false
        }

        guard !canUseZenMode else {
            requestedTerminalDismissal = false
            return
        }

        guard !requestedTerminalDismissal else { return }
        requestedTerminalDismissal = true
        DispatchQueue.main.async {
            onBack()
        }
    }

    private var zenModeOverlay: some View {
        ZenModeFloatingOverlay(
            isPanelPresented: $showingZenPanel,
            indicatorColor: selectedSession?.connectionState.statusTintColor ?? .secondary
        ) { panelWidth in
            IOSZenModePanel(
                width: panelWidth,
                serverName: selectedServer?.name ?? String(localized: "Terminal"),
                selectedView: selectedView,
                selectedViewBinding: zenSelectedViewBinding,
                viewTabs: viewTabConfig.currentVisibleTabs,
                sessions: serverSessions,
                selectedSessionId: selectedSessionIdBinding,
                sessionTitle: { sessionManager.displayTitle(for: $0) },
                onCloseSession: { session in
                    pendingCloseSession = session
                },
                fileTabs: serverFileTabs,
                selectedFileTabId: selectedFileTabIdBinding,
                fileTabTitle: displayedFileTabTitle(for:),
                onSelectFileTab: { tab in
                    fileTabs.selectTab(tab)
                },
                onCloseFileTab: { tab in
                    closeFileTab(tab)
                },
                onNewTerminalTab: {
                    showingZenPanel = false
                    openNewTab()
                },
                onNewFileTab: {
                    showingZenPanel = false
                    openNewFileTab()
                },
                onOpenSettings: {
                    showingZenPanel = false
                    showingSettings = true
                },
                onEditServer: selectedServer.map { server in
                    {
                        showingZenPanel = false
                        serverToEdit = server
                    }
                },
                onDisconnect: {
                    showingZenPanel = false
                    disconnectCurrentServerSessions()
                },
                onBack: {
                    showingZenPanel = false
                    dismissKeyboardForCurrentSession()
                    onBack()
                },
                onExitZen: {
                    showingZenPanel = false
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        isZenModeEnabled = false
                    }
                }
            )
        }
    }

    /// Refresh terminal display and trigger server redraw
    private func refreshTerminal(for session: ConnectionSession) {
        guard scenePhase == .active else { return }
        guard let terminal = ConnectionSessionManager.shared.peekTerminal(for: session.id) else { return }
        ConnectionSessionManager.shared.markTerminalUsed(for: session.id)

        // Resume rendering if paused
        terminal.resumeRendering()

        // Force layout + refresh after a brief delay to ensure the view is attached.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak terminal] in
            guard let terminal else { return }
            guard scenePhase == .active else { return }
            guard ConnectionSessionManager.shared.sessions.contains(where: { $0.id == session.id }) else { return }
            guard ConnectionSessionManager.shared.peekTerminal(for: session.id) === terminal else { return }
            guard terminal.window != nil else { return }

            if let container = terminal.superview {
                container.setNeedsLayout()
                container.layoutIfNeeded()

                let targetBounds = container.bounds

                if targetBounds.width > 0, targetBounds.height > 0 {
                    if terminal.frame != targetBounds {
                        terminal.frame = targetBounds
                    }
                    terminal.sizeDidChange(targetBounds.size)
                }
            }

            terminal.forceRefresh()

            // Send resize to force server to redraw prompt
            if let sshClient = ConnectionSessionManager.shared.sshClient(for: session),
               let shellId = ConnectionSessionManager.shared.shellId(for: session) {
                Task {
                    if let size = terminal.terminalSize() {
                        try? await sshClient.resize(cols: Int(size.columns), rows: Int(size.rows), for: shellId)
                    }
                }
            }
        }
    }

    private func focusTerminal(for session: ConnectionSession) {
        guard scenePhase == .active else { return }
        guard let terminal = ConnectionSessionManager.shared.peekTerminal(for: session.id) else { return }
        ConnectionSessionManager.shared.markTerminalUsed(for: session.id)

        let attemptFocus = { [weak terminal] in
            guard let terminal = terminal else { return }
            if terminal.window != nil {
                terminal.requestKeyboardFocus(for: .initialActivation)
            }
        }

        DispatchQueue.main.async {
            attemptFocus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                attemptFocus()
            }
        }
    }


    @ViewBuilder
    private var serverViewSwipeOverlay: some View {
        if (selectedView == ConnectionViewTab.terminal.id && serverSessions.count > 1)
            || (selectedView == ConnectionViewTab.files.id && serverFileTabs.count > 1) {
            GeometryReader { _ in
                let edgeWidth: CGFloat = 32
                let leadingGestureInset: CGFloat = selectedView == ConnectionViewTab.files.id ? 44 : 0
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: leadingGestureInset)
                        .allowsHitTesting(false)

                    Color.clear
                        .frame(width: edgeWidth)
                        .contentShape(Rectangle())
                        .gesture(tabSwipeGesture())

                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)

                    Color.clear
                        .frame(width: edgeWidth)
                        .contentShape(Rectangle())
                        .gesture(tabSwipeGesture())
                }
            }
        }
    }

    private func tabSwipeGesture() -> some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical),
                      abs(horizontal) > 60 else { return }
                if horizontal < 0 {
                    if selectedView == ConnectionViewTab.files.id {
                        selectNextFileTab()
                    } else {
                        selectNextServerSession()
                    }
                } else {
                    if selectedView == ConnectionViewTab.files.id {
                        selectPreviousFileTab()
                    } else {
                        selectPreviousServerSession()
                    }
                }
            }
    }

    private func selectNextServerSession() {
        guard let currentId = sessionManager.selectedSessionId,
              let index = serverSessions.firstIndex(where: { $0.id == currentId }),
              index < serverSessions.count - 1 else { return }
        sessionManager.selectedSessionId = serverSessions[index + 1].id
        triggerTabSwitchFeedback()
    }

    private func selectPreviousServerSession() {
        guard let currentId = sessionManager.selectedSessionId,
              let index = serverSessions.firstIndex(where: { $0.id == currentId }),
              index > 0 else { return }
        sessionManager.selectedSessionId = serverSessions[index - 1].id
        triggerTabSwitchFeedback()
    }

    private func selectNextFileTab() {
        guard let serverId = fileTabServerId else { return }
        fileTabs.selectNextTab(for: serverId)
        triggerTabSwitchFeedback()
    }

    private func selectPreviousFileTab() {
        guard let serverId = fileTabServerId else { return }
        fileTabs.selectPreviousTab(for: serverId)
        triggerTabSwitchFeedback()
    }

    private func triggerTabSwitchFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

}

#if os(iOS)
private struct iOSNativeSegmentedPicker: UIViewRepresentable {
    @Binding var selection: String
    let tabs: [ConnectionViewTab]

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl()
        configure(control, tabs: tabs)
        control.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        control.selectedSegmentIndex = selectedIndex
        control.apportionsSegmentWidthsByContent = true
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .vertical)
        return control
    }

    func updateUIView(_ uiView: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.tabs = tabs
        if context.coordinator.renderedTabs != tabs {
            configure(uiView, tabs: tabs)
            context.coordinator.renderedTabs = tabs
        }

        let resolvedSelection = tabs.contains(where: { $0.id == selection }) ? selection : tabs.first?.id ?? selection
        if resolvedSelection != selection {
            DispatchQueue.main.async {
                selection = resolvedSelection
            }
        }

        let targetIndex = selectedIndex
        guard uiView.selectedSegmentIndex != targetIndex else { return }
        UIView.performWithoutAnimation {
            uiView.selectedSegmentIndex = targetIndex
            uiView.setNeedsLayout()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        uiView.sizeToFit()
        return uiView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, tabs: tabs)
    }

    private var selectedIndex: Int {
        tabs.firstIndex(where: { $0.id == selection }) ?? 0
    }

    private func configure(_ control: UISegmentedControl, tabs: [ConnectionViewTab]) {
        control.removeAllSegments()
        for (index, tab) in tabs.enumerated() {
            control.insertSegment(with: UIImage(systemName: tab.icon), at: index, animated: false)
        }
        control.accessibilityLabel = tabs.map(\.localizedKey).joined(separator: ", ")
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>
        var tabs: [ConnectionViewTab]
        var renderedTabs: [ConnectionViewTab]

        init(selection: Binding<String>, tabs: [ConnectionViewTab]) {
            self.selection = selection
            self.tabs = tabs
            self.renderedTabs = tabs
        }

        @objc func valueChanged(_ sender: UISegmentedControl) {
            let index = sender.selectedSegmentIndex
            guard tabs.indices.contains(index) else { return }
            let selectedTabID = tabs[index].id
            guard selection.wrappedValue != selectedTabID else { return }
            DispatchQueue.main.async { [selection] in
                selection.wrappedValue = selectedTabID
            }
        }
    }
}
#endif

private struct NavBarBackdrop: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 44
            color
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .top)
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}

// MARK: - iOS Terminal Tabs

struct iOSTerminalTabsBar: View {
    let sessions: [ConnectionSession]
    @Binding var selectedSessionId: UUID?
    let titleForSession: (ConnectionSession) -> String
    let onClose: (ConnectionSession) -> Void
    private let minTabWidth: CGFloat = 120

    var body: some View {
        GeometryReader { proxy in
            let count = max(sessions.count, 1)
            let availableWidth = max(proxy.size.width - ServerViewTopTabBarMetrics.horizontalPadding * 2, 0)
            let totalSpacing = ServerViewTopTabBarMetrics.tabSpacing * CGFloat(max(count - 1, 0))
            let itemWidth = count > 0 ? (availableWidth - totalSpacing) / CGFloat(count) : 0
            let useEqualWidth = itemWidth >= minTabWidth

            Group {
                if useEqualWidth {
                    HStack(spacing: ServerViewTopTabBarMetrics.tabSpacing) {
                        ForEach(sessions) { session in
                            iOSTerminalTabButton(
                                session: session,
                                title: titleForSession(session),
                                isSelected: selectedSessionId == session.id,
                                fixedWidth: itemWidth,
                                onSelect: { selectedSessionId = session.id },
                                onClose: { onClose(session) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ServerViewTopTabBarMetrics.horizontalPadding)
                    .padding(.vertical, ServerViewTopTabBarMetrics.barVerticalInset)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ServerViewTopTabBarMetrics.tabSpacing) {
                            ForEach(sessions) { session in
                                iOSTerminalTabButton(
                                    session: session,
                                    title: titleForSession(session),
                                    isSelected: selectedSessionId == session.id,
                                    fixedWidth: nil,
                                    onSelect: { selectedSessionId = session.id },
                                    onClose: { onClose(session) }
                                )
                                .frame(minWidth: minTabWidth)
                            }
                        }
                        .padding(.horizontal, ServerViewTopTabBarMetrics.horizontalPadding)
                        .padding(.vertical, ServerViewTopTabBarMetrics.barVerticalInset)
                        .animation(nil, value: sessions.map(\.id))
                    }
                }
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .frame(height: ServerViewTopTabBarMetrics.barHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .clipShape(Capsule(style: .continuous))
        .padding(.horizontal, ServerViewTopTabBarMetrics.outerHorizontalPadding)
        .padding(.vertical, 6)
    }
}

private struct iOSTerminalTabButton: View {
    let session: ConnectionSession
    let title: String
    let isSelected: Bool
    let fixedWidth: CGFloat?
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 36)
        .padding(.vertical, ServerViewTopTabBarMetrics.tabVerticalPadding)
        .frame(height: ServerViewTopTabBarMetrics.tabHeight)
        .frame(width: fixedWidth, alignment: .leading)
        .foregroundStyle(.primary)
        .background(
            isSelected ? Color.primary.opacity(0.18) : Color.clear,
            in: Capsule(style: .continuous)
        )
        .overlay(alignment: .trailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isSelected ? 0.16 : 0.12))
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .accessibilityAddTraits(.isButton)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected, .idle: return .secondary
        case .failed: return .red
        }
    }
}
#endif
