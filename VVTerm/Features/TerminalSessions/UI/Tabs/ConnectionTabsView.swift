//
//  ConnectionTabsView.swift
//  VVTerm
//

import SwiftUI

// MARK: - Connection Terminal Container

struct ConnectionTerminalContainer: View {
    @ObservedObject var tabManager: TerminalTabManager
    @ObservedObject var fileTabManager: RemoteFileTabManager
    let serverManager: ServerManager
    let fileBrowser: RemoteFileBrowserStore
    let server: Server
    @Binding var isZenModeEnabled: Bool
    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var viewTabConfig = ViewTabConfigurationManager.shared

    /// Theme name from settings
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true

    /// Disconnect confirmation
    @State var showingDisconnectConfirmation = false
    /// Confirmation before closing the focused split pane via a command/panel
    /// (the in-pane close button has its own confirmation in TerminalTabView).
    @State var showingPaneCloseConfirmation = false
    @State var serverToEdit: Server?

    /// Tab limit alert
    @State private var showingTabLimitAlert = false
    @State private var showingFileTabLimitAlert = false
    @State private var showingSplitPaneUpgradeAlert = false
    @State private var showingZenPanel = false
    #if os(macOS)
    @State var zenWindowSafeAreaInsets = EdgeInsets()
    #endif

    /// Selected view type - persisted per server
    var selectedView: String {
        viewTabConfig.effectiveView(for: tabManager.selectedViewByServer[server.id])
    }

    private var visibleViewTabs: [ConnectionViewTab] {
        viewTabConfig.currentVisibleTabs
    }

    var shouldShowViewPicker: Bool {
        visibleViewTabs.count > 1
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var selectedViewBinding: Binding<String> {
        Binding(
            get: { viewTabConfig.effectiveView(for: tabManager.selectedViewByServer[server.id]) },
            set: { newValue in
                let current = viewTabConfig.effectiveView(for: tabManager.selectedViewByServer[server.id])
                guard current != newValue else { return }
                DispatchQueue.main.async {
                    tabManager.selectedViewByServer[server.id] = viewTabConfig.isTabVisible(newValue)
                        ? newValue
                        : viewTabConfig.effectiveDefaultTab()
                }
            }
        )
    }

    /// Tabs for THIS server only
    var serverTabs: [TerminalTab] {
        tabManager.tabs(for: server.id)
    }

    /// Selected tab ID for this server
    var selectedTabId: UUID? {
        tabManager.selectedTabByServer[server.id]
    }

    private var selectedTabIdBinding: Binding<UUID?> {
        Binding(
            get: { tabManager.selectedTabByServer[server.id] },
            set: { newValue in
                let current = tabManager.selectedTabByServer[server.id]
                guard current != newValue else { return }
                DispatchQueue.main.async {
                    tabManager.selectedTabByServer[server.id] = newValue
                }
            }
        )
    }

    /// Currently selected tab
    private var selectedTab: TerminalTab? {
        guard let id = selectedTabId else { return serverTabs.first }
        return serverTabs.first { $0.id == id } ?? serverTabs.first
    }

    var serverFileTabs: [RemoteFileTab] {
        fileTabManager.tabs(for: server.id)
    }

    var selectedFileTabId: UUID? {
        fileTabManager.selectedTab(for: server.id)?.id
    }

    private var selectedFileTabIdBinding: Binding<UUID?> {
        Binding(
            get: { selectedFileTabId },
            set: { newValue in
                guard let newValue,
                      let tab = serverFileTabs.first(where: { $0.id == newValue }) else {
                    return
                }
                DispatchQueue.main.async {
                    fileTabManager.selectTab(tab)
                }
            }
        )
    }

    private var selectedFileTab: RemoteFileTab? {
        fileTabManager.selectedTab(for: server.id)
    }

    private var tmuxAttachPromptBinding: Binding<TmuxAttachPrompt?> {
        Binding(
            get: {
                guard let prompt = tabManager.tmuxAttachPrompt else { return nil }
                guard tabManager.paneStates[prompt.id]?.serverId == server.id else { return nil }
                return prompt
            },
            set: { newValue in
                guard newValue == nil, let prompt = tabManager.tmuxAttachPrompt else { return }
                guard tabManager.paneStates[prompt.id]?.serverId == server.id else { return }
                tabManager.cancelTmuxAttachPrompt(paneId: prompt.id)
            }
        )
    }

    private var liveTerminalBackgroundColor: Color {
        ThemeColorParser.backgroundColor(for: effectiveThemeName)!
    }

    var sharedBody: some View {
        platformChrome(
            contentLayer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(liveTerminalBackgroundColor),
            backgroundColor: liveTerminalBackgroundColor
        )
            .onAppear {
                updateTerminalBackgroundColor()
                // Select first tab if none selected
                if selectedTabId == nil {
                    selectedTabIdBinding.wrappedValue = serverTabs.first?.id
                }
                ensureInitialFileTabIfNeeded()
            }
            .onChange(of: terminalThemeName) { _ in
                updateTerminalBackgroundColor()
            }
            .onChange(of: terminalThemeNameLight) { _ in
                updateTerminalBackgroundColor()
            }
            .onChange(of: usePerAppearanceTheme) { _ in
                updateTerminalBackgroundColor()
            }
            .onChange(of: colorScheme) { _ in
                updateTerminalBackgroundColor()
            }
            .onChange(of: selectedView) { _ in
                ensureInitialFileTabIfNeeded()
            }
            .onChange(of: serverTabs.count) { _ in
                // Auto-select if current selection is invalid
                if let currentId = selectedTabId, !serverTabs.contains(where: { $0.id == currentId }) {
                    selectedTabIdBinding.wrappedValue = serverTabs.first?.id
                }
            }
            .onChange(of: isZenModeEnabled) { newValue in
                if !newValue {
                    showingZenPanel = false
                }
            }
            .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
            .limitReachedAlert(.fileTabs, isPresented: $showingFileTabLimitAlert)
            .splitPaneProFeatureAlert(isPresented: $showingSplitPaneUpgradeAlert)
            .sheet(item: tmuxAttachPromptBinding) { prompt in
                TmuxAttachPromptSheet(
                    prompt: prompt,
                    onConfirm: { selection in
                        tabManager.resolveTmuxAttachPrompt(paneId: prompt.id, selection: selection)
                    }
                )
                .adaptiveSoftScrollEdges()
            }
    }

    @ViewBuilder
    private var contentLayer: some View {
        ZStack {
            // Stats view - always in hierarchy, visibility controlled by opacity
            // Pass isVisible to pause/resume collection when hidden
            ServerStatsView(
                server: server,
                isVisible: selectedView == "stats",
                backgroundColor: liveTerminalBackgroundColor,
                sharedClientProvider: { tabManager.sharedStatsClient(for: server.id) },
                statsCollector: ServerStatsCollector()
            )
                .opacity(selectedView == "stats" ? 1 : 0)
                .allowsHitTesting(selectedView == "stats")
                .zIndex(selectedView == "stats" ? 1 : 0)

            if selectedView == "files" {
                if let selectedFileTab {
                    RemoteFileBrowserScreen(
                        browser: fileBrowser,
                        server: server,
                        fileTab: selectedFileTab,
                        initialPath: selectedFileTab.seedPath
                    ) { currentPath in
                        fileTabManager.updateLastKnownPath(currentPath, for: selectedFileTab.id)
                    }
                    .id(selectedFileTab.id)
                    .zIndex(1)
                } else {
                    RemoteFileTabsEmptyState(server: server) {
                        openNewFileTab(selectFilesViewOnSuccess: false)
                    }
                    .zIndex(1)
                }
            }

            terminalLayer
        }
    }

    var body: some View {
        platformBody
    }

    func handleNewTabCommand() {
        if selectedView == ConnectionViewTab.files.id {
            openNewFileTab(selectFilesViewOnSuccess: true)
        } else {
            openNewTab(selectTerminalViewOnSuccess: true)
        }
    }

    private func ensureInitialFileTabIfNeeded() {
        guard selectedView == ConnectionViewTab.files.id else { return }

        let seedPath = selectedTab.flatMap { tabManager.workingDirectory(for: $0.focusedPaneId) }
        DispatchQueue.main.async {
            guard selectedView == ConnectionViewTab.files.id else { return }
            guard let fileTab = fileTabManager.ensureInitialTab(for: server, seedPath: seedPath) else { return }
            fileBrowser.prepareNewTab(fileTab, duplicating: nil)
        }
    }

    func openNewTab(selectTerminalViewOnSuccess: Bool = false) {
        guard tabManager.canOpenNewTab else {
            showingTabLimitAlert = true
            return
        }

        Task {
            do {
                let tab = try await tabManager.openTab(for: server)
                await MainActor.run {
                    if selectTerminalViewOnSuccess {
                        tabManager.selectedViewByServer[server.id] = viewTabConfig.isTabVisible(ConnectionViewTab.terminal.id)
                            ? ConnectionViewTab.terminal.id
                            : viewTabConfig.effectiveDefaultTab()
                    }
                    selectedTabIdBinding.wrappedValue = tab.id
                }
            } catch {
                // No-op: user cancelled biometric auth or open failed.
            }
        }
    }

    private func openNewFileTab(selectFilesViewOnSuccess: Bool = false) {
        guard fileTabManager.canOpenNewTab(for: server.id) else {
            showingFileTabLimitAlert = true
            return
        }

        let sourceTab = selectedFileTab
        let seedPath = sourceTab.flatMap { fileBrowser.lastVisitedPath(for: $0) }
            ?? selectedTab.flatMap { tabManager.workingDirectory(for: $0.focusedPaneId) }
        let newTab = sourceTab.flatMap { fileTabManager.duplicateTab($0, seedPath: seedPath) }
            ?? fileTabManager.openTab(for: server, seedPath: seedPath)

        guard let newTab else { return }
        fileBrowser.prepareNewTab(newTab, duplicating: sourceTab)

        if selectFilesViewOnSuccess {
            tabManager.selectedViewByServer[server.id] = viewTabConfig.isTabVisible(ConnectionViewTab.files.id)
                ? ConnectionViewTab.files.id
                : viewTabConfig.effectiveDefaultTab()
        }
    }

    private func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = serverTabs.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[currentIndex - 1].id
    }

    private func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = serverTabs.firstIndex(where: { $0.id == currentId }),
              currentIndex < serverTabs.count - 1 else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[currentIndex + 1].id
    }

    private func selectPreviousFileTab() {
        fileTabManager.selectPreviousTab(for: server.id)
    }

    private func selectNextFileTab() {
        fileTabManager.selectNextTab(for: server.id)
    }

    private func baseFileTabTitle(for tab: RemoteFileTab) -> String {
        let candidatePath = fileBrowser.lastVisitedPath(for: tab)
            ?? tab.lastKnownPath
            ?? tab.seedPath

        guard let candidatePath else {
            return server.name.nonEmptyString ?? "/"
        }

        let normalizedPath = RemoteFilePath.normalize(candidatePath)
        guard normalizedPath != "/" else {
            return server.name.nonEmptyString ?? "/"
        }

        return RemoteFilePath.breadcrumbs(for: normalizedPath).last?.title ?? (server.name.nonEmptyString ?? "/")
    }

    private func displayedFileTabTitle(for tab: RemoteFileTab) -> String {
        let baseTitles = Dictionary(
            uniqueKeysWithValues: serverFileTabs.map { ($0.id, baseFileTabTitle(for: $0)) }
        )
        let titleCounts = Dictionary(grouping: baseTitles.values, by: { $0 }).mapValues(\.count)
        var seenCounts: [String: Int] = [:]
        var resolvedTitles: [UUID: String] = [:]

        for tab in serverFileTabs {
            let baseTitle = baseTitles[tab.id] ?? (server.name.nonEmptyString ?? "/")
            guard (titleCounts[baseTitle] ?? 0) > 1 else {
                resolvedTitles[tab.id] = baseTitle
                continue
            }

            seenCounts[baseTitle, default: 0] += 1
            resolvedTitles[tab.id] = "\(baseTitle) (\(seenCounts[baseTitle, default: 0]))"
        }

        return resolvedTitles[tab.id] ?? baseFileTabTitle(for: tab)
    }

    private func closeSelectedFileTab() {
        guard let selectedFileTab,
              let removedTab = fileTabManager.closeTab(selectedFileTab) else {
            return
        }
        fileBrowser.removeState(for: removedTab.id)
    }

    func serverViewTabActions() -> ServerViewTabActions {
        ServerViewTabActions(
            openNew: handleNewTabCommand,
            closeSelected: {
                if selectedView == ConnectionViewTab.files.id {
                    closeSelectedFileTab()
                } else if let selectedTab {
                    // Close the focused split pane first (with confirmation,
                    // since it terminates an SSH connection); only close the
                    // whole tab once it's the last remaining pane.
                    if selectedTab.paneCount > 1 {
                        requestCloseFocusedPane()
                    } else {
                        tabManager.closeTab(selectedTab)
                    }
                }
            },
            selectPrevious: {
                if selectedView == ConnectionViewTab.files.id {
                    selectPreviousFileTab()
                } else {
                    selectPreviousTab()
                }
            },
            selectNext: {
                if selectedView == ConnectionViewTab.files.id {
                    selectNextFileTab()
                } else {
                    selectNextTab()
                }
            },
            selectIndex: { index in
                if selectedView == ConnectionViewTab.files.id {
                    selectFileTab(at: index)
                } else {
                    selectTab(at: index)
                }
            }
        )
    }

    private func selectTab(at index: Int) {
        guard serverTabs.indices.contains(index) else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[index].id
    }

    private func selectFileTab(at index: Int) {
        guard serverFileTabs.indices.contains(index) else { return }
        fileTabManager.selectTab(serverFileTabs[index])
    }

    /// Ask before closing the focused pane (terminates its SSH connection),
    /// matching the in-pane close button's confirmation.
    private func requestCloseFocusedPane() {
        guard selectedTab != nil else { return }
        showingPaneCloseConfirmation = true
    }

    func closeFocusedPaneConfirmed() {
        guard let selectedTab else { return }
        tabManager.closePane(tab: selectedTab, paneId: selectedTab.focusedPaneId)
    }

    private func updateTerminalBackgroundColor() {
        let themeName = effectiveThemeName
        Task.detached(priority: .utility) {
            let resolved = ThemeColorParser.backgroundColor(for: themeName)!
            await MainActor.run {
                UserDefaults.standard.set(resolved.toHex(), forKey: "terminalBackgroundColor")
            }
        }
    }

    // MARK: - Toolbar Items (macOS)

    #if os(macOS)
    /// Publishes this server's toolbar content to the AppKit toolbar bridge,
    /// which renders it with native controls.
    func activateToolbarBridge() {
        MacToolbarBridge.shared.activate(
            ownerId: server.id.uuidString,
            showsViewPicker: shouldShowViewPicker,
            showsTabStrip: (selectedView == ConnectionViewTab.terminal.id && !serverTabs.isEmpty)
                || (selectedView == ConnectionViewTab.files.id && !serverFileTabs.isEmpty),
            showsFilesMenu: selectedView == ConnectionViewTab.files.id,
            isZenMode: isZenModeEnabled,
            zenTitle: server.name,
            zenIcon: "server.rack",
            zenSubtitle: { zenSubtitleText },
            viewPicker: { toolbarViewPickerData() },
            tabStrip: { AnyView(tabsToolbarView) },
            filesMenu: { toolbarFilesMenuEntries() },
            serverMenu: { toolbarServerMenuEntries() },
            onEnterZen: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    isZenModeEnabled = true
                }
            },
            zenPanelContent: { AnyView(zenPanelView) }
        )
    }

    /// Subtitle shown under the server name in zen, derived entirely from live
    /// in-memory state (no persistence / metadata mutation): the focused pane's
    /// runtime title for terminal, the current directory for files, otherwise
    /// the view's own name (e.g. Stats).
    private var zenSubtitleText: String {
        if selectedView == ConnectionViewTab.files.id {
            guard let tab = selectedFileTab else { return "" }
            return fileBrowser.currentPath(for: tab)
        }
        if selectedView == ConnectionViewTab.terminal.id {
            guard let selectedTab else { return "" }
            return tabManager.displayTitle(for: selectedTab)
        }
        if let tab = ConnectionViewTab.from(id: selectedView) {
            return String(localized: String.LocalizationValue(tab.localizedKey))
        }
        return ""
    }

    /// Publishes this server's keyboard-command actions to the command bridge,
    /// which ContentView republishes as scene focus values for the menu commands.
    func updateCommandBridge() {
        MacShellCommandBridge.shared.update(
            ownerId: server.id.uuidString,
            serverViewTabActions: serverViewTabActions(),
            splitActions: TerminalSplitActions(
                splitHorizontal: { splitFocusedPane(.right) },
                splitVertical: { splitFocusedPane(.down) },
                splitLeft: { splitFocusedPane(.left) },
                splitUp: { splitFocusedPane(.up) },
                closePane: { requestCloseFocusedPane() }
            ),
            activeServerId: server.id,
            activePaneId: selectedTab?.focusedPaneId
        )
    }

    private func toolbarViewPickerData() -> ToolbarViewPickerData {
        ToolbarViewPickerData(
            segments: visibleViewTabs.map { tab in
                ToolbarViewPickerData.Segment(
                    id: tab.id,
                    systemImage: tab.icon,
                    help: tab.id.capitalized
                )
            },
            selectedId: selectedView,
            onSelect: { newValue in
                selectedViewBinding.wrappedValue = newValue
            }
        )
    }

    private func toolbarFilesMenuEntries() -> [ToolbarMenuEntry] {
        let tab = selectedFileTab
        let currentPath = tab.map { fileBrowser.currentPath(for: $0) } ?? "/"
        let hiddenVisible = tab.map { fileBrowser.showHiddenFiles(for: $0) } ?? false
        let hasTab = tab != nil

        return [
            ToolbarMenuEntry(title: String(localized: "Parent"), systemImage: "arrow.turn.up.left", isEnabled: hasTab && currentPath != "/") {
                guard let tab = selectedFileTab else { return }
                Task { await fileBrowser.goUp(in: tab, server: server) }
            },
            ToolbarMenuEntry(title: String(localized: "Refresh"), systemImage: "arrow.clockwise", isEnabled: hasTab) {
                guard let tab = selectedFileTab else { return }
                Task { await fileBrowser.refresh(server: server, tab: tab) }
            },
            .separator,
            ToolbarMenuEntry(title: String(localized: "Upload…"), systemImage: "square.and.arrow.up", isEnabled: hasTab) {
                guard let tab = selectedFileTab else { return }
                fileBrowser.requestUploadPicker(for: tab, destinationPath: currentPath)
            },
            ToolbarMenuEntry(title: String(localized: "New Folder…"), systemImage: "folder.badge.plus", isEnabled: hasTab) {
                guard let tab = selectedFileTab else { return }
                fileBrowser.requestCreateFolder(for: tab, destinationPath: currentPath)
            },
            ToolbarMenuEntry(
                title: hiddenVisible ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files"),
                systemImage: hiddenVisible ? "eye.slash" : "eye",
                isEnabled: hasTab
            ) {
                guard let tab = selectedFileTab else { return }
                fileBrowser.setShowHiddenFiles(!hiddenVisible, for: tab)
            },
            .separator,
            ToolbarMenuEntry(title: String(localized: "Copy Path"), systemImage: "document.on.document") {
                Clipboard.copy(currentPath)
            }
        ]
    }

    private func toolbarServerMenuEntries() -> [ToolbarMenuEntry] {
        [
            ToolbarMenuEntry(title: String(localized: "Settings"), systemImage: "gear") {
                SettingsWindowManager.shared.show()
            },
            ToolbarMenuEntry(title: String(localized: "Edit Server"), systemImage: "pencil") {
                serverToEdit = server
            },
            .separator,
            ToolbarMenuEntry(title: String(localized: "Disconnect"), systemImage: "xmark.circle", isDestructive: true) {
                showingDisconnectConfirmation = true
            }
        ]
    }

    private var viewPickerControl: some View {
        Picker("View", selection: selectedViewBinding) {
            ForEach(visibleViewTabs) { tab in
                Label(tab.localizedKey, systemImage: tab.icon)
                    .tag(tab.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var tabsToolbarView: some View {
            if selectedView == ConnectionViewTab.files.id {
                RemoteFileTabsScrollView(
                    tabs: serverFileTabs,
                    selectedTabId: selectedFileTabIdBinding,
                    fileBrowser: fileBrowser,
                    titleForTab: displayedFileTabTitle(for:),
                    onSelect: { fileTabManager.selectTab($0) },
                    onClose: { tab in
                        if let removedTab = fileTabManager.closeTab(tab) {
                            fileBrowser.removeState(for: removedTab.id)
                        }
                    },
                    onCloseOtherTabs: { tab in
                        for removedTab in fileTabManager.closeOtherTabs(except: tab) {
                            fileBrowser.removeState(for: removedTab.id)
                        }
                    },
                    onCloseTabsToLeft: { tab in
                        for removedTab in fileTabManager.closeTabsToLeft(of: tab) {
                            fileBrowser.removeState(for: removedTab.id)
                        }
                    },
                    onCloseTabsToRight: { tab in
                        for removedTab in fileTabManager.closeTabsToRight(of: tab) {
                            fileBrowser.removeState(for: removedTab.id)
                        }
                    },
                    onDuplicate: { tab in
                        guard fileTabManager.canOpenNewTab(for: server.id) else {
                            showingFileTabLimitAlert = true
                            return
                        }

                        let seedPath = fileBrowser.lastVisitedPath(for: tab)
                        guard let duplicate = fileTabManager.duplicateTab(tab, seedPath: seedPath) else { return }
                        fileBrowser.prepareNewTab(duplicate, duplicating: tab)
                    },
                    onNew: { openNewFileTab(selectFilesViewOnSuccess: false) }
                )
            } else {
                TerminalTabsScrollView(
                    tabs: serverTabs,
                    selectedTabId: selectedTabIdBinding,
                    onClose: { tab in tabManager.closeTab(tab) },
                    onNew: { openNewTab() },
                    tabManager: tabManager
                )
            }
    }

    private var zenModeToolbarButton: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                isZenModeEnabled = true
            }
        } label: {
            Label("Zen", systemImage: "arrow.up.left.and.arrow.down.right")
                .labelStyle(.iconOnly)
        }
        .help(Text("Enter Zen Mode"))
    }

    private var filesActionsToolbarButton: some View {
        let currentPath = selectedFileTab.map { fileBrowser.currentPath(for: $0) } ?? "/"
        let areHiddenFilesVisible = selectedFileTab.map { fileBrowser.showHiddenFiles(for: $0) } ?? false

        return Menu {
            Button {
                guard let selectedFileTab else { return }
                Task { await fileBrowser.goUp(in: selectedFileTab, server: server) }
            } label: {
                Label("Parent", systemImage: "arrow.turn.up.left")
            }
            .disabled(selectedFileTab == nil || currentPath == "/")

            Button {
                guard let selectedFileTab else { return }
                Task { await fileBrowser.refresh(server: server, tab: selectedFileTab) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(selectedFileTab == nil)

            Divider()

            Button {
                guard let selectedFileTab else { return }
                fileBrowser.requestUploadPicker(for: selectedFileTab, destinationPath: currentPath)
            } label: {
                Label("Upload…", systemImage: "square.and.arrow.up")
            }
            .disabled(selectedFileTab == nil)

            Button {
                guard let selectedFileTab else { return }
                fileBrowser.requestCreateFolder(for: selectedFileTab, destinationPath: currentPath)
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
            .disabled(selectedFileTab == nil)

            Button {
                guard let selectedFileTab else { return }
                fileBrowser.setShowHiddenFiles(!areHiddenFilesVisible, for: selectedFileTab)
            } label: {
                Label(
                    areHiddenFilesVisible ? "Hide Hidden Files" : "Show Hidden Files",
                    systemImage: areHiddenFilesVisible ? "eye.slash" : "eye"
                )
            }
            .disabled(selectedFileTab == nil)

            Divider()

            Button {
                Clipboard.copy(currentPath)
            } label: {
                Label("Copy Path", systemImage: "document.on.document")
            }
        } label: {
            Label("Files", systemImage: "folder")
                .labelStyle(.titleAndIcon)
        }
        .help(Text("Files Menu"))
    }

    private var serverMenuToolbarButton: some View {
        Menu {
            Button {
                SettingsWindowManager.shared.show()
            } label: {
                Label("Settings", systemImage: "gear")
            }

            Button {
                serverToEdit = server
            } label: {
                Label("Edit Server", systemImage: "pencil")
            }

            Button(role: .destructive) {
                showingDisconnectConfirmation = true
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        } label: {
            Label("Server", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .help(Text("Server Options"))
    }

    /// The rich Zen controls panel, hosted inside the native zen toolbar
    /// button's menu (NSMenuItem.view) so we get a native circle button AND the
    /// full panel.
    private var zenPanelView: some View {
            ZenModePanel(
                width: 360,
                serverName: server.name,
                statusText: tabsStatusText,
                statusColor: zenIndicatorColor,
                selectedView: selectedView,
                selectedViewBinding: selectedViewBinding,
                viewTabs: visibleViewTabs,
                terminalTabs: serverTabs,
                selectedTerminalTabId: selectedTabIdBinding,
                terminalTabTitle: { tabManager.displayTitle(for: $0) },
                paneState: { tab in
                    tabManager.paneStates[tab.focusedPaneId]
                },
                fileTabs: serverFileTabs,
                selectedFileTabId: selectedFileTabIdBinding,
                fileTabTitle: displayedFileTabTitle(for:),
                onPreviousTab: {
                    if selectedView == ConnectionViewTab.files.id {
                        selectPreviousFileTab()
                    } else {
                        selectPreviousTab()
                    }
                },
                onNextTab: {
                    if selectedView == ConnectionViewTab.files.id {
                        selectNextFileTab()
                    } else {
                        selectNextTab()
                    }
                },
                onNewTerminalTab: {
                    showingZenPanel = false
                    openNewTab(selectTerminalViewOnSuccess: true)
                },
                onCloseTerminalTab: { tab in
                    tabManager.closeTab(tab)
                },
                onNewFileTab: {
                    showingZenPanel = false
                    openNewFileTab(selectFilesViewOnSuccess: true)
                },
                onCloseFileTab: { tab in
                    if let removedTab = fileTabManager.closeTab(tab) {
                        fileBrowser.removeState(for: removedTab.id)
                    }
                },
                onSelectFileTab: { tab in
                    fileTabManager.selectTab(tab)
                },
                onSplitRight: {
                    splitFocusedPane(.right)
                },
                onSplitDown: {
                    splitFocusedPane(.down)
                },
                onClosePane: { requestCloseFocusedPane() },
                canSplit: selectedTab != nil,
                canClosePane: selectedTab != nil,
                isSidebarVisible: isSidebarVisible,
                onToggleSidebar: {
                    showingZenPanel = false
                    onToggleSidebar()
                },
                onDisconnect: {
                    showingZenPanel = false
                    showingDisconnectConfirmation = true
                },
                canFilesGoUp: selectedFileTab.map { fileBrowser.currentPath(for: $0) != "/" } ?? false,
                filesShowHiddenBinding: Binding(
                    get: { selectedFileTab.map { fileBrowser.showHiddenFiles(for: $0) } ?? false },
                    set: { newValue in
                        guard let selectedFileTab else { return }
                        fileBrowser.setShowHiddenFiles(newValue, for: selectedFileTab)
                    }
                ),
                onFilesGoUp: {
                    guard let selectedFileTab else { return }
                    Task { await fileBrowser.goUp(in: selectedFileTab, server: server) }
                },
                onFilesRefresh: {
                    guard let selectedFileTab else { return }
                    Task { await fileBrowser.refresh(server: server, tab: selectedFileTab) }
                },
                onExitZen: {
                    showingZenPanel = false
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        isZenModeEnabled = false
                    }
                }
            )
            .adaptiveSoftScrollEdges()
            .frame(width: 360)
    }

    func disconnectFromServer() {
        tabManager.closeAllTabs(for: server.id)
        fileBrowser.disconnect(serverId: server.id)
        fileTabManager.disconnect(serverId: server.id)
        tabManager.connectedServerIds.remove(server.id)
    }

    private func splitFocusedPane(_ placement: TerminalSplitPlacement) {
        guard let selectedTab else { return }
        guard StoreManager.shared.isPro else {
            showingZenPanel = false
            showingSplitPaneUpgradeAlert = true
            return
        }

        switch placement {
        case .right:
            _ = tabManager.splitRight(tab: selectedTab, paneId: selectedTab.focusedPaneId)
        case .left:
            _ = tabManager.splitLeft(tab: selectedTab, paneId: selectedTab.focusedPaneId)
        case .down:
            _ = tabManager.splitDown(tab: selectedTab, paneId: selectedTab.focusedPaneId)
        case .up:
            _ = tabManager.splitUp(tab: selectedTab, paneId: selectedTab.focusedPaneId)
        }
    }
    #endif
}

#if os(macOS)
extension ConnectionTerminalContainer {
    var zenIndicatorColor: Color {
        guard let state = selectedTab.flatMap({ tabManager.paneStates[$0.focusedPaneId] }) else {
            if selectedView == ConnectionViewTab.files.id {
                return serverFileTabs.isEmpty ? .secondary : .green
            }
            return serverTabs.isEmpty ? .secondary : .green
        }

        switch state.connectionState {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected, .idle:
            return .secondary
        case .failed:
            return .red
        }
    }

    var tabsStatusText: String {
        let count = selectedView == ConnectionViewTab.files.id ? serverFileTabs.count : serverTabs.count

        if selectedView == ConnectionViewTab.files.id {
            if count == 0 {
                return String(localized: "No file tabs")
            }

            return count == 1
                ? String(localized: "1 file tab")
                : String(format: String(localized: "%lld file tabs"), Int64(count))
        }

        if count == 0 {
            return String(localized: "No terminals")
        }

        return count == 1
            ? String(localized: "1 tab")
            : String(format: String(localized: "%lld tabs"), Int64(count))
    }

    var compactTabsStatusText: String {
        let count = selectedView == ConnectionViewTab.files.id ? serverFileTabs.count : serverTabs.count

        if selectedView == ConnectionViewTab.files.id {
            return count == 1
                ? String(localized: "1 file tab")
                : String(format: String(localized: "%lld file tabs"), Int64(count))
        }

        return count == 1
            ? String(localized: "1 tab")
            : String(format: String(localized: "%lld tabs"), Int64(count))
    }

    var disconnectAlertTitle: String {
        String(localized: "Close Tab?")
    }

    var disconnectActionTitle: String {
        String(localized: "Close")
    }

    var disconnectAlertMessage: String {
        let terminalCount = serverTabs.count
        let fileCount = serverFileTabs.count

        if terminalCount == 0, fileCount == 0 {
            return String(localized: "This will return to the server list.")
        }

        if terminalCount > 0, fileCount > 0 {
            return String(localized: "All terminal and file tabs for this server will be closed.")
        }

        if fileCount > 0 {
            return String(localized: "All file tabs for this server will be closed.")
        }

        return String(localized: "All terminal tabs for this server will be closed.")
    }
}
#endif
