import SwiftUI

#if os(macOS)
import AppKit
#endif

struct ServerViewTabNavigationButton: View {
    let icon: String
    let action: () -> Void
    var help: String = ""

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
                #if os(macOS)
                .background(
                    isHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                    in: Circle()
                )
                #else
                .background(
                    isHovering ? Color.gray.opacity(0.3) : Color.clear,
                    in: Circle()
                )
                #endif
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
        .help(help)
    }
}

struct ServerViewNewTabButton: View {
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
                #if os(macOS)
                .background(
                    isHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                    in: Circle()
                )
                #else
                .background(
                    isHovering ? Color.gray.opacity(0.3) : Color.clear,
                    in: Circle()
                )
                #endif
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
        .help(Text(help))
    }
}

enum ServerViewTopTabBarMetrics {
    static let tabHeight: CGFloat = 36
    static let tabVerticalPadding: CGFloat = 7
    static let barVerticalInset: CGFloat = 4
    static let tabSpacing: CGFloat = 4
    static let horizontalPadding: CGFloat = 4
    static let outerHorizontalPadding: CGFloat = 12
    #if os(macOS)
    static let toolbarTabCapsuleHeight: CGFloat = 28
    /// Outer height of a toolbar tab cell. Kept close to the native toolbar
    /// control height so the tab strip isn't taller than the other items.
    static let toolbarTabStripHeight: CGFloat = 30
    static let toolbarTabStripIdealWidth: CGFloat = 640
    static let toolbarTabStripFallbackWidth: CGFloat = 1_600
    /// Per-tab sizing shared by terminal and file tabs (browser-like).
    static let toolbarTabMinimumWidth: CGFloat = 120
    static let toolbarTabMaximumWidth: CGFloat = 240
    #endif
    static var barHeight: CGFloat { tabHeight + barVerticalInset * 2 }
}

#if os(macOS)
struct ServerToolbarTabCell: View {
    let title: String
    let isSelected: Bool
    let statusColor: Color
    let width: CGFloat
    var accessibilityLabel: String?
    /// Shared namespace so the selected glass capsule morphs between tabs.
    var glassNamespace: Namespace.ID?
    /// 1-based tab position; shows a ⌘N hint on hover for the first nine tabs.
    var shortcutNumber: Int?
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                tabSurface
                tabLabel
            }
            .frame(width: width, height: ServerViewTopTabBarMetrics.toolbarTabCapsuleHeight)
            .frame(height: ServerViewTopTabBarMetrics.toolbarTabStripHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityValue(isSelected ? String(localized: "Selected") : "")
    }

    @ViewBuilder
    private var tabLabel: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                    )
            }
            .buttonStyle(.plain)

            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)

            if let shortcutNumber, shortcutNumber <= 9 {
                Spacer(minLength: 4)
                Text("⌘\(shortcutNumber)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(
            width: width,
            height: ServerViewTopTabBarMetrics.toolbarTabCapsuleHeight,
            alignment: .leading
        )
    }

    @ViewBuilder
    private var tabSurface: some View {
        if isSelected {
            selectedGlassSurface
        } else {
            // No background at rest — only a subtle highlight on hover.
            Capsule()
                .fill(Color(nsColor: .separatorColor).opacity(isHovering ? 0.5 : 0))
        }
    }

    @ViewBuilder
    private var selectedGlassSurface: some View {
        if reduceTransparency {
            Capsule()
                .fill(.regularMaterial)
        } else if #available(iOS 26, macOS 26, *) {
            selectedLiquidGlass
        } else {
            Capsule()
                .fill(.ultraThinMaterial)
        }
    }

    /// The selected tab's glass capsule. matchedGeometryEffect with a shared id
    /// makes the capsule slide/morph from the previously selected tab to the new
    /// one on switch. The glass stays per-cell (behind the label only), so the
    /// label is never composited into the glass and stays sharp.
    @available(iOS 26, macOS 26, *)
    @ViewBuilder
    private var selectedLiquidGlass: some View {
        let glass = GlassEffectContainer(spacing: 0) {
            Capsule()
                .fill(.clear)
                .frame(width: width, height: ServerViewTopTabBarMetrics.toolbarTabCapsuleHeight)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        if let glassNamespace {
            glass.matchedGeometryEffect(id: ServerToolbarTabCell.selectedGlassID, in: glassNamespace)
        } else {
            glass
        }
    }

    private static let selectedGlassID = "vvterm.selectedTab"
}

struct AdaptiveServerTabSizing: Equatable {
    let tabWidth: CGFloat
    let isScrollable: Bool

    static func resolve(
        containerWidth: CGFloat,
        itemCount: Int,
        minimumTabWidth: CGFloat = ServerViewTopTabBarMetrics.toolbarTabMinimumWidth,
        maximumTabWidth: CGFloat = ServerViewTopTabBarMetrics.toolbarTabMaximumWidth,
        horizontalPadding: CGFloat = ServerViewTopTabBarMetrics.horizontalPadding,
        tabSpacing: CGFloat = ServerViewTopTabBarMetrics.tabSpacing
    ) -> AdaptiveServerTabSizing {
        let resolvedContainerWidth = containerWidth.isFinite
            ? containerWidth
            : ServerViewTopTabBarMetrics.toolbarTabStripFallbackWidth

        guard itemCount > 0, resolvedContainerWidth > 0 else {
            return AdaptiveServerTabSizing(tabWidth: minimumTabWidth, isScrollable: false)
        }

        let availableWidth = max(resolvedContainerWidth - horizontalPadding * 2, 0)
        let totalSpacing = tabSpacing * CGFloat(max(itemCount - 1, 0))
        let candidateWidth = (availableWidth - totalSpacing) / CGFloat(itemCount)

        // Below the minimum usable width we stop dividing evenly and scroll the
        // tabs horizontally at their minimum width instead.
        guard candidateWidth.isFinite, candidateWidth >= minimumTabWidth else {
            return AdaptiveServerTabSizing(tabWidth: minimumTabWidth, isScrollable: true)
        }

        // Cap individual tabs so a single tab never grows comically wide; the
        // leftover width is left to the rest of the toolbar (leading aligned).
        return AdaptiveServerTabSizing(
            tabWidth: min(candidateWidth, maximumTabWidth),
            isScrollable: false
        )
    }
}

struct AdaptiveServerTabStrip<Item: Identifiable, TabContent: View>: View where Item.ID: Hashable {
    let items: [Item]
    let selectedId: Item.ID?
    var minimumTabWidth: CGFloat = ServerViewTopTabBarMetrics.toolbarTabMinimumWidth
    var maximumTabWidth: CGFloat = ServerViewTopTabBarMetrics.toolbarTabMaximumWidth
    var tabContent: (Item, CGFloat, Namespace.ID) -> TabContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace

    var body: some View {
        GeometryReader { proxy in
            let sizing = AdaptiveServerTabSizing.resolve(
                containerWidth: proxy.size.width,
                itemCount: items.count,
                minimumTabWidth: minimumTabWidth,
                maximumTabWidth: maximumTabWidth
            )

            ScrollViewReader { scrollProxy in
                Group {
                    if sizing.isScrollable {
                        ScrollView(.horizontal, showsIndicators: false) {
                            tabStack(tabWidth: sizing.tabWidth)
                        }
                    } else {
                        tabStack(tabWidth: sizing.tabWidth)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .transaction { transaction in
                    if reduceMotion {
                        transaction.animation = nil
                    }
                }
                // Animate only when tabs are added/removed, not on every
                // container width change — otherwise the capsule eases behind
                // the window edge during live resize.
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.14),
                    value: items.count
                )
                // Morph the selected glass capsule between tabs on switch.
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.3),
                    value: selectedId
                )
                .onChange(of: selectedId) { newValue in
                    guard sizing.isScrollable, let newValue else { return }
                    withOptionalTabAnimation {
                        scrollProxy.scrollTo(newValue, anchor: .center)
                    }
                }
                .onChange(of: items.map(\.id)) { _ in
                    guard sizing.isScrollable, let selectedId else { return }
                    withOptionalTabAnimation {
                        scrollProxy.scrollTo(selectedId, anchor: .center)
                    }
                }
            }
        }
        .frame(
            minWidth: minimumTabWidth,
            idealWidth: ServerViewTopTabBarMetrics.toolbarTabStripIdealWidth,
            maxWidth: .infinity,
            minHeight: ServerViewTopTabBarMetrics.toolbarTabStripHeight,
            maxHeight: ServerViewTopTabBarMetrics.toolbarTabStripHeight
        )
    }

    private func tabStack(tabWidth: CGFloat) -> some View {
        HStack(spacing: ServerViewTopTabBarMetrics.tabSpacing) {
            ForEach(items) { item in
                tabContent(item, tabWidth, glassNamespace)
                    .id(item.id)
            }
        }
        .padding(.horizontal, ServerViewTopTabBarMetrics.horizontalPadding)
        .frame(height: ServerViewTopTabBarMetrics.toolbarTabStripHeight)
    }

    private func withOptionalTabAnimation(_ action: () -> Void) {
        if reduceMotion {
            action()
        } else {
            withAnimation(.easeInOut(duration: 0.14), action)
        }
    }
}

struct ServerToolbarTabStrip<Item: Identifiable, TabContent: View>: View where Item.ID: Hashable {
    let items: [Item]
    let selectedId: Item.ID?
    let previousHelp: String
    let nextHelp: String
    let newHelp: String
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onNew: () -> Void
    var tabContent: (Item, CGFloat, Namespace.ID) -> TabContent

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                ServerViewTabNavigationButton(
                    icon: "chevron.left",
                    action: onPrevious,
                    help: previousHelp
                )
                .disabled(items.count <= 1)

                ServerViewTabNavigationButton(
                    icon: "chevron.right",
                    action: onNext,
                    help: nextHelp
                )
                .disabled(items.count <= 1)
            }
            .padding(.leading, 8)

            // Tabs stretch to fill the strip and shrink/scroll when there are
            // too many. The strip simply fills its container — its width is set
            // by the hosting NSToolbarItem, which provides native fill + overflow.
            AdaptiveServerTabStrip(
                items: items,
                selectedId: selectedId,
                maximumTabWidth: .infinity,
                tabContent: tabContent
            )
            .layoutPriority(1)

            ServerViewNewTabButton(
                help: newHelp,
                action: onNew
            )
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

#endif
