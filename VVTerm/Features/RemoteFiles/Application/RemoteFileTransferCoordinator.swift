import Combine
import Foundation

extension RemoteFileBrowserStore {
    struct LocalUploadItemInfo: Sendable {
        let name: String
        let isDirectory: Bool
    }

    final class TransferProgressTracker {
        private(set) var completedUnitCount = 0
        let totalUnitCount: Int
        let onProgress: (@MainActor @Sendable (TransferProgress) -> Void)?

        init(
            totalUnitCount: Int,
            onProgress: (@MainActor @Sendable (TransferProgress) -> Void)?
        ) {
            self.totalUnitCount = max(1, totalUnitCount)
            self.onProgress = onProgress
        }

        @MainActor
        func advance(currentItemName: String) {
            completedUnitCount += 1
            onProgress?(
                TransferProgress(
                    completedUnitCount: min(completedUnitCount, totalUnitCount),
                    totalUnitCount: totalUnitCount,
                    currentItemName: currentItemName
                )
            )
        }
    }

    func upload(
        data: Data,
        to remotePath: String,
        server: Server,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        try await withRemoteFileService(for: server) { service in
            try await service.upload(
                data,
                to: remotePath,
                permissions: permissions,
                strategy: strategy
            )
        }
    }

    func upload(
        fileAt localURL: URL,
        to remoteDirectoryPath: String,
        server: Server,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        let remotePath = RemoteFilePath.appending(localURL.lastPathComponent, to: remoteDirectoryPath)
        let data = try await loadLocalFileData(from: localURL)
        try await upload(
            data: data,
            to: remotePath,
            server: server,
            permissions: permissions,
            strategy: strategy
        )
    }

    func createDirectory(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server,
        permissions: Int32 = 0o755
    ) async throws {
        try await performMutation(in: tab, server: server) { service in
            try await service.createDirectory(at: remotePath, permissions: permissions)
        }
    }

    func createDirectory(
        named directoryName: String,
        in remoteDirectoryPath: String,
        tab: RemoteFileTab,
        server: Server,
        permissions: Int32 = 0o755
    ) async throws {
        let remotePath = RemoteFilePath.appending(
            try validatedRemoteName(directoryName),
            to: remoteDirectoryPath
        )
        try await createDirectory(at: remotePath, in: tab, server: server, permissions: permissions)
    }

    func renameItem(
        at sourcePath: String,
        to destinationPath: String,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        try await performMutation(in: tab, server: server) { service in
            try await service.renameItem(at: sourcePath, to: destinationPath)
        }
    }

    func deleteFile(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        try await performMutation(in: tab, server: server) { service in
            try await service.deleteFile(at: remotePath)
        }
    }

    func deleteDirectory(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        try await performMutation(in: tab, server: server) { [self] service in
            try await deleteDirectoryRecursively(at: remotePath, using: service)
        }
    }

    func deleteItem(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server,
        type: RemoteFileType? = nil
    ) async throws {
        switch type {
        case .directory:
            try await deleteDirectory(at: remotePath, in: tab, server: server)
        case .file, .symlink, .other, nil:
            try await deleteFile(at: remotePath, in: tab, server: server)
        }
    }

    func setPermissions(
        _ entry: RemoteFileEntry,
        permissions: UInt32,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        let updatedEntry = try await withRemoteFileService(for: server) { service in
            try await service.setPermissions(at: entry.path, permissions: permissions)
            return try await service.lstat(at: entry.path)
        }

        let requestedPermissionBits = permissions & 0o7777
        let updatedPermissionBits = (updatedEntry.permissions ?? 0) & 0o7777
        if updatedPermissionBits != requestedPermissionBits {
            throw RemoteFileBrowserError.failed(
                String(
                    localized: "This server accepted the request, but the file permissions did not change. Some remote systems, including many Windows SFTP servers, do not support POSIX chmod."
                )
            )
        }

        updateState(for: tab) { state in
            if let index = state.entries.firstIndex(where: { $0.path == entry.path }) {
                state.entries[index] = updatedEntry
            }

            if state.selectedEntryPath == entry.path,
               let payload = state.viewerPayload,
               payload.entry.path == entry.path {
                state.viewerPayload = RemoteFileViewerPayload(
                    previewKind: payload.previewKind,
                    entry: updatedEntry,
                    textPreview: payload.textPreview,
                    previewFileURL: payload.previewFileURL,
                    isTruncated: payload.isTruncated,
                    unavailableMessage: payload.unavailableMessage,
                    requiresExplicitDownload: payload.requiresExplicitDownload,
                    previewByteCount: payload.previewByteCount
                )
            }
        }
    }

    func uploadFiles(
        at urls: [URL],
        to directoryPath: String,
        in tab: RemoteFileTab,
        server: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        let plans = urls.map { LocalUploadPlanItem(sourceURL: $0, remoteName: $0.lastPathComponent) }
        try await uploadFiles(
            plans: plans,
            to: directoryPath,
            in: tab,
            server: server,
            onProgress: onProgress
        )
    }

    func uploadFiles(
        plans: [LocalUploadPlanItem],
        to directoryPath: String,
        in tab: RemoteFileTab,
        server: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        let urls = plans.map(\.sourceURL)
        try await withSecurityScopedAccess(to: urls) {
            let progressTracker = TransferProgressTracker(
                totalUnitCount: try await countLocalTransferUnits(at: urls),
                onProgress: onProgress
            )
            try await withRemoteFileService(for: server) { [self] service in
                for plan in plans {
                    try await self.uploadItem(
                        at: plan.sourceURL,
                        to: destinationDirectory,
                        remoteName: plan.remoteName,
                        using: service,
                        progressTracker: progressTracker
                    )
                }
            }
        }

        clearViewer(for: tab)
        await refresh(server: server, tab: tab)
    }

    func prepareLocalUploadPlan(
        at urls: [URL],
        to directoryPath: String,
        server: Server
    ) async throws -> [LocalUploadPlanCandidate] {
        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        return try await withSecurityScopedAccess(to: urls) {
            try await withRemoteFileService(for: server) { service in
                var reservedNames: Set<String> = []
                var candidates: [LocalUploadPlanCandidate] = []

                for url in urls {
                    let itemInfo = try await self.localItemInfo(at: url)
                    let originalName = itemInfo.name
                    let resolution = try await self.conflictResolver.resolveName(
                        for: originalName,
                        in: destinationDirectory,
                        policy: .keepBoth,
                        using: service,
                        reservedNames: &reservedNames
                    )
                    candidates.append(
                        LocalUploadPlanCandidate(
                            sourceURL: url,
                            originalName: originalName,
                            existingEntry: resolution.existingEntry,
                            suggestedName: resolution.hasConflict ? resolution.resolvedName : nil
                        )
                    )
                }

                return candidates
            }
        }
    }

    func copyEntries(
        _ entries: [RemoteFileEntry],
        from sourceServerId: UUID,
        to destinationDirectoryPath: String,
        destinationTab: RemoteFileTab,
        destinationServer: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard destinationTab.serverId == destinationServer.id,
              let sourceServer = server(for: sourceServerId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let uniqueEntries = uniqueTransferEntries(entries)
        guard !uniqueEntries.isEmpty else { return }

        let destinationDirectory = RemoteFilePath.normalize(destinationDirectoryPath)
        let totalUnitCount = try await withRemoteFileService(for: sourceServer) { service in
            try await self.countRemoteTransferUnits(for: uniqueEntries, using: service)
        }
        let progressTracker = TransferProgressTracker(
            totalUnitCount: totalUnitCount,
            onProgress: onProgress
        )

        try await withRemoteFileService(for: sourceServer) { sourceService in
            try await self.withRemoteFileService(for: destinationServer) { destinationService in
                for entry in uniqueEntries {
                    try await self.copyRemoteEntry(
                        entry,
                        to: destinationDirectory,
                        sourceService: sourceService,
                        destinationService: destinationService,
                        progressTracker: progressTracker
                    )
                }
            }
        }

        clearViewer(for: destinationTab)
        await refresh(server: destinationServer, tab: destinationTab)
    }

    func downloadFile(
        at remotePath: String,
        to localURL: URL,
        server: Server
    ) async throws {
        try await withRemoteFileService(for: server) { service in
            try await service.downloadFile(at: remotePath, to: localURL)
        }
    }

    func downloadItem(
        _ entry: RemoteFileEntry,
        to localURL: URL,
        server: Server
    ) async throws {
        try await withRemoteFileService(for: server) { service in
            try await self.downloadItem(entry, to: localURL, using: service)
        }
    }

    func listDirectories(
        at path: String,
        server: Server
    ) async throws -> [RemoteFileEntry] {
        let normalizedPath = RemoteFilePath.normalize(path)
        let entries = try await withRemoteFileService(for: server) { service in
            try await service.listDirectory(at: normalizedPath, maxEntries: Self.directoryEntryLimit)
        }
        return entries
            .filter { $0.type == .directory }
            .sortedForBrowser(using: .name, direction: .ascending)
    }

    func performMutation(
        in tab: RemoteFileTab,
        server: Server,
        operation: @escaping (any RemoteFileService) async throws -> Void
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        try await withRemoteFileService(for: server) { service in
            try await operation(service)
        }
        await refresh(server: server, tab: tab)
    }

    func deleteDirectoryRecursively(
        at remotePath: String,
        using service: any RemoteFileService
    ) async throws {
        let normalizedPath = RemoteFilePath.normalize(remotePath)
        let entries = try await service.listDirectory(at: normalizedPath, maxEntries: nil)

        for entry in entries {
            try Task.checkCancellation()

            switch entry.type {
            case .directory:
                try await deleteDirectoryRecursively(at: entry.path, using: service)
            case .file, .symlink, .other:
                try await service.deleteFile(at: entry.path)
            }
        }

        try await service.deleteDirectory(at: normalizedPath)
    }

    func loadLocalFileData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url, options: [.mappedIfSafe])
        }.value
    }

    func localItemInfo(at url: URL) async throws -> LocalUploadItemInfo {
        try await Task.detached(priority: .utility) {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            return LocalUploadItemInfo(
                name: resourceValues.name ?? url.lastPathComponent,
                isDirectory: resourceValues.isDirectory == true
            )
        }.value
    }

    func localDirectoryContents(at url: URL) async throws -> [URL] {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                options: []
            )
            return contents.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }.value
    }

    func uploadItem(
        at localURL: URL,
        to remoteDirectoryPath: String,
        remoteName: String? = nil,
        using client: any RemoteFileService,
        progressTracker: TransferProgressTracker? = nil
    ) async throws {
        let itemInfo = try await localItemInfo(at: localURL)
        let targetName = remoteName ?? itemInfo.name
        let remotePath = RemoteFilePath.appending(targetName, to: remoteDirectoryPath)

        if itemInfo.isDirectory {
            try await ensureRemoteDirectoryExists(
                at: remotePath,
                permissions: 0o755,
                using: client
            )
            progressTracker?.advance(currentItemName: targetName)
            let children = try await localDirectoryContents(at: localURL)
            for child in children {
                try await uploadItem(
                    at: child,
                    to: remotePath,
                    using: client,
                    progressTracker: progressTracker
                )
            }
            return
        }

        let data = try await loadLocalFileData(from: localURL)
        try await client.upload(data, to: remotePath, permissions: Int32(0o644), strategy: .automatic)
        progressTracker?.advance(currentItemName: targetName)
    }

    func downloadItem(
        _ entry: RemoteFileEntry,
        to localURL: URL,
        using service: any RemoteFileService
    ) async throws {
        let effectiveEntry = try await resolvedTransferEntry(for: entry, using: service)

        if effectiveEntry.type == .directory {
            try await createLocalDirectory(at: localURL)
            let children = try await service.listDirectory(at: entry.path, maxEntries: nil)
            for child in children {
                let childURL = localURL.appendingPathComponent(
                    child.name,
                    isDirectory: child.type == .directory
                )
                try await downloadItem(child, to: childURL, using: service)
            }
            return
        }

        try await service.downloadFile(at: entry.path, to: localURL)
    }

    func copyRemoteEntry(
        _ entry: RemoteFileEntry,
        to remoteDirectoryPath: String,
        sourceService: any RemoteFileService,
        destinationService: any RemoteFileService,
        progressTracker: TransferProgressTracker?
    ) async throws {
        let effectiveEntry = try await resolvedTransferEntry(for: entry, using: sourceService)
        let remotePath = RemoteFilePath.appending(entry.name, to: remoteDirectoryPath)

        if effectiveEntry.type == .directory {
            try await ensureRemoteDirectoryExists(
                at: remotePath,
                permissions: Int32(effectiveEntry.permissions ?? 0o755),
                using: destinationService
            )
            progressTracker?.advance(currentItemName: entry.name)
            let children = try await sourceService.listDirectory(at: entry.path, maxEntries: nil)
            for child in children {
                try await copyRemoteEntry(
                    child,
                    to: remotePath,
                    sourceService: sourceService,
                    destinationService: destinationService,
                    progressTracker: progressTracker
                )
            }
            return
        }

        let temporaryURL = try temporaryStorage.makeTransferFileURL(for: entry)
        defer { temporaryStorage.removeItem(at: temporaryURL) }

        try await sourceService.downloadFile(at: entry.path, to: temporaryURL)
        let data = try await loadLocalFileData(from: temporaryURL)
        try await destinationService.upload(
            data,
            to: remotePath,
            permissions: Int32(effectiveEntry.permissions ?? 0o644),
            strategy: .automatic
        )
        progressTracker?.advance(currentItemName: entry.name)
    }

    func countLocalTransferUnits(at urls: [URL]) async throws -> Int {
        var totalUnitCount = 0

        for url in urls {
            totalUnitCount += try await countLocalTransferUnits(at: url)
        }

        return max(1, totalUnitCount)
    }

    func countLocalTransferUnits(at url: URL) async throws -> Int {
        let itemInfo = try await localItemInfo(at: url)
        guard itemInfo.isDirectory else { return 1 }

        let children = try await localDirectoryContents(at: url)
        var totalUnitCount = 1

        for child in children {
            totalUnitCount += try await countLocalTransferUnits(at: child)
        }

        return totalUnitCount
    }

    func countRemoteTransferUnits(
        for entries: [RemoteFileEntry],
        using client: any RemoteFileService
    ) async throws -> Int {
        var totalUnitCount = 0

        for entry in entries {
            totalUnitCount += try await countRemoteTransferUnits(for: entry, using: client)
        }

        return max(1, totalUnitCount)
    }

    func countRemoteTransferUnits(
        for entry: RemoteFileEntry,
        using client: any RemoteFileService
    ) async throws -> Int {
        let effectiveEntry = try await resolvedTransferEntry(for: entry, using: client)
        guard effectiveEntry.type == .directory else { return 1 }

        let children = try await client.listDirectory(at: entry.path, maxEntries: nil)
        var totalUnitCount = 1

        for child in children {
            totalUnitCount += try await countRemoteTransferUnits(for: child, using: client)
        }

        return totalUnitCount
    }

    func resolvedTransferEntry(
        for entry: RemoteFileEntry,
        using client: any RemoteFileService
    ) async throws -> RemoteFileEntry {
        guard entry.type == .symlink else { return entry }

        let resolvedEntry = try await client.stat(at: entry.path)
        return RemoteFileEntry(
            name: entry.name,
            path: entry.path,
            type: resolvedEntry.type,
            size: resolvedEntry.size,
            modifiedAt: resolvedEntry.modifiedAt,
            permissions: resolvedEntry.permissions,
            symlinkTarget: entry.symlinkTarget ?? resolvedEntry.symlinkTarget
        )
    }

    func ensureRemoteDirectoryExists(
        at remotePath: String,
        permissions: Int32,
        using client: any RemoteFileService
    ) async throws {
        do {
            let existingEntry = try await client.lstat(at: remotePath)
            guard existingEntry.type == .directory else {
                throw RemoteFileBrowserError.failed(
                    String(
                        format: String(localized: "\"%@\" already exists and is not a folder."),
                        existingEntry.name.isEmpty ? remotePath : existingEntry.name
                    )
                )
            }
        } catch let error as RemoteFileBrowserError {
            guard case .pathNotFound = error else { throw error }
            try await client.createDirectory(at: remotePath, permissions: permissions)
        } catch {
            throw error
        }
    }

    func uniqueTransferEntries(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        var seenPaths: Set<String> = []
        return entries.filter { seenPaths.insert($0.path).inserted }
    }

    func createLocalDirectory(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }.value
    }

    func withSecurityScopedAccess<T>(
        to urls: [URL],
        operation: () async throws -> T
    ) async throws -> T {
        let accessedURLs = urls.map { url in
            (url: url, accessed: url.startAccessingSecurityScopedResource())
        }
        defer {
            for entry in accessedURLs where entry.accessed {
                entry.url.stopAccessingSecurityScopedResource()
            }
        }
        return try await operation()
    }

    func validatedRemoteName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "A name is required."))
        }
        guard trimmed != "." && trimmed != ".." else {
            throw RemoteFileBrowserError.failed(String(localized: "This name is not allowed."))
        }
        guard !trimmed.contains("/") else {
            throw RemoteFileBrowserError.failed(String(localized: "Names cannot contain '/'."))
        }
        return trimmed
    }
}
