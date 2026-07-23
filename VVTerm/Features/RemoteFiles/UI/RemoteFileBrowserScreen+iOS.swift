import SwiftUI

#if os(iOS)
import Combine
import UIKit

@MainActor
final class RemoteFileBrowserPlatformState: ObservableObject {
    @Published var searchQuery = ""
}

extension RemoteFileBrowserScreen {
    @ViewBuilder
    func platformContent(_ snapshot: Snapshot) -> some View {
        browserContent(snapshot)
    }

    func platformUploadImportPresentation<Content: View>(_ content: Content) -> some View {
        content
            .sheet(item: $uploadImportRequest) { request in
                RemoteFileImportPicker { result in
                    handleUploadSelection(result, for: request)
                }
                .adaptiveSoftScrollEdges()
            }
    }

    func platformSearchPresentation<Content: View>(_ content: Content) -> some View {
        content
            .searchable(text: $platformState.searchQuery, prompt: String(localized: "Search Files"))
    }

    func platformSharePresentation<Content: View>(_ content: Content) -> some View {
        content
            .sheet(item: $shareItem) { item in
                RemoteFileShareSheet(item: item) {
                    finishSharing(item)
                }
                .adaptiveSoftScrollEdges()
            }
    }

    func platformDropPresentation<Content: View>(_ content: Content, snapshot: Snapshot) -> some View {
        content
            .onDrop(of: remoteRowDropTypeIdentifiers, isTargeted: $isDropTargeted) { providers in
                handleCurrentDirectoryDrop(providers, to: snapshot.currentPath)
            }
    }

    func platformNewFolderPresentation<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: newFolderPromptBinding, onDismiss: resetNewFolderPrompt) {
                if let destinationPath = newFolderDestinationPath {
                    RemoteFileCreateFolderSheet(
                        destinationPath: destinationPath,
                        folderName: $newFolderName,
                        isSubmitting: isCreateFolderSubmitting,
                        onCancel: resetNewFolderPrompt,
                        onCreate: createFolder
                    )
                    .adaptiveSoftScrollEdges()
                }
            }
    }

    func platformRenamePresentation<Content: View>(_ content: Content) -> some View {
        content
            .sheet(item: $renameTargetEntry, onDismiss: resetRenamePrompt) { entry in
                renameSheet(entry: entry)
                    .adaptiveSoftScrollEdges()
            }
    }

    func platformDeletePresentation<Content: View>(_ content: Content) -> some View {
        content
            .sheet(item: $deleteTargetEntry, onDismiss: { deleteTargetEntry = nil }) { entry in
                deleteSheet(entry: entry)
                    .adaptiveSoftScrollEdges()
            }
    }

    func platformCurrentPathDidChange() {}

    func platformSelectionTrackingPresentation<Content: View>(
        _ content: Content,
        snapshot: Snapshot
    ) -> some View {
        content
    }

    func platformRenameSheetSizing<Content: View>(_ content: Content) -> some View {
        content
    }

    func platformMoveSheetSizing<Content: View>(_ content: Content) -> some View {
        content
    }

    func platformPermissionSheetSizing<Content: View>(_ content: Content) -> some View {
        content
    }

    func platformTransferCompletionAction(fileURL: URL?) -> NoticeAction? {
        nil
    }

    func platformBeginUpload(to remotePath: String) {
        uploadImportRequest = UploadImportRequest(destinationPath: remotePath)
    }

    func platformBeginDownload(_ entry: RemoteFileEntry) {
        cleanupDownloadExport()
        if let downloadTransferNoticeID {
            noticeHost.dismiss(id: downloadTransferNoticeID.uuidString)
        }

        let transferID = UUID()
        downloadTransferNoticeID = transferID

        let temporaryURL: URL
        do {
            temporaryURL = try temporaryDownloadURL(for: entry)
        } catch {
            downloadTransferNoticeID = nil
            presentOperationError(error)
            return
        }

        performTransfer(
            id: transferID,
            title: String(localized: "Downloading"),
            initialMessage: String(localized: "Preparing remote file."),
            successMessage: String(localized: "Download ready to export."),
            completionLifetime: .persistent,
            onSuccess: {
                guard downloadTransferNoticeID == transferID else { return }
                downloadExportDocument = RemoteFileDownloadDocument(sourceURL: temporaryURL)
                downloadExportFilename = entry.name
                isDownloadExporterPresented = true
            }
        ) {
            try await browser.downloadFile(
                at: entry.path,
                to: temporaryURL,
                server: server
            )
        }
    }

    func platformBeginCreateFolder(in remotePath: String) {
        newFolderDestinationPath = remotePath
        newFolderName = ""
        isCreateFolderSubmitting = false
    }

    func platformBeginRename(_ entry: RemoteFileEntry) {
        renameTargetEntry = entry
        renameName = entry.name
        isRenameSubmitting = false
    }

    func platformDidActivatePreviewEntry(_ entry: RemoteFileEntry) async {
        guard browser.selectedEntryPath(for: fileTab) == entry.path else { return }

        await MainActor.run {
            presentedPreviewPath = entry.path
        }
    }

    func platformRequestDelete(_ entries: [RemoteFileEntry]) {
        guard entries.count == 1, let entry = entries.first else { return }
        deleteTargetEntry = entry
    }

    @ViewBuilder
    func browserContent(_ snapshot: Snapshot) -> some View {
        let displayedEntries = filteredEntries(snapshot)
        let emptyState = makeEmptyStateContent(snapshot, displayedEntries: displayedEntries)

        ZStack {
            if emptyState == nil {
                List {
                    ForEach(displayedEntries) { entry in
                        Button {
                            handleIOSEntryTap(entry)
                        } label: {
                            RemoteFileRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .onDrag {
                            dragItemProvider(for: entry)
                        }
                        .onDrop(of: remoteRowDropTypeIdentifiers, isTargeted: nil) { providers in
                            handleFolderDrop(providers, to: entry)
                        }
                        .contextMenu {
                            entryActionMenu(entry)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                }
                .refreshable {
                    await browser.refresh(server: server, tab: fileTab)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }

            if let emptyState {
                Group {
                    if emptyState.icon == "spinner" {
                        RemoteFileLoadingState(
                            title: emptyState.title,
                            message: emptyState.message
                        )
                    } else {
                        RemoteFileEmptyState(
                            icon: emptyState.icon,
                            title: emptyState.title,
                            message: emptyState.message
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 24)
            }
        }
        .background(Color.clear)
        .navigationDestination(isPresented: previewBinding) {
            fileNoticeHost {
                RemoteFileInspectorView(
                    selectedEntry: snapshot.selectedEntry,
                    viewerPayload: snapshot.viewerPayload,
                    isLoadingViewer: snapshot.isLoadingViewer,
                    viewerError: snapshot.viewerError,
                    directoryError: snapshot.directoryError,
                    chrome: .sheet,
                    backgroundColor: Color(UIColor.systemGroupedBackground),
                    previewBackgroundColor: Color(UIColor.secondarySystemGroupedBackground),
                    sectionBackgroundColor: Color(UIColor.secondarySystemGroupedBackground),
                    onLoadPreview: { entry in
                        Task { await browser.loadPreview(for: entry, in: fileTab, server: server) }
                    },
                    onDownloadPreview: { entry in
                        Task {
                            await browser.loadPreview(for: entry, in: fileTab, server: server, allowLargeDownloads: true)
                        }
                    },
                    onDownload: { entry in
                        beginDownload(entry)
                    },
                    onShare: { entry in
                        beginShare(entry)
                    },
                    onRename: { entry in
                        beginRename(entry)
                    },
                    onMove: { entry in
                        beginMove(entry)
                    },
                    onEditPermissions: { entry in
                        guard canEditPermissions(for: entry) else { return }
                        beginEditPermissions(entry)
                    },
                    onDelete: { entry in
                        deleteTargetEntry = entry
                    },
                    onClose: nil,
                    onSaveText: { entry, text in
                        try await browser.saveTextPreview(text, for: entry, in: fileTab, server: server)
                    }
                )
                .navigationTitle(snapshot.selectedEntry?.name ?? snapshot.viewerPayload?.entry.name ?? String(localized: "Preview"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if let entry = snapshot.selectedEntry ?? snapshot.viewerPayload?.entry {
                            Menu {
                                inspectorActionMenu(entry)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            if #available(iOS 26, *) {
                ToolbarItem(placement: .bottomBar) {
                    toolbarButton(
                        systemName: "arrow.turn.up.left",
                        isDisabled: snapshot.currentPath == "/"
                    ) {
                        Task { await browser.goUp(in: fileTab, server: server) }
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItem(placement: .bottomBar) {
                    toolbarButton(systemName: "arrow.up.doc") {
                        beginUpload(to: snapshot.currentPath)
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItem(placement: .bottomBar) {
                    toolbarButton(systemName: "folder.badge.plus") {
                        beginCreateFolder(in: snapshot.currentPath)
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItem(placement: .bottomBar) {
                    toolbarButton(systemName: "document.on.document") {
                        copyPathToClipboard(snapshot.currentPath)
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItem(placement: .bottomBar) {
                    browserMenu()
                }
            } else {
                ToolbarItemGroup(placement: .bottomBar) {
                    toolbarButton(
                        systemName: "arrow.turn.up.left",
                        isDisabled: snapshot.currentPath == "/"
                    ) {
                        Task { await browser.goUp(in: fileTab, server: server) }
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    toolbarButton(systemName: "arrow.up.doc") {
                        beginUpload(to: snapshot.currentPath)
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    toolbarButton(systemName: "folder.badge.plus") {
                        beginCreateFolder(in: snapshot.currentPath)
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    toolbarButton(systemName: "document.on.document") {
                        copyPathToClipboard(snapshot.currentPath)
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    browserMenu()
                }
            }
        }
        .onChange(of: snapshot.currentPath) { _ in
            platformState.searchQuery = ""
        }
    }

    var previewBinding: Binding<Bool> {
        Binding(
            get: { presentedPreviewPath != nil },
            set: { isPresented in
                if !isPresented {
                    presentedPreviewPath = nil
                }
            }
        )
    }

    func handleIOSEntryTap(_ entry: RemoteFileEntry) {
        Task {
            await browser.activate(entry, in: fileTab, server: server)
            if browser.selectedEntryPath(for: fileTab) == entry.path {
                await MainActor.run {
                    presentedPreviewPath = entry.path
                }
            }
        }
    }

    func filteredEntries(_ snapshot: Snapshot) -> [RemoteFileEntry] {
        guard !trimmedSearchQuery.isEmpty else { return snapshot.entries }

        return snapshot.entries.filter { entry in
            entry.name.localizedCaseInsensitiveContains(trimmedSearchQuery)
                || (entry.symlinkTarget?.localizedCaseInsensitiveContains(trimmedSearchQuery) ?? false)
        }
    }

    var trimmedSearchQuery: String {
        platformState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func makeEmptyStateContent(
        _ snapshot: Snapshot,
        displayedEntries: [RemoteFileEntry]
    ) -> EmptyStateContent? {
        if let error = snapshot.directoryError {
            return EmptyStateContent(
                icon: "exclamationmark.triangle.fill",
                title: String(localized: "Browser Error"),
                message: error.errorDescription ?? error.localizedDescription
            )
        }

        if snapshot.isLoadingDirectory && snapshot.entries.isEmpty {
            return EmptyStateContent(
                icon: "spinner",
                title: String(localized: "Loading Files"),
                message: String(localized: "Fetching the contents of this remote directory.")
            )
        }

        if displayedEntries.isEmpty && !snapshot.isLoadingDirectory {
            guard !trimmedSearchQuery.isEmpty else {
                return EmptyStateContent(
                    icon: "folder",
                    title: String(localized: "Empty Folder"),
                    message: String(localized: "This remote folder does not contain any files yet.")
                )
            }

            return EmptyStateContent(
                icon: "magnifyingglass",
                title: String(localized: "No Results"),
                message: String(
                    format: String(localized: "No items match \"%@\"."),
                    trimmedSearchQuery
                )
            )
        }

        return nil
    }

    func browserMenu() -> some View {
        Menu {
            Toggle(
                String(localized: "Show Hidden Files"),
                isOn: Binding(
                    get: { browser.showHiddenFiles(for: fileTab) },
                    set: { browser.setShowHiddenFiles($0, for: fileTab) }
                )
            )

            Picker(
                String(localized: "Sort"),
                selection: Binding(
                    get: { browser.sort(for: fileTab) },
                    set: { browser.updateSort($0, for: fileTab) }
                )
            ) {
                ForEach(RemoteFileSort.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 36, height: 36)
        }
    }

    func toolbarButton(
        systemName: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .disabled(isDisabled)
    }

}
#endif
