import SwiftUI

#if os(macOS)
import AppKit
#endif

struct RemoteFileTabsEmptyState: View {
    let server: Server?
    let onNewTab: () -> Void

    init(server: Server? = nil, onNewTab: @escaping () -> Void) {
        self.server = server
        self.onNewTab = onNewTab
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "folder")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text(server?.name ?? String(localized: "Files"))
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("No file tabs open")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onNewTab) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("New File Tab")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.tint, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
struct RemoteFileTabsScrollView: View {
    let tabs: [RemoteFileTab]
    @Binding var selectedTabId: UUID?
    // Observed so the hosted tab strip redraws when navigation changes a tab's
    // path/title (the title closures read this store). The toolbar host itself
    // only observes the terminal manager, so without this the strip would keep
    // showing the old folder until a tab open/close/select forced a redraw.
    @ObservedObject var fileBrowser: RemoteFileBrowserStore
    let titleForTab: (RemoteFileTab) -> String
    let onSelect: (RemoteFileTab) -> Void
    let onClose: (RemoteFileTab) -> Void
    let onCloseOtherTabs: (RemoteFileTab) -> Void
    let onCloseTabsToLeft: (RemoteFileTab) -> Void
    let onCloseTabsToRight: (RemoteFileTab) -> Void
    let onDuplicate: (RemoteFileTab) -> Void
    let onNew: () -> Void

    var body: some View {
        ServerToolbarTabStrip(
            items: tabs,
            selectedId: selectedTabId,
            previousHelp: String(localized: "Previous file tab"),
            nextHelp: String(localized: "Next file tab"),
            newHelp: String(localized: "New file tab"),
            onPrevious: selectPrevious,
            onNext: selectNext,
            onNew: onNew
        ) { tab, tabWidth, glassNamespace in
            ServerToolbarTabCell(
                title: titleForTab(tab),
                isSelected: selectedTabId == tab.id,
                statusColor: .green,
                width: tabWidth,
                glassNamespace: glassNamespace,
                shortcutNumber: tabs.firstIndex(where: { $0.id == tab.id }).map { $0 + 1 },
                onSelect: { onSelect(tab) },
                onClose: { onClose(tab) }
            )
            .contextMenu {
                Button(String(localized: "Close Tab")) {
                    onClose(tab)
                }

                Divider()

                Button(String(localized: "Close Other Tabs")) {
                    onCloseOtherTabs(tab)
                }

                Button(String(localized: "Close All to the Left")) {
                    onCloseTabsToLeft(tab)
                }
                .disabled((tabs.firstIndex(where: { $0.id == tab.id }) ?? 0) == 0)

                Button(String(localized: "Close All to the Right")) {
                    onCloseTabsToRight(tab)
                }
                .disabled((tabs.firstIndex(where: { $0.id == tab.id }) ?? (tabs.count - 1)) >= tabs.count - 1)

                Divider()

                Button(String(localized: "Duplicate Tab")) {
                    onDuplicate(tab)
                }
            }
        }
    }

    private func selectPrevious() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }

        let target = tabs[currentIndex - 1]
        onSelect(target)
    }

    private func selectNext() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }),
              currentIndex < tabs.count - 1 else { return }

        let target = tabs[currentIndex + 1]
        onSelect(target)
    }
}

#endif

#if os(iOS)
struct iOSRemoteFileTabsBar: View {
    let tabs: [RemoteFileTab]
    @Binding var selectedTabId: UUID?
    let titleForTab: (RemoteFileTab) -> String
    let onSelect: (RemoteFileTab) -> Void
    let onClose: (RemoteFileTab) -> Void

    private let minTabWidth: CGFloat = 120
    private let searchAlignedOuterHorizontalPadding: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let count = max(tabs.count, 1)
            let availableWidth = max(proxy.size.width - ServerViewTopTabBarMetrics.horizontalPadding * 2, 0)
            let totalSpacing = ServerViewTopTabBarMetrics.tabSpacing * CGFloat(max(count - 1, 0))
            let itemWidth = count > 0 ? (availableWidth - totalSpacing) / CGFloat(count) : 0
            let useEqualWidth = itemWidth >= minTabWidth

            Group {
                if useEqualWidth {
                    HStack(spacing: ServerViewTopTabBarMetrics.tabSpacing) {
                        ForEach(tabs) { tab in
                            iOSRemoteFileTabButton(
                                title: titleForTab(tab),
                                isSelected: selectedTabId == tab.id,
                                fixedWidth: itemWidth,
                                onSelect: {
                                    selectedTabId = tab.id
                                    onSelect(tab)
                                },
                                onClose: { onClose(tab) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ServerViewTopTabBarMetrics.horizontalPadding)
                    .padding(.vertical, ServerViewTopTabBarMetrics.barVerticalInset)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ServerViewTopTabBarMetrics.tabSpacing) {
                            ForEach(tabs) { tab in
                                iOSRemoteFileTabButton(
                                    title: titleForTab(tab),
                                    isSelected: selectedTabId == tab.id,
                                    fixedWidth: nil,
                                    onSelect: {
                                        selectedTabId = tab.id
                                        onSelect(tab)
                                    },
                                    onClose: { onClose(tab) }
                                )
                                .frame(minWidth: minTabWidth)
                            }
                        }
                        .padding(.horizontal, ServerViewTopTabBarMetrics.horizontalPadding)
                        .padding(.vertical, ServerViewTopTabBarMetrics.barVerticalInset)
                        .animation(nil, value: tabs.map(\.id))
                    }
                }
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .frame(height: ServerViewTopTabBarMetrics.barHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .clipShape(Capsule(style: .continuous))
        .padding(.horizontal, searchAlignedOuterHorizontalPadding)
        .padding(.vertical, 6)
    }
}

private struct iOSRemoteFileTabButton: View {
    let title: String
    let isSelected: Bool
    let fixedWidth: CGFloat?
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 36)
        .padding(.vertical, ServerViewTopTabBarMetrics.tabVerticalPadding)
        .frame(height: ServerViewTopTabBarMetrics.tabHeight)
        .frame(width: fixedWidth, alignment: .leading)
        .foregroundStyle(.primary)
        .background(
            isSelected ? Color.primary.opacity(0.18) : Color.clear,
            in: Capsule(style: .continuous)
        )
        .overlay(alignment: .trailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isSelected ? 0.16 : 0.12))
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .accessibilityAddTraits(.isButton)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}
#endif
