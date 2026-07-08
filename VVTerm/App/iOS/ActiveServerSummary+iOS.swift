//
//  ActiveServerSummary+iOS.swift
//  VVTerm
//

import Foundation

#if os(iOS)
struct ActiveServerSummary: Identifiable {
    let id: UUID
    let terminalTab: TerminalTab?
    let title: String
    let status: ConnectionState
    let tmuxStatus: TmuxStatus
    let tabCount: Int
    let targetViewId: String

    static func makeAll(
        tabManager: TerminalTabManager,
        fileTabs: RemoteFileTabManager,
        serverName: (UUID) -> String?,
        viewTabConfig: ViewTabConfigurationManager
    ) -> [ActiveServerSummary] {
        let serverIds = Set(tabManager.tabsByServer.keys).union(fileTabs.tabsByServer.keys)

        return serverIds.compactMap { serverId in
            let terminalTabs = tabManager.tabs(for: serverId)
            let remoteFileTabs = fileTabs.tabs(for: serverId)
            guard !terminalTabs.isEmpty || !remoteFileTabs.isEmpty else { return nil }

            let tab = representativeTab(
                for: serverId,
                tabs: terminalTabs,
                selectedTabByServer: tabManager.selectedTabByServer
            )
            let state = representativePaneState(in: terminalTabs, tabManager: tabManager)

            return ActiveServerSummary(
                id: serverId,
                terminalTab: tab,
                title: serverName(serverId)
                    ?? tab.map { tabManager.displayTitle(for: $0) }
                    ?? String(localized: "Server"),
                status: state.map { normalizedConnectionState(for: $0, tabManager: tabManager) } ?? .disconnected,
                tmuxStatus: state?.tmuxStatus ?? .off,
                tabCount: terminalTabs.count + remoteFileTabs.count,
                targetViewId: targetViewId(
                    serverId: serverId,
                    hasTerminalTabs: !terminalTabs.isEmpty,
                    hasFileTabs: !remoteFileTabs.isEmpty,
                    selectedViewByServer: tabManager.selectedViewByServer,
                    viewTabConfig: viewTabConfig
                )
            )
        }
        .sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func representativeTab(
        for serverId: UUID,
        tabs: [TerminalTab],
        selectedTabByServer: [UUID: UUID]
    ) -> TerminalTab? {
        guard !tabs.isEmpty else { return nil }
        if let selectedId = selectedTabByServer[serverId],
           let match = tabs.first(where: { $0.id == selectedId }) {
            return match
        }
        return tabs.first
    }

    private static func representativePaneState(
        in tabs: [TerminalTab],
        tabManager: TerminalTabManager
    ) -> TerminalPaneState? {
        tabs
            .flatMap { orderedPaneIds(for: $0) }
            .compactMap { tabManager.paneStates[$0] }
            .min { lhs, rhs in
                stateSortRank(normalizedConnectionState(for: lhs, tabManager: tabManager))
                    < stateSortRank(normalizedConnectionState(for: rhs, tabManager: tabManager))
            }
    }

    private static func normalizedConnectionState(
        for state: TerminalPaneState,
        tabManager: TerminalTabManager
    ) -> ConnectionState {
        if case .connected = state.connectionState,
           tabManager.shellId(for: state.paneId) == nil {
            return .disconnected
        }
        return state.connectionState
    }

    private static func stateSortRank(_ state: ConnectionState) -> Int {
        switch state {
        case .connected:
            return 0
        case .connecting, .reconnecting:
            return 1
        case .failed:
            return 2
        case .disconnected:
            return 3
        case .idle:
            return 4
        }
    }

    private static func orderedPaneIds(for tab: TerminalTab) -> [UUID] {
        var paneIds = [tab.focusedPaneId, tab.rootPaneId]
        paneIds.append(contentsOf: tab.allPaneIds)
        return paneIds.reduce(into: []) { uniquePaneIds, paneId in
            if !uniquePaneIds.contains(paneId) {
                uniquePaneIds.append(paneId)
            }
        }
    }

    private static func targetViewId(
        serverId: UUID,
        hasTerminalTabs: Bool,
        hasFileTabs: Bool,
        selectedViewByServer: [UUID: String],
        viewTabConfig: ViewTabConfigurationManager
    ) -> String {
        let selected = viewTabConfig.effectiveView(for: selectedViewByServer[serverId])
        if selected == ConnectionViewTab.stats.id {
            return ConnectionViewTab.stats.id
        }
        if selected == ConnectionViewTab.files.id, hasFileTabs {
            return ConnectionViewTab.files.id
        }
        if selected == ConnectionViewTab.terminal.id, hasTerminalTabs {
            return ConnectionViewTab.terminal.id
        }
        return hasTerminalTabs ? ConnectionViewTab.terminal.id : ConnectionViewTab.files.id
    }
}
#endif
