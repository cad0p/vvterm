#if os(iOS) && DEBUG
import SwiftUI

struct TerminalZenModeUITestHarness: View {
    @State private var isZenModeEnabled = false
    @State private var showingZenPanel = false
    @State private var selectedView = ConnectionViewTab.terminal.id
    @State private var selectedTerminalTabId: UUID?
    @State private var selectedFileTabId: UUID?
    @State private var diagnosticsTapped = false

    var body: some View {
        NavigationStack {
            Color.black
                .overlay {
                    Text("Terminal")
                        .foregroundStyle(.white)
                }
                .overlay(alignment: .bottom) {
                    if diagnosticsTapped {
                        Text("diagnostics-tapped")
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("vvterm.zenTest.diagnosticsTapped")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isZenModeEnabled {
                        ZenModeFloatingOverlay(isPanelPresented: $showingZenPanel) { width in
                            ZenModePanel(
                                width: width,
                                serverName: "Test Server",
                                selectedView: selectedView,
                                selectedViewBinding: $selectedView,
                                viewTabs: [.terminal, .files],
                                terminalTabs: [],
                                selectedTerminalTabId: $selectedTerminalTabId,
                                terminalTabTitle: { _ in "Test Terminal" },
                                paneState: { _ in nil },
                                onCloseTerminalTab: { _ in },
                                fileTabs: [],
                                selectedFileTabId: $selectedFileTabId,
                                fileTabTitle: { _ in "Test Files" },
                                onSelectFileTab: { _ in },
                                onCloseFileTab: { _ in },
                                onNewTerminalTab: {},
                                onNewFileTab: {},
                                onOpenSettings: {},
                                onEditServer: {},
                                onDisconnect: {},
                                onBack: {},
                                onShareDiagnostics: { diagnosticsTapped = true },
                                onExitZen: exitZenMode
                            )
                        }
                    }
                }
                .navigationTitle("Test Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Chrome") {}
                            .accessibilityIdentifier("vvterm.zenTest.chrome")
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                    isZenModeEnabled = true
                                }
                            } label: {
                                Label("Enter Zen Mode", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .accessibilityIdentifier("vvterm.terminal.enterZenMode")
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("vvterm.terminal.moreMenu")
                    }
                }
                .toolbar(isZenModeEnabled ? .hidden : .visible, for: .navigationBar)
        }
    }

    private func exitZenMode() {
        showingZenPanel = false
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            isZenModeEnabled = false
        }
    }
}
#endif
