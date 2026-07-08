#if os(macOS)
import SwiftUI

struct TerminalTabsScrollView: View {
    let tabs: [TerminalTab]
    @Binding var selectedTabId: UUID?
    let onClose: (TerminalTab) -> Void
    let onNew: () -> Void
    @ObservedObject var tabManager: TerminalTabManager

    var body: some View {
        ServerToolbarTabStrip(
            items: tabs,
            selectedId: selectedTabId,
            previousHelp: String(localized: "Previous tab"),
            nextHelp: String(localized: "Next tab"),
            newHelp: String(localized: "New terminal tab"),
            onPrevious: selectPrevious,
            onNext: selectNext,
            onNew: onNew
        ) { tab, tabWidth, glassNamespace in
            TerminalTabButton(
                tab: tab,
                isSelected: selectedTabId == tab.id,
                width: tabWidth,
                glassNamespace: glassNamespace,
                shortcutNumber: tabs.firstIndex(where: { $0.id == tab.id }).map { $0 + 1 },
                onSelect: { selectedTabId = tab.id },
                onClose: { onClose(tab) },
                tabManager: tabManager
            )
        }
    }

    private func selectPrevious() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        selectedTabId = tabs[currentIndex - 1].id
    }

    private func selectNext() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }),
              currentIndex < tabs.count - 1 else { return }
        selectedTabId = tabs[currentIndex + 1].id
    }
}

private struct TerminalTabButton: View {
    let tab: TerminalTab
    let isSelected: Bool
    let width: CGFloat
    var glassNamespace: Namespace.ID?
    var shortcutNumber: Int?
    let onSelect: () -> Void
    let onClose: () -> Void
    @ObservedObject var tabManager: TerminalTabManager

    private var paneState: TerminalPaneState? {
        tabManager.paneStates[tab.focusedPaneId]
    }

    private var statusColor: Color {
        guard let state = paneState else { return .secondary }
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

    var body: some View {
        ServerToolbarTabCell(
            title: tabTitle,
            isSelected: isSelected,
            statusColor: statusColor,
            width: width,
            accessibilityLabel: tabManager.displayTitle(for: tab),
            glassNamespace: glassNamespace,
            shortcutNumber: shortcutNumber,
            onSelect: onSelect,
            onClose: onClose
        )
    }

    private var tabTitle: String {
        let title = tabManager.displayTitle(for: tab)
        guard tab.paneCount > 1 else { return title }
        return "\(title) ⊞"
    }
}
#endif
