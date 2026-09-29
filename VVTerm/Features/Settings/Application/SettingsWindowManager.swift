//
//  SettingsWindowManager.swift
//  VVTerm
//
//  Centralized settings window presenter
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)

/// Wrapper view that observes language changes and applies locale environment
private struct LocalizedSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @StateObject private var appLockManager = AppLockManager.shared
    @StateObject private var terminalThemeManager = TerminalThemeManager.shared
    @StateObject private var terminalAccessoryPreferencesManager = TerminalAccessoryPreferencesManager.shared

    var body: some View {
        let locale = AppLanguage(rawValue: appLanguage)?.locale ?? Locale.current
        SettingsView()
            .modifier(AppearanceModifier())
            .adaptiveSoftScrollEdges()
            .environment(\.locale, locale)
            .environmentObject(appLockManager)
            .environmentObject(terminalThemeManager)
            .environmentObject(terminalAccessoryPreferencesManager)
    }
}

@MainActor
final class SettingsWindowManager {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    static let shared = SettingsWindowManager()

    private var settingsWindow: NSWindow?

    private init() {}

    func show() {
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = LocalizedSettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false

        // Create toolbar for unified style with subtitles
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.setContentSize(NSSize(width: 800, height: 600))
        window.minSize = NSSize(width: 750, height: 500)

        window.center()
        window.makeKeyAndOrderFront(nil)

        settingsWindow = window
    }
}
#endif
