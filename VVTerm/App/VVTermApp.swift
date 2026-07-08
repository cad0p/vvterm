//
//  VVTermApp.swift
//  VVTerm
//

import SwiftUI

@main
struct VVTermApp: App {
    init() {
        TerminalDefaults.applyIfNeeded()
    }

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    #if os(iOS)
    @StateObject private var ghosttyApp = Ghostty.App(autoStart: false)
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
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true

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

    var body: some Scene {
        WindowGroup("", id: "main") {
            let appLocale = AppLanguage(rawValue: appLanguage)?.locale ?? Locale.current
            AppLockContainer {
                NoticeAppHost {
                    Group {
                        #if os(iOS)
                        iOSContentView(
                            fileTabs: remoteFileTabManager,
                            fileBrowser: remoteFileBrowserStore
                        )
                            .environmentObject(ghosttyApp)
                            .environmentObject(terminalThemeManager)
                            .environmentObject(terminalAccessoryPreferencesManager)
                            .modifier(AppearanceModifier())
                            .task(id: "\(terminalFontName)\(terminalFontSize)\(terminalCursorStyle)\(terminalCursorBlink)\(terminalThemeName)\(terminalThemeNameLight)\(usePerAppearanceTheme)\(activeCustomThemeVersionToken)") {
                                ghosttyApp.reloadConfig()
                            }
                            .sheet(isPresented: .init(
                                get: { !hasSeenWelcome },
                                set: { if !$0 { hasSeenWelcome = true } }
                            )) {
                                WelcomeView(hasSeenWelcome: $hasSeenWelcome)
                                    .adaptiveSoftScrollEdges()
                            }
                        #else
                        ContentView(
                            fileTabs: remoteFileTabManager,
                            fileBrowser: remoteFileBrowserStore
                        )
                            .environmentObject(ghosttyApp)
                            .environmentObject(terminalThemeManager)
                            .environmentObject(terminalAccessoryPreferencesManager)
                            .modifier(AppearanceModifier())
                            .task(id: "\(terminalFontName)\(terminalFontSize)\(terminalCursorStyle)\(terminalCursorBlink)\(terminalThemeName)\(terminalThemeNameLight)\(usePerAppearanceTheme)\(activeCustomThemeVersionToken)") {
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
                        ServerManager.shared.handleAppLanguageChange()
                    }
                    .onChange(of: appLanguage) { newValue in
                        AppLanguage.applySelection(newValue)
                        ServerManager.shared.handleAppLanguageChange()
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
