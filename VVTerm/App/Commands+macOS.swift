#if os(macOS)
import AppKit
import SwiftUI

struct VVTermCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.serverViewTabActions) private var serverViewTabActions
    @FocusedValue(\.openLocalSSHDiscovery) private var openLocalSSHDiscovery
    @FocusedValue(\.terminalSplitActions) private var terminalSplitActions

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About VVTerm") {
                AboutWindowController.shared.show()
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button("New Tab") {
                serverViewTabActions?.openNew()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(serverViewTabActions == nil)

            Button(String(localized: "Discover Local Devices...")) {
                openLocalSSHDiscovery?()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(openLocalSSHDiscovery == nil)

            Button("Close Tab") {
                serverViewTabActions?.closeSelected()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(serverViewTabActions == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                SettingsWindowManager.shared.show()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .windowArrangement) {
            Button("Previous Tab") {
                serverViewTabActions?.selectPrevious()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(serverViewTabActions == nil)

            Button("Next Tab") {
                serverViewTabActions?.selectNext()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(serverViewTabActions == nil)

            Divider()

            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") {
                    serverViewTabActions?.selectIndex(number - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                .disabled(serverViewTabActions == nil)
            }
        }

        SplitCommands()
    }
}
#endif
