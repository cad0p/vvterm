import Combine
import Foundation
import os.log

@MainActor
final class RemoteFileBrowserStore: ObservableObject {
    typealias ServerProvider = @MainActor (UUID) -> Server?
    typealias WorkingDirectoryProvider = @MainActor (UUID) -> String?

    enum ToolbarCommandAction: Sendable {
        case upload(destinationPath: String)
        case createFolder(destinationPath: String)
    }

    struct ToolbarCommand: Identifiable, Sendable {
        let id = UUID()
        let serverId: UUID
        let tabId: UUID
        let action: ToolbarCommandAction
    }

    struct TransferProgress: Sendable {
        let completedUnitCount: Int
        let totalUnitCount: Int
        let currentItemName: String
    }

    struct LocalUploadPlanItem: Identifiable, Sendable {
        let sourceURL: URL
        let remoteName: String

        var id: String {
            "\(sourceURL.absoluteString)->\(remoteName)"
        }
    }

    struct LocalUploadPlanCandidate: Identifiable, Sendable {
        let sourceURL: URL
        let originalName: String
        let existingEntry: RemoteFileEntry?
        let suggestedName: String?

        var id: String {
            "\(sourceURL.absoluteString)->\(originalName)"
        }

        var hasConflict: Bool {
            existingEntry != nil
        }
    }

    struct BrowserState: Sendable {
        let serverId: UUID
        var currentPath: String?
        var entries: [RemoteFileEntry]
        var sort: RemoteFileSort
        var sortDirection: RemoteFileSortDirection
        var showHiddenFiles: Bool
        var hasCustomizedHiddenFiles: Bool
        var hasLoadedDirectory: Bool
        var isLoadingDirectory: Bool
        var isLoadingViewer: Bool
        var isDirectoryTruncated: Bool
        var filesystemStatus: RemoteFileFilesystemStatus?
        var error: RemoteFileBrowserError?
        var viewerError: RemoteFileBrowserError?
        var viewerPayload: RemoteFileViewerPayload?
        var selectedEntryPath: String?

        init(serverId: UUID, persisted: RemoteFileBrowserPersistedState) {
            self.serverId = serverId
            currentPath = persisted.lastVisitedPath.map { RemoteFilePath.normalize($0) }
            entries = []
            sort = persisted.sort
            sortDirection = persisted.sortDirection
            showHiddenFiles = persisted.showHiddenFiles
            hasCustomizedHiddenFiles = persisted.hasCustomizedHiddenFiles
            hasLoadedDirectory = false
            isLoadingDirectory = false
            isLoadingViewer = false
            isDirectoryTruncated = false
            filesystemStatus = nil
            error = nil
            viewerError = nil
            viewerPayload = nil
            selectedEntryPath = nil
        }

        var breadcrumbs: [RemoteFileBreadcrumb] {
            guard let currentPath else { return [] }
            return RemoteFilePath.breadcrumbs(for: currentPath)
        }
    }

    struct DirectorySnapshot: Sendable {
        let path: String
        let entries: [RemoteFileEntry]
        let isTruncated: Bool
        let filesystemStatus: RemoteFileFilesystemStatus?
    }

    @Published private(set) var states: [UUID: BrowserState] = [:]
    @Published var pendingToolbarCommand: ToolbarCommand?

    let defaults: UserDefaults
    let persistenceKey = "remoteFileBrowserState.v2"
    let legacyPersistenceKey = "remoteFileBrowserState.v1"
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "RemoteFiles")
    let remoteFileServiceAdapter: SSHSFTPAdapter
    let temporaryStorage: RemoteFileTemporaryStorage
    let previewLoader: RemoteFilePreviewLoader
    let conflictResolver: RemoteFileConflictResolver
    let serverProvider: ServerProvider
    let workingDirectoryProvider: WorkingDirectoryProvider

    var persistedStates: [String: RemoteFileBrowserPersistedState] = [:]
    var directoryRequestIDs: [UUID: UUID] = [:]
    var viewerRequestIDs: [UUID: UUID] = [:]

    static let directoryEntryLimit = 2_000
    static let defaultPreviewBytes = 512 * 1_024
    static let hardPreviewBytes = 2 * 1_024 * 1_024
    static let previewConfirmationBytes = 1 * 1_024 * 1_024
    static let maxMediaPreviewBytes = 64 * 1_024 * 1_024

    init(
        defaults: UserDefaults = .standard,
        remoteFileServiceAdapter: SSHSFTPAdapter? = nil,
        temporaryStorage: RemoteFileTemporaryStorage = RemoteFileTemporaryStorage(),
        previewLoader: RemoteFilePreviewLoader = RemoteFilePreviewLoader(),
        conflictResolver: RemoteFileConflictResolver = RemoteFileConflictResolver(),
        serverProvider: @escaping ServerProvider = { serverId in
            ServerManager.shared.servers.first { $0.id == serverId }
        },
        workingDirectoryProvider: @escaping WorkingDirectoryProvider = { serverId in
            if let selectedSessionId = ConnectionSessionManager.shared.selectedSessionByServer[serverId],
               let path = ConnectionSessionManager.shared.workingDirectory(for: selectedSessionId) {
                return path
            }

            if let anySession = ConnectionSessionManager.shared.sessions.first(where: { $0.serverId == serverId }),
               let path = ConnectionSessionManager.shared.workingDirectory(for: anySession.id) {
                return path
            }

            if let selectedTab = TerminalTabManager.shared.selectedTab(for: serverId),
               let path = TerminalTabManager.shared.workingDirectory(for: selectedTab.focusedPaneId) {
                return path
            }

            if let anyPane = TerminalTabManager.shared.paneStates.values.first(where: { $0.serverId == serverId }),
               let path = TerminalTabManager.shared.workingDirectory(for: anyPane.paneId) {
                return path
            }

            return nil
        }
    ) {
        self.defaults = defaults
        self.remoteFileServiceAdapter = remoteFileServiceAdapter ?? SSHSFTPAdapter()
        self.temporaryStorage = temporaryStorage
        self.previewLoader = previewLoader
        self.conflictResolver = conflictResolver
        self.serverProvider = serverProvider
        self.workingDirectoryProvider = workingDirectoryProvider
        loadPersistedStates()
    }

    func prepareNewTab(_ tab: RemoteFileTab, duplicating sourceTab: RemoteFileTab?) {
        if let sourceTab {
            let sourceState = state(for: sourceTab)
            let sourcePersistedState = persistedState(for: sourceTab.id)
            let sourcePath = sourceState.currentPath
                ?? sourcePersistedState.lastVisitedPath
                ?? sourceTab.lastKnownPath
                ?? sourceTab.seedPath

            persistedStates[tab.id.uuidString] = RemoteFileBrowserPersistedState(
                lastVisitedPath: sourcePath,
                sort: sourceState.sort,
                sortDirection: sourceState.sortDirection,
                showHiddenFiles: sourceState.showHiddenFiles,
                hasCustomizedHiddenFiles: sourceState.hasCustomizedHiddenFiles
            )
            states[tab.id] = BrowserState(serverId: tab.serverId, persisted: persistedState(for: tab.id))
            persistStates()
            return
        }

        guard persistedStates[tab.id.uuidString] == nil else { return }
        persistedStates[tab.id.uuidString] = RemoteFileBrowserPersistedState(
            lastVisitedPath: tab.seedPath ?? tab.lastKnownPath
        )
        persistStates()
    }

    func state(for tab: RemoteFileTab) -> BrowserState {
        states[tab.id] ?? BrowserState(serverId: tab.serverId, persisted: persistedState(for: tab.id))
    }

    func currentPathValue(for tab: RemoteFileTab) -> String? {
        state(for: tab).currentPath
    }

    func lastVisitedPath(for tab: RemoteFileTab) -> String? {
        state(for: tab).currentPath
            ?? persistedState(for: tab.id).lastVisitedPath
            ?? tab.lastKnownPath
            ?? tab.seedPath
    }

    func currentPath(for tab: RemoteFileTab) -> String {
        lastVisitedPath(for: tab) ?? "/"
    }

    func displayedEntries(for tab: RemoteFileTab) -> [RemoteFileEntry] {
        let state = state(for: tab)
        let visibleEntries = state.showHiddenFiles
            ? state.entries
            : state.entries.filter { !$0.isHidden }
        return visibleEntries.sortedForBrowser(using: state.sort, direction: state.sortDirection)
    }

    func entries(for tab: RemoteFileTab) -> [RemoteFileEntry] {
        displayedEntries(for: tab)
    }

    func selectedEntryPath(for tab: RemoteFileTab) -> String? {
        state(for: tab).selectedEntryPath
    }

    func viewerPayload(for tab: RemoteFileTab) -> RemoteFileViewerPayload? {
        state(for: tab).viewerPayload
    }

    func error(for tab: RemoteFileTab) -> RemoteFileBrowserError? {
        state(for: tab).error
    }

    func viewerError(for tab: RemoteFileTab) -> RemoteFileBrowserError? {
        state(for: tab).viewerError
    }

    func isLoading(for tab: RemoteFileTab) -> Bool {
        state(for: tab).isLoadingDirectory
    }

    func isLoadingViewer(for tab: RemoteFileTab) -> Bool {
        state(for: tab).isLoadingViewer
    }

    func isTruncated(for tab: RemoteFileTab) -> Bool {
        state(for: tab).isDirectoryTruncated
    }

    func filesystemStatus(for tab: RemoteFileTab) -> RemoteFileFilesystemStatus? {
        state(for: tab).filesystemStatus
    }

    func sort(for tab: RemoteFileTab) -> RemoteFileSort {
        state(for: tab).sort
    }

    func sortDirection(for tab: RemoteFileTab) -> RemoteFileSortDirection {
        state(for: tab).sortDirection
    }

    func showHiddenFiles(for tab: RemoteFileTab) -> Bool {
        state(for: tab).showHiddenFiles
    }

    func breadcrumbs(for tab: RemoteFileTab) -> [RemoteFileBreadcrumb] {
        state(for: tab).breadcrumbs
    }

    func loadInitialPath(for server: Server, tab: RemoteFileTab, initialPath: String? = nil) async {
        guard tab.serverId == server.id else { return }

        let currentState = state(for: tab)
        guard !currentState.isLoadingDirectory else { return }
        guard !currentState.hasLoadedDirectory else { return }

        let requestID = UUID()
        directoryRequestIDs[tab.id] = requestID

        updateState(for: tab) { state in
            state.isLoadingDirectory = true
            state.error = nil
        }

        do {
            let snapshot = try await resolveInitialDirectorySnapshot(for: server, tab: tab, initialPath: initialPath)
            guard directoryRequestIDs[tab.id] == requestID else { return }
            applyDirectorySnapshot(snapshot, to: tab)
        } catch {
            guard directoryRequestIDs[tab.id] == requestID else { return }
            logger.error("Initial file browser load failed for \(server.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            updateState(for: tab) { state in
                state.isLoadingDirectory = false
                state.error = RemoteFileBrowserError.map(error)
            }
        }
    }

    func refresh(server: Server, tab: RemoteFileTab) async {
        guard tab.serverId == server.id else { return }
        let targetPath = lastVisitedPath(for: tab)
            ?? bestWorkingDirectory(for: server.id)
            ?? "/"
        await loadDirectory(path: targetPath, in: tab, server: server)
    }

    func openBreadcrumb(_ breadcrumb: RemoteFileBreadcrumb, in tab: RemoteFileTab, server: Server) async {
        guard tab.serverId == server.id else { return }
        await loadDirectory(path: breadcrumb.path, in: tab, server: server)
    }

    func openDirectory(_ entry: RemoteFileEntry, in tab: RemoteFileTab, server: Server) async {
        guard tab.serverId == server.id else { return }
        await loadDirectory(path: entry.path, in: tab, server: server)
    }

    func activate(_ entry: RemoteFileEntry, in tab: RemoteFileTab, server: Server) async {
        guard tab.serverId == server.id else { return }

        switch entry.type {
        case .directory:
            await openDirectory(entry, in: tab, server: server)
        case .symlink:
            do {
                let resolvedEntry = try await withRemoteFileService(for: server) { service in
                    try await service.stat(at: entry.path)
                }
                if resolvedEntry.type == .directory {
                    await loadDirectory(path: entry.path, in: tab, server: server)
                } else {
                    selectFile(entry, in: tab)
                }
            } catch {
                selectFile(entry, in: tab)
            }
        case .file, .other:
            selectFile(entry, in: tab)
        }
    }

    func focus(_ entry: RemoteFileEntry, in tab: RemoteFileTab) {
        viewerRequestIDs[tab.id] = UUID()
        cleanupPreviewArtifact(for: state(for: tab).viewerPayload)
        updateState(for: tab) { state in
            state.selectedEntryPath = entry.path
            state.viewerPayload = nil
            state.viewerError = nil
            state.isLoadingViewer = false
        }
    }

    func updateSort(_ sort: RemoteFileSort, for tab: RemoteFileTab) {
        updateSort(sort, direction: sort.defaultDirection, for: tab)
    }

    func updateSort(_ sort: RemoteFileSort, direction: RemoteFileSortDirection, for tab: RemoteFileTab) {
        updateState(for: tab) { state in
            state.sort = sort
            state.sortDirection = direction
        }
        persistState(for: tab.id)
    }

    func setShowHiddenFiles(_ showHiddenFiles: Bool, for tab: RemoteFileTab) {
        updateState(for: tab) { state in
            state.showHiddenFiles = showHiddenFiles
            state.hasCustomizedHiddenFiles = true
        }
        persistState(for: tab.id)
    }

    func removeState(for tabId: UUID) {
        removeRuntimeState(for: tabId)
        persistedStates.removeValue(forKey: tabId.uuidString)
        persistStates()
    }

    func removeRuntimeState(for tabId: UUID) {
        directoryRequestIDs.removeValue(forKey: tabId)
        viewerRequestIDs.removeValue(forKey: tabId)
        temporaryStorage.removePreviewArtifact(for: states[tabId]?.viewerPayload)
        states.removeValue(forKey: tabId)

        if pendingToolbarCommand?.tabId == tabId {
            pendingToolbarCommand = nil
        }
    }

    func disconnect(serverId: UUID) {
        let affectedTabIDs = Set(
            states.compactMap { tabId, state in
                state.serverId == serverId ? tabId : nil
            }
        )

        for tabId in affectedTabIDs {
            removeRuntimeState(for: tabId)
        }

        remoteFileServiceAdapter.disconnect(serverId: serverId)
    }

    func goUp(in tab: RemoteFileTab, server: Server) async {
        guard tab.serverId == server.id else { return }
        let currentPath = currentPath(for: tab)
        let parentPath = RemoteFilePath.parent(of: currentPath)
        guard parentPath != currentPath else { return }
        await loadDirectory(path: parentPath, in: tab, server: server)
    }

    func loadDirectory(path: String, in tab: RemoteFileTab, server: Server) async {
        guard tab.serverId == server.id else { return }

        let normalizedPath = RemoteFilePath.normalize(path)
        let requestID = UUID()
        directoryRequestIDs[tab.id] = requestID
        cleanupPreviewArtifact(for: state(for: tab).viewerPayload)

        updateState(for: tab) { state in
            state.isLoadingDirectory = true
            state.error = nil
            state.viewerError = nil
            state.viewerPayload = nil
            state.selectedEntryPath = nil
        }
        viewerRequestIDs.removeValue(forKey: tab.id)

        do {
            let snapshot = try await directorySnapshot(path: normalizedPath, for: server)
            guard directoryRequestIDs[tab.id] == requestID else { return }
            applyDirectorySnapshot(snapshot, to: tab)
        } catch {
            guard directoryRequestIDs[tab.id] == requestID else { return }
            logger.error("Directory load failed for \(normalizedPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            updateState(for: tab) { state in
                state.isLoadingDirectory = false
                state.error = RemoteFileBrowserError.map(error)
            }
        }
    }

    func resolveInitialDirectorySnapshot(
        for server: Server,
        tab: RemoteFileTab,
        initialPath: String?
    ) async throws -> DirectorySnapshot {
        for path in initialDirectoryCandidates(for: server, tab: tab, initialPath: initialPath) {
            do {
                return try await directorySnapshot(path: path, for: server)
            } catch {
                logger.debug("Skipping initial browser path \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let homePath = try await withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }
        return try await directorySnapshot(path: homePath, for: server)
    }

    func initialDirectoryCandidates(
        for server: Server,
        tab: RemoteFileTab,
        initialPath: String?
    ) -> [String] {
        let persistedPath = persistedState(for: tab.id).lastVisitedPath
        let workingDirectory = bestWorkingDirectory(for: server.id)
        var seenPaths = Set<String>()

        return [
            persistedPath,
            tab.lastKnownPath,
            initialPath,
            tab.seedPath,
            workingDirectory
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { RemoteFilePath.normalize($0) }
        .filter { seenPaths.insert($0).inserted }
    }

    private func directorySnapshot(path: String, for server: Server) async throws -> DirectorySnapshot {
        let normalizedPath = RemoteFilePath.normalize(path)
        let entries = try await withRemoteFileService(for: server) { service in
            try await service.listDirectory(at: normalizedPath, maxEntries: Self.directoryEntryLimit)
        }
        let filesystemStatus = try? await withRemoteFileService(for: server) { service in
            try await service.fileSystemStatus(at: normalizedPath)
        }
        return DirectorySnapshot(
            path: normalizedPath,
            entries: entries,
            isTruncated: entries.count >= Self.directoryEntryLimit,
            filesystemStatus: filesystemStatus
        )
    }

    func applyDirectorySnapshot(_ snapshot: DirectorySnapshot, to tab: RemoteFileTab) {
        updateState(for: tab) { state in
            state.currentPath = snapshot.path
            state.entries = snapshot.entries
            state.hasLoadedDirectory = true
            state.isDirectoryTruncated = snapshot.isTruncated
            state.filesystemStatus = snapshot.filesystemStatus
            state.isLoadingDirectory = false
            state.error = nil
        }
        persistState(for: tab.id)
    }

    func selectFile(_ entry: RemoteFileEntry, in tab: RemoteFileTab) {
        focus(entry, in: tab)
    }

    func withRemoteFileService<T>(
        for server: Server,
        operation: @escaping (any RemoteFileService) async throws -> T
    ) async throws -> T {
        try await remoteFileServiceAdapter.withService(for: server, operation: operation)
    }

    func bestWorkingDirectory(for serverId: UUID) -> String? {
        workingDirectoryProvider(serverId)
    }

    func updateState(for tab: RemoteFileTab, mutation: (inout BrowserState) -> Void) {
        updateState(for: tab.id, serverId: tab.serverId, mutation: mutation)
    }

    func updateState(for tabId: UUID, serverId: UUID, mutation: (inout BrowserState) -> Void) {
        var state = states[tabId] ?? BrowserState(serverId: serverId, persisted: persistedState(for: tabId))
        mutation(&state)
        states[tabId] = state
    }

    func server(for serverId: UUID) -> Server? {
        serverProvider(serverId)
    }

    func setPendingToolbarCommand(_ command: ToolbarCommand?) {
        pendingToolbarCommand = command
    }
}

extension String {
    var nonEmptyString: String? {
        isEmpty ? nil : self
    }
}
