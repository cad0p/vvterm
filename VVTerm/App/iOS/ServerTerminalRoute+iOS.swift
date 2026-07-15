//
//  ServerTerminalRoute+iOS.swift
//  VVTerm
//

import SwiftUI

#if os(iOS)
import UIKit

// MARK: - Server Terminal Route

struct ServerTerminalRoute: View {
    @ObservedObject var tabManager: TerminalTabManager
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    let requestedServerId: UUID?
    let connectingServer: Server?
    let isConnecting: Bool
    let onBack: () -> Void

    @ObservedObject private var keyboardCoordinator: TerminalKeyboardCoordinator
    @ObservedObject private var viewTabConfig = ViewTabConfigurationManager.shared
    @EnvironmentObject private var appLockManager: AppLockManager

    @State private var currentServerId: UUID?
    @State private var isRouteVisible = false
    @State private var showingSettings = false
    @State private var serverToEdit: Server?
    @State private var showingTabLimitAlert = false
    @State private var showingFileTabLimitAlert = false
    @SceneStorage("vvterm.zenMode.ios") private var isZenModeEnabled = false
    @AppStorage(PrivacyModeSettings.enabledKey) private var privacyModeEnabled = false
    @AppStorage("terminalVoiceButtonEnabled") private var terminalVoiceButtonEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    init(
        tabManager: TerminalTabManager,
        serverManager: ServerManager,
        fileTabs: RemoteFileTabManager,
        fileBrowser: RemoteFileBrowserStore,
        requestedServerId: UUID?,
        connectingServer: Server?,
        isConnecting: Bool,
        onBack: @escaping () -> Void
    ) {
        self.tabManager = tabManager
        self.serverManager = serverManager
        self.fileTabs = fileTabs
        self.fileBrowser = fileBrowser
        self.requestedServerId = requestedServerId
        self.connectingServer = connectingServer
        self.isConnecting = isConnecting
        self.onBack = onBack
        self._keyboardCoordinator = ObservedObject(wrappedValue: tabManager.keyboardCoordinator)
    }

    private var activeServerIds: [UUID] {
        var ordered: [UUID] = []
        for (serverId, tabs) in tabManager.tabsByServer where !tabs.isEmpty {
            ordered.append(serverId)
        }
        for (serverId, tabs) in fileTabs.tabsByServer where !tabs.isEmpty && !ordered.contains(serverId) {
            ordered.append(serverId)
        }
        return ordered
    }

    private var selectedServer: Server? {
        if let currentServerId,
           let server = serverManager.servers.first(where: { $0.id == currentServerId }) {
            return server
        }

        if let requestedServerId,
           let server = serverManager.servers.first(where: { $0.id == requestedServerId }) {
            return server
        }

        if let connectingServer {
            return connectingServer
        }

        guard let firstActiveId = activeServerIds.first else { return nil }
        return serverManager.servers.first { $0.id == firstActiveId }
    }

    private var selectedView: String {
        guard let server = selectedServer else {
            return viewTabConfig.effectiveDefaultTab()
        }
        return viewTabConfig.effectiveView(for: tabManager.selectedViewByServer[server.id])
    }

    private var selectedTab: TerminalTab? {
        guard let server = selectedServer else { return nil }
        return tabManager.selectedTab(for: server.id)
    }

    private var selectedFileTab: RemoteFileTab? {
        guard let server = selectedServer else { return nil }
        return fileTabs.selectedTab(for: server.id)
    }

    private var focusedTerminal: GhosttyTerminalView? {
        guard let paneId = selectedTab?.focusedPaneId else { return nil }
        return tabManager.getTerminal(for: paneId)
    }

    private var focusedPaneId: UUID? {
        selectedTab?.focusedPaneId
    }

    private var isFocusedTerminalFindNavigatorVisible: Bool {
        guard let focusedPaneId else { return false }
        return tabManager.terminalFindNavigatorVisibleByPane[focusedPaneId] ?? false
    }

    private var isFocusedTerminalVoiceRecording: Bool {
        guard let focusedPaneId else { return false }
        return tabManager.terminalVoiceRecordingByPane[focusedPaneId] ?? false
    }

    private var isFocusedTerminalPendingVoiceReturn: Bool {
        guard let focusedPaneId else { return false }
        return tabManager.terminalPendingVoiceReturnByPane[focusedPaneId] ?? false
    }

    private var shouldShowFloatingTerminalControls: Bool {
        return UIDevice.current.userInterfaceIdiom == .phone
            && selectedView == ConnectionViewTab.terminal.id
            && focusedPaneId != nil
            && keyboardCoordinator.isUserHidden
            && focusedTerminal?.isHardwareKeyboardAttached != true
            && !isFocusedTerminalFindNavigatorVisible
            && !isFocusedTerminalVoiceRecording
    }

    private var shouldShowFloatingVoiceButton: Bool {
        shouldShowFloatingTerminalControls && terminalVoiceButtonEnabled
    }

    private var shouldShowFloatingReturnButton: Bool {
        shouldShowFloatingTerminalControls && isFocusedTerminalPendingVoiceReturn
    }

    var body: some View {
        content
            .overlay(alignment: .bottom) {
                if shouldShowFloatingTerminalControls {
                    floatingTerminalControls
                        .padding(.bottom, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationBarBackButtonHidden(true)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { navigationToolbar }
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
            .onAppear {
                isRouteVisible = true
                reconcileSelectedServer()
                updateKeyboardCoordinatorInputs()
            }
            .onDisappear {
                isRouteVisible = false
                keyboardCoordinator.setViewActive(false)
                keyboardCoordinator.setActivePane(nil)
            }
            .onChange(of: connectingServer?.id) { _ in
                reconcileSelectedServer()
                updateKeyboardCoordinatorInputs()
            }
            .onChange(of: requestedServerId) { _ in
                reconcileSelectedServer()
                updateKeyboardCoordinatorInputs()
            }
            .onChange(of: selectedView) { newValue in
                if newValue != ConnectionViewTab.terminal.id {
                    clearPendingVoiceReturnForFocusedPane()
                }
                updateKeyboardCoordinatorInputs()
            }
            .onChange(of: selectedTab?.id) { _ in
                updateKeyboardCoordinatorInputs()
            }
            .onChange(of: focusedPaneId) { _ in
                updateKeyboardCoordinatorInputs()
            }
            .onChange(of: tabManager.terminalRegistryVersion) { _ in
                updateKeyboardCoordinatorInputs()
            }
            .onChangeCompat(of: tabManager.tabsByServer) { _ in
                reconcileSelectedServer()
                updateKeyboardCoordinatorInputs()
            }
            .onChangeCompat(of: fileTabs.tabsByServer) { _ in
                reconcileSelectedServer()
                updateKeyboardCoordinatorInputs()
            }
            .onChange(of: scenePhase) { _ in
                updateKeyboardCoordinatorInputs()
            }
            .onChange(of: isContentObscured) { _ in
                updateKeyboardCoordinatorInputs()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
                updateKeyboardCoordinatorInputs()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { notification in
                handleSceneWillDeactivate(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { notification in
                handleTerminalWindowKeyChange(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didResignKeyNotification)) { notification in
                handleTerminalWindowKeyChange(notification)
            }
            .onChange(of: isFocusedTerminalFindNavigatorVisible) { _ in
                updateKeyboardCoordinatorInputs()
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: shouldShowFloatingTerminalControls)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: shouldShowFloatingReturnButton)
    }

    @ViewBuilder
    private var content: some View {
        if let server = selectedServer {
            ConnectionTerminalContainer(
                tabManager: tabManager,
                fileTabManager: fileTabs,
                serverManager: serverManager,
                fileBrowser: fileBrowser,
                server: server,
                isZenModeEnabled: $isZenModeEnabled,
                isSidebarVisible: false,
                onToggleSidebar: {}
            )
            .id(server.id)
            .navigationTitle(server.name)
        } else if isConnecting {
            connectingStateView(serverName: connectingServer?.name ?? String(localized: "Server"))
        } else {
            TerminalEmptyStateView(server: nil) {
                onBack()
            }
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    keyboardCoordinator.setViewActive(false)
                    keyboardCoordinator.setActivePane(nil)
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
            }
        }

        if let server = selectedServer, viewTabConfig.currentVisibleTabs.count > 1 {
            ToolbarItem(placement: .principal) {
                ConnectionViewSegmentedPicker(
                    selection: selectedViewBinding(for: server.id),
                    tabs: viewTabConfig.currentVisibleTabs
                )
                .fixedSize()
            }
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if let server = selectedServer, selectedView == ConnectionViewTab.terminal.id {
                Button {
                    openNewTab(for: server)
                } label: {
                    Image(systemName: "plus")
                }
            }

            if let server = selectedServer, selectedView == ConnectionViewTab.files.id {
                Button {
                    openNewFileTab(for: server)
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

                if let server = selectedServer {
                    if selectedView == ConnectionViewTab.terminal.id {
                        Button {
                            focusedTerminal?.showFindNavigator()
                        } label: {
                            Label("Find", systemImage: "magnifyingglass")
                        }

                        Button {
                            showKeyboardForFocusedTerminal()
                        } label: {
                            Label("Keyboard", systemImage: "keyboard")
                        }
                    }

                    Button {
                        serverToEdit = server
                    } label: {
                        Label("Edit Server", systemImage: "pencil")
                    }

                    Divider()

                    Button(role: .destructive) {
                        disconnect(server)
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func selectedViewBinding(for serverId: UUID) -> Binding<String> {
        Binding(
            get: { viewTabConfig.effectiveView(for: tabManager.selectedViewByServer[serverId]) },
            set: { newValue in
                tabManager.selectedViewByServer[serverId] = viewTabConfig.effectiveView(for: newValue)
            }
        )
    }

    /// Prefer the terminal's own UIKit scene because SwiftUI's scenePhase can
    /// lag under iPhone Mirroring and another foreground scene must not make
    /// this route appear active.
    private var keyboardSceneActivation: TerminalKeyboardRouteActivationPolicy.SceneActivation {
        if let activationState = focusedTerminal?.window?.windowScene?.activationState {
            switch activationState {
            case .foregroundActive:
                return .foregroundActive
            case .foregroundInactive:
                return .foregroundInactive
            case .background, .unattached:
                return .background
            @unknown default:
                return .background
            }
        }

        switch scenePhase {
        case .active:
            return .foregroundActive
        case .inactive:
            return .foregroundInactive
        case .background:
            return .background
        @unknown default:
            return .background
        }
    }

    private var isContentObscured: Bool {
        AppContentProtectionPolicy.shouldObscureContent(
            sceneIsActive: scenePhase == .active,
            fullAppLockEnabled: appLockManager.fullAppLockEnabled,
            privacyModeEnabled: privacyModeEnabled,
            isAppLocked: appLockManager.isAppLocked
        )
    }

    private func handleSceneWillDeactivate(_ notification: Notification) {
        if let notifyingScene = notification.object as? UIScene,
           let terminalScene = focusedTerminal?.window?.windowScene,
           notifyingScene !== terminalScene {
            return
        }

        if AppContentProtectionPolicy.shouldPrepareForSceneDeactivation(
            fullAppLockEnabled: appLockManager.fullAppLockEnabled,
            privacyModeEnabled: privacyModeEnabled,
            isAppLocked: appLockManager.isAppLocked
        ) {
            keyboardCoordinator.deactivateInputImmediately()
        } else {
            updateKeyboardCoordinatorInputs()
        }
    }

    private func handleTerminalWindowKeyChange(_ notification: Notification) {
        guard let notifyingWindow = notification.object as? UIWindow,
              notifyingWindow === focusedTerminal?.window else {
            return
        }
        updateKeyboardCoordinatorInputs()
    }

    private func updateKeyboardCoordinatorInputs() {
        let effect = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: isRouteVisible,
            terminalSelected: selectedView == ConnectionViewTab.terminal.id,
            sceneActivation: keyboardSceneActivation,
            windowOwnership: focusedTerminal?.window.map {
                $0.isKeyWindow ? .key : .notKey
            } ?? .unknown,
            contentObscured: isContentObscured
        )

        guard effect != .preserve else { return }

        if effect == .deactivate, isContentObscured {
            keyboardCoordinator.deactivateInputImmediately()
            return
        }

        let activePaneId = effect == .activate ? focusedPaneId : nil

        keyboardCoordinator.setActivePane(activePaneId)
        keyboardCoordinator.setViewActive(effect == .activate)
        keyboardCoordinator.setFindNavigatorActive(activePaneId != nil && isFocusedTerminalFindNavigatorVisible)

        if let activePaneId {
            keyboardCoordinator.setPaneConnected(
                tabManager.paneStates[activePaneId]?.connectionState.isConnected == true,
                for: activePaneId
            )
        }
    }

    private func showKeyboardForFocusedTerminal() {
        guard selectedView == ConnectionViewTab.terminal.id else { return }
        clearPendingVoiceReturnForFocusedPane()
        keyboardCoordinator.userRequestedShow()
        focusedTerminal?.requestKeyboardFocus(for: .explicitUserRequest)
    }

    private func startVoiceInputForFocusedTerminal() {
        guard selectedView == ConnectionViewTab.terminal.id else { return }
        guard terminalVoiceButtonEnabled else { return }
        guard let focusedPaneId,
              tabManager.paneStates[focusedPaneId]?.connectionState.isConnected == true else { return }
        clearPendingVoiceReturnForFocusedPane()
        if focusedTerminal?.triggerVoiceInput() == true {
            tabManager.setTerminalVoiceRecording(true, for: focusedPaneId)
        }
    }

    private func sendReturnForFocusedTerminal() {
        guard selectedView == ConnectionViewTab.terminal.id else { return }
        if focusedTerminal?.sendReturnKey() == true {
            clearPendingVoiceReturnForFocusedPane()
        }
    }

    private func clearPendingVoiceReturnForFocusedPane() {
        guard let focusedPaneId else { return }
        tabManager.setTerminalPendingVoiceReturn(false, for: focusedPaneId)
    }

    @ViewBuilder
    private var floatingTerminalControls: some View {
        HStack(spacing: 10) {
            floatingKeyboardVoiceControls(showsTitle: true)
                .layoutPriority(1)
            if shouldShowFloatingReturnButton {
                Spacer(minLength: 14)
                floatingReturnControl()
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: shouldShowFloatingReturnButton ? .infinity : nil)
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
            showsTitle: showsTitle,
            action: showKeyboardForFocusedTerminal
        )
    }

    @ViewBuilder
    private func floatingVoiceControl(showsTitle: Bool) -> some View {
        floatingTerminalControlButton(
            title: "Voice input",
            systemImage: "mic.fill",
            accessibilityLabel: "Voice input",
            showsTitle: showsTitle,
            action: startVoiceInputForFocusedTerminal
        )
    }

    @ViewBuilder
    private func floatingReturnControl() -> some View {
        floatingTerminalControlButton(
            title: "Enter",
            systemImage: "arrow.turn.down.left",
            accessibilityLabel: "Enter",
            showsTitle: false,
            isPrimary: true,
            action: sendReturnForFocusedTerminal
        )
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
        Button(action: action) {
            HStack(spacing: showsTitle ? 6 : 0) {
                Image(systemName: systemImage)
                if showsTitle {
                    Text(title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(isPrimary ? Color.accentColor : Color.primary)
            .padding(.horizontal, showsTitle ? 2 : 0)
        }
        .accessibilityLabel(Text(accessibilityLabel))
        .modifier(
            FloatingTerminalControlButtonStyle(
                isPrimary: isPrimary,
                colorScheme: colorScheme
            )
        )
    }

    private func reconcileSelectedServer() {
        if let currentServerId,
           activeServerIds.contains(currentServerId)
                || connectingServer?.id == currentServerId {
            return
        }

        let requestedId = requestedServerId ?? connectingServer?.id
        if let requestedId,
           activeServerIds.contains(requestedId) || connectingServer?.id == requestedId {
            currentServerId = requestedId
        } else {
            currentServerId = connectingServer?.id ?? activeServerIds.first
        }

        if currentServerId == nil && !isConnecting {
            isZenModeEnabled = false
            onBack()
        }
    }

    private func openNewTab(for server: Server) {
        guard tabManager.canOpenNewTab else {
            showingTabLimitAlert = true
            return
        }

        Task {
            do {
                let tab = try await tabManager.openTab(for: server)
                await MainActor.run {
                    currentServerId = server.id
                    tabManager.selectedViewByServer[server.id] = viewTabConfig.effectiveView(for: ConnectionViewTab.terminal.id)
                    tabManager.selectedTabByServer[server.id] = tab.id
                }
            } catch {
                // No-op: user cancelled biometric auth or open failed.
            }
        }
    }

    private func openNewFileTab(for server: Server) {
        guard fileTabs.canOpenNewTab(for: server.id) else {
            showingFileTabLimitAlert = true
            return
        }

        let sourceTab = selectedFileTab
        let seedPath = sourceTab.flatMap { fileBrowser.lastVisitedPath(for: $0) }
            ?? selectedTab.flatMap { tabManager.workingDirectory(for: $0.focusedPaneId) }
        let newTab = sourceTab.flatMap { fileTabs.duplicateTab($0, seedPath: seedPath) }
            ?? fileTabs.openTab(for: server, seedPath: seedPath)

        guard let newTab else { return }
        currentServerId = server.id
        fileBrowser.prepareNewTab(newTab, duplicating: sourceTab)
        tabManager.selectedViewByServer[server.id] = viewTabConfig.effectiveView(for: ConnectionViewTab.files.id)
    }

    private func disconnect(_ server: Server) {
        fileBrowser.disconnect(serverId: server.id)
        fileTabs.disconnect(serverId: server.id)
        tabManager.disconnectServer(server.id)
        onBack()
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
}

private struct FloatingTerminalControlButtonStyle: ViewModifier {
    let isPrimary: Bool
    let colorScheme: ColorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if isPrimary {
                content
                    .tint(Color.accentColor)
                    .buttonStyle(SwiftUI.GlassButtonStyle())
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            } else {
                content
                    .buttonStyle(SwiftUI.GlassButtonStyle())
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
        } else {
            content
                .buttonStyle(
                    .glass(
                        tint: Color.accentColor.opacity(
                            isPrimary ? 0.5 : (colorScheme == .dark ? 0.24 : 0.14)
                        )
                    )
                )
        }
    }
}
#endif
