//
//  ServerTerminalRoute+iOS.swift
//  VVTerm
//

import SwiftUI

#if os(iOS)
import UIKit

// MARK: - Server Terminal Route

struct ServerTerminalRoute: View {
    private enum PresentedRouteSheet: Hashable, Identifiable {
        case settings
        case editServer(Server)

        var id: Self { self }
    }

    @ObservedObject var tabManager: TerminalTabManager
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    let route: ServerTerminalNavigationRoute
    let onBack: () -> Void

    @ObservedObject private var keyboardCoordinator: TerminalKeyboardCoordinator
    @ObservedObject private var viewTabConfig = ViewTabConfigurationManager.shared
    @EnvironmentObject private var appLockManager: AppLockManager
    @EnvironmentObject private var screenAwakeCoordinator: TerminalScreenAwakeCoordinator

    @State private var isRouteVisible = false
    @State private var screenAwakeRequestID = UUID()
    @State private var presentedRouteSheet: PresentedRouteSheet?
    @State private var showingTabLimitAlert = false
    @State private var showingFileTabLimitAlert = false
    @SceneStorage("vvterm.zenMode.ios") private var isZenModeEnabled = false
    @AppStorage(PrivacyModeSettings.enabledKey) private var privacyModeEnabled = false
    @AppStorage(TerminalDefaults.keepScreenAwakeKey) private var keepScreenAwakeEnabled = TerminalDefaults.defaultKeepScreenAwake
    @AppStorage("terminalVoiceButtonEnabled") private var terminalVoiceButtonEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    init(
        tabManager: TerminalTabManager,
        serverManager: ServerManager,
        fileTabs: RemoteFileTabManager,
        fileBrowser: RemoteFileBrowserStore,
        route: ServerTerminalNavigationRoute,
        onBack: @escaping () -> Void
    ) {
        self.tabManager = tabManager
        self.serverManager = serverManager
        self.fileTabs = fileTabs
        self.fileBrowser = fileBrowser
        self.route = route
        self.onBack = onBack
        self._keyboardCoordinator = ObservedObject(wrappedValue: tabManager.keyboardCoordinator)
    }

    private var selectedServer: Server? {
        if let server = serverManager.servers.first(where: { $0.id == route.serverId }) {
            return server
        }
        return route.connectingServer
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

    private var hasNavigationContext: Bool {
        route.isConnecting
            || !tabManager.tabs(for: route.serverId).isEmpty
            || !fileTabs.tabs(for: route.serverId).isEmpty
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
            .sheet(item: $presentedRouteSheet, onDismiss: updateTerminalRouteActivation) { sheet in
                switch sheet {
                case .settings:
                    SettingsView()
                        .modifier(AppearanceModifier())
                        .adaptiveSoftScrollEdges()
                case .editServer(let server):
                    NavigationStack {
                        ServerFormSheet(
                            serverManager: serverManager,
                            workspace: serverManager.workspaces.first { $0.id == server.workspaceId },
                            server: server,
                            onSave: { _ in presentedRouteSheet = nil }
                        )
                    }
                    .adaptiveSoftScrollEdges()
                }
            }
            .onAppear {
                isRouteVisible = true
                dismissIfContextEnded()
                updateTerminalRouteActivation()
            }
            .onDisappear {
                isRouteVisible = false
                tabManager.invalidateReconnectPreparations(for: route.serverId)
                keyboardCoordinator.setViewActive(false)
                keyboardCoordinator.setActivePane(nil)
                screenAwakeCoordinator.update(isRequested: false, for: screenAwakeRequestID)
            }
            .onChange(of: selectedView) { newValue in
                if newValue != ConnectionViewTab.terminal.id {
                    clearPendingVoiceReturnForFocusedPane()
                }
                updateTerminalRouteActivation()
            }
            .onChange(of: selectedTab?.id) { _ in
                updateTerminalRouteActivation()
            }
            .onChange(of: focusedPaneId) { _ in
                updateTerminalRouteActivation()
            }
            .onChange(of: tabManager.terminalRegistryVersion) { _ in
                updateTerminalRouteActivation()
            }
            .onChangeCompat(of: tabManager.tabsByServer) { _ in
                dismissIfContextEnded()
                updateTerminalRouteActivation()
            }
            .onChangeCompat(of: fileTabs.tabsByServer) { _ in
                dismissIfContextEnded()
                updateTerminalRouteActivation()
            }
            .onChange(of: scenePhase) { _ in
                updateTerminalRouteActivation()
            }
            .onChange(of: isContentObscured) { _ in
                updateTerminalRouteActivation()
            }
            .onChange(of: keepScreenAwakeEnabled) { _ in
                updateTerminalRouteActivation()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { notification in
                handleSceneDidActivate(notification)
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
                updateTerminalRouteActivation()
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
            .navigationTitle(server.name)
        } else if route.isConnecting {
            connectingStateView(
                serverName: route.connectingServer?.name ?? String(localized: "Server")
            )
        } else {
            TerminalEmptyStateView(server: nil) {
                leaveRoute()
            }
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                leaveRoute()
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityIdentifier("vvterm.terminal.back")
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
                    presentRouteSheet(.settings)
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
                        presentRouteSheet(.editServer(server))
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
            .accessibilityIdentifier("vvterm.terminal.moreMenu")
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
    private var terminalSceneActivation: TerminalKeyboardRouteActivationPolicy.SceneActivation {
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

    private var keyboardPresentationOwnership: TerminalKeyboardRouteActivationPolicy.PresentationOwnership {
        presentedRouteSheet == nil ? .terminal : .routeModal
    }

    private var screenAwakeSceneIsInBackground: Bool {
        switch terminalSceneActivation {
        case .foregroundActive, .foregroundInactive:
            false
        case .background:
            true
        }
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
            if let focusedPaneId {
                keyboardCoordinator.activeTerminalSceneWillDeactivate(for: focusedPaneId)
            }
            updateTerminalRouteActivation()
        }
    }

    private func handleSceneDidActivate(_ notification: Notification) {
        guard let notifyingScene = notification.object as? UIScene,
              let terminal = focusedTerminal,
              notifyingScene === terminal.window?.windowScene else {
            return
        }

        updateTerminalRouteActivation()
        guard let focusedPaneId else { return }
        keyboardCoordinator.activeTerminalSceneDidActivate(for: focusedPaneId)
    }

    private func handleTerminalWindowKeyChange(_ notification: Notification) {
        guard let notifyingWindow = notification.object as? UIWindow,
              notifyingWindow === focusedTerminal?.window else {
            return
        }
        updateTerminalRouteActivation()
        if notifyingWindow.isKeyWindow, let focusedPaneId {
            keyboardCoordinator.activeTerminalWindowDidBecomeKey(for: focusedPaneId)
        }
    }

    private func updateTerminalRouteActivation() {
        let presentationOwnership = keyboardPresentationOwnership
        let effect = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: isRouteVisible,
            terminalSelected: selectedView == ConnectionViewTab.terminal.id,
            sceneActivation: terminalSceneActivation,
            windowOwnership: focusedTerminal?.window.map {
                $0.isKeyWindow ? .key : .notKey
            } ?? .unknown,
            presentationOwnership: presentationOwnership,
            contentObscured: isContentObscured
        )

        screenAwakeCoordinator.update(
            isRequested: TerminalScreenAwakeCoordinator.shouldRequest(
                preferenceEnabled: keepScreenAwakeEnabled,
                routeVisible: isRouteVisible,
                terminalSelected: selectedView == ConnectionViewTab.terminal.id,
                sceneIsInBackground: screenAwakeSceneIsInBackground
            ),
            for: screenAwakeRequestID
        )

        if effect == .preserve {
            if let focusedPaneId {
                keyboardCoordinator.activeTerminalSceneWillDeactivate(for: focusedPaneId)
            }
            return
        }

        if effect == .deactivate {
            if isContentObscured {
                keyboardCoordinator.deactivateInputImmediately()
                return
            }
            if presentationOwnership == .routeModal {
                keyboardCoordinator.deactivateInputImmediately(reason: .routeModal)
                return
            }
        }

        let activePaneId = effect == .activate ? focusedPaneId : nil

        keyboardCoordinator.setActivePane(activePaneId)
        keyboardCoordinator.setViewActive(effect == .activate)
        if let activePaneId {
            keyboardCoordinator.setFindNavigatorActive(
                isFocusedTerminalFindNavigatorVisible,
                for: activePaneId
            )
        }
    }

    private func dismissIfContextEnded() {
        guard !hasNavigationContext else { return }
        isZenModeEnabled = false
        leaveRoute()
    }

    private func leaveRoute() {
        tabManager.invalidateReconnectPreparations(for: route.serverId)
        keyboardCoordinator.relinquishRouteOwnershipForNavigation()
        onBack()
    }

    private func presentRouteSheet(_ sheet: PresentedRouteSheet) {
        keyboardCoordinator.deactivateInputImmediately(reason: .routeModal)
        presentedRouteSheet = sheet
    }

    private func showKeyboardForFocusedTerminal() {
        guard selectedView == ConnectionViewTab.terminal.id else { return }
        clearPendingVoiceReturnForFocusedPane()
        keyboardCoordinator.userRequestedShow()
        focusedTerminal?.dismissFindNavigator()
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
            accessibilityIdentifier: "vvterm.terminal.floating.keyboard",
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
            accessibilityIdentifier: "vvterm.terminal.floating.voiceInput",
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
            accessibilityIdentifier: "vvterm.terminal.floating.return",
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
        accessibilityIdentifier: String,
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
        .accessibilityIdentifier(accessibilityIdentifier)
        .modifier(
            FloatingTerminalControlButtonStyle(
                isPrimary: isPrimary,
                colorScheme: colorScheme
            )
        )
    }

    private func openNewTab(for server: Server) {
        guard tabManager.canOpenNewTab else {
            showingTabLimitAlert = true
            return
        }

        Task {
            do {
                let tab = try await tabManager.openTab(for: server)
                tabManager.selectedViewByServer[server.id] = viewTabConfig.effectiveView(for: ConnectionViewTab.terminal.id)
                tabManager.selectedTabByServer[server.id] = tab.id
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
        fileBrowser.prepareNewTab(newTab, duplicating: sourceTab)
        tabManager.selectedViewByServer[server.id] = viewTabConfig.effectiveView(for: ConnectionViewTab.files.id)
    }

    private func disconnect(_ server: Server) {
        fileBrowser.disconnect(serverId: server.id)
        fileTabs.disconnect(serverId: server.id)
        tabManager.disconnectServer(server.id)
        dismissIfContextEnded()
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
