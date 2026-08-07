//
//  VVTermApp.swift
//  VVTerm
//

import SwiftUI
#if os(iOS)
import WidgetKit
#endif

@main
struct VVTermApp: App {
    init() {
        TerminalDefaults.applyIfNeeded()
        #if os(iOS)
        VVTermLauncherWidgetRefresh.refreshIfNeeded()
        AnalyticsTracker.shared.prepareAppleAdsAttribution()
        #endif
    }

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    #if os(iOS)
    @StateObject private var ghosttyApp = Ghostty.App(autoStart: false)
    @StateObject private var screenAwakeCoordinator = TerminalScreenAwakeCoordinator()
    #else
    @StateObject private var ghosttyApp = Ghostty.App()
    #endif
    @StateObject private var appLockManager = AppLockManager.shared
    @StateObject private var storeManager = StoreManager.shared
    @StateObject private var remoteFileTabManager = RemoteFileTabManager()
    @StateObject private var remoteFileBrowserStore = VVTermApp.makeRemoteFileBrowserStore()
    @StateObject private var terminalThemeManager = TerminalThemeManager.shared
    @StateObject private var terminalAccessoryPreferencesManager = TerminalAccessoryPreferencesManager.shared

    // Welcome screen flag
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    // App language
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(PrivacyModeSettings.enabledKey) private var privacyModeEnabled = false

    // Terminal settings to watch for changes
    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = TerminalDefaults.defaultFontName
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.cursorStyleKey) private var terminalCursorStyle = TerminalDefaults.defaultCursorStyle.rawValue
    @AppStorage(TerminalDefaults.cursorBlinkKey) private var terminalCursorBlink = TerminalDefaults.defaultCursorBlink
    #if os(macOS)
    @AppStorage(TerminalDefaults.optionAsAltModeKey) private var terminalOptionAsAltMode = TerminalOptionAsAltMode.none.rawValue
    #endif
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true

    private var terminalOptionAsAltReloadToken: String {
        #if os(macOS)
        terminalOptionAsAltMode
        #else
        ""
        #endif
    }

    private var activeCustomThemeVersionToken: String {
        let activeThemes = terminalThemeManager.customThemes.filter { !$0.isDeleted }
        let byName = Dictionary(
            activeThemes.map { ($0.name, $0) },
            uniquingKeysWith: { current, candidate in
                current.updatedAt >= candidate.updatedAt ? current : candidate
            }
        )

        let darkVersion = byName[terminalThemeName]?.updatedAt.timeIntervalSince1970 ?? 0
        let lightVersion = byName[terminalThemeNameLight]?.updatedAt.timeIntervalSince1970 ?? 0

        if usePerAppearanceTheme {
            return "\(darkVersion):\(lightVersion)"
        }

        return "\(darkVersion)"
    }

    #if os(iOS) && DEBUG
    private var usesTerminalKeyboardUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-keyboard-harness")
    }

    private var usesTerminalSplitKeyboardUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-terminal-split-keyboard-harness"
        )
    }

    private var usesTerminalReconnectUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-reconnect-harness")
    }

    private var usesTerminalScreenAwakeUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-screen-awake-harness")
    }

    private var usesNoticePresentationUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-notice-harness")
    }

    private var usesStatsStorageUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-stats-storage-harness")
    }

    private var usesStatsCardsLayoutUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-stats-cards-layout-harness")
    }

    private var usesTerminalZenModeUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-zen-mode-harness")
    }

    private var usesTeleportUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-teleport-harness")
    }

    private var usesTeleportServerListUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-teleport-serverlist")
    }

    private var usesTeleportIOSServerListUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-teleport-ios-serverlist")
    }

    private var usesTeleportPhaseChainUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-teleport-phase-chain")
    }
    #endif

    /// True when ANY UI test harness launch arg is present. Used to skip
    /// app-side singletons (ServerManager → CloudKitManager) that trap in
    /// the simulator without iCloud entitlements.
    ///
    /// Available in both Debug and Release — in Release it always returns
    /// false (no launch args), so the guard is a no-op. Must NOT be inside
    /// the `#if DEBUG` block because it's referenced from `.onAppear`/
    /// `.onChange` modifiers in the `#if os(iOS)` section below.
    static var isUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--vvterm-ui-test-") }
    }

    #if os(iOS)
    @ViewBuilder
    private var iOSRootContent: some View {
        #if DEBUG
        if usesTeleportServerListUITestHarness {
            TeleportServerListUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTeleportIOSServerListUITestHarness {
            TeleportIOSServerListUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTeleportPhaseChainUITestHarness {
            TeleportPhaseChainUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTeleportUITestHarness {
            TeleportUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesNoticePresentationUITestHarness {
            NoticePresentationUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesStatsCardsLayoutUITestHarness {
            StatsCardsLayoutUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTerminalZenModeUITestHarness {
            TerminalZenModeUITestHarness()
                .environmentObject(ghosttyApp)
                .modifier(AppearanceModifier())
        } else if usesStatsStorageUITestHarness {
            StatsStorageUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTerminalScreenAwakeUITestHarness {
            TerminalScreenAwakeUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTerminalReconnectUITestHarness {
            TerminalReconnectUITestHarness()
                .environmentObject(ghosttyApp)
                .environmentObject(terminalThemeManager)
                .environmentObject(terminalAccessoryPreferencesManager)
                .modifier(AppearanceModifier())
        } else if usesTerminalSplitKeyboardUITestHarness {
            TerminalSplitKeyboardUITestHarness()
                .environmentObject(ghosttyApp)
                .environmentObject(terminalThemeManager)
                .environmentObject(terminalAccessoryPreferencesManager)
                .modifier(AppearanceModifier())
        } else if usesTerminalKeyboardUITestHarness {
            TerminalKeyboardUITestHarness()
                .environmentObject(ghosttyApp)
                .environmentObject(terminalThemeManager)
                .environmentObject(terminalAccessoryPreferencesManager)
                .modifier(AppearanceModifier())
        } else {
            iOSAppContent
        }
        #else
        iOSAppContent
        #endif
    }

    private var iOSAppContent: some View {
        iOSContentView(
            fileTabs: remoteFileTabManager,
            fileBrowser: remoteFileBrowserStore
        )
            .environmentObject(ghosttyApp)
            .environmentObject(terminalThemeManager)
            .environmentObject(terminalAccessoryPreferencesManager)
            .modifier(AppearanceModifier())
            .task(id: "\(terminalFontName)\(terminalFontSize)\(terminalCursorStyle)\(terminalCursorBlink)\(terminalOptionAsAltReloadToken)\(terminalThemeName)\(terminalThemeNameLight)\(usePerAppearanceTheme)\(activeCustomThemeVersionToken)") {
                ghosttyApp.reloadConfig()
            }
            .sheet(isPresented: .init(
                get: { !hasSeenWelcome },
                set: { if !$0 { hasSeenWelcome = true } }
            )) {
                WelcomeView(hasSeenWelcome: $hasSeenWelcome)
                    .adaptiveSoftScrollEdges()
            }
    }
    #endif

    var body: some Scene {
        WindowGroup("", id: "main") {
            let appLocale = AppLanguage(rawValue: appLanguage)?.locale ?? Locale.current
            AppLockContainer {
                NoticeAppHost {
                    Group {
                        #if os(iOS)
                        iOSRootContent
                            .environmentObject(screenAwakeCoordinator)
                        #else
                        ContentView(
                            fileTabs: remoteFileTabManager,
                            fileBrowser: remoteFileBrowserStore
                        )
                            .environmentObject(ghosttyApp)
                            .environmentObject(terminalThemeManager)
                            .environmentObject(terminalAccessoryPreferencesManager)
                            .modifier(AppearanceModifier())
                            .task(id: "\(terminalFontName)\(terminalFontSize)\(terminalCursorStyle)\(terminalCursorBlink)\(terminalOptionAsAltReloadToken)\(terminalThemeName)\(terminalThemeNameLight)\(usePerAppearanceTheme)\(activeCustomThemeVersionToken)") {
                                ghosttyApp.reloadConfig()
                            }
                            .sheet(isPresented: .init(
                                get: { !hasSeenWelcome },
                                set: { if !$0 { hasSeenWelcome = true } }
                            )) {
                                WelcomeView(hasSeenWelcome: $hasSeenWelcome)
                                    .adaptiveSoftScrollEdges()
                            }
                        #endif
                    }
                    .adaptiveSoftScrollEdges()
                    .environment(\.locale, appLocale)
                    .environment(\.privacyModeEnabled, privacyModeEnabled)
                    .onAppear {
                        AppLanguage.applySelection(appLanguage)
                        // Skip ServerManager access under UI test harnesses —
                        // ServerManager.shared lazily inits CloudKitManager,
                        // which calls CKContainer(identifier:) and traps
                        // (EXC_BREAKPOINT) in the simulator without iCloud
                        // entitlements. The harnesses don't need sync.
                        if !Self.isUITestHarness {
                            ServerManager.shared.handleAppLanguageChange()
                        }
                    }
                    .onChange(of: appLanguage) { newValue in
                        AppLanguage.applySelection(newValue)
                        if !Self.isUITestHarness {
                            ServerManager.shared.handleAppLanguageChange()
                        }
                    }
                }
            }
            .environmentObject(appLockManager)
            .environmentObject(storeManager)
        }
        #if os(macOS)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 700)
        .commands {
            VVTermCommands()
        }
        #endif
    }
}

#if os(iOS)
private enum VVTermLauncherWidgetRefresh {
    private static let renderingRevision = 1
    private static let renderingRevisionKey = "launcherWidgetRenderingRevision"

    static func refreshIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: renderingRevisionKey) < renderingRevision else { return }

        WidgetCenter.shared.reloadTimelines(ofKind: VVTermWidgetKind.launcher)
        defaults.set(renderingRevision, forKey: renderingRevisionKey)
    }
}
#endif

private extension VVTermApp {
    static func makeRemoteFileBrowserStore() -> RemoteFileBrowserStore {
        let adapter = SSHSFTPAdapter(borrowedClientProvider: { serverId in
            TerminalTabManager.shared.sharedStatsClient(for: serverId)
        })

        return RemoteFileBrowserStore(
            remoteFileServiceAdapter: adapter,
            serverProvider: { serverId in
                ServerManager.shared.servers.first { $0.id == serverId }
            },
            workingDirectoryProvider: { serverId in
                if let selectedTab = TerminalTabManager.shared.selectedTab(for: serverId),
                   let path = TerminalTabManager.shared.workingDirectory(for: selectedTab.focusedPaneId) {
                    return path
                }

                if let anyPane = TerminalTabManager.shared.paneStates.values.first(where: { $0.serverId == serverId }),
                   let path = TerminalTabManager.shared.workingDirectory(for: anyPane.paneId) {
                    return path
                }

                return nil
            }
        )
    }
}
