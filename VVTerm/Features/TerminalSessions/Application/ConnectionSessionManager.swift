import Foundation
import Combine
import os.log
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

@MainActor
final class ConnectionSessionManager: ObservableObject {
    static let shared = ConnectionSessionManager()

    private struct SSHUnregisterResult: Sendable {
        let shellToClose: (client: SSHClient, shellId: UUID)?
        let clientToDisconnect: SSHClient?
    }

    @Published var sessions: [ConnectionSession] = [] {
        didSet {
            LiveActivityManager.shared.refresh(with: sessions)
            schedulePersist()
        }
    }
    @Published var selectedSessionId: UUID? {
        didSet {
            schedulePersist()
            if let selectedSessionId,
               let session = sessions.first(where: { $0.id == selectedSessionId }) {
                selectedSessionByServer[session.serverId] = selectedSessionId
            }
            updateTmuxSelectionStatuses()
        }
    }

    /// Servers we're currently connected to (persists even when all terminals closed)
    /// Cleared when user explicitly disconnects from a server
    @Published var connectedServerIds: Set<UUID> = []

    /// Per-server view state (stats/terminal) - persists when switching servers
    @Published var selectedViewByServer: [UUID: String] = [:] {
        didSet { schedulePersist() }
    }

    /// Per-server selected terminal tab - persists when switching servers
    @Published var selectedSessionByServer: [UUID: UUID] = [:] {
        didSet { schedulePersist() }
    }

    @Published var tmuxAttachPrompt: TmuxAttachPrompt?
    @Published var terminalBrowseModeBySession: [UUID: Bool] = [:]
    @Published var terminalFindNavigatorVisibleBySession: [UUID: Bool] = [:]
    @Published private(set) var runtimeTitleBySession: [UUID: String] = [:]

    let tmuxResolver = TmuxAttachResolver()

    /// Legacy single server ID for backward compatibility
    var connectedServerId: UUID? {
        get { connectedServerIds.first }
        set {
            if let id = newValue {
                connectedServerIds.insert(id)
            } else {
                connectedServerIds.removeAll()
            }
        }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ConnectionSession")
    private var shellRegistry = SSHShellRegistry(staleThreshold: 120)

    /// Terminal views indexed by session ID for voice input and other external interactions
    private var terminalViews: [UUID: GhosttyTerminalView] = [:]
    /// Sessions whose preserved terminal must be reset before attaching a fresh shell.
    private var terminalsNeedingReconnectReset: Set<UUID> = []

    /// Shell cancel handlers indexed by session ID - called before closing to cancel async tasks
    private var shellCancelHandlers: [UUID: () -> Void] = [:]
    /// Shell suspend handlers indexed by session ID - cancel in-flight connects without destroying terminals
    private var shellSuspendHandlers: [UUID: () -> Void] = [:]
    /// Server IDs with an in-flight open request, used to collapse repeated clicks.
    private var sessionOpensInFlight: Set<UUID> = []
    @Published private(set) var isSuspendingForBackground = false

    /// Servers that already ran tmux cleanup (per app launch)
    private var tmuxCleanupServers: Set<UUID> = []

    // MARK: - LRU Terminal Cache

    /// Maximum number of terminal surfaces to keep in memory
    /// Each Ghostty surface uses ~50-100MB (font atlas, Metal textures, scrollback)
    private let maxTerminals = 20

    /// LRU access order - most recently accessed at the end
    private var terminalAccessOrder: [UUID] = []

    private let persistenceKey = "connectionSessionsSnapshot.v1"
    private var persistTask: Task<Void, Never>?
    private var isRestoring = false

    private init() {
        restoreSnapshot()
    }

    private func sessionWithID(_ sessionId: UUID) -> ConnectionSession? {
        sessions.first { $0.id == sessionId }
    }

    private func indexOfSession(_ sessionId: UUID) -> Int? {
        sessions.firstIndex { $0.id == sessionId }
    }

    private func firstSession(for serverId: UUID) -> ConnectionSession? {
        sessions.first { $0.serverId == serverId }
    }

    private func firstConnectedSession(for serverId: UUID) -> ConnectionSession? {
        sessions.first { $0.serverId == serverId && $0.connectionState.isConnected }
    }

    private func selectedSession(for serverId: UUID) -> ConnectionSession? {
        if let selectedSessionId = selectedSessionByServer[serverId] {
            return sessionWithID(selectedSessionId)
        }

        guard let selectedSessionId,
              let session = sessionWithID(selectedSessionId),
              session.serverId == serverId else {
            return nil
        }

        return session
    }

    private func sourceSessionForNewTab(on serverId: UUID) -> ConnectionSession? {
        if let selectedSessionId = selectedSessionByServer[serverId],
           let session = sessionWithID(selectedSessionId),
           session.serverId == serverId {
            return session
        }

        if let selectedSessionId,
           let session = sessionWithID(selectedSessionId),
           session.serverId == serverId {
            return session
        }

        return firstSession(for: serverId)
    }

    private func storedWorkingDirectory(for sessionId: UUID) -> String? {
        sessionWithID(sessionId)?.workingDirectory
    }

    private func setStoredWorkingDirectory(_ workingDirectory: String, for sessionId: UUID) {
        guard let index = indexOfSession(sessionId) else { return }
        sessions[index].workingDirectory = workingDirectory
    }

    private func tmuxStatus(for sessionId: UUID) -> TmuxStatus? {
        sessionWithID(sessionId)?.tmuxStatus
    }

    private func setTmuxStatus(_ status: TmuxStatus, for sessionId: UUID) {
        guard let index = indexOfSession(sessionId) else { return }
        sessions[index].tmuxStatus = status
    }

    private func setTransport(
        _ transport: ShellTransport,
        fallbackReason: MoshFallbackReason?,
        for sessionId: UUID
    ) {
        guard let index = indexOfSession(sessionId) else { return }
        sessions[index].activeTransport = transport
        sessions[index].moshFallbackReason = fallbackReason
    }

    private func handleStaleShellStartContext(
        _ staleContext: SSHShellRegistry.StartContext?,
        logMessage: StaticString,
        sessionId: UUID
    ) {
        guard let staleContext else { return }

        logger.warning("\(logMessage) \(sessionId.uuidString, privacy: .public)")
        if !shellRegistry.hasClientReferences(staleContext.client) {
            Task.detached(priority: .utility) { [client = staleContext.client] in
                await client.disconnect()
            }
        }
    }

    private func clearTmuxRuntimeState(for sessionId: UUID) {
        tmuxResolver.clearRuntimeState(for: sessionId, setPrompt: setTmuxAttachPrompt)
    }

    // MARK: - Session Management

    var selectedSession: ConnectionSession? {
        guard let id = selectedSessionId else { return nil }
        return sessionWithID(id)
    }

    var activeSessions: [ConnectionSession] {
        sessions.filter { $0.connectionState.isConnected || $0.connectionState.isConnecting }
    }

    var canOpenNewTab: Bool {
        if StoreManager.shared.isPro { return true }
        return activeSessions.count < FreeTierLimits.maxTabs
    }

    // MARK: - Open Connection

    /// Opens a connection to a server
    /// - Parameters:
    ///   - server: The server to connect to
    ///   - forceNew: If true, always creates a new tab even if one exists for this server
    func openConnection(to server: Server, forceNew: Bool = false) async throws -> ConnectionSession {
        // Check if server is locked due to downgrade
        if ServerManager.shared.isServerLocked(server) {
            throw VVTermError.serverLocked(server.name)
        }

        if sessionOpensInFlight.contains(server.id) {
            throw VVTermError.connectionFailed(
                String(localized: "A connection is already opening for this server.")
            )
        }
        sessionOpensInFlight.insert(server.id)
        defer { sessionOpensInFlight.remove(server.id) }

        guard await AppLockManager.shared.ensureServerUnlocked(server) else {
            throw VVTermError.authenticationFailed
        }

        // Check if already have a session for this server (unless forcing new)
        if !forceNew, let existingSession = firstSession(for: server.id) {
            selectedSessionId = existingSession.id
            return existingSession
        }

        guard canOpenNewTab else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for multiple connections"))
        }

        let sourceSession = sourceSessionForNewTab(on: server.id)
        var sourceWorkingDirectory = sourceSession?.workingDirectory
        if tmuxResolver.isTmuxEnabled(for: server.id),
           let sourceSession,
           let client = sshClient(for: sourceSession),
           let path = await RemoteTmuxManager.shared.currentPath(
               sessionName: tmuxResolver.sessionName(for: sourceSession.id),
               using: client
           ) {
            sourceWorkingDirectory = path
            if let index = indexOfSession(sourceSession.id) {
                sessions[index].workingDirectory = path
            }
        }

        // Create new session - actual SSH connection happens in SSHTerminalWrapper
        let session = ConnectionSession(
            serverId: server.id,
            title: server.name,
            connectionState: .connecting,  // Will connect when terminal view appears
            tmuxStatus: tmuxResolver.isTmuxEnabled(for: server.id) ? .unknown : .off,
            workingDirectory: sourceWorkingDirectory
        )

        sessions.append(session)
        selectedSessionId = session.id
        connectedServerId = server.id

        // Update server's last connected after the navigation animation completes
        Task { [server] in
            try? await Task.sleep(for: .milliseconds(350))
            await ServerManager.shared.updateLastConnected(for: server)
        }

        logger.info("Created session for \(server.name)")
        return session
    }

    // MARK: - Connection State Updates

    func updateSessionState(_ sessionId: UUID, to state: ConnectionState) {
        guard let index = indexOfSession(sessionId) else { return }

        sessions[index].connectionState = state
        let serverId = sessions[index].serverId

        switch state {
        case .connected:
            connectedServerIds.insert(serverId)
        case .disconnected, .failed:
            if sessions[index].tmuxStatus == .foreground {
                setTmuxStatus(.background, for: sessionId)
            }
            let hasOtherConnections = sessions.contains {
                $0.serverId == serverId && $0.connectionState.isConnected
            }
            if !hasOtherConnections {
                connectedServerIds.remove(serverId)
            }
        case .connecting, .reconnecting:
            sessions[index].activeTransport = .ssh
            sessions[index].moshFallbackReason = nil
        case .idle:
            break
        }
    }

    func sessionState(for sessionId: UUID) -> ConnectionState? {
        sessionWithID(sessionId)?.connectionState
    }

    func hasOtherActiveSessions(for serverId: UUID, excluding sessionId: UUID) -> Bool {
        sessions.contains {
            $0.serverId == serverId
                && $0.id != sessionId
                && $0.connectionState.isConnected
        }
    }

    /// Returns true when the same SSH client instance is registered to another live session.
    /// This is used to avoid disconnecting a truly shared client during retry cleanup.
    func hasOtherRegistrations(using client: SSHClient, excluding sessionId: UUID) -> Bool {
        shellRegistry.hasOtherRegistrations(using: client, excluding: sessionId)
    }

    func updateTmuxStatus(_ sessionId: UUID, status: TmuxStatus) {
        setTmuxStatus(status, for: sessionId)
    }

    func updateSessionWorkingDirectory(_ sessionId: UUID, rawDirectory: String) {
        guard let normalized = normalizeWorkingDirectory(rawDirectory) else { return }
        setStoredWorkingDirectory(normalized, for: sessionId)
    }

    func updateSessionTitle(_ sessionId: UUID, rawTitle: String) {
        guard sessionWithID(sessionId) != nil else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard runtimeTitleBySession[sessionId] != title else { return }

        runtimeTitleBySession[sessionId] = title
        logger.info("Runtime session title changed: \(title, privacy: .public)")
    }

    func displayTitle(for session: ConnectionSession) -> String {
        runtimeTitleBySession[session.id] ?? session.title
    }

    // MARK: - Close Terminal

    /// Closes a terminal session and removes it from the list
    func closeSession(_ session: ConnectionSession) {
        let sessionId = session.id
        let title = session.title
        let wasSelected = selectedSessionId == sessionId

        if session.tmuxStatus == .foreground || session.tmuxStatus == .background || session.tmuxStatus == .installing {
            killTmuxIfNeeded(for: sessionId)
        }

        let replacementSessionId = replacementSessionIDAfterClosing(
            sessionId: sessionId,
            serverId: session.serverId,
            wasSelected: wasSelected
        )

        clearRuntimeStateForClosedSession(sessionId)

        // Remove from UI immediately
        sessions.removeAll { $0.id == sessionId }

        // Select another session if this was selected (prefer same server)
        if wasSelected {
            selectedSessionId = replacementSessionId
        }

        handleTerminalCloseUI(
            sessionId: sessionId,
            wasSelected: wasSelected,
            replacementSessionId: replacementSessionId
        )

        // Disconnect SSH client in background
        scheduleSSHUnregister(for: sessionId, priority: .high)

        if let selectedId = replacementSessionId ?? selectedSessionId,
           let selectedSession = sessionWithID(selectedId) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.redrawSessionAfterClose(selectedSession)
            }
        }

        logger.info("Closed terminal session \(title)")
    }

    private func replacementSessionIDAfterClosing(
        sessionId: UUID,
        serverId: UUID,
        wasSelected: Bool
    ) -> UUID? {
        guard wasSelected else { return nil }

        let serverSessions = sessions.filter { $0.serverId == serverId }
        if let index = serverSessions.firstIndex(where: { $0.id == sessionId }) {
            if index + 1 < serverSessions.count {
                return serverSessions[index + 1].id
            }
            if index > 0 {
                return serverSessions[index - 1].id
            }
        }

        return sessions.first(where: { $0.id != sessionId })?.id
    }

    private func clearRuntimeStateForClosedSession(_ sessionId: UUID) {
        cancelAndClearShellHandlers(for: sessionId)
        terminalsNeedingReconnectReset.remove(sessionId)
        terminalBrowseModeBySession.removeValue(forKey: sessionId)
        clearTmuxRuntimeState(for: sessionId)
        runtimeTitleBySession.removeValue(forKey: sessionId)
    }

    private func handleTerminalCloseUI(
        sessionId: UUID,
        wasSelected: Bool,
        replacementSessionId: UUID?
    ) {
        if let terminal = terminalViews[sessionId], terminal.window != nil {
            terminal.pauseRendering()
            if !wasSelected {
                _ = terminal.resignFirstResponder()
            }
        } else {
            unregisterTerminal(for: sessionId)
        }

        guard let replacementSessionId,
              let replacementTerminal = terminalViews[replacementSessionId],
              replacementTerminal.window != nil else {
            return
        }

        DispatchQueue.main.async {
            #if os(iOS)
            guard UIApplication.shared.applicationState == .active else { return }
            replacementTerminal.requestKeyboardFocus(for: .initialActivation)
            #else
            _ = replacementTerminal.window?.makeFirstResponder(replacementTerminal)
            #endif
        }
    }

    private func redrawSessionAfterClose(_ session: ConnectionSession) {
        guard let terminal = terminalViews[session.id] else { return }
        terminal.resumeRendering()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak terminal] in
            guard let terminal = terminal else { return }
            terminal.forceRefresh()

            if let size = terminal.terminalSize(),
               let client = self?.sshClient(for: session),
               let shellId = self?.shellId(for: session) {
                Task {
                    try? await client.resize(cols: Int(size.columns), rows: Int(size.rows), for: shellId)
                }
            }

            // Nudge the shell to redraw the prompt after layout changes without adding a new line.
            #if os(iOS)
            terminal.sendText("\u{0C}")
            #endif
        }
    }

    // MARK: - Disconnect All

    /// Fully disconnects all sessions for a server and clears connection state
    func disconnectAll() {
        let sessionsToClose = sessions
        for session in sessionsToClose {
            closeSession(session)
        }
        connectedServerId = nil
        logger.info("Disconnected all sessions")
    }

    /// Disconnects all sessions without removing tabs (used when app backgrounds)
    func suspendAllForBackground() async {
        guard !isSuspendingForBackground else { return }
        isSuspendingForBackground = true
        defer { isSuspendingForBackground = false }

        pauseCachedTerminalsForBackground()
        let sessionsToSuspend = sessions
        var unregisterResults: [SSHUnregisterResult] = []
        unregisterResults.reserveCapacity(sessionsToSuspend.count)
        for session in sessionsToSuspend {
            if session.connectionState.isConnected || session.connectionState.isConnecting {
                updateSessionState(session.id, to: .disconnected)
                markTerminalForReconnectReset(for: session.id)
            }
            // Cancel any in-flight connects while preserving terminal state
            shellSuspendHandlers[session.id]?()
            unregisterResults.append(takeSSHClientRegistration(for: session.id))
        }

        if unregisterResults.contains(where: { $0.shellToClose != nil || $0.clientToDisconnect != nil }) {
            await withTaskGroup(of: Void.self) { group in
                for unregisterResult in unregisterResults {
                    group.addTask {
                        await ConnectionSessionManager.finishSSHCleanup(for: unregisterResult)
                    }
                }
            }
        }

        logger.info("Suspended all sessions for background")
    }

    /// Handle shell exit without removing the session (keeps tab for reconnect)
    func handleShellExit(for sessionId: UUID) {
        updateSessionState(sessionId, to: .disconnected)
        markTerminalForReconnectReset(for: sessionId)
        scheduleSSHUnregister(for: sessionId)
    }

    /// Disconnect all sessions for a specific server
    func disconnectServer(_ serverId: UUID) {
        let sessionsToClose = sessions.filter { $0.serverId == serverId }
        for session in sessionsToClose {
            closeSession(session)
        }
        connectedServerIds.remove(serverId)
        if connectedServerIds.isEmpty {
            connectedServerId = nil
        }
        logger.info("Disconnected all sessions for server \(serverId)")
    }

    // MARK: - Tab Navigation

    func selectSession(_ session: ConnectionSession) {
        selectedSessionId = session.id
    }

    func selectPreviousSession() {
        guard let currentId = selectedSessionId,
              let currentIndex = indexOfSession(currentId),
              currentIndex > 0 else { return }
        selectedSessionId = sessions[currentIndex - 1].id
    }

    func selectNextSession() {
        guard let currentId = selectedSessionId,
              let currentIndex = indexOfSession(currentId),
              currentIndex < sessions.count - 1 else { return }
        selectedSessionId = sessions[currentIndex + 1].id
    }

    func selectSession(at index: Int) {
        guard index >= 0 && index < sessions.count else { return }
        selectedSessionId = sessions[index].id
    }

    // MARK: - Close Operations

    func closeOtherSessions(except session: ConnectionSession) {
        let toClose = sessions.filter { $0.id != session.id }
        for s in toClose {
            closeSession(s)
        }
    }

    func closeSessionsToLeft(of session: ConnectionSession) {
        guard let index = indexOfSession(session.id) else { return }
        let toClose = Array(sessions[..<index])
        for s in toClose {
            closeSession(s)
        }
    }

    func closeSessionsToRight(of session: ConnectionSession) {
        guard let index = indexOfSession(session.id) else { return }
        let toClose = Array(sessions[(index + 1)...])
        for s in toClose {
            closeSession(s)
        }
    }

    // MARK: - SSH Client Registration

    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        for sessionId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        skipTmuxLifecycle: Bool = false
    ) {
        let registerResult = shellRegistry.register(
            client: client,
            shellId: shellId,
            for: sessionId,
            serverId: serverId,
            transport: transport,
            fallbackReason: fallbackReason
        )

        if let stale = registerResult.staleIncomingShell {
            logger.warning("Ignoring stale shell registration for session \(sessionId.uuidString, privacy: .public)")
            Task.detached(priority: .utility) { [client = stale.client, shellId = stale.shellId] in
                await client.closeShell(shellId)
                await client.disconnect()
            }
            return
        }

        if let replaced = registerResult.replacedShell {
            Task.detached { [client = replaced.client, shellId = replaced.shellId] in
                await client.closeShell(shellId)
            }
        }

        setTransport(transport, fallbackReason: fallbackReason, for: sessionId)
        terminalsNeedingReconnectReset.remove(sessionId)

        if !skipTmuxLifecycle {
            Task { [weak self] in
                await self?.handleTmuxLifecycle(sessionId: sessionId, serverId: serverId, client: client, shellId: shellId)
            }
        }
    }

    func unregisterSSHClient(for sessionId: UUID) async {
        let unregisterResult = takeSSHClientRegistration(for: sessionId)
        await Self.finishSSHCleanup(for: unregisterResult)
    }

    func sshClient(for session: ConnectionSession) -> SSHClient? {
        shellRegistry.client(for: session.id)
    }

    func sshClient(forSessionId sessionId: UUID) -> SSHClient? {
        shellRegistry.client(for: sessionId)
    }

    func shellId(for session: ConnectionSession) -> UUID? {
        shellRegistry.shellId(for: session.id)
    }

    func shellId(for sessionId: UUID) -> UUID? {
        shellRegistry.shellId(for: sessionId)
    }

    /// Returns true only for the first caller while no live shell exists for the session.
    func tryBeginShellStart(for sessionId: UUID, client: SSHClient) -> Bool {
        guard let serverId = sessionWithID(sessionId)?.serverId else {
            return false
        }

        let startResult = shellRegistry.tryBeginStart(
            for: sessionId,
            serverId: serverId,
            client: client
        )

        handleStaleShellStartContext(
            startResult.staleContext,
            logMessage: "Recovered stale session shell-start lock for",
            sessionId: sessionId
        )
        return startResult.started
    }

    func finishShellStart(for sessionId: UUID, client: SSHClient) {
        shellRegistry.finishStart(for: sessionId, client: client)
    }

    func isShellStartInFlight(for sessionId: UUID) -> Bool {
        let result = shellRegistry.isStartInFlight(for: sessionId)
        handleStaleShellStartContext(
            result.staleContext,
            logMessage: "Cleared stale session shell-start in-flight flag for",
            sessionId: sessionId
        )
        return result.inFlight
    }

    private func preferredSSHClient(for serverId: UUID, allowPendingStart: Bool) -> SSHClient? {
        if let selectedId = selectedSessionId,
           let selectedSession = sessionWithID(selectedId),
           selectedSession.serverId == serverId,
           let client = shellRegistry.client(for: selectedSession.id) {
            return client
        }

        if let anySession = firstSession(for: serverId),
           let client = shellRegistry.client(for: anySession.id) {
            return client
        }

        if let client = shellRegistry.firstRegisteredClient(for: serverId) {
            return client
        }

        if allowPendingStart, let client = shellRegistry.firstPendingClient(for: serverId) {
            return client
        }

        return nil
    }

    func sshClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: true)
    }

    func activeSSHClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: false)
    }

    func sharedStatsClient(for serverId: UUID) -> SSHClient? {
        if selectedTransport(for: serverId) == .mosh {
            return nil
        }
        return sshClient(for: serverId)
    }

    private func selectedTransport(for serverId: UUID) -> ShellTransport {
        if let session = selectedSession(for: serverId) {
            return session.activeTransport
        }

        if let connected = firstConnectedSession(for: serverId) {
            return connected.activeTransport
        }

        return firstSession(for: serverId)?.activeTransport ?? .ssh
    }

    // MARK: - Terminal Registration (with LRU caching)

    func registerTerminal(_ terminal: GhosttyTerminalView, for sessionId: UUID) {
        // Evict oldest terminals if we're at capacity
        evictOldTerminalsIfNeeded()

        #if os(iOS)
        terminal.onKeyboardBrowseModeChange = { [weak self] isBrowsing in
            Task { @MainActor [weak self] in
                self?.setTerminalBrowseMode(isBrowsing, for: sessionId)
            }
        }
        terminal.onFindNavigatorVisibilityChange = { [weak self] isVisible in
            Task { @MainActor [weak self] in
                self?.setTerminalFindNavigatorVisible(isVisible, for: sessionId)
            }
        }
        #endif
        terminalViews[sessionId] = terminal
        #if os(iOS)
        Task { @MainActor [weak self, weak terminal] in
            guard let self, let terminal, self.terminalViews[sessionId] === terminal else { return }
            self.setTerminalBrowseMode(terminal.isKeyboardInBrowseMode, for: sessionId)
            self.setTerminalFindNavigatorVisible(terminal.isFindNavigatorVisible, for: sessionId)
        }
        #endif
        touchTerminal(sessionId)

        logger.debug("Registered terminal for session, total: \(self.terminalViews.count)/\(self.maxTerminals)")
    }

    func unregisterTerminal(for sessionId: UUID) {
        cleanupTerminalSurface(for: sessionId)
        terminalsNeedingReconnectReset.remove(sessionId)
        #if os(iOS)
        Task { @MainActor [weak self] in
            self?.terminalBrowseModeBySession.removeValue(forKey: sessionId)
            self?.terminalFindNavigatorVisibleBySession.removeValue(forKey: sessionId)
        }
        #else
        terminalBrowseModeBySession.removeValue(forKey: sessionId)
        terminalFindNavigatorVisibleBySession.removeValue(forKey: sessionId)
        #endif
        removeTerminalFromAccessOrder(sessionId)
        logger.debug("Unregistered terminal, remaining: \(self.terminalViews.count)")
    }

    /// Update access order for LRU tracking
    private func touchTerminal(_ sessionId: UUID) {
        removeTerminalFromAccessOrder(sessionId)
        terminalAccessOrder.append(sessionId)
    }

    private func cleanupTerminalSurface(for sessionId: UUID) {
        if let terminal = terminalViews.removeValue(forKey: sessionId) {
            #if os(iOS)
            terminal.onKeyboardBrowseModeChange = nil
            terminal.onFindNavigatorVisibilityChange = nil
            #endif
            terminal.cleanup()
        }
    }

    private func setTerminalBrowseMode(_ isBrowsing: Bool, for sessionId: UUID) {
        if terminalBrowseModeBySession[sessionId] != isBrowsing {
            terminalBrowseModeBySession[sessionId] = isBrowsing
        }
    }

    private func setTerminalFindNavigatorVisible(_ isVisible: Bool, for sessionId: UUID) {
        if terminalFindNavigatorVisibleBySession[sessionId] != isVisible {
            terminalFindNavigatorVisibleBySession[sessionId] = isVisible
        }
    }

    private func removeTerminalFromAccessOrder(_ sessionId: UUID) {
        terminalAccessOrder.removeAll { $0 == sessionId }
    }

    /// Evict least recently used terminals if over capacity
    private func evictOldTerminalsIfNeeded() {
        while terminalViews.count >= maxTerminals, let oldestId = terminalAccessOrder.first {
            // Don't evict the currently selected session
            if oldestId == selectedSessionId {
                terminalAccessOrder.removeFirst()
                terminalAccessOrder.append(oldestId)
                continue
            }

            logger.info("Evicting oldest terminal to free memory (count: \(self.terminalViews.count))")

            // Remove from access order
            terminalAccessOrder.removeFirst()

            // Cleanup and remove terminal
            cleanupTerminalSurface(for: oldestId)

            // Also cleanup associated SSH shell
            scheduleSSHUnregister(for: oldestId)

            // Call shell cancel handler
            cancelAndClearShellHandlers(for: oldestId)
        }
    }

    // MARK: - Shell Cancel Handler Registration

    func registerShellCancelHandler(_ handler: @escaping () -> Void, for sessionId: UUID) {
        shellCancelHandlers[sessionId] = handler
    }

    func unregisterShellCancelHandler(for sessionId: UUID) {
        shellCancelHandlers.removeValue(forKey: sessionId)
    }

    func registerShellSuspendHandler(_ handler: @escaping () -> Void, for sessionId: UUID) {
        shellSuspendHandlers[sessionId] = handler
    }

    func unregisterShellSuspendHandler(for sessionId: UUID) {
        shellSuspendHandlers.removeValue(forKey: sessionId)
    }

    private func pauseCachedTerminalsForBackground() {
        #if os(iOS)
        for terminal in terminalViews.values {
            terminal.pauseRendering()
            if terminal.isFirstResponder {
                terminal.markKeyboardFocusForReconnect()
            }
            _ = terminal.resignFirstResponder()
        }
        #endif
    }

    func getTerminal(for sessionId: UUID) -> GhosttyTerminalView? {
        if let terminal = terminalViews[sessionId] {
            touchTerminal(sessionId)
            return terminal
        }
        return nil
    }

    /// Returns a terminal without mutating LRU state.
    func peekTerminal(for sessionId: UUID) -> GhosttyTerminalView? {
        terminalViews[sessionId]
    }

    /// Returns whether a terminal exists without mutating LRU state.
    func hasTerminal(for sessionId: UUID) -> Bool {
        terminalViews[sessionId] != nil
    }

    func markTerminalForReconnectReset(for sessionId: UUID) {
        terminalsNeedingReconnectReset.insert(sessionId)
    }

    func consumeTerminalReconnectReset(for sessionId: UUID) -> Bool {
        terminalsNeedingReconnectReset.remove(sessionId) != nil
    }

    private func cancelAndClearShellHandlers(for sessionId: UUID) {
        shellCancelHandlers[sessionId]?()
        shellCancelHandlers.removeValue(forKey: sessionId)
        shellSuspendHandlers.removeValue(forKey: sessionId)
    }

    private func scheduleSSHUnregister(for sessionId: UUID, priority: TaskPriority = .utility) {
        Task.detached(priority: priority) { [weak self] in
            await self?.unregisterSSHClient(for: sessionId)
        }
    }

    /// Marks an existing terminal as recently used without fetching it for body evaluation.
    func markTerminalUsed(for sessionId: UUID) {
        guard terminalViews[sessionId] != nil else { return }
        touchTerminal(sessionId)
    }

    /// Send text to the terminal for a given session (used by voice input)
    func sendText(_ text: String, to sessionId: UUID) {
        guard let terminal = terminalViews[sessionId] else { return }
        terminal.sendText(text)
    }

    // MARK: - Reconnection

    func reconnect(session: ConnectionSession) async throws {
        guard !isSuspendingForBackground else { return }
        guard let serverManager = ServerManager.shared as ServerManager?,
              serverManager.servers.contains(where: { $0.id == session.serverId }) else {
            throw SSHError.connectionFailed("Server not found")
        }

        if let current = sessionWithID(session.id),
           current.connectionState.isConnecting {
            return
        }

        // Update state
        if let index = indexOfSession(session.id) {
            sessions[index].connectionState = .reconnecting(attempt: 1)
        }
        markTerminalForReconnectReset(for: session.id)

        // Cancel in-flight shell work but keep the terminal surface for reuse
        shellSuspendHandlers[session.id]?()

        // Disconnect existing SSH client
        await unregisterSSHClient(for: session.id)
    }

    private func takeSSHClientRegistration(for sessionId: UUID) -> SSHUnregisterResult {
        let unregisterResult = shellRegistry.unregister(for: sessionId)
        var shellToClose: (client: SSHClient, shellId: UUID)?
        var clientToDisconnect: SSHClient?

        if let registration = unregisterResult.registration {
            shellToClose = (client: registration.client, shellId: registration.shellId)
            if !shellRegistry.hasClientReferences(registration.client) {
                clientToDisconnect = registration.client
            }
        } else if let pendingStart = unregisterResult.pendingStart,
                  !shellRegistry.hasClientReferences(pendingStart.client) {
            clientToDisconnect = pendingStart.client
        }

        if unregisterResult.registration != nil {
            setTransport(.ssh, fallbackReason: nil, for: sessionId)
        }

        return SSHUnregisterResult(
            shellToClose: shellToClose,
            clientToDisconnect: clientToDisconnect
        )
    }

    private static func finishSSHCleanup(for unregisterResult: SSHUnregisterResult) async {
        if let shellToClose = unregisterResult.shellToClose {
            await shellToClose.client.closeShell(shellToClose.shellId)
        }

        if let clientToDisconnect = unregisterResult.clientToDisconnect {
            await clientToDisconnect.disconnect()
        }
    }

}

// MARK: - Persistence

extension ConnectionSessionManager {
    private func makeServerSnapshots() -> [ConnectionSessionsSnapshot.ServerSnapshot] {
        Set(sessions.map(\.serverId)).map { serverId in
            ConnectionSessionsSnapshot.ServerSnapshot(
                serverId: serverId,
                selectedSessionId: selectedSessionByServer[serverId],
                selectedView: selectedViewByServer[serverId]
            )
        }
    }

    private func makeSnapshot() -> ConnectionSessionsSnapshot {
        ConnectionSessionsSnapshot(
            sessions: sessions.map { ConnectionSessionsSnapshot.SessionSnapshot(from: $0) },
            selectedSessionId: selectedSessionId,
            serverSelections: makeServerSnapshots()
        )
    }

    private func applyRestoredSnapshot(_ snapshot: ConnectionSessionsSnapshot) {
        var restoredSessions = snapshot.sessions.map { $0.toSession() }
        for index in restoredSessions.indices {
            let serverId = restoredSessions[index].serverId
            if !tmuxResolver.isTmuxEnabled(for: serverId) {
                restoredSessions[index].tmuxStatus = .off
            }
        }

        sessions = restoredSessions
        selectedSessionId = snapshot.selectedSessionId
        selectedSessionByServer = Dictionary(
            uniqueKeysWithValues: snapshot.serverSelections.compactMap { snapshot in
                guard let selected = snapshot.selectedSessionId else { return nil }
                return (snapshot.serverId, selected)
            }
        )
        selectedViewByServer = Dictionary(
            uniqueKeysWithValues: snapshot.serverSelections.compactMap { snapshot in
                guard let view = snapshot.selectedView else { return nil }
                return (snapshot.serverId, view)
            }
        )
        connectedServerIds = Set(restoredSessions.map(\.serverId))
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
            logger.error("Failed to persist session snapshot: \(error.localizedDescription)")
        }
    }

    private func restoreSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else { return }
        do {
            let snapshot = try JSONDecoder().decode(ConnectionSessionsSnapshot.self, from: data)
            isRestoring = true
            applyRestoredSnapshot(snapshot)
        } catch {
            logger.error("Failed to restore session snapshot: \(error.localizedDescription)")
        }
        isRestoring = false
    }
}

private struct ConnectionSessionsSnapshot: Codable {
    struct SessionSnapshot: Codable {
        let id: UUID
        let serverId: UUID
        let title: String
        let createdAt: Date
        let lastActivity: Date
        let autoReconnect: Bool
        let parentSessionId: UUID?
        let workingDirectory: String?

        init(from session: ConnectionSession) {
            self.id = session.id
            self.serverId = session.serverId
            self.title = session.title
            self.createdAt = session.createdAt
            self.lastActivity = session.lastActivity
            self.autoReconnect = session.autoReconnect
            self.parentSessionId = session.parentSessionId
            self.workingDirectory = session.workingDirectory
        }

        func toSession() -> ConnectionSession {
            ConnectionSession(
                id: id,
                serverId: serverId,
                title: title,
                connectionState: .disconnected,
                createdAt: createdAt,
                lastActivity: lastActivity,
                terminalSurfaceId: nil,
                autoReconnect: autoReconnect,
                workingDirectory: workingDirectory,
                parentSessionId: parentSessionId
            )
        }
    }

    struct ServerSnapshot: Codable {
        let serverId: UUID
        let selectedSessionId: UUID?
        let selectedView: String?
    }

    let sessions: [SessionSnapshot]
    let selectedSessionId: UUID?
    let serverSelections: [ServerSnapshot]
}

// MARK: - tmux Integration

extension ConnectionSessionManager {
    private func resolveTmuxWorkingDirectory(for sessionId: UUID, using client: SSHClient) async -> String {
        if let path = await RemoteTmuxManager.shared.currentPath(
            sessionName: tmuxResolver.sessionName(for: sessionId),
            using: client
        ) {
            setStoredWorkingDirectory(path, for: sessionId)
            return path
        }

        if let candidate = storedWorkingDirectory(for: sessionId)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidate.isEmpty {
            return candidate
        }

        return "~"
    }

    func workingDirectory(for sessionId: UUID) -> String? {
        storedWorkingDirectory(for: sessionId)
    }

    func shouldApplyWorkingDirectory(for sessionId: UUID) -> Bool {
        guard let status = tmuxStatus(for: sessionId) else { return false }
        return status == .off || status == .missing
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
        guard let selectedId = selectedSessionId else {
            for index in sessions.indices {
                if sessions[index].tmuxStatus == .foreground {
                    setTmuxStatus(.background, for: sessions[index].id)
                }
            }
            return
        }
        for index in sessions.indices {
            let status = sessions[index].tmuxStatus
            guard status == .foreground || status == .background else { continue }
            setTmuxStatus((sessions[index].id == selectedId) ? .foreground : .background, for: sessions[index].id)
        }
    }

    private func managedTmuxSessionNames(for serverId: UUID) -> Set<String> {
        var names: Set<String> = []
        for session in sessions where session.serverId == serverId {
            let ownership = tmuxResolver.sessionOwnership[session.id] ?? .managed
            guard ownership == .managed else { continue }
            names.insert(tmuxResolver.sessionName(for: session.id))
        }
        return names
    }

    private func tmuxSessionNamesToKeep(
        for serverId: UUID,
        sessionId: UUID,
        selection: TmuxAttachSelection
    ) -> Set<String> {
        var names = managedTmuxSessionNames(for: serverId)
        switch selection {
        case .skipTmux:
            break
        case .createManaged:
            names.insert(tmuxResolver.sessionName(for: sessionId))
        case .attachExisting(let sessionName):
            names.insert(sessionName)
        }
        return names
    }

    private func setTmuxAttachPrompt(_ prompt: TmuxAttachPrompt?) {
        tmuxAttachPrompt = prompt
    }

    func resolveTmuxAttachPrompt(sessionId: UUID, selection: TmuxAttachSelection) {
        tmuxResolver.resolvePrompt(entityId: sessionId, selection: selection, setPrompt: setTmuxAttachPrompt)
    }

    func cancelTmuxAttachPrompt(sessionId: UUID) {
        tmuxResolver.cancelPrompt(entityId: sessionId, setPrompt: setTmuxAttachPrompt)
    }

    private func currentTmuxStatus(for sessionId: UUID) -> TmuxStatus {
        selectedSessionId == sessionId ? .foreground : .background
    }

    private func disableTmuxAttachment(for sessionId: UUID, status: TmuxStatus) {
        tmuxResolver.clearAttachmentState(for: sessionId)
        updateTmuxStatus(sessionId, status: status)
    }

    private func runTmuxCleanupIfNeeded(
        for serverId: UUID,
        sessionId: UUID,
        selection: TmuxAttachSelection,
        using client: SSHClient
    ) async {
        var cleanupSet = tmuxCleanupServers
        await tmuxResolver.runCleanupIfNeeded(
            serverId: serverId,
            cleanupSet: &cleanupSet,
            managedNames: tmuxSessionNamesToKeep(for: serverId, sessionId: sessionId, selection: selection),
            using: client
        )
        tmuxCleanupServers = cleanupSet
    }

    private func prepareActiveTmuxSession(for sessionId: UUID, using client: SSHClient) async {
        updateTmuxStatus(sessionId, status: currentTmuxStatus(for: sessionId))
        let terminalType = await client.remoteTerminalType()
        await RemoteTmuxManager.shared.prepareConfig(using: client, terminalType: terminalType)
    }

    private func immediateTmuxSelection(for sessionId: UUID) -> TmuxAttachSelection {
        if tmuxResolver.sessionOwnership[sessionId] == .external {
            return .attachExisting(sessionName: tmuxResolver.sessionName(for: sessionId))
        }

        tmuxResolver.sessionNames[sessionId] = tmuxResolver.managedSessionName(for: sessionId)
        tmuxResolver.sessionOwnership[sessionId] = .managed
        return .createManaged
    }

    private func tmuxStartupCommand(
        for sessionId: UUID,
        selection: TmuxAttachSelection,
        workingDirectory: String
    ) -> String? {
        switch selection {
        case .skipTmux:
            return nil
        case .createManaged:
            return RemoteTmuxManager.shared.attachCommand(
                sessionName: tmuxResolver.sessionName(for: sessionId),
                workingDirectory: workingDirectory
            )
        case .attachExisting(let sessionName):
            return RemoteTmuxManager.shared.attachExistingCommand(sessionName: sessionName)
        }
    }

    private func handleTmuxLifecycle(
        sessionId: UUID,
        serverId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            await MainActor.run {
                self.disableTmuxAttachment(for: sessionId, status: .off)
            }
            return
        }

        guard await client.supportsTmuxRuntime() else {
            logger.info("Resolved remote environment does not support tmux runtime for session \(sessionId.uuidString, privacy: .public); using plain SSH shell")
            await MainActor.run {
                self.disableTmuxAttachment(for: sessionId, status: .off)
            }
            return
        }

        let tmuxAvailable = await RemoteTmuxManager.shared.isTmuxAvailable(using: client)
        guard tmuxAvailable else {
            await MainActor.run {
                self.disableTmuxAttachment(for: sessionId, status: .missing)
            }
            return
        }

        let selection = immediateTmuxSelection(for: sessionId)

        await runTmuxCleanupIfNeeded(for: serverId, sessionId: sessionId, selection: selection, using: client)
        await prepareActiveTmuxSession(for: sessionId, using: client)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: client)
        guard let rebuilt = tmuxResolver.buildAttachExecCommand(
            for: sessionId,
            selection: selection,
            workingDirectory: workingDirectory
        ) else {
            return
        }

        await RemoteTmuxManager.shared.sendScript(rebuilt, using: client, shellId: shellId)
    }

    func tmuxStartupPlan(
        for sessionId: UUID,
        serverId: UUID,
        client: SSHClient
    ) async -> (command: String?, skipTmuxLifecycle: Bool) {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            disableTmuxAttachment(for: sessionId, status: .off)
            return (nil, true)
        }

        guard await client.supportsTmuxRuntime() else {
            disableTmuxAttachment(for: sessionId, status: .off)
            return (nil, true)
        }

        let tmuxAvailable = await RemoteTmuxManager.shared.isTmuxAvailable(using: client)
        guard tmuxAvailable else {
            disableTmuxAttachment(for: sessionId, status: .missing)
            return (nil, true)
        }

        let selection = await tmuxResolver.resolveSelection(
            for: sessionId, serverId: serverId, client: client, setPrompt: setTmuxAttachPrompt
        )
        tmuxResolver.updateAttachmentState(for: sessionId, selection: selection, setPrompt: setTmuxAttachPrompt)

        if case .skipTmux = selection {
            updateTmuxStatus(sessionId, status: .off)
            return (nil, true)
        }

        await runTmuxCleanupIfNeeded(for: serverId, sessionId: sessionId, selection: selection, using: client)
        await prepareActiveTmuxSession(for: sessionId, using: client)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: client)
        return (tmuxStartupCommand(for: sessionId, selection: selection, workingDirectory: workingDirectory), true)
    }

    func startTmuxInstall(for sessionId: UUID) async {
        guard let registration = shellRegistry.registration(for: sessionId) else { return }
        let serverId = registration.serverId
        guard tmuxResolver.isTmuxEnabled(for: serverId) else { return }

        updateTmuxStatus(sessionId, status: .installing)

        let sessionName = tmuxResolver.sessionName(for: sessionId)
        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: registration.client)
        let terminalType = await registration.client.remoteTerminalType()
        let script = RemoteTmuxManager.shared.installAndAttachScript(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            terminalType: terminalType
        )
        await RemoteTmuxManager.shared.sendScript(script, using: registration.client, shellId: registration.shellId)

        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(2))
                let available = await RemoteTmuxManager.shared.isTmuxAvailable(using: registration.client)
                if available {
                    await MainActor.run {
                        self.tmuxResolver.sessionNames[sessionId] = sessionName
                        self.tmuxResolver.sessionOwnership[sessionId] = .managed
                        self.updateTmuxStatus(sessionId, status: self.currentTmuxStatus(for: sessionId))
                    }
                    return
                }
            }
            await MainActor.run {
                self.updateTmuxStatus(sessionId, status: .missing)
            }
        }
    }

    func installMoshServer(for sessionId: UUID) async throws {
        guard let registration = shellRegistry.registration(for: sessionId) else {
            throw SSHError.notConnected
        }
        try await RemoteMoshManager.shared.installMoshServer(using: registration.client)
    }

    func killTmuxIfNeeded(for sessionId: UUID) {
        guard let registration = shellRegistry.registration(for: sessionId) else { return }
        let ownership = tmuxResolver.sessionOwnership[sessionId] ?? .managed
        guard ownership == .managed else { return }

        let sessionName = tmuxResolver.sessionName(for: sessionId)
        Task.detached { [client = registration.client, sessionName] in
            await RemoteTmuxManager.shared.killSession(named: sessionName, using: client)
        }
    }

    func disableTmux(for serverId: UUID) {
        for index in sessions.indices where sessions[index].serverId == serverId {
            let sessionId = sessions[index].id
            setTmuxStatus(.off, for: sessionId)
            clearTmuxRuntimeState(for: sessionId)
        }
    }
}

#if DEBUG
extension ConnectionSessionManager {
    /// Resets manager state for deterministic integration tests.
    func resetForTesting() async {
        persistTask?.cancel()
        persistTask = nil

        let allSessionIds = Set(sessions.map(\.id))
            .union(shellRegistry.startsInFlight.keys)
        for sessionId in allSessionIds {
            clearTmuxRuntimeState(for: sessionId)
        }

        var uniqueClients: [ObjectIdentifier: SSHClient] = [:]
        for registration in shellRegistry.registrations.values {
            uniqueClients[ObjectIdentifier(registration.client)] = registration.client
        }
        for context in shellRegistry.startsInFlight.values {
            uniqueClients[ObjectIdentifier(context.client)] = context.client
        }

        let terminals = Array(terminalViews.values)
        isRestoring = true
        sessions = []
        selectedSessionId = nil
        connectedServerIds = []
        selectedViewByServer = [:]
        selectedSessionByServer = [:]
        tmuxAttachPrompt = nil
        shellRegistry.removeAll()
        shellCancelHandlers.removeAll()
        shellSuspendHandlers.removeAll()
        sessionOpensInFlight.removeAll()
        terminalsNeedingReconnectReset.removeAll()
        isSuspendingForBackground = false
        tmuxCleanupServers.removeAll()
        terminalViews.removeAll()
        terminalAccessOrder.removeAll()
        isRestoring = false

        UserDefaults.standard.removeObject(forKey: persistenceKey)
        for terminal in terminals {
            terminal.cleanup()
        }
        for client in uniqueClients.values {
            await client.disconnect()
        }
    }

    func setBackgroundSuspendInProgressForTesting(_ isSuspending: Bool) {
        isSuspendingForBackground = isSuspending
    }
}
#endif

actor ConnectionReliabilityManager {
    private var reconnectAttempts = 0
    private let maxAttempts = 3
    private let baseDelay: TimeInterval = 1.0

    func handleDisconnect(session: ConnectionSession) async {
        guard session.autoReconnect else { return }

        while reconnectAttempts < maxAttempts {
            reconnectAttempts += 1
            let delay = baseDelay * pow(2, Double(reconnectAttempts - 1))

            try? await Task.sleep(for: .seconds(delay))

            do {
                try await ConnectionSessionManager.shared.reconnect(session: session)
                reconnectAttempts = 0
                return
            } catch {
                continue
            }
        }
    }

    func resetAttempts() {
        reconnectAttempts = 0
    }
}
