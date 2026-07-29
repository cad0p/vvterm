//
//  ServerListScreen+iOS.swift
//  VVTerm
//

import SwiftUI

#if os(iOS)
struct ServerListScreen: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var tabManager: TerminalTabManager
    @ObservedObject var fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedEnvironment: ServerEnvironment?
    let onServerSelected: (Server) -> Void
    let onActiveConnectionSelected: (Server) -> Void

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
    @State private var showingCustomEnvironmentAlert = false
    @State private var addServerPrefill: ServerFormPrefill?
    /// The server being set up via the Teleport prompt-on-connect flow.
    /// Set when a non-ready Teleport server is tapped; drives the sheet.
    @State private var teleportSetupServer: Server?
    /// The readiness state for the current Teleport setup sheet. Flipped
    /// by each phase's `onSuccess` to chain bootstrap → registration → login
    /// (mirrors `ServerSidebarView`).
    @State private var teleportSetupReadiness: TeleportDeviceReadiness?
    /// The Phase-1 bootstrap result, held in memory so the Phase-2
    /// registration sheet can resume without redoing Phase 1. Mirrors
    /// `ServerSidebarView.teleportBootstrapResult`.
    @State private var teleportBootstrapResult: TeleportBootstrapCoordinator.BootstrapResult?

    private var canAddServer: Bool {
        !serverManager.workspaces.isEmpty
    }

    var body: some View {
        List {
            serversSection
            activeConnectionsSection
        }
        .accessibilityIdentifier("vvterm.serverList.list")
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
                WorkspacePickerSheet(
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
        .sheet(isPresented: Binding(
            get: { teleportSetupServer != nil },
            set: { if !$0 { teleportSetupServer = nil; teleportSetupReadiness = nil; teleportBootstrapResult = nil } }
        )) {
            if let server = teleportSetupServer, let readiness = teleportSetupReadiness {
                teleportSetupSheet(server: server, readiness: readiness)
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
                    ServerListRow(
                        server: server,
                        onTap: { onServerSelected(server) },
                        onEdit: { serverToEdit = server },
                        onMove: { serverToMove = server },
                        onLockedTap: { lockedServerAlert = server },
                        onTeleportSetup: { srv, readiness in
                            teleportSetupServer = srv
                            teleportSetupReadiness = readiness
                        }
                    )
                    .accessibilityIdentifier(
                        "vvterm.serverList.server.\(server.id.uuidString)"
                    )
                }
            }
        } header: {
            HStack {
                Text("Servers")

                Spacer()

                if selectedWorkspace != nil {
                    EnvironmentFilterMenu(
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
                    ActiveConnectionListRow(
                        title: connection.title,
                        status: connection.status,
                        tmuxStatus: connection.tmuxStatus,
                        tabCount: connection.tabCount,
                        onOpen: { openActiveConnection(connection) },
                        onDisconnect: { disconnectActiveConnection(connection) }
                    )
                    .accessibilityIdentifier(
                        "vvterm.serverList.activeConnection.\(connection.id.uuidString)"
                    )
                }
            } header: {
                Text("Active Connections")
            }
        }
    }

    private var activeConnections: [ActiveServerSummary] {
        ActiveServerSummary.makeAll(
            tabManager: tabManager,
            fileTabs: fileTabs,
            server: { server(for: $0) },
            viewTabConfig: viewTabConfig
        )
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

    private func openActiveConnection(_ connection: ActiveServerSummary) {
        Task {
            guard let serverToUnlock = server(for: connection.id) else { return }
            guard await AppLockManager.shared.ensureServerUnlocked(serverToUnlock) else { return }
            guard let currentConnection = activeConnections.first(where: {
                $0.id == connection.id
            }), let currentServer = server(for: connection.id) else {
                return
            }

            if let tab = currentConnection.terminalTab {
                tabManager.selectedTabByServer[currentServer.id] = tab.id
            }
            tabManager.selectedViewByServer[currentServer.id] = currentConnection.targetViewId
            onActiveConnectionSelected(currentServer)
        }
    }

    private func disconnectActiveConnection(_ connection: ActiveServerSummary) {
        fileBrowser.disconnect(serverId: connection.id)
        fileTabs.disconnect(serverId: connection.id)
        tabManager.disconnectServer(connection.id)
    }

    private func server(for serverId: UUID) -> Server? {
        serverManager.servers.first { $0.id == serverId }
    }

    // MARK: - Teleport Setup Sheet (mirrors ServerSidebarView.teleportSetupSheet)

    /// The Teleport setup sheet, presented when a non-ready Teleport server
    /// is tapped. Routes to the appropriate view (bootstrap/registration/login)
    /// based on the readiness state.
    ///
    /// Phase chaining: the sheet is presented once (driven by
    /// `teleportSetupServer` + `teleportSetupReadiness`). When a phase
    /// succeeds, its `onSuccess` flips `teleportSetupReadiness` to the next
    /// phase instead of dismissing — SwiftUI re-renders the same sheet as
    /// the next phase's view. The `BootstrapResult` is held in
    /// `teleportBootstrapResult` so the registration sheet can resume
    /// without redoing Phase 1 (the TLS keypair is ephemeral and not
    /// persisted to the keychain). Mirrors the `ServerSidebarView` pattern.
    @ViewBuilder
    private func teleportSetupSheet(server: Server, readiness: TeleportDeviceReadiness) -> some View {
        let cluster = TeleportCluster(
            id: server.id,
            host: server.host,
            port: server.port,
            username: server.username
        )
        switch readiness {
        case .needsBootstrap:
            TeleportBootstrapSheet(
                makeCoordinator: { makeBootstrapCoordinator() },
                cluster: cluster,
                onSuccess: { result in
                    // Phase 1 → Phase 2: hold the result (TLS keypair) in
                    // memory and flip readiness so the sheet re-renders as
                    // the registration view. Do NOT dismiss — the user
                    // should flow straight into Phase 2.
                    teleportBootstrapResult = result
                    teleportSetupReadiness = .needsRegistration
                },
                onCancel: {
                    teleportSetupServer = nil
                    teleportSetupReadiness = nil
                    teleportBootstrapResult = nil
                }
            )
            .adaptiveSoftScrollEdges()
        case .needsRegistration:
            // The Phase-1 TLS keypair is ephemeral (held only for the gRPC
            // mTLS dial) and is NOT persisted to the keychain. Instead, the
            // `BootstrapResult` is held in `teleportBootstrapResult` so the
            // registration sheet can resume directly without redoing Phase 1.
            // If the result is missing (e.g. the app was killed between
            // Phase 1 and Phase 2), fall back to re-bootstrapping.
            if let bootstrapResult = teleportBootstrapResult {
                TeleportRegistrationSheet(
                    makeCoordinator: { makeRegistrationCoordinator() },
                    cluster: cluster,
                    bootstrapResult: bootstrapResult,
                    onSuccess: {
                        // Phase 2 → Phase 3: the SEP key is now registered,
                        // but the live cert hasn't been issued yet. Flip to
                        // the login sheet so the user gets a fresh cert via
                        // native Face ID.
                        teleportSetupReadiness = .needsLogin
                    },
                    onCancel: {
                        teleportSetupServer = nil
                        teleportSetupReadiness = nil
                        teleportBootstrapResult = nil
                    }
                )
                .adaptiveSoftScrollEdges()
            } else {
                // No in-memory bootstrap result — re-bootstrap to regenerate
                // the TLS keypair, then chain to registration on success.
                TeleportBootstrapSheet(
                    makeCoordinator: { makeBootstrapCoordinator() },
                    cluster: cluster,
                    onSuccess: { result in
                        teleportBootstrapResult = result
                        teleportSetupReadiness = .needsRegistration
                    },
                    onCancel: {
                        teleportSetupServer = nil
                        teleportSetupReadiness = nil
                        teleportBootstrapResult = nil
                    }
                )
                .adaptiveSoftScrollEdges()
            }
        case .needsLogin:
            TeleportLoginSheet(
                makeCoordinator: { makeLoginCoordinator() },
                cluster: cluster,
                onSuccess: {
                    // Phase 3 complete — the live cert is issued. Dismiss.
                    teleportSetupServer = nil
                    teleportSetupReadiness = nil
                    teleportBootstrapResult = nil
                },
                onCancel: {
                    teleportSetupServer = nil
                    teleportSetupReadiness = nil
                    teleportBootstrapResult = nil
                }
            )
            .adaptiveSoftScrollEdges()
        case .ready:
            // Shouldn't happen — ready servers don't trigger the setup sheet.
            EmptyView()
        }
    }

    @MainActor
    private func makeBootstrapCoordinator() -> TeleportBootstrapCoordinator {
        TeleportBootstrapCoordinator(
            httpClient: LiveTeleportHTTPClient(),
            keyRing: TeleportKeyRing.shared,
            safariPresenter: WebAuthenticationSessionPresenter.shared,
            signer: SecureEnclaveSigner()
        )
    }

    @MainActor
    private func makeRegistrationCoordinator() -> TeleportRegistrationCoordinator {
        TeleportRegistrationCoordinator(
            grpcClient: LiveTeleportGRPCClient(),
            browserMFACeremony: LiveBrowserMFACeremony(),
            keyRing: TeleportKeyRing.shared,
            signer: SecureEnclaveSigner(),
            webAuthnBuilder: TeleportWebAuthnBuilder()
        )
    }

    @MainActor
    private func makeLoginCoordinator() -> TeleportLoginCoordinator {
        TeleportLoginCoordinator(
            httpClient: LiveTeleportHTTPClient(),
            keyRing: TeleportKeyRing.shared,
            signer: SecureEnclaveSigner(),
            webAuthnBuilder: TeleportWebAuthnBuilder()
        )
    }
}

// MARK: - Teleport phase sheet wrappers
//
// Each Teleport phase view (bootstrap / registration / login) observes its
// coordinator via `@ObservedObject`. The coordinator MUST be held in a
// `@StateObject`-backed wrapper so SwiftUI creates it once (when the sheet
// first appears) and preserves its identity across the PARENT view's body
// re-evaluations. Constructing the coordinator inline in `teleportSetupSheet`
// (the previous wiring) orphaned the coordinator that reached `.success`
// when the parent re-rendered during the async POST — the sheet's
// `.onChange(of: coordinator.state)` then observed a fresh `.idle`
// coordinator, so `onSuccess` never fired (the live-device "stuck on Waiting
// for Safari approval" bug).

private struct TeleportBootstrapSheet: View {
    let makeCoordinator: () -> TeleportBootstrapCoordinator
    let cluster: TeleportCluster
    let onSuccess: (TeleportBootstrapCoordinator.BootstrapResult) -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator: TeleportBootstrapCoordinator

    @MainActor
    init(
        makeCoordinator: @escaping () -> TeleportBootstrapCoordinator,
        cluster: TeleportCluster,
        onSuccess: @escaping (TeleportBootstrapCoordinator.BootstrapResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.makeCoordinator = makeCoordinator
        self.cluster = cluster
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        _coordinator = StateObject(wrappedValue: makeCoordinator())
    }

    var body: some View {
        TeleportBootstrapView(
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: onSuccess,
            onCancel: onCancel
        )
    }
}

private struct TeleportRegistrationSheet: View {
    let makeCoordinator: () -> TeleportRegistrationCoordinator
    let cluster: TeleportCluster
    let bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator: TeleportRegistrationCoordinator

    @MainActor
    init(
        makeCoordinator: @escaping () -> TeleportRegistrationCoordinator,
        cluster: TeleportCluster,
        bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult,
        onSuccess: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.makeCoordinator = makeCoordinator
        self.cluster = cluster
        self.bootstrapResult = bootstrapResult
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        _coordinator = StateObject(wrappedValue: makeCoordinator())
    }

    var body: some View {
        TeleportRegistrationView(
            coordinator: coordinator,
            cluster: cluster,
            bootstrapResult: bootstrapResult,
            onSuccess: onSuccess,
            onCancel: onCancel
        )
    }
}

private struct TeleportLoginSheet: View {
    let makeCoordinator: () -> TeleportLoginCoordinator
    let cluster: TeleportCluster
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator: TeleportLoginCoordinator

    @MainActor
    init(
        makeCoordinator: @escaping () -> TeleportLoginCoordinator,
        cluster: TeleportCluster,
        onSuccess: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.makeCoordinator = makeCoordinator
        self.cluster = cluster
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        _coordinator = StateObject(wrappedValue: makeCoordinator())
    }

    var body: some View {
        TeleportLoginView(
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: onSuccess,
            onCancel: onCancel
        )
    }
}
#endif
