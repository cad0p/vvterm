import SwiftUI

struct ZenModeFloatingOverlay<Panel: View>: View {
    @Binding var isPanelPresented: Bool
    let panel: (CGFloat) -> Panel

    #if os(macOS)
    private let chromeTopPadding: CGFloat = 6
    private let chromeTrailingPadding: CGFloat = 8
    #else
    private let chromeTopPadding: CGFloat = 12
    private let chromeTrailingPadding: CGFloat = 12
    #endif

    init(
        isPanelPresented: Binding<Bool>,
        indicatorColor: Color? = nil,
        @ViewBuilder panel: @escaping (CGFloat) -> Panel
    ) {
        self._isPanelPresented = isPanelPresented
        self.panel = panel
    }

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = max(250, min(proxy.size.width - 24, 360))

            ZStack(alignment: .topTrailing) {
                if isPanelPresented {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            closePanel()
                        }
                        .transition(.opacity)
                }

                chromeStack(panelWidth: panelWidth)
                    .padding(.top, chromeTopPadding)
                    .padding(.trailing, chromeTrailingPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    @ViewBuilder
    private func chromeStack(panelWidth: CGFloat) -> some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: 12) {
                overlayContent(panelWidth: panelWidth)
            }
        } else {
            overlayContent(panelWidth: panelWidth)
        }
    }

    private func overlayContent(panelWidth: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            launcherButton

            if isPanelPresented {
                panel(panelWidth)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var launcherButton: some View {
        Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                isPanelPresented.toggle()
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(.primary)
                .zenModeLauncherGlass()
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Zen controls"))
        .accessibilityValue(isPanelPresented ? String(localized: "Expanded") : String(localized: "Collapsed"))
    }

    private func closePanel() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isPanelPresented = false
        }
    }
}

private extension View {
    @ViewBuilder
    func zenModeLauncherGlass() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }
}

struct ZenModePanelCard<Content: View>: View {
    let width: CGFloat
    let backgroundColor: Color?
    let content: Content
    private let cornerRadius: CGFloat = 22

    init(width: CGFloat, backgroundColor: Color? = nil, @ViewBuilder content: () -> Content) {
        self.width = width
        self.backgroundColor = backgroundColor
        self.content = content()
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(width: width)
        .frame(maxHeight: 430)
        .background(panelBackground(for: cardShape))
        .clipShape(cardShape)
        .overlay(
            cardShape
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 14, y: 10)
    }

    @ViewBuilder
    private func panelBackground(for shape: RoundedRectangle) -> some View {
        if let backgroundColor {
            shape
                .fill(backgroundColor)
                .overlay(
                    shape.fill(Color.white.opacity(0.02))
                )
        } else {
            shape
                .fill(.ultraThinMaterial)
        }
    }
}

struct ZenModeSection<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(sectionHeaderColor)
                .textCase(.uppercase)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionHeaderColor: Color {
        #if os(iOS)
        Color.primary.opacity(0.78)
        #else
        Color.secondary
        #endif
    }
}

struct ZenModeChoiceChip: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(foregroundColor)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(backgroundOpacity))
                )
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        if isSelected {
            return .primary
        }

        #if os(iOS)
        return Color.primary.opacity(0.8)
        #else
        return Color.primary.opacity(0.72)
        #endif
    }

    private var backgroundOpacity: Double {
        if isSelected {
            return 0.16
        }

        #if os(iOS)
        return 0.1
        #else
        return 0.08
        #endif
    }
}

struct ZenModeActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = .primary
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .foregroundStyle(isDisabled ? Color.secondary : tint)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct ZenModeStatusLine: View {
    let title: String
    let subtitle: String
    let indicatorColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.headline)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(subtitleColor)
        }
    }

    private var subtitleColor: Color {
        #if os(iOS)
        Color.primary.opacity(0.72)
        #else
        .secondary
        #endif
    }
}

#if os(macOS)
struct MacOSZenModePanel: View {
    let width: CGFloat
    let serverName: String
    let statusText: String
    let statusColor: Color
    let selectedView: String
    let selectedViewBinding: Binding<String>
    let viewTabs: [ConnectionViewTab]
    let terminalTabs: [TerminalTab]
    let selectedTerminalTabId: Binding<UUID?>
    let terminalTabTitle: (TerminalTab) -> String
    let paneState: (TerminalTab) -> TerminalPaneState?
    let fileTabs: [RemoteFileTab]
    let selectedFileTabId: Binding<UUID?>
    let fileTabTitle: (RemoteFileTab) -> String
    let onPreviousTab: () -> Void
    let onNextTab: () -> Void
    let onNewTerminalTab: () -> Void
    let onCloseTerminalTab: (TerminalTab) -> Void
    let onNewFileTab: () -> Void
    let onCloseFileTab: (RemoteFileTab) -> Void
    let onSelectFileTab: (RemoteFileTab) -> Void
    let onSplitRight: () -> Void
    let onSplitDown: () -> Void
    let onClosePane: () -> Void
    let canSplit: Bool
    let canClosePane: Bool
    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void
    let onDisconnect: () -> Void
    let canFilesGoUp: Bool
    let filesShowHiddenBinding: Binding<Bool>
    let onFilesGoUp: () -> Void
    let onFilesRefresh: () -> Void
    let onExitZen: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                panelContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(width: width)
        .frame(maxHeight: 430)
        .background(.clear)
    }

    @ViewBuilder
    private var panelContent: some View {
        ZenModeStatusLine(
            title: serverName,
            subtitle: statusText,
            indicatorColor: statusColor
        )

        ZenModeSection("View") {
            HStack(spacing: 8) {
                ForEach(viewTabs) { tab in
                    ZenModeChoiceChip(
                        title: LocalizedStringKey(tab.localizedKey),
                        systemImage: tab.icon,
                        isSelected: selectedView == tab.id
                    ) {
                        selectedViewBinding.wrappedValue = tab.id
                    }
                }
            }
        }

        ZenModeSection("Tabs") {
            HStack(spacing: 8) {
                ZenModeActionButton(title: "Previous Tab", systemImage: "chevron.left") {
                    onPreviousTab()
                }
                .frame(maxWidth: .infinity)
                .disabled(activeTabCount <= 1)

                ZenModeActionButton(title: "Next Tab", systemImage: "chevron.right") {
                    onNextTab()
                }
                .frame(maxWidth: .infinity)
                .disabled(activeTabCount <= 1)
            }

            ZenModeActionButton(title: "New Tab", systemImage: "plus") {
                if selectedView == ConnectionViewTab.files.id {
                    onNewFileTab()
                } else {
                    onNewTerminalTab()
                }
            }

            if selectedView == ConnectionViewTab.files.id {
                if fileTabs.isEmpty {
                    Text("No file tabs open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(fileTabs) { tab in
                            macOSFileTabRow(tab)
                        }
                    }
                }
            } else if terminalTabs.isEmpty {
                Text("No terminals open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(terminalTabs) { tab in
                        macOSTabRow(tab)
                    }
                }
            }
        }

        if selectedView == "terminal" {
            ZenModeSection("Pane") {
                ZenModeActionButton(
                    title: "Split Right",
                    systemImage: "rectangle.split.2x1"
                ) {
                    onSplitRight()
                }
                .disabled(!canSplit)

                ZenModeActionButton(
                    title: "Split Down",
                    systemImage: "rectangle.split.1x2"
                ) {
                    onSplitDown()
                }
                .disabled(!canSplit)

                ZenModeActionButton(
                    title: "Close Pane",
                    systemImage: "xmark.square",
                    tint: .red
                ) {
                    onClosePane()
                }
                .disabled(!canClosePane)
            }
        }

        if selectedView == "files" {
            ZenModeSection("Files") {
                HStack(spacing: 8) {
                    ZenModeActionButton(title: "Parent", systemImage: "arrow.turn.up.left") {
                        onFilesGoUp()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(!canFilesGoUp)

                    ZenModeActionButton(title: "Refresh", systemImage: "arrow.clockwise") {
                        onFilesRefresh()
                    }
                    .frame(maxWidth: .infinity)
                }

                ZenModeActionButton(
                    title: filesShowHiddenBinding.wrappedValue
                        ? "Hide Hidden Files"
                        : "Show Hidden Files",
                    systemImage: filesShowHiddenBinding.wrappedValue
                        ? "eye.slash"
                        : "eye",
                    tint: filesShowHiddenBinding.wrappedValue ? .orange : .primary
                ) {
                    filesShowHiddenBinding.wrappedValue.toggle()
                }
                .frame(maxWidth: .infinity)
            }
        }

        ZenModeSection("Window") {
            ZenModeActionButton(
                title: LocalizedStringKey(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"),
                systemImage: "sidebar.left"
            ) {
                onToggleSidebar()
            }
        }

        ZenModeSection("Session") {
            ZenModeActionButton(
                title: "Disconnect",
                systemImage: "xmark.circle",
                tint: .red
            ) {
                onDisconnect()
            }
        }

        ZenModeSection("Zen") {
            ZenModeActionButton(
                title: "Exit Zen Mode",
                systemImage: "arrow.down.right.and.arrow.up.left"
            ) {
                onExitZen()
            }
        }
    }

    private func macOSTabRow(_ tab: TerminalTab) -> some View {
        let state = paneState(tab)
        let tint = state?.connectionState.statusTintColor ?? .secondary
        let isSelected = selectedTerminalTabId.wrappedValue == tab.id

        return HStack(spacing: 8) {
            Button {
                selectedViewBinding.wrappedValue = "terminal"
                selectedTerminalTabId.wrappedValue = tab.id
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(terminalTabTitle(tab))
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)

                        if tab.paneCount > 1 {
                            Text(String(format: String(localized: "%lld panes"), Int64(tab.paneCount)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.14 : 0.07))
                )
            }
            .buttonStyle(.plain)

            Button {
                onCloseTerminalTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func macOSFileTabRow(_ tab: RemoteFileTab) -> some View {
        let isSelected = selectedFileTabId.wrappedValue == tab.id

        return HStack(spacing: 8) {
            Button {
                selectedViewBinding.wrappedValue = ConnectionViewTab.files.id
                selectedFileTabId.wrappedValue = tab.id
                onSelectFileTab(tab)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)

                    Text(fileTabTitle(tab))
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.14 : 0.07))
                )
            }
            .buttonStyle(.plain)

            Button {
                onCloseFileTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var activeTabCount: Int {
        selectedView == ConnectionViewTab.files.id ? fileTabs.count : terminalTabs.count
    }
}
#endif

#if os(iOS)
struct IOSZenModePanel: View {
    let width: CGFloat
    let serverName: String
    let selectedView: String
    let selectedViewBinding: Binding<String>
    let viewTabs: [ConnectionViewTab]
    let sessions: [ConnectionSession]
    let selectedSessionId: Binding<UUID?>
    let sessionTitle: (ConnectionSession) -> String
    let onCloseSession: (ConnectionSession) -> Void
    let fileTabs: [RemoteFileTab]
    let selectedFileTabId: Binding<UUID?>
    let fileTabTitle: (RemoteFileTab) -> String
    let onSelectFileTab: (RemoteFileTab) -> Void
    let onCloseFileTab: (RemoteFileTab) -> Void
    let onNewTerminalTab: () -> Void
    let onNewFileTab: () -> Void
    let onOpenSettings: () -> Void
    let onEditServer: (() -> Void)?
    let onDisconnect: () -> Void
    let onBack: () -> Void
    let onExitZen: () -> Void

    var body: some View {
        ZenModePanelCard(width: width) {
            ZenModeStatusLine(
                title: serverName,
                subtitle: statusText,
                indicatorColor: sessions.first?.connectionState.statusTintColor ?? .secondary
            )

            ZenModeSection("View") {
                HStack(spacing: 8) {
                    ForEach(viewTabs) { tab in
                        ZenModeChoiceChip(
                            title: LocalizedStringKey(tab.localizedKey),
                            systemImage: tab.icon,
                            isSelected: selectedView == tab.id
                        ) {
                            selectedViewBinding.wrappedValue = tab.id
                        }
                    }
                }
            }

            ZenModeSection("Tabs") {
                ZenModeActionButton(title: "New Tab", systemImage: "plus") {
                    if selectedView == ConnectionViewTab.files.id {
                        onNewFileTab()
                    } else {
                        onNewTerminalTab()
                    }
                }

                if selectedView == ConnectionViewTab.files.id {
                    if fileTabs.isEmpty {
                        Text("No file tabs open.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(fileTabs) { tab in
                                iosFileTabRow(tab)
                            }
                        }
                    }
                } else if sessions.isEmpty {
                    Text("No terminals open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(sessions) { session in
                            iosSessionRow(session)
                        }
                    }
                }
            }

            ZenModeSection("Server") {
                ZenModeActionButton(title: "Settings", systemImage: "gear") {
                    onOpenSettings()
                }

                if let onEditServer {
                    ZenModeActionButton(title: "Edit Server", systemImage: "pencil") {
                        onEditServer()
                    }
                }

                ZenModeActionButton(title: "Back", systemImage: "chevron.left") {
                    onBack()
                }
            }

            ZenModeSection("Session") {
                ZenModeActionButton(
                    title: "Disconnect",
                    systemImage: "xmark.circle",
                    tint: .red
                ) {
                    onDisconnect()
                }
            }

            ZenModeSection("Zen") {
                ZenModeActionButton(
                    title: "Exit Zen Mode",
                    systemImage: "arrow.down.right.and.arrow.up.left"
                ) {
                    onExitZen()
                }
            }
        }
    }

    private func iosSessionRow(_ session: ConnectionSession) -> some View {
        let isSelected = selectedSessionId.wrappedValue == session.id

        return HStack(spacing: 8) {
            Button {
                selectedViewBinding.wrappedValue = "terminal"
                selectedSessionId.wrappedValue = session.id
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(session.connectionState.statusTintColor)
                        .frame(width: 7, height: 7)

                    Text(sessionTitle(session))
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.14 : 0.07))
                )
            }
            .buttonStyle(.plain)

            Button {
                onCloseSession(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.12))
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func iosFileTabRow(_ tab: RemoteFileTab) -> some View {
        let isSelected = selectedFileTabId.wrappedValue == tab.id

        return HStack(spacing: 8) {
            Button {
                selectedViewBinding.wrappedValue = ConnectionViewTab.files.id
                selectedFileTabId.wrappedValue = tab.id
                onSelectFileTab(tab)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)

                    Text(fileTabTitle(tab))
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.14 : 0.07))
                )
            }
            .buttonStyle(.plain)

            Button {
                onCloseFileTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.12))
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var statusText: String {
        if selectedView == ConnectionViewTab.files.id {
            return fileTabs.isEmpty
                ? String(localized: "No open file tabs")
                : String(format: String(localized: "%lld open file tabs"), Int64(fileTabs.count))
        }

        return sessions.isEmpty
            ? String(localized: "No open terminals")
            : String(format: String(localized: "%lld open tabs"), Int64(sessions.count))
    }
}
#endif

extension ConnectionState {
    var statusTintColor: Color {
        switch self {
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
}
