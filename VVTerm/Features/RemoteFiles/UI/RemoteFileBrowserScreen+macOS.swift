import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

extension RemoteFileBrowserScreen {
    enum MacOSInlineEditor: Equatable {
        case createFolder(parentPath: String, proposedName: String, isSubmitting: Bool)
        case rename(entryPath: String, originalName: String, proposedName: String, isSubmitting: Bool)

        var proposedName: String {
            switch self {
            case .createFolder(_, let proposedName, _),
                 .rename(_, _, let proposedName, _):
                return proposedName
            }
        }

        var isSubmitting: Bool {
            switch self {
            case .createFolder(_, _, let isSubmitting),
                 .rename(_, _, _, let isSubmitting):
                return isSubmitting
            }
        }

        var createFolderParentPath: String? {
            guard case .createFolder(let parentPath, _, _) = self else { return nil }
            return parentPath
        }

        var renameEntryPath: String? {
            guard case .rename(let entryPath, _, _, _) = self else { return nil }
            return entryPath
        }
    }

    @ViewBuilder
    func platformContent(_ snapshot: Snapshot) -> some View {
        macOSContent(snapshot)
    }

    func platformUploadImportPresentation<Content: View>(_ content: Content) -> some View {
        content
            .fileImporter(
                isPresented: uploadImporterBinding,
                allowedContentTypes: [.item, .folder],
                allowsMultipleSelection: true
            ) { result in
                handleUploadSelection(result)
            }
    }

    func platformSearchPresentation<Content: View>(_ content: Content) -> some View {
        content
    }

    func platformSharePresentation<Content: View>(_ content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if let shareItem {
                    RemoteFileSharePicker(item: shareItem) {
                        finishSharing(shareItem)
                    }
                    .frame(width: 1, height: 1)
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                }
            }
    }

    func platformDropPresentation<Content: View>(_ content: Content, snapshot: Snapshot) -> some View {
        content
    }

    func platformNewFolderPresentation<Content: View>(_ content: Content) -> some View {
        content
    }

    func platformRenamePresentation<Content: View>(_ content: Content) -> some View {
        content
    }

    func platformDeletePresentation<Content: View>(_ content: Content) -> some View {
        content
    }

    func platformCurrentPathDidChange() {
        cancelMacOSInlineEdit()
        macOSSelectedPaths.removeAll()
    }

    func platformSelectionTrackingPresentation<Content: View>(
        _ content: Content,
        snapshot: Snapshot
    ) -> some View {
        content
            .onChange(of: snapshot.entries.map(\.id)) { visiblePaths in
                let nextSelection = macOSSelectedPaths.intersection(Set(visiblePaths))
                if nextSelection != macOSSelectedPaths {
                    macOSSelectedPaths = nextSelection
                }

                if let inlineRenamePath = macOSInlineEditor?.renameEntryPath,
                   !visiblePaths.contains(inlineRenamePath),
                   macOSInlineEditor?.isSubmitting == false {
                    macOSInlineEditor = nil
                }
            }
            .onChange(of: snapshot.selectedPath) { newValue in
                guard macOSSelectedPaths.count <= 1 else { return }

                guard let newValue, snapshot.entries.contains(where: { $0.id == newValue }) else {
                    if !macOSSelectedPaths.isEmpty {
                        macOSSelectedPaths = []
                    }
                    return
                }

                if macOSSelectedPaths != [newValue] {
                    macOSSelectedPaths = [newValue]
                }
            }
    }

    func macOSContent(_ snapshot: Snapshot) -> some View {
        GeometryReader { proxy in
            let splitMetrics = macOSSplitMetrics(
                totalWidth: proxy.size.width,
                showsPreview: shouldShowMacOSPreview(snapshot)
            )

            VStack(spacing: 0) {
                if macOSTitlebarHeight > 0 {
                    Color.clear
                        .frame(height: macOSTitlebarHeight)
                }

                if splitMetrics.showsPreview {
                    HSplitView {
                        macOSTable(snapshot)
                            .frame(minWidth: macOSMinimumTableWidth, maxWidth: .infinity, maxHeight: .infinity)

                        macOSPreviewPanel(snapshot)
                            .frame(
                                minWidth: macOSPreviewMinimumWidth,
                                idealWidth: splitMetrics.previewIdealWidth,
                                maxWidth: splitMetrics.previewMaximumWidth,
                                maxHeight: .infinity
                            )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    macOSTable(snapshot)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()
                macOSPathBar(snapshot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
            .background {
                MacOSWindowTopInsetBridge(topInset: $macOSTitlebarHeight)
                    .frame(width: 0, height: 0)
            }
            .background(macOSCanvasColor)
            .contextMenu {
                browserActionMenu(currentPath: snapshot.currentPath)
            }
        }
    }

    func macOSTable(_ snapshot: Snapshot) -> some View {
        MacOSRemoteFileTableView(
            entries: snapshot.entries,
            currentPath: snapshot.currentPath,
            selectedPaths: effectiveMacOSSelection(snapshot: snapshot, entries: snapshot.entries),
            sort: snapshot.sort,
            sortDirection: snapshot.sortDirection,
            inlineCreateFolderParentPath: macOSInlineEditor?.createFolderParentPath,
            inlineRenamePath: macOSInlineEditor?.renameEntryPath,
            inlineProposedName: macOSInlineEditor?.proposedName ?? "",
            isInlineSubmitting: macOSInlineEditor?.isSubmitting == true,
            onSelectionChange: { selection, modifierFlags in
                handleMacOSSelectionChange(selection, modifierFlags: modifierFlags, entries: snapshot.entries)
            },
            onActivate: { entry in
                previewEntry(entry)
            },
            onSortChange: { sort, direction in
                browser.updateSort(sort, direction: direction, for: fileTab)
            },
            onUploadDroppedURLs: { urls, destinationPath in
                handleMacOSDroppedURLs(urls, to: destinationPath)
            },
            onDropRemotePayload: { payload, destinationPath in
                handleMacOSDroppedRemotePayload(payload, to: destinationPath)
            },
            menuForEntry: { entry in
                appKitEntryMenu(for: entry)
            },
            menuForBackground: {
                appKitBackgroundMenu(currentPath: snapshot.currentPath)
            },
            exportEntry: { entry, destinationURL in
                try await browser.downloadItem(entry, to: destinationURL, server: server)
            },
            fileTypeIdentifier: { entry in
                dragFileTypeIdentifier(for: entry)
            },
            kindLabel: { entry in
                kindLabel(for: entry)
            },
            onSubmitInlineEdit: { proposedName in
                submitMacOSInlineEdit(proposedName)
            },
            onCancelInlineEdit: {
                cancelMacOSInlineEdit()
            },
            serverId: server.id
        )
        .background(macOSCanvasColor)
        .overlay {
            if let error = snapshot.directoryError {
                RemoteFileEmptyState(
                    icon: "exclamationmark.triangle.fill",
                    title: String(localized: "Browser Error"),
                    message: error.errorDescription ?? error.localizedDescription
                )
                .padding(32)
            }
        }
    }

    func beginMacOSInlineCreateFolder(in remotePath: String) {
        let destinationPath = RemoteFilePath.normalize(remotePath, relativeTo: snapshot.currentPath)

        Task {
            if snapshot.currentPath != destinationPath {
                await browser.openBreadcrumb(
                    RemoteFileBreadcrumb(title: "", path: destinationPath),
                    in: fileTab,
                    server: server
                )
            }

            let folderName = await MainActor.run {
                uniqueMacOSFolderName(in: browser.entries(for: fileTab))
            }

            let createdPath = RemoteFilePath.appending(folderName, to: destinationPath)

            do {
                try await browser.createDirectory(
                    named: folderName,
                    in: destinationPath,
                    tab: fileTab,
                    server: server
                )

                await MainActor.run {
                    macOSSelectedPaths = [createdPath]
                    browser.clearViewer(for: fileTab)
                    macOSInlineEditor = .rename(
                        entryPath: createdPath,
                        originalName: folderName,
                        proposedName: folderName,
                        isSubmitting: false
                    )
                }
            } catch {
                await MainActor.run {
                    presentOperationError(error)
                }
            }
        }
    }

    func cancelMacOSInlineEdit() {
        guard macOSInlineEditor?.isSubmitting != true else { return }
        macOSInlineEditor = nil
    }

    func submitMacOSInlineEdit(_ proposedName: String) {
        guard let editor = macOSInlineEditor, !editor.isSubmitting else { return }

        switch editor {
        case .createFolder(let parentPath, _, _):
            let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                macOSInlineEditor = nil
                return
            }
            do {
                let validatedName = try validatedRemoteName(proposedName)
                let createdPath = RemoteFilePath.appending(validatedName, to: parentPath)
                macOSInlineEditor = .createFolder(
                    parentPath: parentPath,
                    proposedName: proposedName,
                    isSubmitting: true
                )

                performOperation(
                    operation: {
                        try await browser.createDirectory(
                            named: validatedName,
                            in: parentPath,
                            tab: fileTab,
                            server: server
                        )
                    },
                    onSuccess: { _ in
                        macOSInlineEditor = nil
                        selectMacOSEntry(at: createdPath)
                    },
                    onFailure: { error in
                        macOSInlineEditor = .createFolder(
                            parentPath: parentPath,
                            proposedName: proposedName,
                            isSubmitting: false
                        )
                        presentOperationError(error)
                    }
                )
            } catch {
                macOSInlineEditor = .createFolder(
                    parentPath: parentPath,
                    proposedName: proposedName,
                    isSubmitting: false
                )
                presentOperationError(error)
            }

        case .rename(let entryPath, let originalName, _, _):
            do {
                let validatedName = try validatedRemoteName(proposedName)
                if validatedName == originalName {
                    macOSInlineEditor = nil
                    return
                }

                let destinationPath = RemoteFilePath.appending(
                    validatedName,
                    to: RemoteFilePath.parent(of: entryPath)
                )

                macOSInlineEditor = .rename(
                    entryPath: entryPath,
                    originalName: originalName,
                    proposedName: proposedName,
                    isSubmitting: true
                )

                performOperation(
                    operation: {
                        try await browser.renameItem(
                            at: entryPath,
                            to: destinationPath,
                            in: fileTab,
                            server: server
                        )
                    },
                    onSuccess: { _ in
                        macOSInlineEditor = nil
                        selectMacOSEntry(at: destinationPath)
                    },
                    onFailure: { error in
                        macOSInlineEditor = .rename(
                            entryPath: entryPath,
                            originalName: originalName,
                            proposedName: proposedName,
                            isSubmitting: false
                        )
                        presentOperationError(error)
                    }
                )
            } catch {
                macOSInlineEditor = .rename(
                    entryPath: entryPath,
                    originalName: originalName,
                    proposedName: proposedName,
                    isSubmitting: false
                )
                presentOperationError(error)
            }
        }
    }

    func selectMacOSEntry(at path: String) {
        macOSSelectedPaths = [path]
        if let entry = browser.entries(for: fileTab).first(where: { $0.path == path }) {
            browser.focus(entry, in: fileTab)
        } else {
            browser.clearViewer(for: fileTab)
        }
    }

    func uniqueMacOSFolderName(in entries: [RemoteFileEntry]) -> String {
        let baseName = String(localized: "Untitled Folder")
        let existingNames = Set(entries.map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })

        guard !existingNames.contains(baseName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) else {
            for index in 2...10_000 {
                let candidate = "\(baseName) \(index)"
                let foldedCandidate = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if !existingNames.contains(foldedCandidate) {
                    return candidate
                }
            }

            return "\(baseName) \(UUID().uuidString.prefix(4))"
        }

        return baseName
    }

    func macOSPreviewPanel(_ snapshot: Snapshot) -> some View {
        RemoteFileInspectorView(
            selectedEntry: snapshot.selectedEntry,
            viewerPayload: snapshot.viewerPayload,
            isLoadingViewer: snapshot.isLoadingViewer,
            viewerError: snapshot.viewerError,
            directoryError: snapshot.directoryError,
            chrome: .sidebar,
            backgroundColor: macOSCanvasColor,
            previewBackgroundColor: macOSRaisedSurfaceColor,
            sectionBackgroundColor: macOSRaisedSurfaceColor,
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
                requestDelete([entry])
            },
            onClose: {
                browser.clearViewer(for: fileTab)
            },
            onSaveText: { entry, text in
                try await browser.saveTextPreview(text, for: entry, in: fileTab, server: server)
            }
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .background(macOSCanvasColor)
    }

    func shouldShowMacOSPreview(_ snapshot: Snapshot) -> Bool {
        snapshot.selectedEntry != nil || snapshot.viewerPayload != nil || snapshot.viewerError != nil || snapshot.isLoadingViewer
    }

    func macOSPathBar(_ snapshot: Snapshot) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    macOSBreadcrumbButton(
                        title: server.name,
                        systemImage: "server.rack",
                        isCurrent: snapshot.currentPath == "/"
                    ) {
                        Task {
                            await browser.openBreadcrumb(
                                .init(title: server.name, path: "/"),
                                in: fileTab,
                                server: server
                            )
                        }
                    }

                    ForEach(Array(snapshot.breadcrumbs.dropFirst().enumerated()), id: \.element.id) { index, breadcrumb in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)

                        macOSBreadcrumbButton(
                            title: breadcrumb.title,
                            systemImage: "folder.fill",
                            isCurrent: index == snapshot.breadcrumbs.dropFirst().count - 1
                        ) {
                            Task { await browser.openBreadcrumb(breadcrumb, in: fileTab, server: server) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }

            Divider()

            HStack {
                Spacer(minLength: 0)

                Text(macOSFooterStatusLabel(snapshot))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .background(macOSChromeSurfaceColor)
    }

    func effectiveMacOSSelection(snapshot: Snapshot, entries: [RemoteFileEntry]) -> Set<String> {
        let visiblePaths = Set(entries.map(\.id))
        var selection = macOSSelectedPaths.intersection(visiblePaths)

        if selection.isEmpty,
           let selectedPath = snapshot.selectedPath,
           visiblePaths.contains(selectedPath) {
            selection = [selectedPath]
        }

        return selection
    }

    func macOSSelectedEntries(for snapshot: Snapshot) -> [RemoteFileEntry] {
        let selectedPaths = effectiveMacOSSelection(snapshot: snapshot, entries: snapshot.entries)
        guard !selectedPaths.isEmpty else { return [] }
        return snapshot.entries.filter { selectedPaths.contains($0.id) }
    }

    func handleMacOSSelectionChange(
        _ selection: Set<String>,
        modifierFlags: NSEvent.ModifierFlags,
        entries: [RemoteFileEntry]
    ) {
        macOSSelectedPaths = selection

        guard selection.count == 1,
              let selectedPath = selection.first,
              let entry = entries.first(where: { $0.id == selectedPath }) else {
            browser.clearViewer(for: fileTab)
            return
        }

        let selectionModifiers = modifierFlags.intersection([.command, .shift])
        guard selectionModifiers.isEmpty || selection.count == 1 else {
            browser.clearViewer(for: fileTab)
            return
        }

        browser.focus(entry, in: fileTab)
    }

    func handleMacOSDroppedURLs(_ urls: [URL], to destinationPath: String) {
        guard !urls.isEmpty else { return }
        beginUploadFlow(
            urls: urls,
            to: destinationPath,
            initialMessage: String(localized: "Preparing dropped files.")
        )
    }

    func handleMacOSDroppedRemotePayload(_ payload: RemoteFileDragPayload, to destinationPath: String) {
        performTransfer(
            title: String(localized: "Transferring"),
            initialMessage: String(localized: "Preparing remote items."),
            successMessage: String(localized: "Transfer complete.")
        ) { onProgress in
            try await transferDroppedRemoteItems([payload], to: destinationPath, onProgress: onProgress)
        }
    }

    func presentMacOSUploadPanel(for remotePath: String) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Upload to Remote Folder")
        panel.message = String(localized: "Choose files or folders to upload.")
        panel.prompt = String(localized: "Upload")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        let response = panel.runModal()
        guard response == .OK else { return }

        let urls = panel.urls
        guard !urls.isEmpty else { return }

        beginUploadFlow(
            urls: urls,
            to: remotePath,
            initialMessage: String(localized: "Preparing files for upload.")
        )
    }

    func presentMacOSDownloadPanel(for entry: RemoteFileEntry) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Download Remote File")
        panel.message = String(localized: "Choose where to save the downloaded file.")
        panel.nameFieldStringValue = entry.name.isEmpty ? "download" : entry.name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let response = panel.runModal()
        guard response == .OK, let destinationURL = panel.url else { return }

        performTransfer(
            title: String(localized: "Downloading"),
            initialMessage: String(localized: "Downloading remote file."),
            successMessage: String(localized: "Download complete."),
            successFileURL: destinationURL,
            successFileName: destinationURL.lastPathComponent,
            successFilePath: destinationURL.path
        ) {
            try await browser.downloadFile(
                at: entry.path,
                to: destinationURL,
                server: server
            )
        }
    }

    func presentMacOSDeleteConfirmation(for entries: [RemoteFileEntry]) {
        let sortedEntries = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "trash", accessibilityDescription: String(localized: "Delete"))

        if sortedEntries.count == 1, let entry = sortedEntries.first {
            alert.messageText = deleteAlertTitle(for: entry)
            alert.informativeText = deleteAlertMessage(for: entry)
        } else {
            alert.messageText = String(
                format: String(localized: "Delete %lld Items?"),
                Int64(sortedEntries.count)
            )

            let previewNames = sortedEntries.prefix(3).map(\.name).joined(separator: ", ")
            if sortedEntries.count > 3 {
                alert.informativeText = String(
                    format: String(localized: "This will permanently remove %@ and %lld more items from the remote server. This cannot be undone."),
                    previewNames,
                    Int64(sortedEntries.count - 3)
                )
            } else {
                alert.informativeText = String(
                    format: String(localized: "This will permanently remove %@ from the remote server. This cannot be undone."),
                    previewNames
                )
            }
        }

        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        deleteEntries(sortedEntries)
    }

    func appKitBackgroundMenu(currentPath: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            makeMacOSMenuItem(
                title: String(localized: "Upload…"),
                systemImage: "square.and.arrow.up"
            ) {
                beginUpload(to: currentPath)
            }
        )
        menu.addItem(
            makeMacOSMenuItem(
                title: String(localized: "New Folder"),
                systemImage: "folder.badge.plus"
            ) {
                beginCreateFolder(in: currentPath)
            }
        )
        menu.addItem(makeMacOSSeparatorMenuItem())
        menu.addItem(
            makeMacOSMenuItem(
                title: String(localized: "Copy Path"),
                systemImage: "document.on.document"
            ) {
                Clipboard.copy(currentPath)
            }
        )
        return menu
    }

    func appKitEntryMenu(for entry: RemoteFileEntry) -> NSMenu {
        let targetEntries = macOSContextMenuEntries(for: entry)
        if targetEntries.count > 1 {
            return appKitMultiEntryMenu(for: targetEntries)
        }

        let menu = NSMenu()

        switch entry.type {
        case .directory:
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "Open"), systemImage: "folder") {
                    Task { await browser.openDirectory(entry, in: fileTab, server: server) }
                }
            )
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "Upload…"), systemImage: "square.and.arrow.up") {
                    beginUpload(to: entry.path)
                }
            )
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "New Folder"), systemImage: "folder.badge.plus") {
                    beginCreateFolder(in: entry.path)
                }
            )
            if canEditPermissions(for: entry) {
                menu.addItem(
                    makeMacOSMenuItem(title: String(localized: "Permissions…"), systemImage: "lock.shield") {
                        beginEditPermissions(entry)
                    }
                )
            }

        case .file, .other, .symlink:
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "Open"), systemImage: "doc.text") {
                    previewEntry(entry)
                }
            )
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "Download…"), systemImage: "arrow.down.circle") {
                    beginDownload(entry)
                }
            )
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "Share…"), systemImage: "square.and.arrow.up") {
                    beginShare(entry)
                }
            )
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "Upload Here…"), systemImage: "square.and.arrow.up") {
                    beginUpload(to: RemoteFilePath.parent(of: entry.path))
                }
            )
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "New Folder Here"), systemImage: "folder.badge.plus") {
                    beginCreateFolder(in: RemoteFilePath.parent(of: entry.path))
                }
            )
            if canEditPermissions(for: entry) {
                menu.addItem(
                    makeMacOSMenuItem(title: String(localized: "Permissions…"), systemImage: "lock.shield") {
                        beginEditPermissions(entry)
                    }
                )
            }
        }

        menu.addItem(makeMacOSSeparatorMenuItem())
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Rename"), systemImage: "pencil") {
                beginRename(entry)
            }
        )
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Move…"), systemImage: "arrow.right.circle") {
                beginMove(entry)
            }
        )
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Delete"), systemImage: "trash") {
                requestDelete([entry])
            }
        )

        menu.addItem(makeMacOSSeparatorMenuItem())
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Copy Name"), systemImage: "textformat") {
                Clipboard.copy(entry.name)
            }
        )
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Copy Path"), systemImage: "document.on.document") {
                Clipboard.copy(entry.path)
            }
        )

        return menu
    }

    func macOSContextMenuEntries(for entry: RemoteFileEntry) -> [RemoteFileEntry] {
        let selectedEntries = snapshot.entries.filter { macOSSelectedPaths.contains($0.id) }
        guard selectedEntries.count > 1,
              selectedEntries.contains(where: { $0.id == entry.id }) else {
            return [entry]
        }
        return selectedEntries
    }

    func appKitMultiEntryMenu(for entries: [RemoteFileEntry]) -> NSMenu {
        let sortedEntries = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let menu = NSMenu()

        let title = String(
            format: String(localized: "%lld Selected"),
            Int64(sortedEntries.count)
        )
        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(makeMacOSSeparatorMenuItem())
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Delete"), systemImage: "trash") {
                requestDelete(sortedEntries)
            }
        )

        menu.addItem(makeMacOSSeparatorMenuItem())
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Copy Names"), systemImage: "textformat") {
                Clipboard.copy(sortedEntries.map(\.name).joined(separator: "\n"))
            }
        )
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Copy Paths"), systemImage: "document.on.document") {
                Clipboard.copy(sortedEntries.map(\.path).joined(separator: "\n"))
            }
        )

        return menu
    }

    func macOSFooterStatusLabel(_ snapshot: Snapshot) -> String {
        let selectedEntries = macOSSelectedEntries(for: snapshot)
        var parts: [String] = []

        if selectedEntries.isEmpty {
            parts.append(itemCountLabel(for: snapshot.entries.count))
            if snapshot.isTruncated {
                parts.append(String(localized: "Listing truncated"))
            }
        } else {
            parts.append(selectionCountLabel(for: selectedEntries.count))
            if let totalBytes = totalSelectedBytes(for: selectedEntries) {
                parts.append(
                    String(
                        format: String(localized: "%@ total"),
                        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
                    )
                )
            }
        }

        if let availableBytes = snapshot.filesystemStatus?.availableBytes {
            parts.append(
                String(
                    format: String(localized: "%@ available"),
                    ByteCountFormatter.string(fromByteCount: Int64(availableBytes), countStyle: .file)
                )
            )
        }

        return parts.joined(separator: ", ")
    }

    func selectionCountLabel(for count: Int) -> String {
        count == 1
            ? String(localized: "1 selected")
            : String(format: String(localized: "%lld selected"), Int64(count))
    }

    func totalSelectedBytes(for entries: [RemoteFileEntry]) -> UInt64? {
        let fileSizes = entries.compactMap { entry -> UInt64? in
            guard entry.type != .directory else { return nil }
            return entry.size
        }
        guard !fileSizes.isEmpty else { return nil }

        var total: UInt64 = 0
        for size in fileSizes {
            let result = total.addingReportingOverflow(size)
            total = result.partialValue
            if result.overflow {
                return UInt64.max
            }
        }

        return total
    }

    func macOSBreadcrumbButton(
        title: String,
        systemImage: String,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(systemImage == "server.rack" ? Color.accentColor : macOSFolderTint)

                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    var macOSFolderTint: Color {
        Color(nsColor: .systemBlue)
    }

    var macOSCanvasColor: Color {
        terminalThemeBackgroundColor
    }

    var macOSPreviewMinimumWidth: CGFloat {
        220
    }

    var macOSPreviewMaximumWidth: CGFloat {
        440
    }

    var macOSMinimumTableWidth: CGFloat {
        220
    }

    func macOSSplitMetrics(totalWidth: CGFloat, showsPreview: Bool) -> (showsPreview: Bool, previewIdealWidth: CGFloat, previewMaximumWidth: CGFloat) {
        guard showsPreview else {
            return (false, 0, 0)
        }

        let splitDividerAllowance: CGFloat = 12
        let availablePreviewWidth = totalWidth - macOSMinimumTableWidth - splitDividerAllowance

        guard availablePreviewWidth >= macOSPreviewMinimumWidth else {
            return (false, 0, 0)
        }

        let previewMaximumWidth = min(macOSPreviewMaximumWidth, availablePreviewWidth)
        let previewIdealWidth = min(
            previewMaximumWidth,
            max(macOSPreviewMinimumWidth, totalWidth * 0.34)
        )

        return (true, previewIdealWidth, previewMaximumWidth)
    }

    var macOSChromeSurfaceColor: Color {
        macOSSurfaceColor(blendFraction: colorScheme == .dark ? 0.05 : 0.035)
    }

    var macOSPanelColor: Color {
        macOSSurfaceColor(blendFraction: colorScheme == .dark ? 0.09 : 0.06)
    }

    var macOSRaisedSurfaceColor: Color {
        macOSSurfaceColor(blendFraction: colorScheme == .dark ? 0.14 : 0.10)
    }

    func macOSSurfaceColor(blendFraction: CGFloat) -> Color {
        let baseColor = NSColor(terminalThemeBackgroundColor)
        let targetColor: NSColor = baseColor.brightnessComponent > 0.5 ? .black : .white
        return Color(baseColor.blended(withFraction: blendFraction, of: targetColor) ?? baseColor)
    }
}
#endif
