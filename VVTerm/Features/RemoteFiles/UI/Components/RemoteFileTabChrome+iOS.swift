import SwiftUI

#if os(iOS)
struct RemoteFileTabsBar: View {
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
                            RemoteFileTabButton(
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
                                RemoteFileTabButton(
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

private struct RemoteFileTabButton: View {
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
