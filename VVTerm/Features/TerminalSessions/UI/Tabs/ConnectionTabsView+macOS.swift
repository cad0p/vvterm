#if os(macOS)
import SwiftUI
import AppKit

struct ZenWindowChromeBridge: NSViewRepresentable {
    @Binding var contentInsets: EdgeInsets

    func makeNSView(context: Context) -> WindowObserverView {
        WindowObserverView()
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onWindowUpdate = { [contentInsets = _contentInsets] window in
            guard let closeButton = window.standardWindowButton(.closeButton),
                  let miniButton = window.standardWindowButton(.miniaturizeButton),
                  let zoomButton = window.standardWindowButton(.zoomButton) else { return }

            let buttons = [closeButton, miniButton, zoomButton]
            buttons.forEach { button in
                button.isHidden = false
                button.alphaValue = 1
                button.superview?.isHidden = false
                button.superview?.alphaValue = 1
            }

            let safeArea = window.contentView?.safeAreaInsets
                ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            let titlebarHeight = max(
                window.frame.height - window.contentLayoutRect.height,
                safeArea.top
            )
            let newInsets = EdgeInsets(
                top: titlebarHeight,
                leading: safeArea.left,
                bottom: safeArea.bottom,
                trailing: safeArea.right
            )

            let currentInsets = contentInsets.wrappedValue
            let didChange =
                abs(currentInsets.top - newInsets.top) > 0.5 ||
                abs(currentInsets.leading - newInsets.leading) > 0.5 ||
                abs(currentInsets.bottom - newInsets.bottom) > 0.5 ||
                abs(currentInsets.trailing - newInsets.trailing) > 0.5

            if didChange {
                contentInsets.wrappedValue = newInsets
            }
        }
        nsView.triggerUpdate()
    }

    static func dismantleNSView(_ nsView: WindowObserverView, coordinator: ()) {
        nsView.removeObservers()
    }

    final class WindowObserverView: NSView {
        var onWindowUpdate: ((NSWindow) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override var intrinsicContentSize: NSSize {
            .zero
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installObservers()
            triggerUpdate()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            triggerUpdate()
        }

        override func layout() {
            super.layout()
            triggerUpdate()
        }

        func triggerUpdate() {
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.onWindowUpdate?(window)
            }
        }

        func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }

        private func installObservers() {
            removeObservers()
            guard let window else { return }

            let center = NotificationCenter.default
            observers = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didBecomeKeyNotification
            ].map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.triggerUpdate()
                }
            }
        }

        deinit {
            removeObservers()
        }
    }
}

struct ToolbarBackdrop: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 52
            color
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
        }
        .allowsHitTesting(false)
    }
}

extension ConnectionTerminalContainer {
    var platformBody: some View {
        sharedBody
            .focusedValue(\.openTerminalTab, handleNewTabCommand)
            .focusedValue(\.serverViewTabActions, serverViewTabActions())
            // The connected-server toolbar is rendered by the AppKit NSToolbar
            // (see MacConnectionToolbar). This pane publishes its sections into
            // the shared bridge; the toolbar hosts them.
            .onAppear { activateToolbarBridge(); updateCommandBridge() }
            .onDisappear {
                MacToolbarBridge.shared.deactivate(ownerId: server.id.uuidString)
                MacShellCommandBridge.shared.clear(ownerId: server.id.uuidString)
            }
            .onChange(of: selectedView) { _ in activateToolbarBridge(); updateCommandBridge() }
            .onChange(of: shouldShowViewPicker) { _ in activateToolbarBridge() }
            .onChange(of: serverTabs.count) { _ in activateToolbarBridge() }
            .onChange(of: serverFileTabs.count) { _ in activateToolbarBridge() }
            .onChange(of: selectedFileTabId) { _ in activateToolbarBridge() }
            .onChange(of: selectedTabId) { _ in activateToolbarBridge(); updateCommandBridge() }
            .onChange(of: selectedTab?.focusedPaneId) { _ in updateCommandBridge() }
            .onChange(of: selectedTab?.layout) { _ in updateCommandBridge() }
            .onChange(of: tabManager.splitZoomedTabIds) { _ in updateCommandBridge() }
            .onChange(of: isZenModeEnabled) { _ in activateToolbarBridge() }
            .alert(
                disconnectAlertTitle,
                isPresented: $showingDisconnectConfirmation,
            ) {
                Button("Cancel", role: .cancel) {}
                Button(disconnectActionTitle, role: .destructive) {
                    disconnectFromServer()
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text(disconnectAlertMessage)
            }
            .alert("Close this terminal?", isPresented: $showingPaneCloseConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Close", role: .destructive) {
                    closeFocusedPaneConfirmed()
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text("The SSH connection will be terminated.")
            }
            .sheet(item: $serverToEdit) { editingServer in
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: serverManager.workspaces.first { $0.id == editingServer.workspaceId },
                    server: editingServer,
                    onSave: { _ in
                        serverToEdit = nil
                    }
                )
                .adaptiveSoftScrollEdges()
                .frame(
                    minWidth: 640,
                    idealWidth: 700,
                    maxWidth: 760,
                    minHeight: 520,
                    idealHeight: 620,
                    maxHeight: 680
                )
            }
    }

    /// Publishes this server's toolbar content to the AppKit toolbar bridge,
    /// which renders it with native controls.
    private func activateToolbarBridge() {
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
    private func updateCommandBridge() {
        MacShellCommandBridge.shared.update(
            ownerId: server.id.uuidString,
            serverViewTabActions: serverViewTabActions(),
            splitActions: TerminalSplitActions(
                perform: performSplitCommand,
                isEnabled: { command in
                    guard let selectedTab else { return false }
                    return tabManager.canPerformSplitCommand(command, in: selectedTab)
                },
                isZoomed: {
                    guard let selectedTab else { return false }
                    return tabManager.isSplitZoomed(in: selectedTab)
                }
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

    private func disconnectFromServer() {
        fileBrowser.disconnect(serverId: server.id)
        fileTabManager.disconnect(serverId: server.id)
        tabManager.disconnectServer(server.id)
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

    private func performSplitCommand(_ command: TerminalSplitCommand) {
        guard let selectedTab else { return }
        switch tabManager.performSplitCommand(command, in: selectedTab) {
        case .performed, .unavailable:
            break
        case .requiresUpgrade:
            showingZenPanel = false
            showingSplitPaneUpgradeAlert = true
        case .requiresCloseConfirmation:
            requestCloseFocusedPane()
        }
    }

    private var zenIndicatorColor: Color {
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

    private var tabsStatusText: String {
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

    private var compactTabsStatusText: String {
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

    private var disconnectAlertTitle: String {
        String(localized: "Close Tab?")
    }

    private var disconnectActionTitle: String {
        String(localized: "Close")
    }

    private var disconnectAlertMessage: String {
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

    func platformChrome<Content: View>(
        _ content: Content,
        backgroundColor: Color
    ) -> some View {
        content
            .overlay(alignment: .top) {
                if !isZenModeEnabled {
                    ToolbarBackdrop(color: backgroundColor)
                }
            }
            .background {
                if isZenModeEnabled {
                    ZenWindowChromeBridge(contentInsets: $zenWindowSafeAreaInsets)
                        .frame(width: 0, height: 0)
                }
            }
            .zenExpandedTopSafeArea(isZenModeEnabled && selectedView == "terminal")
    }

    private var terminalContentInsets: EdgeInsets {
        isZenModeEnabled ? zenWindowSafeAreaInsets : EdgeInsets()
    }

    @ViewBuilder
    var terminalLayer: some View {
        ForEach(serverTabs, id: \.id) { tab in
            let isVisible = selectedView == "terminal" && selectedTabId == tab.id
            TerminalTabView(
                tab: tab,
                server: server,
                tabManager: tabManager,
                isSelected: isVisible
            )
            .padding(terminalContentInsets)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .zIndex(isVisible ? 1 : 0)
        }

        if selectedView == "terminal" && serverTabs.isEmpty {
            TerminalEmptyStateView(server: server) {
                openNewTab()
            }
            .padding(terminalContentInsets)
        }
    }
}

private extension View {
    @ViewBuilder
    func zenExpandedTopSafeArea(_ isEnabled: Bool) -> some View {
        if isEnabled {
            self.ignoresSafeArea(.container, edges: .top)
        } else {
            self
        }
    }
}
#endif
