//
//  ContentView.swift
//  VVTerm
//

import SwiftUI
import StoreKit
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    let fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var tabManager = TerminalTabManager.shared
    @StateObject private var storeManager = StoreManager.shared
    @StateObject private var engagementTracker = EngagementTracker.shared
    @Environment(\.requestReview) private var requestReview
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedWorkspace: Workspace?
    @State private var selectedServer: Server?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var restoredColumnVisibility: NavigationSplitViewVisibility = .all
    @SceneStorage("vvterm.zenMode.macos") private var isZenModeEnabled = false
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true

    /// Whether the selected server is connected
    private var isSelectedServerConnected: Bool {
        guard let selected = selectedServer else { return false }
        return tabManager.connectedServerIds.contains(selected.id)
    }

    /// Whether we have any connected servers
    private var hasConnectedServers: Bool {
        !tabManager.connectedServerIds.isEmpty
    }

    private var canUseZenMode: Bool {
        selectedServer != nil && isSelectedServerConnected
    }

    private var effectiveZenModeEnabled: Bool {
        canUseZenMode && isZenModeEnabled
    }

    private var effectiveTerminalThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var macOSWindowBackgroundColor: Color {
        ThemeColorParser.backgroundColor(for: effectiveTerminalThemeName)!
    }

    #if os(macOS)
    private var zenWindowTitle: String {
        guard effectiveZenModeEnabled, let selectedServer else { return "" }
        return selectedServer.name
    }

    private var zenNavigationTitle: String {
        guard effectiveZenModeEnabled, let selectedServer else { return "" }
        return selectedServer.name
    }
    #endif

    private var isSidebarVisible: Bool {
        columnVisibility != .detailOnly
    }

    @ViewBuilder
    private var detailContent: some View {
        if let server = selectedServer {
            // A server is selected
            if isSelectedServerConnected {
                // Server is connected - show its terminal container
                ConnectionTerminalContainer(
                    tabManager: tabManager,
                    fileTabManager: fileTabs,
                    serverManager: serverManager,
                    fileBrowser: fileBrowser,
                    server: server,
                    isZenModeEnabled: $isZenModeEnabled,
                    isSidebarVisible: isSidebarVisible,
                    onToggleSidebar: toggleSidebarInZenMode
                )
                .id(server.id) // Ensure isolation per server
            } else if !hasConnectedServers {
                // Not connected to any server - can connect freely
                ServerConnectEmptyState(server: server) {
                    connectToServer(server)
                }
            } else if storeManager.isPro {
                // Pro user already connected to other servers - can connect to more
                ServerConnectEmptyState(server: server) {
                    connectToServer(server)
                }
            } else {
                // Free user already connected to different server - show upgrade
                MultiConnectionUpgradeEmptyState(server: server)
            }
        } else {
            // Nothing selected
            NoServerSelectedEmptyState()
        }
    }

    private func connectToServer(_ server: Server) {
        Task { @MainActor in
            guard await AppLockManager.shared.ensureServerUnlocked(server) else { return }
            tabManager.selectedViewByServer[server.id] = ViewTabConfigurationManager.shared.effectiveDefaultTab()
            tabManager.connectedServerIds.insert(server.id)
        }
    }

    private func applyZenPresentation(_ enabled: Bool) {
        if enabled {
            if columnVisibility != .detailOnly {
                restoredColumnVisibility = columnVisibility
            }
            columnVisibility = .detailOnly
        } else if columnVisibility == .detailOnly {
            columnVisibility = restoredColumnVisibility == .detailOnly ? .all : restoredColumnVisibility
        }
    }

    private func setZenMode(_ enabled: Bool) {
        guard enabled != isZenModeEnabled else { return }
        isZenModeEnabled = enabled
    }

    private func toggleZenMode() {
        guard canUseZenMode || isZenModeEnabled else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            setZenMode(!isZenModeEnabled)
        }
    }

    private func setSidebarVisible(_ isVisible: Bool) {
        if isVisible {
            columnVisibility = restoredColumnVisibility == .detailOnly ? .all : restoredColumnVisibility
        } else {
            if columnVisibility != .detailOnly {
                restoredColumnVisibility = columnVisibility
            }
            columnVisibility = .detailOnly
        }
    }

    private func toggleSidebarInZenMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            setSidebarVisible(!isSidebarVisible)
        }
    }

    private var zenToggleAction: (() -> Void)? {
        guard canUseZenMode else { return nil }
        return { toggleZenMode() }
    }

    private var splitViewContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // LEFT: Sidebar with workspace + servers
            ServerSidebarView(
                serverManager: serverManager,
                backgroundColor: macOSWindowBackgroundColor,
                selectedWorkspace: $selectedWorkspace,
                selectedServer: $selectedServer
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            // RIGHT: Detail view based on selection state
            detailContent
                #if os(macOS)
                .navigationTitle(zenNavigationTitle)
                #endif
        }
        .background(macOSWindowBackgroundColor)
        .onAppear {
            if selectedWorkspace == nil {
                selectedWorkspace = serverManager.workspaces.first
            }
            if !canUseZenMode {
                setZenMode(false)
            } else if isZenModeEnabled {
                applyZenPresentation(true)
            }
        }
        .onChange(of: serverManager.workspaces) { workspaces in
            if selectedWorkspace == nil {
                selectedWorkspace = workspaces.first
            }
        }
        .onChange(of: columnVisibility) { newValue in
            if !isZenModeEnabled && newValue != .detailOnly {
                restoredColumnVisibility = newValue
            }
        }
        .onChange(of: isZenModeEnabled) { enabled in
            applyZenPresentation(enabled && canUseZenMode)
        }
        .onChange(of: canUseZenMode) { available in
            if !available && isZenModeEnabled {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setZenMode(false)
                }
            }
        }
    }

    var body: some View {
        #if os(macOS)
        splitViewContent
            .proUpgradePresentation(isPresented: $engagementTracker.shouldShowProIntro, source: .postFirstConnection)
            .onChange(of: engagementTracker.reviewRequestToken) { _ in
                requestReview()
            }
            .focusedValue(\.toggleZenMode, zenToggleAction)
            .focusedValue(\.isZenModeEnabled, canUseZenMode ? effectiveZenModeEnabled : nil)
            .background(
                MainWindowChromeBridge(
                    windowTitle: zenWindowTitle,
                    backgroundColor: macOSWindowBackgroundColor
                )
                    .frame(width: 0, height: 0)
            )
            .frame(minWidth: 800, minHeight: 500)
        #endif
        #if !os(macOS)
        splitViewContent
        #endif
    }
}

// MARK: - Preview

#Preview {
    ContentView(
        fileTabs: RemoteFileTabManager(),
        fileBrowser: RemoteFileBrowserStore()
    )
}

#if os(macOS)
private struct MainWindowChromeBridge: NSViewRepresentable {
    let windowTitle: String
    let backgroundColor: Color

    func makeNSView(context: Context) -> NSView {
        WindowObserverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowObserverView else { return }
        view.windowTitle = windowTitle
        view.backgroundColor = backgroundColor
        view.applyIfPossible()
    }

    private func configure(_ window: NSWindow, title: String, backgroundColor: Color) {
        let nsBackgroundColor = NSColor(backgroundColor)
        if window.title != title {
            window.title = title
        }
        window.backgroundColor = nsBackgroundColor
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Keep the content area interactive. Enabling background dragging here
        // causes terminal clicks and drag-to-select gestures to start moving the window.
        window.isMovableByWindowBackground = false
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = nsBackgroundColor.cgColor
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.backgroundColor = nsBackgroundColor.cgColor
    }

    final class WindowObserverView: NSView {
        var windowTitle = ""
        var backgroundColor: Color = .clear

        override var intrinsicContentSize: NSSize { .zero }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyIfPossible()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyIfPossible()
        }

        func applyIfPossible() {
            guard let window else { return }
            MainWindowChromeBridge(
                windowTitle: windowTitle,
                backgroundColor: backgroundColor
            )
            .configure(
                window,
                title: windowTitle,
                backgroundColor: backgroundColor
            )
        }
    }
}
#endif
