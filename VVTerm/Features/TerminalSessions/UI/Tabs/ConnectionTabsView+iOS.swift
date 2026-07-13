#if os(iOS)
import SwiftUI

extension ConnectionTerminalContainer {
    var platformBody: some View {
        sharedBody
            .alert(
                disconnectAlertTitle,
                isPresented: $showingDisconnectConfirmation,
            ) {
                Button("Cancel", role: .cancel) {}
                Button(disconnectActionTitle, role: .destructive) {
                    disconnectFromServer()
                }
            } message: {
                Text(disconnectAlertMessage)
            }
            .alert("Close this terminal?", isPresented: $showingPaneCloseConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Close", role: .destructive) {
                    closeFocusedPaneConfirmed()
                }
            } message: {
                Text("The SSH connection will be terminated.")
            }
            .sheet(item: $serverToEdit) { editingServer in
                NavigationStack {
                    ServerFormSheet(
                        serverManager: serverManager,
                        workspace: serverManager.workspaces.first { $0.id == editingServer.workspaceId },
                        server: editingServer,
                        onSave: { _ in
                            serverToEdit = nil
                        }
                    )
                }
                .adaptiveSoftScrollEdges()
            }
    }

    func platformChrome<Content: View>(
        _ content: Content,
        backgroundColor: Color
    ) -> some View {
        VStack(spacing: 0) {
            if !isZenModeEnabled {
                headerTabsBar
            }

            content
        }
        .background(backgroundColor.ignoresSafeArea(.all))
        .modifier(
            TerminalKeyboardSafeAreaModifier(
                isEnabled: preservesTerminalSizeForKeyboard
                    && selectedView == ConnectionViewTab.terminal.id
            )
        )
    }

    @ViewBuilder
    var platformContentStack: some View {
        switch selectedView {
        case ConnectionViewTab.stats.id:
            statsLayer
        case ConnectionViewTab.files.id:
            filesLayer
        case ConnectionViewTab.terminal.id:
            terminalLayer
        default:
            terminalLayer
        }
    }

    @ViewBuilder
    var terminalLayer: some View {
        if selectedView == ConnectionViewTab.terminal.id, let tab = selectedTab {
            TerminalTabView(
                tab: tab,
                server: server,
                tabManager: tabManager,
                isSelected: true
            )
            // Per-tab identity: without it SwiftUI reuses the previous tab's
            // representable (and its Ghostty view + SSH coordinator) when the
            // selected tab changes.
            .id(tab.id)
        }

        if selectedView == ConnectionViewTab.terminal.id && serverTabs.isEmpty {
            TerminalEmptyStateView(server: server) {
                openNewTab()
            }
        }
    }

    @ViewBuilder
    private var headerTabsBar: some View {
        if selectedView == ConnectionViewTab.terminal.id && serverTabs.count > 1 {
            SharedTerminalTabsBar(
                tabs: serverTabs,
                selectedTabId: selectedTabIdBinding,
                titleForTab: { tabManager.displayTitle(for: $0) },
                paneState: { tabManager.paneStates[$0.focusedPaneId] },
                onClose: { tabManager.closeTab($0) }
            )
        }

        if selectedView == ConnectionViewTab.files.id && serverFileTabs.count > 1 {
            RemoteFileTabsBar(
                tabs: serverFileTabs,
                selectedTabId: selectedFileTabIdBinding,
                titleForTab: displayedFileTabTitle(for:),
                onSelect: { fileTabManager.selectTab($0) },
                onClose: { tab in
                    if let removedTab = fileTabManager.closeTab(tab) {
                        fileBrowser.removeState(for: removedTab.id)
                    }
                }
            )
        }
    }

    private func disconnectFromServer() {
        tabManager.disconnectServer(server.id)
        fileBrowser.disconnect(serverId: server.id)
        fileTabManager.disconnect(serverId: server.id)
    }

    private var disconnectAlertTitle: String {
        String(localized: "Close Tab?")
    }

    private var disconnectActionTitle: String {
        String(localized: "Close")
    }

    private var disconnectAlertMessage: String {
        let terminalCount = serverTabs.count
        let fileCount = serverFileTabs.count

        if terminalCount == 0, fileCount == 0 {
            return String(localized: "This will return to the server list.")
        }

        if terminalCount > 0, fileCount > 0 {
            return String(localized: "All terminal and file tabs for this server will be closed.")
        }

        if fileCount > 0 {
            return String(localized: "All file tabs for this server will be closed.")
        }

        return String(localized: "All terminal tabs for this server will be closed.")
    }
}

private struct TerminalKeyboardSafeAreaModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.ignoresSafeArea(.keyboard, edges: .bottom)
        } else {
            content
        }
    }
}

private struct SharedTerminalTabsBar: View {
    let tabs: [TerminalTab]
    @Binding var selectedTabId: UUID?
    let titleForTab: (TerminalTab) -> String
    let paneState: (TerminalTab) -> TerminalPaneState?
    let onClose: (TerminalTab) -> Void

    private let minTabWidth: CGFloat = 120

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
                            SharedTerminalTabButton(
                                title: titleForTab(tab),
                                statusColor: statusColor(for: tab),
                                isSelected: selectedTabId == tab.id,
                                fixedWidth: itemWidth,
                                onSelect: { selectedTabId = tab.id },
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
                                SharedTerminalTabButton(
                                    title: titleForTab(tab),
                                    statusColor: statusColor(for: tab),
                                    isSelected: selectedTabId == tab.id,
                                    fixedWidth: nil,
                                    onSelect: { selectedTabId = tab.id },
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
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
    }

    private func statusColor(for tab: TerminalTab) -> Color {
        switch paneState(tab)?.connectionState ?? .idle {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .failed:
            return .red
        case .disconnected, .idle:
            return .secondary
        }
    }
}

private struct SharedTerminalTabButton: View {
    let title: String
    let statusColor: Color
    let isSelected: Bool
    let fixedWidth: CGFloat?
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

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
