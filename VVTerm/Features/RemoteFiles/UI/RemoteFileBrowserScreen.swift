import SwiftUI
import UniformTypeIdentifiers

struct RemoteFileBrowserScreen: View {
    @ObservedObject var browser: RemoteFileBrowserStore
    let server: Server
    let fileTab: RemoteFileTab
    let initialPath: String?
    let onCurrentPathChange: @MainActor (String?) -> Void

    @Environment(\.colorScheme) var colorScheme
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) var usePerAppearanceTheme = true
    @State var presentedPreviewPath: String?
    @State var uploadDestinationPath: String?
    @State var uploadImportRequest: UploadImportRequest?
    @State var downloadExportDocument: RemoteFileDownloadDocument?
    @State var downloadExportFilename = ""
    @State var isDownloadExporterPresented = false
    @State var downloadTransferNoticeID: UUID?
    @State var shareItem: RemoteFileShareItem?
    @State var newFolderDestinationPath: String?
    @State var newFolderName = ""
    @State var isCreateFolderSubmitting = false
    @State var renameTargetEntry: RemoteFileEntry?
    @State var renameName = ""
    @State var isRenameSubmitting = false
    @State var moveTargetEntry: RemoteFileEntry?
    @State var moveDestinationDirectory = ""
    @State var isMoveSubmitting = false
    @State var deleteTargetEntry: RemoteFileEntry?
    @State var permissionTargetEntry: RemoteFileEntry?
    @State var permissionDraft = RemoteFilePermissionDraft(accessBits: 0)
    @State var permissionOriginalAccessBits: UInt32 = 0
    @State var permissionPreservedBits: UInt32 = 0
    @State var permissionFileTypeBits: UInt32 = 0
    @State var isPermissionSubmitting = false
    @State var permissionErrorMessage: String?
    @State var operationErrorMessage: String?
    @State var transferCancellationRequest: TransferCancellationRequest?
    @State var transferTasks: [UUID: Task<Void, Never>] = [:]
    @State var activeTransferKinds: [UUID: TransferKind] = [:]
    @State var isDropTargeted = false
    @StateObject var platformState = RemoteFileBrowserPlatformState()
    @StateObject var noticeHost = NoticeHostModel()

    struct Snapshot {
        let currentPath: String
        let breadcrumbs: [RemoteFileBreadcrumb]
        let entries: [RemoteFileEntry]
        let selectedEntry: RemoteFileEntry?
        let viewerPayload: RemoteFileViewerPayload?
        let directoryError: RemoteFileBrowserError?
        let viewerError: RemoteFileBrowserError?
        let isLoadingDirectory: Bool
        let isLoadingViewer: Bool
        let sort: RemoteFileSort
        let sortDirection: RemoteFileSortDirection
        let showHiddenFiles: Bool
        let isTruncated: Bool
        let selectedPath: String?
        let filesystemStatus: RemoteFileFilesystemStatus?
    }

    struct EmptyStateContent {
        let icon: String
        let title: String
        let message: String
    }

    struct UploadImportRequest: Identifiable {
        let id = UUID()
        let destinationPath: String
    }

    enum TransferKind {
        case upload
        case transfer

        var confirmationTitle: String {
            switch self {
            case .upload:
                return String(localized: "Cancel Upload?")
            case .transfer:
                return String(localized: "Cancel Transfer?")
            }
        }

        var cancelButtonTitle: String {
            switch self {
            case .upload:
                return String(localized: "Cancel Upload")
            case .transfer:
                return String(localized: "Cancel Transfer")
            }
        }

        var keepButtonTitle: String {
            switch self {
            case .upload:
                return String(localized: "Keep Uploading")
            case .transfer:
                return String(localized: "Continue Transfer")
            }
        }

        var confirmationMessage: String {
            switch self {
            case .upload:
                return String(localized: "The current upload will stop.")
            case .transfer:
                return String(localized: "The current file transfer will stop.")
            }
        }
    }

    struct TransferCancellationRequest: Identifiable {
        let id: UUID
        let kind: TransferKind
    }

    init(
        browser: RemoteFileBrowserStore,
        server: Server,
        fileTab: RemoteFileTab,
        initialPath: String? = nil,
        onCurrentPathChange: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.browser = browser
        self.server = server
        self.fileTab = fileTab
        self.initialPath = initialPath
        self.onCurrentPathChange = onCurrentPathChange
    }

    var snapshot: Snapshot {
        let entries = browser.entries(for: fileTab)
        let viewerPayload = browser.viewerPayload(for: fileTab)
        let selectedPath = browser.selectedEntryPath(for: fileTab) ?? viewerPayload?.entry.path
        let selectedEntry = entries.first(where: { $0.path == selectedPath }) ?? viewerPayload?.entry

        return Snapshot(
            currentPath: browser.currentPath(for: fileTab),
            breadcrumbs: browser.breadcrumbs(for: fileTab),
            entries: entries,
            selectedEntry: selectedEntry,
            viewerPayload: viewerPayload,
            directoryError: browser.error(for: fileTab),
            viewerError: browser.viewerError(for: fileTab),
            isLoadingDirectory: browser.isLoading(for: fileTab),
            isLoadingViewer: browser.isLoadingViewer(for: fileTab),
            sort: browser.sort(for: fileTab),
            sortDirection: browser.sortDirection(for: fileTab),
            showHiddenFiles: browser.showHiddenFiles(for: fileTab),
            isTruncated: browser.isTruncated(for: fileTab),
            selectedPath: selectedPath,
            filesystemStatus: browser.filesystemStatus(for: fileTab)
        )
    }

    var initialLoadTaskID: String {
        "\(server.id.uuidString):\(fileTab.id.uuidString):\(initialPath ?? "")"
    }

    var remoteRowDropTypeIdentifiers: [String] {
        [UTType.vvtermRemoteFileEntry.identifier, UTType.fileURL.identifier]
    }

    var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    var terminalThemeBackgroundColor: Color {
        if let color = ThemeColorParser.backgroundColor(for: effectiveThemeName) {
            return color
        }

        if let cachedHex = UserDefaults.standard.string(forKey: "terminalBackgroundColor") {
            return Color.fromHex(cachedHex)
        }

        return colorScheme == .dark ? .black : .white
    }

    var operationErrorText: String {
        operationErrorMessage ?? ""
    }

    @ViewBuilder
    var newFolderPromptActions: some View {
        TextField(String(localized: "Folder Name"), text: $newFolderName)

        Button(String(localized: "Create")) {
            createFolder()
        }
        .disabled(trimmedNewFolderName.isEmpty || isCreateFolderSubmitting)

        Button(String(localized: "Cancel"), role: .cancel) {
            resetNewFolderPrompt()
        }
    }

    var newFolderPromptMessage: Text {
        Text(String(localized: "Create a folder in the current remote directory."))
    }

    @ViewBuilder
    var operationErrorActions: some View {
        Button(String(localized: "OK"), role: .cancel) {
            operationErrorMessage = nil
        }
    }

    var operationErrorMessageView: Text {
        Text(operationErrorText)
    }

    @ViewBuilder
    func renameSheet(entry: RemoteFileEntry) -> some View {
        platformRenameSheetSizing(RemoteFileRenameSheet(
            entry: entry,
            proposedName: $renameName,
            isSubmitting: isRenameSubmitting,
            onCancel: resetRenamePrompt,
            onRename: { renameEntry() }
        ))
    }

    func moveSheet(entry: RemoteFileEntry) -> some View {
        let fileBrowser = browser
        let fileServer = server

        return platformMoveSheetSizing(RemoteFileMoveSheet(
            entry: entry,
            destinationDirectory: $moveDestinationDirectory,
            onLoadDirectories: { path in
                try await fileBrowser.listDirectories(at: path, server: fileServer)
            },
            isSubmitting: isMoveSubmitting,
            onCancel: resetMovePrompt,
            onMove: moveEntry
        ))
    }

    @ViewBuilder
    func deleteSheet(entry: RemoteFileEntry) -> some View {
        RemoteFileDeleteConfirmationSheet(
            entry: entry,
            message: deleteAlertMessage(for: entry),
            onCancel: { deleteTargetEntry = nil },
            onDelete: deleteEntry
        )
    }

    @ViewBuilder
    func permissionSheet(entry: RemoteFileEntry) -> some View {
        platformPermissionSheetSizing(RemoteFilePermissionEditorSheet(
            entry: entry,
            draft: $permissionDraft,
            originalAccessBits: permissionOriginalAccessBits,
            preservedBits: permissionPreservedBits,
            errorMessage: permissionErrorMessage,
            isSubmitting: isPermissionSubmitting,
            onCancel: resetPermissionEditor,
            onApply: applyPermissions
        ))
    }

    var body: some View {
        let base = fileNoticeHost {
            ZStack {
                platformContent(snapshot)

                if isDropTargeted {
                    RemoteFileDropOverlay()
                        .padding(20)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .task(id: initialLoadTaskID) {
            await browser.loadInitialPath(for: server, tab: fileTab, initialPath: initialPath)
        }
        .onAppear {
            onCurrentPathChange(browser.lastVisitedPath(for: fileTab))
        }

        let withUploadImport = platformUploadImportPresentation(base)

        let withDownloadExport = downloadExportPresentation(withUploadImport)

        let withSearch = platformSearchPresentation(withDownloadExport)
        let withShare = platformSharePresentation(withSearch)
        let withDrop = platformDropPresentation(withShare, snapshot: snapshot)
        let withNewFolder = platformNewFolderPresentation(withDrop)

        let withOperationError = withNewFolder
        .alert(
            String(localized: "Files"),
            isPresented: operationErrorBinding,
            actions: { operationErrorActions },
            message: { operationErrorMessageView }
        )

        let withTransferCancellation = withOperationError
        .alert(
            transferCancellationRequest?.kind.confirmationTitle ?? String(localized: "Cancel Transfer?"),
            isPresented: transferCancellationBinding,
            presenting: transferCancellationRequest
        ) { request in
            Button(request.kind.keepButtonTitle, role: .cancel) {}
            Button(request.kind.cancelButtonTitle, role: .destructive) {
                cancelTransfer(id: request.id)
            }
        } message: { request in
            Text(request.kind.confirmationMessage)
        }

        let withRename = platformRenamePresentation(withTransferCancellation)

        let withMove = withRename
        .sheet(item: $moveTargetEntry, onDismiss: resetMovePrompt) { entry in
            moveSheet(entry: entry)
                .adaptiveSoftScrollEdges()
        }

        let withDelete = platformDeletePresentation(withMove)

        let withPermission = withDelete
        .sheet(item: $permissionTargetEntry, onDismiss: resetPermissionEditor) { entry in
            permissionSheet(entry: entry)
                .adaptiveSoftScrollEdges()
        }

        let withPathTracking = withPermission
        .onChange(of: snapshot.currentPath) { newValue in
            onCurrentPathChange(newValue)
            if let destination = newFolderDestinationPath, destination != newValue {
                resetNewFolderPrompt()
            }
            platformCurrentPathDidChange()
        }

        let withToolbarCommands = withPathTracking
        .onChange(of: browser.pendingToolbarCommand?.id) { _ in
            handlePendingToolbarCommand()
        }

        platformSelectionTrackingPresentation(withToolbarCommands, snapshot: snapshot)
    }

    @ViewBuilder
    func fileNoticeHost<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NoticeHost(
            topBanner: noticeHost.topBanner,
            bottomOperations: noticeHost.bottomOperations,
            bottomInsetBehavior: .contentBottom
        ) {
            content()
        }
    }

    @ViewBuilder
    func downloadExportPresentation<Content: View>(_ content: Content) -> some View {
        if #available(iOS 17, macOS 14, *) {
            content.fileExporter(
                isPresented: $isDownloadExporterPresented,
                document: downloadExportDocument,
                contentTypes: [.data],
                defaultFilename: downloadExportFilename,
                onCompletion: handleDownloadExportCompletion,
                onCancellation: handleDownloadExportCancellation
            )
        } else {
            content.fileExporter(
                isPresented: $isDownloadExporterPresented,
                document: downloadExportDocument,
                contentType: .data,
                defaultFilename: downloadExportFilename,
                onCompletion: handleDownloadExportCompletion
            )
        }
    }

    var uploadImporterBinding: Binding<Bool> {
        Binding(
            get: { uploadDestinationPath != nil },
            set: { isPresented in
                if !isPresented {
                    uploadDestinationPath = nil
                }
            }
        )
    }

    var transferCancellationBinding: Binding<Bool> {
        Binding(
            get: { transferCancellationRequest != nil },
            set: { if !$0 { transferCancellationRequest = nil } }
        )
    }

    var newFolderPromptBinding: Binding<Bool> {
        Binding(
            get: { newFolderDestinationPath != nil },
            set: { isPresented in
                if !isPresented {
                    resetNewFolderPrompt()
                }
            }
        )
    }

    var renamePromptBinding: Binding<Bool> {
        Binding(
            get: { renameTargetEntry != nil },
            set: { isPresented in
                if !isPresented {
                    resetRenamePrompt()
                }
            }
        )
    }

    var deletePromptBinding: Binding<Bool> {
        Binding(
            get: { deleteTargetEntry != nil },
            set: { isPresented in
                if !isPresented {
                    deleteTargetEntry = nil
                }
            }
        )
    }

    func deleteAlertMessage(for entry: RemoteFileEntry) -> String {
        let itemName = entry.name.isEmpty ? entry.path : entry.name
        return String(
            format: String(localized: "This will permanently remove \"%@\" from the remote server. This cannot be undone."),
            itemName
        )
    }

    var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { operationErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    operationErrorMessage = nil
                }
            }
        )
    }

    func remoteOperationErrorMessage(for error: Error) -> String {
        RemoteFileBrowserError.map(error).errorDescription ?? error.localizedDescription
    }

    @MainActor
    func presentOperationError(_ error: Error) {
        operationErrorMessage = remoteOperationErrorMessage(for: error)
    }

    @MainActor
    func copyPathToClipboard(_ path: String) {
        Clipboard.copy(path)
        noticeHost.show(
            NoticeItem(
                id: UUID().uuidString,
                lane: .topBanner,
                level: .success,
                leading: .icon("checkmark.circle.fill"),
                message: String(localized: "Path copied to clipboard."),
                lifetime: .autoDismiss(.seconds(1.5))
            )
        )
    }

    @MainActor
    func beginTransferStatus(
        id: UUID,
        title: String,
        message: String,
        completedUnitCount: Int? = nil,
        totalUnitCount: Int? = nil,
        fileURL: URL? = nil,
        fileName: String? = nil,
        filePath: String? = nil
    ) {
        noticeHost.show(
            NoticeItem(
                id: id.uuidString,
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: title,
                message: message,
                detail: transferDetail(fileName: fileName, filePath: filePath),
                progress: transferProgress(
                    completedUnitCount: completedUnitCount,
                    totalUnitCount: totalUnitCount
                ),
                action: transferCompletionAction(fileURL: fileURL),
                dismissAction: { requestTransferCancellation(id: id) }
            )
        )
    }

    @MainActor
    func updateTransferStatus(
        id: UUID,
        title: String,
        message: String,
        completedUnitCount: Int,
        totalUnitCount: Int
    ) {
        noticeHost.show(
            NoticeItem(
                id: id.uuidString,
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: title,
                message: message,
                progress: NoticeProgress(
                    completedUnitCount: completedUnitCount,
                    totalUnitCount: totalUnitCount
                ),
                dismissAction: { requestTransferCancellation(id: id) }
            )
        )
    }

    @MainActor
    func completeTransferStatus(
        id: UUID,
        title: String,
        message: String,
        fileURL: URL? = nil,
        fileName: String? = nil,
        filePath: String? = nil,
        lifetime: NoticeLifetime = .autoDismiss(.seconds(2))
    ) {
        noticeHost.show(
            NoticeItem(
                id: id.uuidString,
                lane: .bottomOperation,
                level: .success,
                leading: .icon("checkmark.circle.fill"),
                title: title,
                message: message,
                detail: transferDetail(fileName: fileName, filePath: filePath),
                lifetime: lifetime,
                action: transferCompletionAction(fileURL: fileURL)
            )
        )
    }

    func transferProgress(
        completedUnitCount: Int?,
        totalUnitCount: Int?
    ) -> NoticeProgress? {
        guard let completedUnitCount, let totalUnitCount else { return nil }
        return NoticeProgress(
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount
        )
    }

    func transferDetail(fileName: String?, filePath: String?) -> String? {
        if let filePath, !filePath.isEmpty {
            return filePath
        }

        if let fileName, !fileName.isEmpty {
            return fileName
        }

        return nil
    }

    func transferCompletionAction(fileURL: URL?) -> NoticeAction? {
        platformTransferCompletionAction(fileURL: fileURL)
    }

    @MainActor
    func performTransfer(
        id: UUID = UUID(),
        cancellationKind: TransferKind = .transfer,
        title: String,
        initialMessage: String,
        successMessage: String,
        successFileURL: URL? = nil,
        successFileName: String? = nil,
        successFilePath: String? = nil,
        completionLifetime: NoticeLifetime = .autoDismiss(.seconds(2)),
        onSuccess: (@MainActor () -> Void)? = nil,
        operation: @escaping (@escaping @MainActor (RemoteFileBrowserStore.TransferProgress) -> Void) async throws -> Void
    ) {
        let transferID = id
        activeTransferKinds[transferID] = cancellationKind

        withAnimation(.easeInOut(duration: 0.2)) {
            beginTransferStatus(
                id: transferID,
                title: title,
                message: initialMessage
            )
        }

        let transferTask = Task {
            do {
                try await operation { progress in
                    let itemName = progress.currentItemName.isEmpty
                        ? String(localized: "item")
                        : progress.currentItemName
                    let progressMessage: String
                    if progress.completedUnitCount == 0 {
                        progressMessage = String(
                            format: String(localized: "Uploading %@"),
                            itemName
                        )
                    } else {
                        progressMessage = String(
                            format: String(localized: "%lld of %lld: %@"),
                            Int64(progress.completedUnitCount),
                            Int64(progress.totalUnitCount),
                            itemName
                        )
                    }
                    updateTransferStatus(
                        id: transferID,
                        title: title,
                        message: progressMessage,
                        completedUnitCount: progress.completedUnitCount,
                        totalUnitCount: progress.totalUnitCount
                    )
                }

                try Task.checkCancellation()

                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        completeTransferStatus(
                            id: transferID,
                            title: title,
                            message: successMessage,
                            fileURL: successFileURL,
                            fileName: successFileName,
                            filePath: successFilePath,
                            lifetime: completionLifetime
                        )
                        finishTransfer(id: transferID)
                    }
                    onSuccess?()
                }
            } catch is CancellationError {
                await MainActor.run {
                    noticeHost.dismiss(id: transferID.uuidString)
                    finishTransfer(id: transferID)
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else {
                        noticeHost.dismiss(id: transferID.uuidString)
                        finishTransfer(id: transferID)
                        return
                    }

                    noticeHost.show(
                        NoticeItem(
                            id: transferID.uuidString,
                            lane: .bottomOperation,
                            level: .error,
                            leading: .icon("xmark.octagon.fill"),
                            title: title,
                            message: remoteOperationErrorMessage(for: error),
                            dismissAction: { noticeHost.dismiss(id: transferID.uuidString) }
                        )
                    )
                    finishTransfer(id: transferID)
                }
            }
        }
        transferTasks[transferID] = transferTask
    }

    @MainActor
    func performTransfer(
        id: UUID = UUID(),
        cancellationKind: TransferKind = .transfer,
        title: String,
        initialMessage: String,
        successMessage: String,
        successFileURL: URL? = nil,
        successFileName: String? = nil,
        successFilePath: String? = nil,
        completionLifetime: NoticeLifetime = .autoDismiss(.seconds(2)),
        onSuccess: (@MainActor () -> Void)? = nil,
        operation: @escaping () async throws -> Void
    ) {
        performTransfer(
            id: id,
            cancellationKind: cancellationKind,
            title: title,
            initialMessage: initialMessage,
            successMessage: successMessage,
            successFileURL: successFileURL,
            successFileName: successFileName,
            successFilePath: successFilePath,
            completionLifetime: completionLifetime,
            onSuccess: onSuccess
        ) { _ in
            try await operation()
        }
    }

    @MainActor
    func requestTransferCancellation(id: UUID) {
        guard transferTasks[id] != nil else {
            noticeHost.dismiss(id: id.uuidString)
            return
        }

        transferCancellationRequest = TransferCancellationRequest(
            id: id,
            kind: activeTransferKinds[id] ?? .transfer
        )
    }

    @MainActor
    func cancelTransfer(id: UUID) {
        transferTasks.removeValue(forKey: id)?.cancel()
        activeTransferKinds.removeValue(forKey: id)
        transferCancellationRequest = nil
        noticeHost.dismiss(id: id.uuidString)
    }

    @MainActor
    func finishTransfer(id: UUID) {
        transferTasks.removeValue(forKey: id)
        activeTransferKinds.removeValue(forKey: id)
        if transferCancellationRequest?.id == id {
            transferCancellationRequest = nil
        }
    }

    func performOperation(
        onFailure: (@MainActor (Error) -> Void)? = nil,
        operation: @escaping () async throws -> Void
    ) {
        Task {
            do {
                try await operation()
            } catch {
                await MainActor.run {
                    if let onFailure {
                        onFailure(error)
                    } else {
                        presentOperationError(error)
                    }
                }
            }
        }
    }

    func performOperation<Result>(
        operation: @escaping () async throws -> Result,
        onSuccess: @escaping @MainActor (Result) -> Void,
        onFailure: (@MainActor (Error) -> Void)? = nil
    ) {
        Task {
            do {
                let result = try await operation()
                await MainActor.run {
                    onSuccess(result)
                }
            } catch {
                await MainActor.run {
                    if let onFailure {
                        onFailure(error)
                    } else {
                        presentOperationError(error)
                    }
                }
            }
        }
    }

    var trimmedNewFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedRenameName: String {
        renameName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func handlePendingToolbarCommand() {
        guard let command = browser.pendingToolbarCommand,
              command.serverId == server.id,
              command.tabId == fileTab.id else {
            return
        }

        switch command.action {
        case .upload(let destinationPath):
            beginUpload(to: destinationPath)
        case .createFolder(let destinationPath):
            beginCreateFolder(in: destinationPath)
        }

        browser.consumeToolbarCommand(command)
    }

    @ViewBuilder
    func browserActionMenu(currentPath: String) -> some View {
        Button {
            beginUpload(to: currentPath)
        } label: {
            Label(String(localized: "Upload…"), systemImage: "square.and.arrow.up")
        }

        Button {
            beginCreateFolder(in: currentPath)
        } label: {
            Label(String(localized: "New Folder…"), systemImage: "folder.badge.plus")
        }

        Divider()

        Button {
            copyPathToClipboard(currentPath)
        } label: {
            Label(String(localized: "Copy Path"), systemImage: "document.on.document")
        }
    }

    @ViewBuilder
    func entryActionMenu(_ entry: RemoteFileEntry) -> some View {
        switch entry.type {
        case .directory:
            Button {
                Task { await browser.openDirectory(entry, in: fileTab, server: server) }
            } label: {
                Label(String(localized: "Open"), systemImage: "folder")
            }

            Button {
                beginUpload(to: entry.path)
            } label: {
                Label(String(localized: "Upload…"), systemImage: "square.and.arrow.up")
            }

            Button {
                beginCreateFolder(in: entry.path)
            } label: {
                Label(String(localized: "New Folder…"), systemImage: "folder.badge.plus")
            }

            permissionMenuAction(for: entry)

        case .file, .other, .symlink:
            Button {
                previewEntry(entry)
            } label: {
                Label(String(localized: "Open"), systemImage: "doc.text")
            }

            Button {
                beginDownload(entry)
            } label: {
                Label(String(localized: "Download…"), systemImage: "arrow.down.circle")
            }

            Button {
                beginShare(entry)
            } label: {
                Label(String(localized: "Share…"), systemImage: "square.and.arrow.up")
            }

            Button {
                beginUpload(to: RemoteFilePath.parent(of: entry.path))
            } label: {
                Label(String(localized: "Upload Here…"), systemImage: "square.and.arrow.up")
            }

            Button {
                beginCreateFolder(in: RemoteFilePath.parent(of: entry.path))
            } label: {
                Label(String(localized: "New Folder Here…"), systemImage: "folder.badge.plus")
            }

            permissionMenuAction(for: entry)
        }

        Divider()

        renameAndMoveMenuActions(for: entry)
        deleteMenuAction(for: entry)

        Divider()

        clipboardMenuActions(for: entry)
    }

    @ViewBuilder
    func inspectorActionMenu(_ entry: RemoteFileEntry) -> some View {
        if entry.type != .directory {
            Button {
                beginDownload(entry)
            } label: {
                Label(String(localized: "Download…"), systemImage: "arrow.down.circle")
            }

            Button {
                beginShare(entry)
            } label: {
                Label(String(localized: "Share…"), systemImage: "square.and.arrow.up")
            }

            Divider()
        }

        permissionMenuAction(for: entry)
        renameAndMoveMenuActions(for: entry)

        Divider()

        clipboardMenuActions(for: entry)

        Divider()

        deleteMenuAction(for: entry)
    }

    @ViewBuilder
    func permissionMenuAction(for entry: RemoteFileEntry) -> some View {
        if canEditPermissions(for: entry) {
            Button {
                beginEditPermissions(entry)
            } label: {
                Label(String(localized: "Permissions…"), systemImage: "lock.shield")
            }
        }
    }

    @ViewBuilder
    func renameAndMoveMenuActions(for entry: RemoteFileEntry) -> some View {
        Button {
            beginRename(entry)
        } label: {
            Label(String(localized: "Rename…"), systemImage: "pencil")
        }

        Button {
            beginMove(entry)
        } label: {
            Label(String(localized: "Move…"), systemImage: "arrow.right.circle")
        }
    }

    @ViewBuilder
    func clipboardMenuActions(for entry: RemoteFileEntry) -> some View {
        Button {
            Clipboard.copy(entry.name)
        } label: {
            Label(String(localized: "Copy Name"), systemImage: "textformat")
        }

        Button {
            copyPathToClipboard(entry.path)
        } label: {
            Label(String(localized: "Copy Path"), systemImage: "document.on.document")
        }
    }

    func deleteMenuAction(for entry: RemoteFileEntry) -> some View {
        Button(role: .destructive) {
            requestDelete([entry])
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
    }

    func beginUpload(to remotePath: String) {
        platformBeginUpload(to: remotePath)
    }

    func beginDownload(_ entry: RemoteFileEntry) {
        guard entry.type != .directory else { return }
        platformBeginDownload(entry)
    }

    func beginShare(_ entry: RemoteFileEntry) {
        guard entry.type != .directory else { return }

        cleanupShareItem()

        performTransfer(
            title: String(localized: "Sharing"),
            initialMessage: String(localized: "Preparing remote file."),
            successMessage: String(localized: "Share sheet ready.")
        ) {
            let temporaryURL = try temporaryDownloadURL(for: entry)
            try await browser.downloadFile(
                at: entry.path,
                to: temporaryURL,
                server: server
            )

            await MainActor.run {
                shareItem = RemoteFileShareItem(
                    sourceURL: temporaryURL,
                    title: entry.name
                )
            }
        }
    }

    func beginCreateFolder(in remotePath: String) {
        platformBeginCreateFolder(in: remotePath)
    }

    func beginRename(_ entry: RemoteFileEntry) {
        platformBeginRename(entry)
    }

    func beginMove(_ entry: RemoteFileEntry) {
        moveTargetEntry = entry
        moveDestinationDirectory = RemoteFilePath.parent(of: entry.path)
        isMoveSubmitting = false
    }

    func beginEditPermissions(_ entry: RemoteFileEntry) {
        guard canEditPermissions(for: entry), let permissions = entry.permissions else { return }
        permissionTargetEntry = entry
        permissionDraft = RemoteFilePermissionDraft(accessBits: permissions)
        permissionOriginalAccessBits = permissions & 0o777
        permissionPreservedBits = entry.specialPermissionBits
        permissionFileTypeBits = permissions & UInt32(LIBSSH2_SFTP_S_IFMT)
        permissionErrorMessage = nil
        isPermissionSubmitting = false
    }

    func canEditPermissions(for entry: RemoteFileEntry) -> Bool {
        guard entry.permissions != nil else { return false }
        switch entry.type {
        case .symlink:
            return false
        case .file, .directory, .other:
            return true
        }
    }

    func previewEntry(_ entry: RemoteFileEntry) {
        Task {
            await browser.activate(entry, in: fileTab, server: server)
            await platformDidActivatePreviewEntry(entry)
        }
    }

    func handleUploadSelection(_ result: Result<[URL], Error>) {
        guard let destinationPath = uploadDestinationPath else { return }
        uploadDestinationPath = nil
        handleUploadSelection(result, to: destinationPath)
    }

    func handleUploadSelection(_ result: Result<[URL], Error>, for request: UploadImportRequest) {
        if uploadImportRequest?.id == request.id {
            uploadImportRequest = nil
        }
        handleUploadSelection(result, to: request.destinationPath)
    }

    func handleUploadSelection(_ result: Result<[URL], Error>, to destinationPath: String) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            beginUploadFlow(
                urls: urls,
                to: destinationPath,
                initialMessage: String(localized: "Preparing files for upload.")
            )
        case .failure(let error):
            presentOperationError(error)
        }
    }

    func handleDownloadExportCompletion(_ result: Result<URL, Error>) {
        isDownloadExporterPresented = false
        let noticeID = downloadTransferNoticeID?.uuidString

        switch result {
        case .success:
            cleanupDownloadExport()
            if let noticeID {
                noticeHost.show(
                    NoticeItem(
                        id: noticeID,
                        lane: .bottomOperation,
                        level: .success,
                        leading: .icon("checkmark.circle.fill"),
                        title: String(localized: "Downloading"),
                        message: String(localized: "Export complete."),
                        lifetime: .autoDismiss(.seconds(2))
                    )
                )
            }
        case .failure(let error):
            let nsError = error as NSError
            if nsError.code == NSUserCancelledError {
                handleDownloadExportCancellation()
            } else if let noticeID {
                cleanupDownloadExport()
                noticeHost.show(
                    NoticeItem(
                        id: noticeID,
                        lane: .bottomOperation,
                        level: .error,
                        leading: .icon("xmark.octagon.fill"),
                        title: String(localized: "Downloading"),
                        message: remoteOperationErrorMessage(for: error),
                        dismissAction: { noticeHost.dismiss(id: noticeID) }
                    )
                )
            } else {
                cleanupDownloadExport()
                presentOperationError(error)
            }
        }

        downloadTransferNoticeID = nil
    }

    func handleDownloadExportCancellation() {
        isDownloadExporterPresented = false
        RemoteFileDownloadExportCancellationHandler.handle(
            noticeID: downloadTransferNoticeID,
            cleanup: cleanupDownloadExport,
            dismissNotice: noticeHost.dismiss
        )

        downloadTransferNoticeID = nil
    }

    func beginUploadFlow(urls: [URL], to destinationPath: String, initialMessage: String) {
        performTransfer(
            cancellationKind: .upload,
            title: String(localized: "Uploading"),
            initialMessage: initialMessage,
            successMessage: String(localized: "Upload complete.")
        ) { onProgress in
            try await browser.uploadFilesResolvingConflicts(
                at: urls,
                to: destinationPath,
                in: fileTab,
                server: server,
                onProgress: onProgress
            )
        }
    }

    func handleCurrentDirectoryDrop(_ providers: [NSItemProvider], to destinationPath: String) -> Bool {
        if handleRemoteDrop(providers, to: destinationPath) {
            return true
        }

        return handleLocalDrop(providers, to: destinationPath)
    }

    func handleLocalDrop(_ providers: [NSItemProvider], to destinationPath: String) -> Bool {
        let fileURLProviders = providers.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileURLProviders.isEmpty else { return false }

        Task {
            do {
                let urls = try await loadDroppedURLs(from: fileURLProviders)
                await MainActor.run {
                    beginUploadFlow(
                        urls: urls,
                        to: destinationPath,
                        initialMessage: String(localized: "Preparing dropped files.")
                    )
                }
            } catch {
                await MainActor.run {
                    presentOperationError(error)
                }
            }
        }

        return true
    }

    func handleRemoteDrop(_ providers: [NSItemProvider], to destinationPath: String) -> Bool {
        let remoteProviders = providers.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.vvtermRemoteFileEntry.identifier)
        }
        guard !remoteProviders.isEmpty else { return false }

        performTransfer(
            title: String(localized: "Transferring"),
            initialMessage: String(localized: "Preparing remote items."),
            successMessage: String(localized: "Transfer complete.")
        ) { onProgress in
            let payloads = try await loadDroppedRemotePayloads(from: remoteProviders)
            try await transferDroppedRemoteItems(
                payloads,
                to: destinationPath,
                onProgress: onProgress
            )
        }

        return true
    }

    func handleFolderDrop(_ providers: [NSItemProvider], to entry: RemoteFileEntry) -> Bool {
        guard entry.type == .directory else { return false }
        return handleCurrentDirectoryDrop(providers, to: entry.path)
    }

    func dragItemProvider(for entry: RemoteFileEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = dragSuggestedName(for: [entry])
        registerRemoteDragPayload(for: [entry], in: provider)
        registerFileRepresentation(for: entry, in: provider)
        return provider
    }

    func registerRemoteDragPayload(for entries: [RemoteFileEntry], in provider: NSItemProvider) {
        let encodedPayload = Result {
            try JSONEncoder().encode(RemoteFileDragPayload(serverId: server.id, entries: entries))
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.vvtermRemoteFileEntry.identifier,
            visibility: .ownProcess
        ) { completion in
            do {
                let data = try encodedPayload.get()
                completion(data, nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
    }

    func registerFileRepresentation(for entry: RemoteFileEntry, in provider: NSItemProvider) {
        let typeIdentifier = dragFileTypeIdentifier(for: entry)
        let preparedTemporaryURL = Result {
            try temporaryDragExportURL(for: entry)
        }
        provider.registerFileRepresentation(
            forTypeIdentifier: typeIdentifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)

            Task {
                do {
                    let temporaryURL = try preparedTemporaryURL.get()
                    try await browser.downloadItem(entry, to: temporaryURL, server: server)
                    guard !progress.isCancelled else {
                        completion(nil, false, CancellationError())
                        return
                    }
                    completion(temporaryURL, false, nil)
                    progress.completedUnitCount = 1
                } catch {
                    completion(nil, false, error)
                }
            }

            return progress
        }
    }

    func dragFileTypeIdentifier(for entry: RemoteFileEntry) -> String {
        if entry.type == .directory {
            return UTType.folder.identifier
        }

        let pathExtension = URL(fileURLWithPath: entry.name).pathExtension
        return UTType(filenameExtension: pathExtension)?.identifier ?? UTType.data.identifier
    }

    func temporaryDragExportURL(for entry: RemoteFileEntry) throws -> URL {
        let exportDirectory = try temporaryDragExportDirectory()
        let fallbackName = entry.type == .directory ? "Folder" : "download"
        let filename = entry.name.isEmpty ? fallbackName : entry.name
        return exportDirectory.appendingPathComponent(filename, isDirectory: entry.type == .directory)
    }

    func temporaryDragExportDirectory(named folderName: String? = nil) throws -> URL {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("VVTermDraggedItems", isDirectory: true)
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let trimmedFolderName = folderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let directoryName = trimmedFolderName.isEmpty ? UUID().uuidString : trimmedFolderName
        let exportDirectory = rootDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        return exportDirectory
    }


    func loadDroppedURLs(from providers: [NSItemProvider]) async throws -> [URL] {
        var urls: [URL] = []

        for provider in providers {
            urls.append(try await loadDroppedURL(from: provider))
        }

        let uniqueURLs = Array(NSOrderedSet(array: urls).compactMap { $0 as? URL })
        guard !uniqueURLs.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "No valid files or folders were dropped."))
        }
        return uniqueURLs
    }

    func loadDroppedURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }

                if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                    return
                }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                    return
                }

                if let text = item as? String,
                   let url = URL(string: text) {
                    continuation.resume(returning: url)
                    return
                }

                continuation.resume(
                    throwing: RemoteFileBrowserError.failed(
                        String(localized: "The dropped item could not be resolved to a local file or folder.")
                    )
                )
            }
        }
    }

    func loadDroppedRemotePayloads(from providers: [NSItemProvider]) async throws -> [RemoteFileDragPayload] {
        var payloads: [RemoteFileDragPayload] = []

        for provider in providers {
            payloads.append(try await loadDroppedRemotePayload(from: provider))
        }

        var seenPaths: Set<String> = []
        let uniquePayloads: [RemoteFileDragPayload] = payloads.compactMap { payload in
            let uniqueEntries = payload.entries.filter { entry in
                seenPaths.insert(entry.path).inserted
            }
            guard !uniqueEntries.isEmpty else { return nil }
            return RemoteFileDragPayload(serverId: payload.serverId, entries: uniqueEntries)
        }
        guard !uniquePayloads.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "No valid remote items were dropped."))
        }
        return uniquePayloads
    }

    func loadDroppedRemotePayload(from provider: NSItemProvider) async throws -> RemoteFileDragPayload {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.vvtermRemoteFileEntry.identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data else {
                    continuation.resume(
                        throwing: RemoteFileBrowserError.failed(
                            String(localized: "The dragged remote item could not be decoded.")
                        )
                    )
                    return
                }

                Task { @MainActor in
                    do {
                        let payload = try JSONDecoder().decode(RemoteFileDragPayload.self, from: data)
                        continuation.resume(returning: payload)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func moveDroppedRemoteItems(
        _ payloads: [RemoteFileDragPayload],
        to destinationDirectoryPath: String,
        onProgress: (@MainActor (RemoteFileBrowserStore.TransferProgress) -> Void)? = nil
    ) async throws {
        let uniqueEntries = payloads
            .flatMap(\.entries)
            .reduce(into: [RemoteFileEntry]()) { entries, entry in
                guard !entries.contains(where: { $0.path == entry.path }) else { return }
                entries.append(entry)
            }
        let totalUnitCount = max(1, uniqueEntries.count)

        for (index, sourceEntry) in uniqueEntries.enumerated() {
            let destinationDirectory = RemoteFilePath.normalize(destinationDirectoryPath)
            let destinationPath = RemoteFilePath.appending(sourceEntry.name, to: destinationDirectory)

            guard destinationPath != sourceEntry.path else { continue }

            if sourceEntry.type == .directory {
                let normalizedSource = RemoteFilePath.normalize(sourceEntry.path)
                if destinationDirectory == normalizedSource || destinationDirectory.hasPrefix(normalizedSource + "/") {
                    throw RemoteFileBrowserError.failed(
                        String(localized: "A folder cannot be moved into itself or one of its descendants.")
                    )
                }
            }

            try await browser.renameItem(
                at: sourceEntry.path,
                to: destinationPath,
                in: fileTab,
                server: server
            )
            onProgress?(
                RemoteFileBrowserStore.TransferProgress(
                    completedUnitCount: index + 1,
                    totalUnitCount: totalUnitCount,
                    currentItemName: sourceEntry.name
                )
            )
        }
    }

    func transferDroppedRemoteItems(
        _ payloads: [RemoteFileDragPayload],
        to destinationDirectoryPath: String,
        onProgress: (@MainActor (RemoteFileBrowserStore.TransferProgress) -> Void)? = nil
    ) async throws {
        let sourceServerIDs = Set(payloads.map(\.serverId))
        guard sourceServerIDs.count == 1, let sourceServerId = sourceServerIDs.first else {
            throw RemoteFileBrowserError.failed(
                String(localized: "A single drop can only contain items from one remote server.")
            )
        }

        if sourceServerId == server.id {
            try await moveDroppedRemoteItems(
                payloads,
                to: destinationDirectoryPath,
                onProgress: onProgress
            )
            return
        }

        let uniqueEntries = payloads
            .flatMap(\.entries)
            .reduce(into: [RemoteFileEntry]()) { entries, entry in
                guard !entries.contains(where: { $0.path == entry.path }) else { return }
                entries.append(entry)
            }
        try await browser.copyEntries(
            uniqueEntries,
            from: sourceServerId,
            to: destinationDirectoryPath,
            destinationTab: fileTab,
            destinationServer: server,
            onProgress: onProgress
        )
    }

    func dragSuggestedName(for entries: [RemoteFileEntry]) -> String? {
        guard entries.count > 1 else {
            guard let name = entries.first?.name, !name.isEmpty else { return nil }
            return name
        }

        return String(
            format: String(localized: "%lld items"),
            Int64(entries.count)
        )
    }

    func createFolder() {
        guard let destinationPath = newFolderDestinationPath else { return }
        guard !isCreateFolderSubmitting else { return }
        guard !trimmedNewFolderName.isEmpty else {
            resetNewFolderPrompt()
            return
        }
        isCreateFolderSubmitting = true

        performOperation(
            operation: {
                let folderName = try validatedRemoteName(trimmedNewFolderName)
                try await browser.createDirectory(
                    named: folderName,
                    in: destinationPath,
                    tab: fileTab,
                    server: server
                )
            },
            onSuccess: { _ in
                resetNewFolderPrompt()
            },
            onFailure: { error in
                isCreateFolderSubmitting = false
                presentOperationError(error)
            }
        )
    }

    func renameEntry() {
        guard let entry = renameTargetEntry, !isRenameSubmitting else { return }
        isRenameSubmitting = true

        performOperation(
            operation: {
                let newName = try validatedRemoteName(trimmedRenameName)
                guard newName != entry.name else {
                    return false
                }

                let destinationPath = RemoteFilePath.appending(
                    newName,
                    to: RemoteFilePath.parent(of: entry.path)
                )
                try await browser.renameItem(
                    at: entry.path,
                    to: destinationPath,
                    in: fileTab,
                    server: server
                )
                return true
            },
            onSuccess: { _ in
                resetRenamePrompt()
            },
            onFailure: { error in
                isRenameSubmitting = false
                presentOperationError(error)
            }
        )
    }

    func moveEntry() {
        guard let entry = moveTargetEntry, !isMoveSubmitting else { return }
        isMoveSubmitting = true

        performOperation(
            operation: {
                let sourceDirectory = RemoteFilePath.parent(of: entry.path)
                let destinationDirectory = try validatedRemoteDirectoryPath(
                    moveDestinationDirectory,
                    relativeTo: sourceDirectory
                )
                let destinationPath = RemoteFilePath.appending(entry.name, to: destinationDirectory)

                guard destinationPath != entry.path else {
                    return false
                }

                try await browser.renameItem(
                    at: entry.path,
                    to: destinationPath,
                    in: fileTab,
                    server: server
                )
                return true
            },
            onSuccess: { _ in
                resetMovePrompt()
            },
            onFailure: { error in
                isMoveSubmitting = false
                presentOperationError(error)
            }
        )
    }

    func deleteEntry() {
        guard let entry = deleteTargetEntry else { return }
        deleteTargetEntry = nil

        deleteEntries([entry])
    }

    func deleteEntries(_ entries: [RemoteFileEntry]) {
        guard !entries.isEmpty else { return }

        performOperation {
            for entry in entries {
                try await browser.deleteItem(
                    at: entry.path,
                    in: fileTab,
                    server: server,
                    type: entry.type
                )
            }
        }
    }

    func requestDelete(_ entries: [RemoteFileEntry]) {
        guard !entries.isEmpty else { return }
        platformRequestDelete(entries)
    }

    func resetNewFolderPrompt() {
        newFolderDestinationPath = nil
        newFolderName = ""
        isCreateFolderSubmitting = false
    }

    func resetRenamePrompt() {
        renameTargetEntry = nil
        renameName = ""
        isRenameSubmitting = false
    }

    func resetMovePrompt() {
        moveTargetEntry = nil
        moveDestinationDirectory = ""
        isMoveSubmitting = false
    }

    func applyPermissions() {
        guard let entry = permissionTargetEntry, !isPermissionSubmitting else { return }
        permissionErrorMessage = nil
        isPermissionSubmitting = true

        performOperation(
            operation: {
                let requestedPermissions = permissionFileTypeBits | permissionPreservedBits | permissionDraft.accessBits
                try await browser.setPermissions(entry, permissions: requestedPermissions, in: fileTab, server: server)
            },
            onSuccess: { _ in
                resetPermissionEditor()
            },
            onFailure: { error in
                isPermissionSubmitting = false
                permissionErrorMessage = remoteOperationErrorMessage(for: error)
            }
        )
    }

    func resetPermissionEditor() {
        permissionTargetEntry = nil
        permissionDraft = RemoteFilePermissionDraft(accessBits: 0)
        permissionOriginalAccessBits = 0
        permissionPreservedBits = 0
        permissionFileTypeBits = 0
        permissionErrorMessage = nil
        isPermissionSubmitting = false
    }

    func validatedRemoteName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "Name cannot be empty."))
        }
        guard trimmed != ".", trimmed != ".." else {
            throw RemoteFileBrowserError.failed(String(localized: "This name is not allowed."))
        }
        guard !trimmed.contains("/") else {
            throw RemoteFileBrowserError.failed(String(localized: "Names cannot contain slashes."))
        }
        return trimmed
    }

    func validatedRemoteDirectoryPath(_ value: String, relativeTo currentPath: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "Destination folder cannot be empty."))
        }
        return RemoteFilePath.normalize(trimmed, relativeTo: currentPath)
    }

    func temporaryDownloadURL(for entry: RemoteFileEntry) throws -> URL {
        let fileManager = FileManager.default
        let downloadDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("VVTermDownloads", isDirectory: true)
        try fileManager.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)

        let uniquePrefix = UUID().uuidString
        let filename = entry.name.isEmpty ? "download" : entry.name
        return downloadDirectory.appendingPathComponent("\(uniquePrefix)-\(filename)")
    }

    func cleanupDownloadExport() {
        if let sourceURL = downloadExportDocument?.sourceURL {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        downloadExportDocument = nil
        downloadExportFilename = ""
    }

    func cleanupShareItem() {
        if let sourceURL = shareItem?.sourceURL {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        shareItem = nil
    }

    func finishSharing(_ item: RemoteFileShareItem) {
        guard shareItem?.id == item.id else { return }
        cleanupShareItem()
    }

    func currentFolderTitle(for path: String) -> String {
        RemoteFilePath.breadcrumbs(for: path).last?.title ?? "/"
    }

    func itemCountLabel(for count: Int) -> String {
        count == 1
            ? String(format: String(localized: "%lld item"), Int64(count))
            : String(format: String(localized: "%lld items"), Int64(count))
    }

    func modifiedLabel(for entry: RemoteFileEntry) -> String {
        guard let modifiedAt = entry.modifiedAt else { return "—" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    func deleteAlertTitle(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Delete Folder?")
        case .file:
            return String(localized: "Delete File?")
        case .symlink, .other:
            return String(localized: "Delete Item?")
        }
    }

    func sizeLabel(for entry: RemoteFileEntry) -> String {
        guard entry.type != .directory, let size = entry.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    func kindLabel(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Folder")
        case .symlink:
            return String(localized: "Symlink")
        case .other:
            return String(localized: "Document")
        case .file:
            let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
            switch ext {
            case "yaml", "yml":
                return String(localized: "YAML Document")
            case "json":
                return String(localized: "JSON Document")
            case "md":
                return String(localized: "Markdown Document")
            case "txt", "log":
                return String(localized: "Text Document")
            case "swift":
                return String(localized: "Swift Source")
            case "sh", "bash", "zsh":
                return String(localized: "Shell Script")
            case "png", "jpg", "jpeg", "gif", "webp", "heic":
                return String(localized: "Image")
            case "zip", "tar", "gz", "tgz", "xz", "bz2":
                return String(localized: "Archive")
            default:
                return String(localized: "Document")
            }
        }
    }

}
