//
//  TerminalTabManager.swift
//  VVTerm
//
//  Manages terminal tabs and their panes.
//  - Tabs are shown in the toolbar
//  - Each tab can have multiple panes via splits
//  - Panes are NOT tabs - they're split views within a tab
//

import Foundation
import SwiftUI
import Combine
import os.log

#if os(macOS)
import AppKit
#endif

enum TerminalRegistryPolicy {
    static func shouldRemove(
        registered: ObjectIdentifier,
        dismantled: ObjectIdentifier
    ) -> Bool {
        registered == dismantled
    }

    static func attachmentToPublish(
        registered: ObjectIdentifier?,
        reporting: ObjectIdentifier,
        currentAttachment: Bool
    ) -> Bool? {
        guard registered == reporting else { return nil }
        return currentAttachment
    }
}

@MainActor
final class TerminalTabManager: ObservableObject {
    private enum ConnectionLifecycle {
        enum Destination {
            case foreground
            case background
        }

        case foreground
        case background
        case suspending(
            epoch: UUID,
            destination: Destination,
            barrier: Task<Void, Never>
        )

        var allowsConnections: Bool {
            if case .foreground = self {
                return true
            }
            return false
        }
    }

    private struct ConnectionCleanup {
        let client: SSHClient
        let task: Task<Void, Never>
    }

    private struct ShellStartIdentity: Hashable {
        let paneId: UUID
        let clientId: ObjectIdentifier
    }

    private struct RetiredShellStart {
        let completion: AsyncStream<Void>
        let signal: AsyncStream<Void>.Continuation
    }

    static let shared = TerminalTabManager()

    // MARK: - Published State

    /// All tabs, organized by server
    @Published var tabsByServer: [UUID: [TerminalTab]] = [:] {
        didSet { schedulePersist() }
    }

    /// Currently selected tab ID per server
    @Published var selectedTabByServer: [UUID: UUID] = [:] {
        didSet {
            schedulePersist()
            updateTmuxSelectionStatuses()
        }
    }

    /// Servers with at least one live terminal shell.
    @Published var connectedServerIds: Set<UUID> = []

    /// Selected view type per server (stats/terminal)
    @Published var selectedViewByServer: [UUID: String] = [:] {
        didSet { schedulePersist() }
    }

    // MARK: - Terminal Registry

    /// Terminal views keyed by pane ID
    private var terminalViews: [UUID: GhosttyTerminalView] = [:]
    private var shellRegistry = SSHShellRegistry(staleThreshold: 120)
    private var connectionCleanupsInFlight: [UUID: ConnectionCleanup] = [:]
    private var retiredShellStarts: [ShellStartIdentity: RetiredShellStart] = [:]
    private var connectionLifecycle: ConnectionLifecycle = .foreground
    private var reconnectPreparationsInFlight: Set<UUID> = []
    /// Server IDs with an in-flight tab-open request to avoid queued duplicates.
    private var tabOpensInFlight: Set<UUID> = []

    /// Pane state keyed by pane ID
    @Published var paneStates: [UUID: TerminalPaneState] = [:] {
        didSet {
            LiveActivityManager.shared.refresh(
                with: paneStates.values.map(\.connectionState)
            )
        }
    }
    @Published private(set) var runtimeTitleByPane: [UUID: String] = [:]
    @Published private(set) var titleOverrideByPane: [UUID: String] = [:]
    #if os(iOS)
    @Published private(set) var terminalFindNavigatorVisibleByPane: [UUID: Bool] = [:]
    @Published private(set) var terminalVoiceRecordingByPane: [UUID: Bool] = [:]
    @Published private(set) var terminalPendingVoiceReturnByPane: [UUID: Bool] = [:]
    let keyboardCoordinator = TerminalKeyboardCoordinator()
    #endif

    @Published var tmuxAttachPrompt: TmuxAttachPrompt?

    let tmuxResolver = TmuxAttachResolver()

    /// Bumps when a terminal view is registered/unregistered so views refresh.
    @Published private(set) var terminalRegistryVersion: Int = 0

    /// Servers that already ran tmux cleanup (per app launch)
    private var tmuxCleanupServers: Set<UUID> = []

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "TerminalTabManager")

    private let persistenceKey = "terminalTabsSnapshot.v1"
    private var persistTask: Task<Void, Never>?
    private var isRestoring = false

    private init() {
        #if os(iOS)
        keyboardCoordinator.terminalProvider = { [weak self] paneId in
            self?.terminalViews[paneId]
        }
        #endif
        restoreSnapshot()
        LiveActivityManager.shared.refresh(
            with: paneStates.values.map(\.connectionState)
        )
    }

    private func paneTmuxStatus(for paneId: UUID) -> TmuxStatus? {
        paneStates[paneId]?.tmuxStatus
    }

    private func setPaneTmuxStatus(_ status: TmuxStatus, for paneId: UUID) {
        paneStates[paneId]?.tmuxStatus = status
    }

    private func paneWorkingDirectory(for paneId: UUID) -> String? {
        paneStates[paneId]?.workingDirectory
    }

    private func setPaneWorkingDirectory(_ workingDirectory: String, for paneId: UUID) {
        paneStates[paneId]?.workingDirectory = workingDirectory
    }

    private func setPanePresentationOverrides(_ presentationOverrides: TerminalPresentationOverrides, for paneId: UUID) {
        paneStates[paneId]?.presentationOverrides = presentationOverrides
    }

    private func setPaneTitle(_ title: String, for paneId: UUID) {
        guard runtimeTitleByPane[paneId] != title else { return }

        runtimeTitleByPane[paneId] = title
        logger.info("Runtime pane title changed: \(title, privacy: .public)")
    }

    private func setPaneTransport(
        _ transport: ShellTransport,
        fallbackReason: MoshFallbackReason?,
        for paneId: UUID
    ) {
        paneStates[paneId]?.activeTransport = transport
        paneStates[paneId]?.moshFallbackReason = fallbackReason
    }

    private func handleStaleShellStartContext(
        _ staleContext: SSHShellRegistry.StartContext?,
        logMessage: StaticString,
        paneId: UUID
    ) {
        guard let staleContext else { return }

        logger.warning("\(logMessage) \(paneId.uuidString, privacy: .public)")
        if !shellRegistry.hasClientReferences(staleContext.client) {
            Task.detached(priority: .utility) { [client = staleContext.client] in
                await client.disconnect()
            }
        }
    }

    // MARK: - Tab Management

    /// Get tabs for a server
    func tabs(for serverId: UUID) -> [TerminalTab] {
        tabsByServer[serverId] ?? []
    }

    /// Get currently selected tab for a server
    func selectedTab(for serverId: UUID) -> TerminalTab? {
        guard let tabId = selectedTabByServer[serverId] else {
            return tabs(for: serverId).first
        }
        return tabs(for: serverId).first { $0.id == tabId }
    }

    /// Check if can open new tab (Pro limit check)
    var canOpenNewTab: Bool {
        if StoreManager.shared.isPro { return true }
        let totalTabs = tabsByServer.values.flatMap { $0 }.count
        return totalTabs < FreeTierLimits.maxTabs
    }

    private func hasLiveTerminalShell(for serverId: UUID) -> Bool {
        paneStates.contains { _, state in
            state.serverId == serverId
                && state.connectionState.isConnected
                && shellId(for: state.paneId) != nil
        }
    }

    private func refreshConnectedServerState(for serverId: UUID) {
        if hasLiveTerminalShell(for: serverId) {
            connectedServerIds.insert(serverId)
        } else {
            connectedServerIds.remove(serverId)
        }
    }

    /// Open a new tab for a server
    @discardableResult
    func openTab(for server: Server) async throws -> TerminalTab {
        if tabOpensInFlight.contains(server.id) {
            throw VVTermError.connectionFailed(
                String(localized: "A tab is already opening for this server.")
            )
        }
        tabOpensInFlight.insert(server.id)
        defer { tabOpensInFlight.remove(server.id) }

        guard await AppLockManager.shared.ensureServerUnlocked(server) else {
            throw VVTermError.authenticationFailed
        }

        let tab = TerminalTab(serverId: server.id, title: server.name)

        let sourcePaneId = selectedTab(for: server.id)?.focusedPaneId
        let sourceWorkingDirectory = sourcePaneId
            .flatMap { paneStates[$0]?.workingDirectory }

        // Create pane state FIRST (before any @Published updates)
        // This ensures the view has state when it renders
        var rootState = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: server.id
        )
        rootState.workingDirectory = sourceWorkingDirectory
        rootState.seedPaneId = sourcePaneId
        rootState.tmuxStatus = tmuxResolver.isTmuxEnabled(for: server.id) ? .unknown : .off
        paneStates[tab.rootPaneId] = rootState

        // Now update tabs (triggers @Published, view will have state ready)
        var serverTabs = tabsByServer[server.id] ?? []
        serverTabs.append(tab)
        tabsByServer[server.id] = serverTabs

        // Select the new tab
        selectedTabByServer[server.id] = tab.id

        logger.info("Opened new tab for \(server.name), pane: \(tab.rootPaneId)")
        return tab
    }

    /// Close a tab
    func closeTab(_ tab: TerminalTab) {
        closeTab(tab, managedTmuxCleanup: .terminate)
    }

    private func closeTab(
        _ tab: TerminalTab,
        managedTmuxCleanup: ManagedTmuxCleanupDisposition
    ) {
        // Clean up all panes in this tab
        for paneId in tab.allPaneIds {
            cleanupPane(paneId, managedTmuxCleanup: managedTmuxCleanup)
        }

        // Remove from tabs
        if var serverTabs = tabsByServer[tab.serverId] {
            let closingIndex = serverTabs.firstIndex { $0.id == tab.id }
            serverTabs.removeAll { $0.id == tab.id }

            // Select the closest neighbor when the selected tab is closed: the
            // tab that shifted into its slot, or the new last tab if it was last.
            if serverTabs.isEmpty {
                tabsByServer.removeValue(forKey: tab.serverId)
                selectedTabByServer.removeValue(forKey: tab.serverId)
            } else {
                tabsByServer[tab.serverId] = serverTabs
            }

            if selectedTabByServer[tab.serverId] == tab.id {
                if let closingIndex, !serverTabs.isEmpty {
                    selectedTabByServer[tab.serverId] = serverTabs[min(closingIndex, serverTabs.count - 1)].id
                } else {
                    selectedTabByServer.removeValue(forKey: tab.serverId)
                }
            }

            refreshConnectedServerState(for: tab.serverId)
        }

        EngagementTracker.shared.noteTerminalSessionEnded(
            otherTerminalsActive: hasConnectedPanes
        )

        logger.info("Closed tab \(tab.id)")
    }

    /// Close all tabs for a server
    func closeAllTabs(for serverId: UUID) {
        let serverTabs = tabs(for: serverId)
        for tab in serverTabs {
            closeTab(tab)
        }
    }

    /// Disconnect all terminal tabs for a specific server.
    func disconnectServer(_ serverId: UUID) {
        closeAllTabs(for: serverId)
        tabsByServer.removeValue(forKey: serverId)
        selectedTabByServer.removeValue(forKey: serverId)
        selectedViewByServer.removeValue(forKey: serverId)
        connectedServerIds.remove(serverId)
        persistSnapshot()
        logger.info("Disconnected all terminal tabs for server \(serverId.uuidString, privacy: .public)")
    }

    /// Disconnect every active terminal tab.
    func disconnectAll() {
        let serverIds = Set(tabsByServer.keys).union(connectedServerIds)
        for serverId in serverIds {
            disconnectServer(serverId)
        }
        connectedServerIds.removeAll()
        persistSnapshot()
        logger.info("Disconnected all terminal tabs")
    }

    /// Synchronously revokes every shell owner before iOS can freeze the app,
    /// then starts one shared cleanup barrier for the revoked clients.
    func beginBackgroundSuspension() {
        beginBackgroundSuspension(beforeCleanup: nil)
    }

    private func beginBackgroundSuspension(
        beforeCleanup: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        let paneIds = Array(paneStates.keys)
        #if os(iOS)
        keyboardCoordinator.setViewActive(false)
        #endif

        switch connectionLifecycle {
        case .background:
            return
        case let .suspending(epoch, _, barrier):
            connectionLifecycle = .suspending(
                epoch: epoch,
                destination: .background,
                barrier: barrier
            )
            return
        case .foreground:
            break
        }

        for paneId in paneIds {
            if let terminal = terminalViews[paneId] {
                terminal.pauseRendering()
            }
            if paneStates[paneId]?.connectionState.isConnected == true
                || paneStates[paneId]?.connectionState.isConnecting == true {
                updatePaneState(paneId, connectionState: .disconnected)
            }
        }

        // Detach every registration before the app can be frozen. Cleanup may
        // then finish after foregrounding without removing a replacement shell.
        let detachedShells = shellRegistry.drain()

        var cleanupByClient: [ObjectIdentifier: SSHClient] = [:]
        for registration in detachedShells.registrations {
            cleanupByClient[ObjectIdentifier(registration.client)] = registration.client
        }
        for pendingStart in detachedShells.pendingStarts {
            let context = pendingStart.context
            cleanupByClient[ObjectIdentifier(context.client)] = context.client
            let identity = ShellStartIdentity(
                paneId: pendingStart.entityId,
                clientId: ObjectIdentifier(context.client)
            )
            let completion = AsyncStream<Void>.makeStream()
            retiredShellStarts[identity]?.signal.finish()
            retiredShellStarts[identity] = RetiredShellStart(
                completion: completion.stream,
                signal: completion.continuation
            )
        }
        let cleanupsInFlight = Array(connectionCleanupsInFlight.values)
        for cleanup in cleanupsInFlight {
            cleanupByClient[ObjectIdentifier(cleanup.client)] = cleanup.client
        }

        let clients = Array(cleanupByClient.values)
        let epoch = UUID()
        let barrier = Task { @MainActor [weak self, clients, beforeCleanup] in
            if let beforeCleanup {
                await beforeCleanup()
            }
            await withTaskGroup(of: Void.self) { group in
                for client in clients {
                    group.addTask {
                        // Disconnect aborts the active session before its bounded
                        // shutdown, avoiding a blocking channel-close handshake.
                        await client.disconnect()
                    }
                }
            }
            await self?.finishBackgroundSuspension(epoch: epoch)
        }

        connectionLifecycle = .suspending(
            epoch: epoch,
            destination: .background,
            barrier: barrier
        )
        logger.info(
            "Started terminal background suspension \(epoch.uuidString, privacy: .public) for \(clients.count, privacy: .public) clients"
        )
    }

    /// Disconnect SSH shells without removing tabs. Used by tests and callers
    /// that need to wait for the full background cleanup.
    func suspendAllForBackground() async {
        beginBackgroundSuspension()
        if case let .suspending(_, _, barrier) = connectionLifecycle {
            await barrier.value
        }
    }

    func noteForegroundActivation() {
        switch connectionLifecycle {
        case .foreground:
            break
        case .background:
            connectionLifecycle = .foreground
        case let .suspending(epoch, _, barrier):
            connectionLifecycle = .suspending(
                epoch: epoch,
                destination: .foreground,
                barrier: barrier
            )
        }
    }

    func prepareForForegroundReconnect() async -> Bool {
        switch connectionLifecycle {
        case .foreground:
            return true
        case .background:
            return false
        case let .suspending(_, destination, barrier):
            guard destination == .foreground else { return false }
            await barrier.value
            return connectionLifecycle.allowsConnections
        }
    }

    func tryBeginReconnectPreparation(for paneId: UUID) -> Bool {
        guard paneStates[paneId] != nil else { return false }
        return reconnectPreparationsInFlight.insert(paneId).inserted
    }

    func finishReconnectPreparation(for paneId: UUID) {
        reconnectPreparationsInFlight.remove(paneId)
    }

    private func finishBackgroundSuspension(epoch: UUID) async {
        while true {
            guard case let .suspending(currentEpoch, destination, _) = connectionLifecycle,
                  currentEpoch == epoch else {
                return
            }

            // Cleanup can be registered after the registry drain when a native
            // shell start finishes late. Keep folding that work into this epoch
            // until the MainActor can atomically observe an empty set and close it.
            let cleanups = Array(connectionCleanupsInFlight)
            if !cleanups.isEmpty {
                for (_, cleanup) in cleanups {
                    await cleanup.task.value
                }
                for (cleanupId, _) in cleanups {
                    connectionCleanupsInFlight.removeValue(forKey: cleanupId)
                }
                continue
            }

            let retiredStarts = Array(retiredShellStarts)
            if !retiredStarts.isEmpty {
                let timeoutCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                    for (_, retiredStart) in retiredStarts {
                        group.addTask {
                            await Self.waitForRetiredShellStart(retiredStart.completion)
                        }
                    }
                    var timeouts = 0
                    for await completed in group {
                        if !completed {
                            timeouts += 1
                        }
                    }
                    return timeouts
                }
                for (identity, retiredStart) in retiredStarts {
                    retiredStart.signal.finish()
                    retiredShellStarts.removeValue(forKey: identity)
                }
                if timeoutCount > 0 {
                    logger.warning(
                        "Timed out waiting for \(timeoutCount, privacy: .public) retired shell starts during background suspension \(epoch.uuidString, privacy: .public)"
                    )
                }
                continue
            }

            switch destination {
            case .foreground:
                connectionLifecycle = .foreground
            case .background:
                connectionLifecycle = .background
            }
            logger.info(
                "Finished terminal background suspension \(epoch.uuidString, privacy: .public) toward \(String(describing: destination), privacy: .public)"
            )
            return
        }
    }

    nonisolated private static func waitForRetiredShellStart(
        _ completion: AsyncStream<Void>
    ) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                for await _ in completion {
                    break
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }
    }

    // MARK: - Split Management

    /// Split a pane horizontally (left | right)
    func splitHorizontal(tab: TerminalTab, paneId: UUID) -> UUID? {
        splitRight(tab: tab, paneId: paneId)
    }

    /// Split a pane vertically (top / bottom)
    func splitVertical(tab: TerminalTab, paneId: UUID) -> UUID? {
        splitDown(tab: tab, paneId: paneId)
    }

    func splitRight(tab: TerminalTab, paneId: UUID) -> UUID? {
        splitPane(tab: tab, paneId: paneId, placement: .right)
    }

    func splitLeft(tab: TerminalTab, paneId: UUID) -> UUID? {
        splitPane(tab: tab, paneId: paneId, placement: .left)
    }

    func splitDown(tab: TerminalTab, paneId: UUID) -> UUID? {
        splitPane(tab: tab, paneId: paneId, placement: .down)
    }

    func splitUp(tab: TerminalTab, paneId: UUID) -> UUID? {
        splitPane(tab: tab, paneId: paneId, placement: .up)
    }

    private func splitPane(tab: TerminalTab, paneId: UUID, placement: TerminalSplitPlacement) -> UUID? {
        guard StoreManager.shared.isPro else { return nil }
        let newPaneId = createSplitPane(tab: tab, paneId: paneId, placement: placement)
        if newPaneId != nil {
            AnalyticsTracker.shared.trackSplitPaneCreated()
        }
        return newPaneId
    }

    private func createSplitPane(tab: TerminalTab, paneId: UUID, placement: TerminalSplitPlacement) -> UUID? {
        // Resolve the latest tab from manager state since the passed value can be stale.
        guard let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }) else {
            logger.warning("createSplitPane: tab not found \(tab.id.uuidString, privacy: .public)")
            return nil
        }

        let paneExists: Bool
        if let layout = currentTab.layout {
            paneExists = layout.findPane(paneId)
        } else {
            paneExists = currentTab.rootPaneId == paneId
        }
        guard paneExists else {
            logger.warning("createSplitPane: pane not found \(paneId.uuidString, privacy: .public)")
            return nil
        }

        let newPaneId = UUID()

        // Create pane state FIRST (before any @Published updates)
        // This ensures the view has state when it renders
        var newState = TerminalPaneState(
            paneId: newPaneId,
            tabId: currentTab.id,
            serverId: currentTab.serverId
        )
        newState.workingDirectory = paneStates[paneId]?.workingDirectory
        newState.seedPaneId = paneId
        newState.tmuxStatus = tmuxResolver.isTmuxEnabled(for: currentTab.serverId) ? .unknown : .off
        paneStates[newPaneId] = newState

        let sourceNode = TerminalSplitNode.leaf(paneId: paneId)
        let newNode = TerminalSplitNode.leaf(paneId: newPaneId)
        // Create the new split node
        let newSplit = TerminalSplitNode.split(TerminalSplitNode.Split(
            direction: placement.direction,
            ratio: 0.5,
            left: placement.insertsBeforeSource ? newNode : sourceNode,
            right: placement.insertsBeforeSource ? sourceNode : newNode
        ))

        // Update tab layout
        var updatedTab = currentTab
        if let currentLayout = currentTab.layout {
            updatedTab.layout = currentLayout.replacingPane(paneId, with: newSplit).equalized()
        } else {
            // No layout yet - create one with the split
            updatedTab.layout = newSplit
        }
        updatedTab.focusedPaneId = newPaneId

        // Update tabs array (triggers @Published, view will have state ready)
        updateTab(updatedTab)

        logger.info("Split pane \(paneId) \(placement.direction.rawValue), new pane: \(newPaneId)")
        return newPaneId
    }

    /// Close a pane within a tab
    func closePane(tab: TerminalTab, paneId: UUID) {
        closePane(tab: tab, paneId: paneId, managedTmuxCleanup: .terminate)
    }

    private func closePane(
        tab: TerminalTab,
        paneId: UUID,
        managedTmuxCleanup: ManagedTmuxCleanupDisposition
    ) {
        // Get current tab from manager (passed tab might be stale)
        guard let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }) else {
            logger.warning("closePane: tab not found")
            return
        }

        let paneExists: Bool
        if let layout = currentTab.layout {
            paneExists = layout.findPane(paneId)
        } else {
            paneExists = currentTab.rootPaneId == paneId
        }
        guard paneExists else {
            logger.warning("closePane: pane not found \(paneId)")
            return
        }

        // If this is the only pane, close the tab
        if currentTab.paneCount <= 1 {
            closeTab(currentTab, managedTmuxCleanup: managedTmuxCleanup)
            return
        }

        // Update layout FIRST (before cleanup) to avoid "Initializing" flash
        // When cleanupPane triggers @Published, the pane won't be rendered anymore
        var updatedTab = currentTab
        if let currentLayout = currentTab.layout,
           let newLayout = currentLayout.removingPane(paneId) {
            // Always keep the layout - even for single pane
            // This ensures allPaneIds returns the correct remaining pane
            // (not rootPaneId which might have been closed)
            updatedTab.layout = newLayout.equalized()

            // Focus the closest remaining pane (the one that took the closed
            // pane's slot, or the new last pane if it was last) instead of
            // jumping to the first pane.
            if updatedTab.focusedPaneId == paneId {
                let oldPanes = currentLayout.allPaneIds()
                let newPanes = newLayout.allPaneIds()
                if let closedIndex = oldPanes.firstIndex(of: paneId), !newPanes.isEmpty {
                    updatedTab.focusedPaneId = newPanes[min(closedIndex, newPanes.count - 1)]
                } else {
                    updatedTab.focusedPaneId = newPanes.first ?? currentTab.rootPaneId
                }
            }
        }
        updateTab(updatedTab)

        // Now clean up the pane (after layout is updated)
        cleanupPane(paneId, managedTmuxCleanup: managedTmuxCleanup)
        refreshConnectedServerState(for: tab.serverId)
        logger.info("Closed pane \(paneId)")
    }

    /// Update a tab in the tabs array
    func updateTab(_ tab: TerminalTab) {
        guard var serverTabs = tabsByServer[tab.serverId],
              let index = serverTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        serverTabs[index] = tab
        tabsByServer[tab.serverId] = serverTabs
        updateTmuxFocus(for: tab)
    }

    // MARK: - Terminal Registry

    /// Register a terminal view for a pane
    func registerTerminal(_ terminal: GhosttyTerminalView, for paneId: UUID) {
        let replacesRegisteredTerminal = terminalViews[paneId].map { $0 !== terminal } ?? false
        #if os(iOS)
        terminal.onWindowAttachmentChange = { [weak self, weak terminal] _ in
            Task { @MainActor [weak self, weak terminal] in
                guard let self, let terminal,
                      let attachment = TerminalRegistryPolicy.attachmentToPublish(
                          registered: self.terminalViews[paneId].map { ObjectIdentifier($0) },
                          reporting: ObjectIdentifier(terminal),
                          currentAttachment: terminal.window != nil
                      ) else { return }
                self.keyboardCoordinator.setWindowAttached(attachment, for: paneId)
            }
        }
        terminal.onTerminalDirectTouch = { [weak self] isFocusTap in
            Task { @MainActor [weak self] in
                self?.keyboardCoordinator.directTouchOnTerminal(isFocusTap: isFocusTap)
            }
        }
        terminal.onKeyboardAccessoryHideRequested = { [weak self] in
            Task { @MainActor [weak self] in
                self?.keyboardCoordinator.userRequestedHide()
            }
        }
        terminal.onFindNavigatorVisibilityChange = { [weak self] isVisible in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setTerminalFindNavigatorVisible(isVisible, for: paneId)
                self.keyboardCoordinator.setFindNavigatorActive(isVisible)
            }
        }
        #endif
        terminalViews[paneId] = terminal
        #if os(iOS)
        terminal.acceptsTerminalInput = paneStates[paneId]?.connectionState.isConnected == true
        // A replacement is commonly registered before UIKit attaches it.
        // Publish that fact before reconciling its new identity so the
        // coordinator cannot spend an acquisition or repair off-window.
        keyboardCoordinator.setWindowAttached(terminal.window != nil, for: paneId)
        if replacesRegisteredTerminal {
            keyboardCoordinator.terminalProviderIdentityDidChange(for: paneId)
        }
        Task { @MainActor [weak self, weak terminal] in
            guard let self, let terminal, self.terminalViews[paneId] === terminal else { return }
            self.keyboardCoordinator.setWindowAttached(terminal.window != nil, for: paneId)
            self.publishTerminalInputAvailability(for: paneId)
            self.setTerminalFindNavigatorVisible(terminal.isFindNavigatorVisible, for: paneId)
            self.keyboardCoordinator.setFindNavigatorActive(terminal.isFindNavigatorVisible)
        }
        #endif
        scheduleTerminalRegistryVersionUpdate()
    }

    /// Unregister a terminal view
    func unregisterTerminal(for paneId: UUID) {
        if let terminal = terminalViews.removeValue(forKey: paneId) {
            #if os(iOS)
            terminal.onWindowAttachmentChange = nil
            terminal.onTerminalDirectTouch = nil
            terminal.onKeyboardAccessoryHideRequested = nil
            terminal.onFindNavigatorVisibilityChange = nil
            terminalFindNavigatorVisibleByPane.removeValue(forKey: paneId)
            terminalVoiceRecordingByPane.removeValue(forKey: paneId)
            terminalPendingVoiceReturnByPane.removeValue(forKey: paneId)
            keyboardCoordinator.setWindowAttached(false, for: paneId)
            keyboardCoordinator.removePane(paneId)
            #endif
            terminal.cleanup()
        }
        scheduleTerminalRegistryVersionUpdate()
    }

    /// Unregister a dismantled platform view only if it is still the pane's
    /// registered terminal. SwiftUI may create its replacement before the old
    /// view's deferred teardown runs during window reconstruction.
    func unregisterTerminal(_ terminal: GhosttyTerminalView, for paneId: UUID) {
        guard let registeredTerminal = terminalViews[paneId],
              TerminalRegistryPolicy.shouldRemove(
                  registered: ObjectIdentifier(registeredTerminal),
                  dismantled: ObjectIdentifier(terminal)
              ) else {
            terminal.cleanup()
            return
        }
        unregisterTerminal(for: paneId)
    }

    #if os(iOS)
    private func setTerminalFindNavigatorVisible(_ isVisible: Bool, for paneId: UUID) {
        if terminalFindNavigatorVisibleByPane[paneId] != isVisible {
            terminalFindNavigatorVisibleByPane[paneId] = isVisible
        }
    }

    func setTerminalVoiceRecording(_ isRecording: Bool, for paneId: UUID) {
        if isRecording {
            if terminalVoiceRecordingByPane[paneId] != true {
                terminalVoiceRecordingByPane[paneId] = true
            }
        } else {
            terminalVoiceRecordingByPane.removeValue(forKey: paneId)
        }
    }

    func setTerminalPendingVoiceReturn(_ isPending: Bool, for paneId: UUID) {
        if isPending {
            if terminalPendingVoiceReturnByPane[paneId] != true {
                terminalPendingVoiceReturnByPane[paneId] = true
            }
        } else {
            terminalPendingVoiceReturnByPane.removeValue(forKey: paneId)
        }
    }
    #endif

    private func scheduleTerminalRegistryVersionUpdate() {
        Task { @MainActor [weak self] in
            self?.terminalRegistryVersion &+= 1
        }
    }

    /// Get terminal for a pane
    func getTerminal(for paneId: UUID) -> GhosttyTerminalView? {
        terminalViews[paneId]
    }

    /// Register SSH shell for a pane
    @discardableResult
    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        for paneId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        skipTmuxLifecycle: Bool = false
    ) async -> Bool {
        let registerResult = shellRegistry.register(
            client: client,
            shellId: shellId,
            for: paneId,
            serverId: serverId,
            transport: transport,
            fallbackReason: fallbackReason
        )

        switch registerResult {
        case .stale:
            logger.warning("Ignoring stale shell registration for pane \(paneId.uuidString, privacy: .public)")
            await performTrackedConnectionCleanup(for: client) {
                if self.shellRegistry.hasClientReferences(client) {
                    await client.closeShell(shellId)
                } else {
                    await client.disconnect()
                }
            }
            return false
        case .accepted:
            break
        }

        setPaneTransport(transport, fallbackReason: fallbackReason, for: paneId)

        if !skipTmuxLifecycle {
            Task { [weak self] in
                await self?.handleTmuxLifecycle(paneId: paneId, serverId: serverId, client: client, shellId: shellId)
            }
        }
        return true
    }

    /// Unregister SSH shell
    func unregisterSSHClient(for paneId: UUID) async {
        await unregisterSSHClient(
            for: paneId,
            killingManagedTmuxSessionNamed: nil,
            beforeCleanup: nil
        )
    }

    func unregisterSSHClient(
        for paneId: UUID,
        ifOwnedBy client: SSHClient,
        shellId: UUID
    ) async {
        guard shellRegistry.owns(
            client: client,
            shellId: shellId,
            for: paneId
        ) else { return }
        await unregisterSSHClient(for: paneId)
    }

    func unregisterSSHClient(
        for paneId: UUID,
        ifOwnedBy client: SSHClient
    ) async {
        guard shellRegistry.ownsConnection(client: client, for: paneId) else { return }
        await unregisterSSHClient(for: paneId)
    }

    private func unregisterSSHClient(
        for paneId: UUID,
        killingManagedTmuxSessionNamed tmuxSessionName: String?,
        beforeCleanup: (@MainActor @Sendable () async -> Void)?
    ) async {
        let unregisterResult = shellRegistry.unregister(for: paneId)

        guard let registration = unregisterResult.registration else {
            if let pendingStart = unregisterResult.pendingStart {
                if !shellRegistry.hasClientReferences(pendingStart.client) {
                    await performTrackedConnectionCleanup(for: pendingStart.client) {
                        if let beforeCleanup {
                            await beforeCleanup()
                        }
                        await pendingStart.client.disconnect()
                    }
                }
            }
            return
        }

        await performTrackedConnectionCleanup(for: registration.client) {
            if let beforeCleanup {
                await beforeCleanup()
            }
            if let tmuxSessionName {
                await RemoteTmuxManager.shared.killSession(named: tmuxSessionName, using: registration.client)
            }
            if !self.shellRegistry.hasClientReferences(registration.client) {
                // Abort the whole session before its bounded shutdown. A last
                // shell does not need a separate channel-close handshake.
                await registration.client.disconnect()
            } else {
                await registration.client.closeShell(registration.shellId)
            }
        }

        setPaneTransport(.ssh, fallbackReason: nil, for: paneId)
    }

    private func performTrackedConnectionCleanup(
        for client: SSHClient,
        operation: @MainActor @Sendable @escaping () async -> Void
    ) async {
        let cleanupId = UUID()
        let task = Task { @MainActor in
            await operation()
        }
        connectionCleanupsInFlight[cleanupId] = ConnectionCleanup(
            client: client,
            task: task
        )
        await task.value
        connectionCleanupsInFlight.removeValue(forKey: cleanupId)
    }

    /// Get SSH client for a pane
    func getSSHClient(for paneId: UUID) -> SSHClient? {
        shellRegistry.client(for: paneId)
    }

    func getConnectionOwnerClient(for paneId: UUID) -> SSHClient? {
        shellRegistry.connectionClient(for: paneId)
    }

    func shellId(for paneId: UUID) -> UUID? {
        shellRegistry.shellId(for: paneId)
    }

    /// Returns true only for the first caller while no live shell exists for the pane.
    func tryBeginShellStart(for paneId: UUID, client: SSHClient) -> Bool {
        guard connectionLifecycle.allowsConnections else {
            return false
        }
        guard let serverId = paneStates[paneId]?.serverId else {
            return false
        }

        let startResult = shellRegistry.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: client
        )

        handleStaleShellStartContext(
            startResult.staleContext,
            logMessage: "Recovered stale pane shell-start lock for",
            paneId: paneId
        )
        return startResult.started
    }

    func finishShellStart(for paneId: UUID, client: SSHClient) {
        let identity = ShellStartIdentity(
            paneId: paneId,
            clientId: ObjectIdentifier(client)
        )
        retiredShellStarts.removeValue(forKey: identity)?.signal.finish()
        shellRegistry.finishStart(for: paneId, client: client)
    }

    func isShellStartInFlight(for paneId: UUID) -> Bool {
        let result = shellRegistry.isStartInFlight(for: paneId)
        handleStaleShellStartContext(
            result.staleContext,
            logMessage: "Cleared stale pane shell-start in-flight flag for",
            paneId: paneId
        )
        return result.inFlight
    }

    func isCurrentShellOwner(for paneId: UUID, client: SSHClient) -> Bool {
        connectionLifecycle.allowsConnections
            && paneStates[paneId] != nil
            && shellRegistry.ownsConnection(client: client, for: paneId)
    }

    private func preferredSSHClient(for serverId: UUID, allowPendingStart: Bool) -> SSHClient? {
        if let selectedTab = selectedTab(for: serverId) {
            let preferredPaneIds = [selectedTab.focusedPaneId, selectedTab.rootPaneId] + selectedTab.allPaneIds
            for paneId in preferredPaneIds {
                if let client = shellRegistry.client(for: paneId) {
                    return client
                }
            }
        }

        let serverTabs = tabs(for: serverId)
        for tab in serverTabs {
            for paneId in tab.allPaneIds {
                if let client = shellRegistry.client(for: paneId) {
                    return client
                }
            }
        }

        if let client = shellRegistry.firstRegisteredClient(for: serverId) {
            return client
        }

        if allowPendingStart, let client = shellRegistry.firstPendingClient(for: serverId) {
            return client
        }

        return nil
    }

    /// Returns the best-known client for this server, including pending shell starts.
    func sshClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: true)
    }

    /// Returns only clients that already have a registered shell for this server.
    func activeSSHClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: false)
    }

    func hasOtherActivePanes(for serverId: UUID, excluding paneId: UUID) -> Bool {
        paneStates.contains { entry in
            entry.key != paneId && entry.value.serverId == serverId && entry.value.connectionState.isConnected
        }
    }

    /// Returns true when the same SSH client instance is registered to another live pane.
    /// This is used to avoid disconnecting a truly shared client during retry cleanup.
    func hasOtherRegistrations(using client: SSHClient, excluding paneId: UUID) -> Bool {
        shellRegistry.hasOtherRegistrations(using: client, excluding: paneId)
    }

    func sharedStatsClient(for serverId: UUID) -> SSHClient? {
        if selectedTransport(for: serverId) == .mosh {
            return nil
        }
        return sshClient(for: serverId)
    }

    private func selectedTransport(for serverId: UUID) -> ShellTransport {
        if let selectedTab = selectedTab(for: serverId),
           let state = paneStates[selectedTab.focusedPaneId] {
            return state.activeTransport
        }

        if let connectedPane = paneStates.values.first(where: { $0.serverId == serverId && $0.connectionState.isConnected }) {
            return connectedPane.activeTransport
        }

        return paneStates.values.first(where: { $0.serverId == serverId })?.activeTransport ?? .ssh
    }

    /// Clean up a pane (terminal + SSH)
    private func cleanupPane(
        _ paneId: UUID,
        managedTmuxCleanup: ManagedTmuxCleanupDisposition = .terminate
    ) {
        let tmuxSessionToKill: String?
        switch managedTmuxCleanup {
        case .terminate:
            tmuxSessionToKill = paneTmuxStatus(for: paneId)
                .flatMap { managedTmuxSessionNameToKill(for: paneId, status: $0) }
        case .alreadyTerminated:
            tmuxSessionToKill = nil
        }

        clearTmuxRuntimeState(for: paneId)
        reconnectPreparationsInFlight.remove(paneId)
        unregisterTerminal(for: paneId)
        #if os(iOS)
        keyboardCoordinator.removePane(paneId)
        #endif
        paneStates.removeValue(forKey: paneId)
        runtimeTitleByPane.removeValue(forKey: paneId)
        titleOverrideByPane.removeValue(forKey: paneId)

        Task.detached { [weak self] in
            await self?.unregisterSSHClient(
                for: paneId,
                killingManagedTmuxSessionNamed: tmuxSessionToKill,
                beforeCleanup: nil
            )
        }
    }

    // MARK: - Pane State

    #if os(iOS)
    private func publishTerminalInputAvailability(for paneId: UUID) {
        let connectionState = paneStates[paneId]?.connectionState ?? .idle
        let terminal = terminalViews[paneId]

        // Routing must be enabled before the coordinator can preserve or
        // reacquire the responder at the connected boundary.
        terminal?.acceptsTerminalInput = connectionState.isConnected
        keyboardCoordinator.setPaneInputEligible(
            TerminalKeyboardCoordinator.paneInputEligible(
                connectionState: connectionState,
                shouldRestoreOnReconnect: terminal?.shouldRestoreKeyboardFocusOnReconnect == true
            ),
            for: paneId
        )
    }
    #endif

    /// Update connection state for a pane
    func updatePaneState(_ paneId: UUID, connectionState: ConnectionState) {
        let serverId = paneStates[paneId]?.serverId
        paneStates[paneId]?.connectionState = connectionState
        if connectionState.isConnecting || connectionState.isConnected {
            let clearedDisconnectReason = paneStates[paneId]?.disconnectReason != nil
            paneStates[paneId]?.disconnectReason = nil
            if clearedDisconnectReason {
                schedulePersist()
            }
        }
        if connectionState.isConnected {
            paneStates[paneId]?.markConnectionEstablished()
        }
        #if os(iOS)
        publishTerminalInputAvailability(for: paneId)
        #endif
        switch connectionState {
        case .connecting, .reconnecting:
            setPaneTransport(.ssh, fallbackReason: nil, for: paneId)
        case .disconnected, .failed:
            setPanePresentationOverrides(.empty, for: paneId)
            terminalViews[paneId]?.applyPresentationOverrides(.empty)
            if paneTmuxStatus(for: paneId) == .foreground {
                setPaneTmuxStatus(.background, for: paneId)
            }
            if let serverId {
                refreshConnectedServerState(for: serverId)
            }
        case .connected:
            if let serverId {
                refreshConnectedServerState(for: serverId)
            }
            EngagementTracker.shared.recordSuccessfulConnection(
                id: paneId,
                transport: paneStates[paneId]?.activeTransport.rawValue ?? ShellTransport.ssh.rawValue
            )
        case .idle:
            if let serverId {
                refreshConnectedServerState(for: serverId)
            }
        }
    }

    func handleShellEnd(
        for paneId: UUID,
        client: SSHClient,
        shellId: UUID,
        reason: TerminalShellEndReason
    ) {
        guard shellRegistry.owns(client: client, shellId: shellId, for: paneId) else {
            logger.info("Ignoring stale shell end for pane \(paneId.uuidString, privacy: .public)")
            return
        }
        handleShellEnd(
            for: paneId,
            reason: reason,
            unregistering: (client, shellId)
        )
    }

    func handleShellEnd(for paneId: UUID, reason: TerminalShellEndReason) {
        handleShellEnd(for: paneId, reason: reason, unregistering: nil)
    }

    private func handleShellEnd(
        for paneId: UUID,
        reason: TerminalShellEndReason,
        unregistering ownership: (client: SSHClient, shellId: UUID)?
    ) {
        guard let paneState = paneStates[paneId] else { return }

        switch reason {
        case .tmuxEnded(.managed):
            guard let tab = tabs(for: paneState.serverId).first(where: { $0.id == paneState.tabId }) else {
                return
            }
            closePane(tab: tab, paneId: paneId, managedTmuxCleanup: .alreadyTerminated)
            return

        case .tmuxDetached(let ownership):
            if ownership == .managed {
                tmuxResolver.confirmManagedSession(for: paneId)
            }
            paneStates[paneId]?.disconnectReason = .tmuxDetached
            updatePaneState(paneId, connectionState: .disconnected)
            schedulePersist()

        case .tmuxCreationFailed:
            tmuxResolver.clearAttachmentState(for: paneId)
            paneStates[paneId]?.disconnectReason = nil
            updatePaneTmuxStatus(paneId, status: .unknown)
            updatePaneState(
                paneId,
                connectionState: .failed(String(localized: "Unable to start tmux session."))
            )
            schedulePersist()

        case .tmuxEnded(.external):
            paneStates[paneId]?.disconnectReason = .externalTmuxEnded
            updatePaneState(paneId, connectionState: .disconnected)
            schedulePersist()

        case .transportEnded:
            paneStates[paneId]?.disconnectReason = .transportEnded
            updatePaneState(paneId, connectionState: .disconnected)
        }

        Task { [weak self, ownership] in
            guard let self else { return }
            if let ownership {
                await self.unregisterSSHClient(
                    for: paneId,
                    ifOwnedBy: ownership.client,
                    shellId: ownership.shellId
                )
            } else {
                await self.unregisterSSHClient(for: paneId)
            }
        }
    }

    private var hasConnectedPanes: Bool {
        paneStates.values.contains { $0.connectionState.isConnected }
    }

    func updatePaneWorkingDirectory(_ paneId: UUID, rawDirectory: String) {
        guard let normalized = normalizeWorkingDirectory(rawDirectory) else { return }
        setPaneWorkingDirectory(normalized, for: paneId)
    }

    func updatePaneTitle(_ paneId: UUID, rawTitle: String) {
        guard paneStates[paneId] != nil else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        setPaneTitle(title, for: paneId)
    }

    func setPaneTitleOverride(_ rawTitle: String?, for paneId: UUID) {
        guard paneStates[paneId] != nil else { return }
        let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
            titleOverrideByPane.removeValue(forKey: paneId)
        } else {
            titleOverrideByPane[paneId] = title
        }
    }

    func displayTitle(forPane paneId: UUID, fallback: String? = nil) -> String? {
        titleOverrideByPane[paneId] ?? runtimeTitleByPane[paneId] ?? fallback
    }

    func presentationOverrides(for paneId: UUID) -> TerminalPresentationOverrides {
        paneStates[paneId]?.presentationOverrides ?? .empty
    }

    func handleTerminalZoom(_ action: TerminalZoomAction, for paneId: UUID) -> TerminalZoomResult? {
        guard paneStates[paneId] != nil else { return nil }

        let currentOverrides = presentationOverrides(for: paneId)
        let overrides = currentOverrides.applyingZoom(action)
        guard overrides != currentOverrides else {
            return TerminalZoomResult(
                presentationOverrides: currentOverrides,
                effectiveFontSize: currentOverrides.resolvedFontSize()
            )
        }
        setPanePresentationOverrides(overrides, for: paneId)
        schedulePersist()
        terminalViews[paneId]?.applyPresentationOverrides(overrides)
        return TerminalZoomResult(
            presentationOverrides: overrides,
            effectiveFontSize: overrides.resolvedFontSize()
        )
    }

    func displayTitle(for tab: TerminalTab) -> String {
        titleOverrideByPane[tab.focusedPaneId]
            ?? runtimeTitleByPane[tab.focusedPaneId]
            ?? titleOverrideByPane[tab.rootPaneId]
            ?? runtimeTitleByPane[tab.rootPaneId]
            ?? tab.title
    }

    func workingDirectory(for paneId: UUID) -> String? {
        paneWorkingDirectory(for: paneId)
    }

    func shouldApplyWorkingDirectory(for paneId: UUID) -> Bool {
        guard let status = paneTmuxStatus(for: paneId) else { return false }
        return status == .off || status == .missing
    }

    func updatePaneTmuxStatus(_ paneId: UUID, status: TmuxStatus) {
        setPaneTmuxStatus(status, for: paneId)
    }

    // MARK: - tmux Integration

    private func setTmuxAttachPrompt(_ prompt: TmuxAttachPrompt?) {
        tmuxAttachPrompt = prompt
    }

    private func clearTmuxRuntimeState(for paneId: UUID) {
        tmuxResolver.clearRuntimeState(for: paneId, setPrompt: setTmuxAttachPrompt)
    }

    func resolveTmuxAttachPrompt(paneId: UUID, selection: TmuxAttachSelection) {
        tmuxResolver.resolvePrompt(entityId: paneId, selection: selection, setPrompt: setTmuxAttachPrompt)
    }

    func cancelTmuxAttachPrompt(paneId: UUID) {
        tmuxResolver.cancelPrompt(entityId: paneId, setPrompt: setTmuxAttachPrompt)
    }

    private func managedTmuxSessionNames(for serverId: UUID) -> Set<String> {
        var names: Set<String> = []
        for tab in tabs(for: serverId) {
            for paneId in tab.allPaneIds {
                let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
                guard ownership == .managed else { continue }
                names.insert(tmuxResolver.sessionName(for: paneId))
            }
        }
        return names
    }

    private func tmuxSessionNamesToKeep(
        for serverId: UUID,
        paneId: UUID,
        selection: TmuxAttachSelection
    ) -> Set<String> {
        var names = managedTmuxSessionNames(for: serverId)
        switch selection {
        case .skipTmux:
            break
        case .createManaged:
            names.insert(tmuxResolver.sessionName(for: paneId))
        case .attachExisting(let sessionName):
            names.insert(sessionName)
        }
        return names
    }

    private func currentTmuxStatus(for paneId: UUID, serverId: UUID) -> TmuxStatus {
        guard let tab = selectedTab(for: serverId) else { return .background }
        return (tab.id == selectedTabByServer[serverId] && tab.focusedPaneId == paneId) ? .foreground : .background
    }

    private func disableTmuxAttachment(for paneId: UUID, status: TmuxStatus) {
        tmuxResolver.clearAttachmentState(for: paneId)
        updatePaneTmuxStatus(paneId, status: status)
    }

    private func runTmuxCleanupIfNeeded(
        for serverId: UUID,
        paneId: UUID,
        selection: TmuxAttachSelection,
        using client: SSHClient
    ) async {
        var cleanupSet = tmuxCleanupServers
        await tmuxResolver.runCleanupIfNeeded(
            serverId: serverId,
            cleanupSet: &cleanupSet,
            managedNames: tmuxSessionNamesToKeep(for: serverId, paneId: paneId, selection: selection),
            using: client
        )
        tmuxCleanupServers = cleanupSet
    }

    private func prepareActiveTmuxPane(
        for paneId: UUID,
        serverId: UUID,
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async {
        updatePaneTmuxStatus(paneId, status: currentTmuxStatus(for: paneId, serverId: serverId))
        let terminalType = await client.remoteTerminalType()
        await RemoteTmuxManager.shared.prepareConfig(using: client, terminalType: terminalType, backend: backend)
    }

    private func immediateTmuxSelection(for paneId: UUID) -> TmuxAttachSelection {
        if tmuxResolver.sessionOwnership[paneId] == .external {
            return .attachExisting(sessionName: tmuxResolver.sessionName(for: paneId))
        }

        tmuxResolver.sessionNames[paneId] = tmuxResolver.managedSessionName(for: paneId)
        tmuxResolver.sessionOwnership[paneId] = .managed
        return .createManaged
    }

    private func tmuxStartupCommand(
        for paneId: UUID,
        selection: TmuxAttachSelection,
        workingDirectory: String,
        backend: RemoteTmuxBackend,
        lifecycleMarkerToken: String,
        reattachingManagedSession: Bool
    ) -> String? {
        switch selection {
        case .skipTmux:
            return nil
        case .createManaged:
            if reattachingManagedSession {
                return RemoteTmuxManager.shared.attachExistingCommand(
                    sessionName: tmuxResolver.sessionName(for: paneId),
                    backend: backend,
                    lifecycleMarkerToken: lifecycleMarkerToken
                )
            }
            return RemoteTmuxManager.shared.attachCommand(
                sessionName: tmuxResolver.sessionName(for: paneId),
                workingDirectory: workingDirectory,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken
            )
        case .attachExisting(let sessionName):
            return RemoteTmuxManager.shared.attachExistingCommand(
                sessionName: sessionName,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken
            )
        }
    }

    func shouldReattachManagedTmuxSession(for paneId: UUID) -> Bool {
        tmuxResolver.sessionOwnership[paneId] == .managed
            && tmuxResolver.sessionNames[paneId] != nil
            && tmuxResolver.hasConfirmedManagedSession(for: paneId)
    }

    private func resolveTmuxWorkingDirectory(for paneId: UUID, using client: SSHClient) async -> String {
        if let seedPaneId = paneStates[paneId]?.seedPaneId,
           let path = await RemoteTmuxManager.shared.currentPath(
               sessionName: tmuxResolver.sessionName(for: seedPaneId),
               using: client
           ) {
            setPaneWorkingDirectory(path, for: paneId)
            return path
        }

        if let path = await RemoteTmuxManager.shared.currentPath(
            sessionName: tmuxResolver.sessionName(for: paneId),
            using: client
        ) {
            setPaneWorkingDirectory(path, for: paneId)
            return path
        }

        if let candidate = paneWorkingDirectory(for: paneId)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidate.isEmpty {
            return candidate
        }

        return "~"
    }

    private func normalizeWorkingDirectory(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let schemeRange = trimmed.range(of: "://") {
            let afterScheme = trimmed[schemeRange.upperBound...]
            guard let pathStart = afterScheme.firstIndex(of: "/") else { return nil }
            let path = String(afterScheme[pathStart...])
            return path.removingPercentEncoding ?? path
        }

        return trimmed
    }

    private func updateTmuxSelectionStatuses() {
        for serverId in tabsByServer.keys {
            let tabsForServer = tabs(for: serverId)
            for tab in tabsForServer {
                updateTmuxFocus(for: tab)
            }
        }
    }

    private func updateTmuxFocus(for tab: TerminalTab) {
        let isSelectedTab = selectedTabByServer[tab.serverId] == tab.id
        for paneId in tab.allPaneIds {
            guard let state = paneStates[paneId] else { continue }
            guard state.tmuxStatus == .foreground || state.tmuxStatus == .background else { continue }
            let newStatus: TmuxStatus = (isSelectedTab && tab.focusedPaneId == paneId) ? .foreground : .background
            if state.tmuxStatus != newStatus {
                setPaneTmuxStatus(newStatus, for: paneId)
            }
        }
    }

    private func handleTmuxLifecycle(
        paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            await MainActor.run {
                self.disableTmuxAttachment(for: paneId, status: .off)
            }
            return
        }

        guard await client.supportsTmuxRuntime() else {
            logger.info("Resolved remote environment does not support tmux runtime for pane \(paneId.uuidString, privacy: .public); using plain SSH shell")
            await MainActor.run {
                self.disableTmuxAttachment(for: paneId, status: .off)
            }
            return
        }

        guard let backend = await RemoteTmuxManager.shared.tmuxBackend(using: client) else {
            await MainActor.run {
                self.disableTmuxAttachment(for: paneId, status: .missing)
            }
            return
        }

        let selection = immediateTmuxSelection(for: paneId)
        await runTmuxCleanupIfNeeded(for: serverId, paneId: paneId, selection: selection, using: client)
        await prepareActiveTmuxPane(for: paneId, serverId: serverId, using: client, backend: backend)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: client)
        guard let command = tmuxResolver.buildAttachExecCommand(
            for: paneId,
            selection: selection,
            workingDirectory: workingDirectory,
            backend: backend
        ) else {
            return
        }

        await RemoteTmuxManager.shared.sendScript(command, using: client, shellId: shellId)
    }

    func tmuxStartupPlan(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient
    ) async -> TerminalShellStartupPlan {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            disableTmuxAttachment(for: paneId, status: .off)
            return .plainShell
        }

        guard await client.supportsTmuxRuntime() else {
            disableTmuxAttachment(for: paneId, status: .off)
            return .plainShell
        }

        guard let backend = await RemoteTmuxManager.shared.tmuxBackend(using: client) else {
            disableTmuxAttachment(for: paneId, status: .missing)
            return .plainShell
        }

        let isReattachingManagedSession = shouldReattachManagedTmuxSession(for: paneId)
        let selection = await tmuxResolver.resolveSelection(
            for: paneId, serverId: serverId, client: client, setPrompt: setTmuxAttachPrompt
        )
        tmuxResolver.updateAttachmentState(for: paneId, selection: selection, setPrompt: setTmuxAttachPrompt)
        schedulePersist()

        if case .skipTmux = selection {
            updatePaneTmuxStatus(paneId, status: .off)
            return .plainShell
        }

        await runTmuxCleanupIfNeeded(for: serverId, paneId: paneId, selection: selection, using: client)
        await prepareActiveTmuxPane(for: paneId, serverId: serverId, using: client, backend: backend)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: client)
        guard let ownership = tmuxResolver.sessionOwnership[paneId] else {
            return .plainShell
        }
        let lifecycleMarkerToken = UUID().uuidString
        let sessionName = tmuxResolver.sessionName(for: paneId)
        let presenceToken = UUID().uuidString
        let existsMarker = "__VVTERM_TMUX_EXISTS_\(presenceToken)__"
        let missingMarker = "__VVTERM_TMUX_MISSING_\(presenceToken)__"
        return TerminalShellStartupPlan(
            command: tmuxStartupCommand(
                for: paneId,
                selection: selection,
                workingDirectory: workingDirectory,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken,
                reattachingManagedSession: isReattachingManagedSession
            ),
            skipTmuxLifecycle: true,
            tmuxLifecycle: TmuxShellLifecycleContext(
                ownership: ownership,
                markerToken: lifecycleMarkerToken,
                presenceProbe: TmuxSessionPresenceProbe(
                    command: RemoteTmuxManager.shared.sessionPresenceProbeCommand(
                        sessionName: sessionName,
                        backend: backend,
                        existsMarker: existsMarker,
                        missingMarker: missingMarker
                    ),
                    existsMarker: existsMarker,
                    missingMarker: missingMarker
                )
            )
        )
    }

    func startTmuxInstall(
        for paneId: UUID,
        onInstalled: @MainActor @escaping () -> Void
    ) async {
        guard let registration = shellRegistry.registration(for: paneId) else { return }
        let serverId = registration.serverId
        guard tmuxResolver.isTmuxEnabled(for: serverId) else { return }

        updatePaneTmuxStatus(paneId, status: .installing)

        guard let backend = await RemoteTmuxManager.shared.tmuxInstallBackend(using: registration.client) else {
            updatePaneTmuxStatus(paneId, status: .off)
            return
        }

        let sessionName = tmuxResolver.sessionName(for: paneId)
        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: registration.client)
        let terminalType = await registration.client.remoteTerminalType()
        let script = RemoteTmuxManager.shared.installAndAttachScript(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            terminalType: terminalType,
            backend: backend,
            attachAfterInstall: false
        )
        await RemoteTmuxManager.shared.sendScript(script, using: registration.client, shellId: registration.shellId)

        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(2))
            if await RemoteTmuxManager.shared.isTmuxAvailable(using: registration.client) {
                guard paneStates[paneId] != nil else { return }
                await unregisterSSHClient(for: paneId)
                completeTmuxInstall(
                    for: paneId,
                    sessionName: sessionName,
                    onInstalled: onInstalled
                )
                return
            }
        }
        updatePaneTmuxStatus(paneId, status: .missing)
    }

    func completeTmuxInstall(
        for paneId: UUID,
        sessionName: String,
        onInstalled: () -> Void
    ) {
        guard paneStates[paneId] != nil else { return }
        tmuxResolver.clearAttachmentState(for: paneId)
        tmuxResolver.sessionNames[paneId] = sessionName
        tmuxResolver.sessionOwnership[paneId] = .managed
        schedulePersist()
        onInstalled()
    }

    func installMoshServer(for paneId: UUID) async throws {
        guard let registration = shellRegistry.registration(for: paneId) else {
            throw SSHError.notConnected
        }
        try await RemoteMoshManager.shared.installMoshServer(using: registration.client)
    }

    private func managedTmuxSessionNameToKill(for paneId: UUID, status: TmuxStatus) -> String? {
        guard status == .foreground || status == .background || status == .installing else { return nil }
        let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
        guard ownership == .managed else { return nil }
        return tmuxResolver.sessionName(for: paneId)
    }

    func killTmuxIfNeeded(for paneId: UUID) {
        guard let registration = shellRegistry.registration(for: paneId) else { return }
        let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
        guard ownership == .managed else { return }

        let sessionName = tmuxResolver.sessionName(for: paneId)
        Task.detached { [client = registration.client, sessionName] in
            await RemoteTmuxManager.shared.killSession(named: sessionName, using: client)
        }
    }

    func disableTmux(for serverId: UUID) {
        for (paneId, state) in paneStates where state.serverId == serverId {
            setPaneTmuxStatus(.off, for: paneId)
            clearTmuxRuntimeState(for: paneId)
        }
    }

    // MARK: - Persistence

    private func makeServerSnapshots() -> [TerminalTabsSnapshot.ServerSnapshot] {
        tabsByServer.compactMap { serverId, tabs in
            guard !tabs.isEmpty else { return nil }
            return TerminalTabsSnapshot.ServerSnapshot(
                serverId: serverId,
                tabs: tabs.map {
                    TerminalTabsSnapshot.TabSnapshot(
                        from: $0,
                        paneStates: paneStates,
                        tmuxResolver: tmuxResolver
                    )
                },
                selectedTabId: selectedTabByServer[serverId],
                selectedView: selectedViewByServer[serverId]
            )
        }
    }

    private func makeSnapshot() -> TerminalTabsSnapshot {
        TerminalTabsSnapshot(servers: makeServerSnapshots())
    }

    private func makeRestoredPaneStates(
        from tabsByServer: [UUID: [TerminalTab]],
        snapshotsByTabId: [UUID: TerminalTabsSnapshot.TabSnapshot]
    ) -> [UUID: TerminalPaneState] {
        var restoredPaneStates: [UUID: TerminalPaneState] = [:]

        for tabs in tabsByServer.values {
            for tab in tabs {
                for paneId in tab.allPaneIds {
                    var paneState = TerminalPaneState(
                        paneId: paneId,
                        tabId: tab.id,
                        serverId: tab.serverId
                    )
                    paneState.connectionState = .disconnected
                    paneState.markConnectionEstablished()
                    if !tmuxResolver.isTmuxEnabled(for: tab.serverId) {
                        paneState.tmuxStatus = .off
                    }
                    paneState.presentationOverrides = snapshotsByTabId[tab.id]?.panePresentationOverrides?[paneId] ?? .empty
                    paneState.disconnectReason = snapshotsByTabId[tab.id]?.paneDisconnectReasons?[paneId]
                    restoredPaneStates[paneId] = paneState
                }
            }
        }

        return restoredPaneStates
    }

    private func applyRestoredSnapshot(_ snapshot: TerminalTabsSnapshot) {
        var restoredTabsByServer: [UUID: [TerminalTab]] = [:]
        var restoredSelectedTabs: [UUID: UUID] = [:]
        var restoredSelectedViews: [UUID: String] = [:]
        var snapshotsByTabId: [UUID: TerminalTabsSnapshot.TabSnapshot] = [:]

        for server in snapshot.servers {
            for tabSnapshot in server.tabs {
                snapshotsByTabId[tabSnapshot.id] = tabSnapshot
            }
            let tabs = server.tabs.map { $0.toTerminalTab() }
            guard !tabs.isEmpty else { continue }
            restoredTabsByServer[server.serverId] = tabs
            if let selected = server.selectedTabId {
                restoredSelectedTabs[server.serverId] = selected
            }
            if let view = server.selectedView {
                restoredSelectedViews[server.serverId] = view
            }
        }

        tabsByServer = restoredTabsByServer
        selectedTabByServer = restoredSelectedTabs
        selectedViewByServer = restoredSelectedViews
        tmuxResolver.clearAllAttachmentState()
        for tabSnapshot in snapshotsByTabId.values {
            for (paneId, attachment) in tabSnapshot.tmuxAttachments ?? [:] {
                tmuxResolver.sessionNames[paneId] = attachment.sessionName
                tmuxResolver.sessionOwnership[paneId] = attachment.ownership
                if attachment.managedSessionConfirmed == true {
                    tmuxResolver.confirmManagedSession(for: paneId)
                }
            }
        }
        paneStates = makeRestoredPaneStates(
            from: restoredTabsByServer,
            snapshotsByTabId: snapshotsByTabId
        )
        connectedServerIds = []
    }

    private func schedulePersist() {
        guard !isRestoring else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run {
                self?.persistSnapshot()
            }
        }
    }

    private func persistSnapshot() {
        do {
            let data = try JSONEncoder().encode(makeSnapshot())
            UserDefaults.standard.set(data, forKey: persistenceKey)
        } catch {
            logger.error("Failed to persist tabs snapshot: \(error.localizedDescription)")
        }
    }

    private func restoreSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else { return }
        do {
            let snapshot = try JSONDecoder().decode(TerminalTabsSnapshot.self, from: data)
            isRestoring = true
            applyRestoredSnapshot(snapshot)
        } catch {
            logger.error("Failed to restore tabs snapshot: \(error.localizedDescription)")
        }
        isRestoring = false
    }
}

// MARK: - Persistence Snapshot

private struct TerminalTabsSnapshot: Codable {
    struct ServerSnapshot: Codable {
        let serverId: UUID
        let tabs: [TabSnapshot]
        let selectedTabId: UUID?
        let selectedView: String?
    }

    struct TabSnapshot: Codable {
        let id: UUID
        let serverId: UUID
        let title: String
        let createdAt: Date
        let layout: TerminalSplitNode?
        let focusedPaneId: UUID
        let rootPaneId: UUID
        let panePresentationOverrides: [UUID: TerminalPresentationOverrides]?
        let paneDisconnectReasons: [UUID: TerminalDisconnectReason]?
        let tmuxAttachments: [UUID: TmuxAttachmentSnapshot]?

        init(
            from tab: TerminalTab,
            paneStates: [UUID: TerminalPaneState],
            tmuxResolver: TmuxAttachResolver
        ) {
            self.id = tab.id
            self.serverId = tab.serverId
            self.title = tab.title
            self.createdAt = tab.createdAt
            self.layout = tab.layout
            self.focusedPaneId = tab.focusedPaneId
            self.rootPaneId = tab.rootPaneId
            let overrides: [UUID: TerminalPresentationOverrides] = Dictionary(
                uniqueKeysWithValues: tab.allPaneIds.compactMap { paneId in
                    guard let overrides = paneStates[paneId]?.presentationOverrides,
                          !overrides.isEmpty else {
                        return nil
                    }
                    return (paneId, overrides)
                }
            )
            self.panePresentationOverrides = overrides.isEmpty ? nil : overrides
            let disconnectReasons: [UUID: TerminalDisconnectReason] = Dictionary(
                uniqueKeysWithValues: tab.allPaneIds.compactMap { paneId in
                    guard let reason = paneStates[paneId]?.disconnectReason else { return nil }
                    return (paneId, reason)
                }
            )
            self.paneDisconnectReasons = disconnectReasons.isEmpty ? nil : disconnectReasons
            let attachments: [UUID: TmuxAttachmentSnapshot] = Dictionary(
                uniqueKeysWithValues: tab.allPaneIds.compactMap { paneId in
                    guard let sessionName = tmuxResolver.sessionNames[paneId],
                          let ownership = tmuxResolver.sessionOwnership[paneId] else {
                        return nil
                    }
                    return (
                        paneId,
                        TmuxAttachmentSnapshot(
                            sessionName: sessionName,
                            ownership: ownership,
                            managedSessionConfirmed: ownership == .managed
                                && tmuxResolver.hasConfirmedManagedSession(for: paneId)
                        )
                    )
                }
            )
            self.tmuxAttachments = attachments.isEmpty ? nil : attachments
        }

        func toTerminalTab() -> TerminalTab {
            TerminalTab(
                id: id,
                serverId: serverId,
                title: title,
                createdAt: createdAt,
                rootPaneId: rootPaneId,
                focusedPaneId: focusedPaneId,
                layout: layout
            )
        }
    }

    struct TmuxAttachmentSnapshot: Codable {
        let sessionName: String
        let ownership: TmuxSessionOwnership
        let managedSessionConfirmed: Bool?
    }

    let servers: [ServerSnapshot]
}

#if DEBUG
extension TerminalTabManager {
    func beginBackgroundSuspensionForTesting(
        beforeCleanup: @MainActor @Sendable @escaping () async -> Void
    ) {
        beginBackgroundSuspension(beforeCleanup: beforeCleanup)
    }

    func unregisterSSHClientForTesting(
        for paneId: UUID,
        beforeCleanup: @MainActor @Sendable @escaping () async -> Void
    ) async {
        await unregisterSSHClient(
            for: paneId,
            killingManagedTmuxSessionNamed: nil,
            beforeCleanup: beforeCleanup
        )
    }

    func trackConnectionCleanupForTesting(
        for client: SSHClient,
        beforeCleanup: @MainActor @Sendable @escaping () async -> Void
    ) async {
        await performTrackedConnectionCleanup(for: client) {
            await beforeCleanup()
            await client.disconnect()
        }
    }

    func persistAndRestoreSnapshotForTesting() {
        persistTask?.cancel()
        persistTask = nil
        persistSnapshot()
        tmuxResolver.clearAllAttachmentState()
        restoreSnapshot()
    }

    /// Resets manager state for deterministic integration tests.
    func resetForTesting() async {
        persistTask?.cancel()
        persistTask = nil

        if case let .suspending(_, _, barrier) = connectionLifecycle {
            barrier.cancel()
        }
        connectionLifecycle = .foreground
        for retiredStart in retiredShellStarts.values {
            retiredStart.signal.finish()
        }
        retiredShellStarts.removeAll()

        let allPaneIds = Set(paneStates.keys)
            .union(shellRegistry.startsInFlight.keys)
        for paneId in allPaneIds {
            clearTmuxRuntimeState(for: paneId)
        }

        var uniqueClients: [ObjectIdentifier: SSHClient] = [:]
        for registration in shellRegistry.registrations.values {
            uniqueClients[ObjectIdentifier(registration.client)] = registration.client
        }
        for context in shellRegistry.startsInFlight.values {
            uniqueClients[ObjectIdentifier(context.client)] = context.client
        }
        for cleanup in connectionCleanupsInFlight.values {
            cleanup.task.cancel()
            uniqueClients[ObjectIdentifier(cleanup.client)] = cleanup.client
        }

        let terminals = Array(terminalViews.values)
        isRestoring = true
        tabsByServer = [:]
        selectedTabByServer = [:]
        connectedServerIds = []
        selectedViewByServer = [:]
        paneStates = [:]
        runtimeTitleByPane = [:]
        titleOverrideByPane = [:]
        #if os(iOS)
        terminalFindNavigatorVisibleByPane = [:]
        terminalVoiceRecordingByPane = [:]
        terminalPendingVoiceReturnByPane = [:]
        keyboardCoordinator.setActivePane(nil)
        keyboardCoordinator.setViewActive(false)
        #endif
        tmuxAttachPrompt = nil
        terminalRegistryVersion = 0
        terminalViews.removeAll()
        shellRegistry.removeAll()
        connectionCleanupsInFlight.removeAll()
        reconnectPreparationsInFlight.removeAll()
        tabOpensInFlight.removeAll()
        tmuxCleanupServers.removeAll()
        isRestoring = false

        UserDefaults.standard.removeObject(forKey: persistenceKey)
        for terminal in terminals {
            terminal.cleanup()
        }
        for client in uniqueClients.values {
            await client.disconnect()
        }
    }
}
#endif
