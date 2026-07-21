//
//  ActiveServerSummary+iOS.swift
//  VVTerm
//

import Foundation

#if os(iOS)
enum ActiveConnectionPresentationStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case resumable
    case failed(String)

    init(
        connectionState: ConnectionState,
        connectionMode: SSHConnectionMode?,
        hasResumeCheckpoint: Bool
    ) {
        if connectionMode == .eternalTerminal, hasResumeCheckpoint {
            switch connectionState {
            case .disconnected, .idle:
                self = .resumable
                return
            case .connecting, .connected, .reconnecting, .failed:
                break
            }
        }
        self = switch connectionState {
        case .disconnected, .idle: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .reconnecting(let attempt): .reconnecting(attempt: attempt)
        case .failed(let message): .failed(message)
        }
    }

    var label: String {
        switch self {
        case .disconnected:
            String(localized: "Disconnected")
        case .connecting:
            String(localized: "Connecting...")
        case .connected:
            String(localized: "Connected")
        case .reconnecting(let attempt):
            String(
                format: String(localized: "Reconnecting (%lld)..."),
                Int64(attempt)
            )
        case .resumable:
            String(localized: "Ready to resume")
        case .failed(let message):
            String(format: String(localized: "Failed: %@"), message)
        }
    }
}

struct ActiveServerSummary: Identifiable {
    let id: UUID
    let terminalTab: TerminalTab?
    let title: String
    let status: ActiveConnectionPresentationStatus
    let tmuxStatus: TmuxStatus
    let tabCount: Int
    let targetViewId: String

    static func makeAll(
        tabManager: TerminalTabManager,
        fileTabs: RemoteFileTabManager,
        server: (UUID) -> Server?,
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
            let configuredServer = server(serverId)

            return ActiveServerSummary(
                id: serverId,
                terminalTab: tab,
                title: configuredServer?.name
                    ?? tab.map { tabManager.displayTitle(for: $0) }
                    ?? String(localized: "Server"),
                status: state.map {
                    return ActiveConnectionPresentationStatus(
                        connectionState: $0.connectionState,
                        connectionMode: configuredServer?.connectionMode,
                        hasResumeCheckpoint: tabManager.hasEternalTerminalCheckpoint(for: $0.paneId)
                    )
                } ?? .disconnected,
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
                stateSortRank(lhs.connectionState) < stateSortRank(rhs.connectionState)
            }
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
