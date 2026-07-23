import SwiftUI

#if os(iOS)
import UIKit

extension RemoteFileBrowserScreen {
    @ViewBuilder
    func iOSContent(_ snapshot: Snapshot) -> some View {
        let displayedEntries = iOSDisplayedEntries(snapshot)
        let emptyState = iOSEmptyStateContent(snapshot, displayedEntries: displayedEntries)

        ZStack {
            if emptyState == nil {
                List {
                    ForEach(displayedEntries) { entry in
                        Button {
                            handleIOSEntryTap(entry)
                        } label: {
                            RemoteFileIOSRow(entry: entry)
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
        .navigationDestination(isPresented: iOSPreviewBinding) {
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
        .toolbar {
            if #available(iOS 26, *) {
                ToolbarItem(placement: .bottomBar) {
                    iOSBottomToolbarButton(
                        systemName: "arrow.turn.up.left",
                        isDisabled: snapshot.currentPath == "/"
                    ) {
                        Task { await browser.goUp(in: fileTab, server: server) }
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItem(placement: .bottomBar) {
                    iOSBottomToolbarButton(systemName: "arrow.up.doc") {
                        beginUpload(to: snapshot.currentPath)
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItem(placement: .bottomBar) {
                    iOSBottomToolbarButton(systemName: "folder.badge.plus") {
                        beginCreateFolder(in: snapshot.currentPath)
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItem(placement: .bottomBar) {
                    iOSBottomToolbarButton(systemName: "document.on.document") {
                        copyPathToClipboard(snapshot.currentPath)
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItem(placement: .bottomBar) {
                    iOSBrowserMenu()
                }
            } else {
                ToolbarItemGroup(placement: .bottomBar) {
                    iOSBottomToolbarButton(
                        systemName: "arrow.turn.up.left",
                        isDisabled: snapshot.currentPath == "/"
                    ) {
                        Task { await browser.goUp(in: fileTab, server: server) }
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    iOSBottomToolbarButton(systemName: "arrow.up.doc") {
                        beginUpload(to: snapshot.currentPath)
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    iOSBottomToolbarButton(systemName: "folder.badge.plus") {
                        beginCreateFolder(in: snapshot.currentPath)
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    iOSBottomToolbarButton(systemName: "document.on.document") {
                        copyPathToClipboard(snapshot.currentPath)
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    iOSBrowserMenu()
                }
            }
        }
        .onChange(of: snapshot.currentPath) { _ in
            iOSSearchQuery = ""
        }
    }

    var iOSPreviewBinding: Binding<Bool> {
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

    func iOSDisplayedEntries(_ snapshot: Snapshot) -> [RemoteFileEntry] {
        guard !trimmedIOSSearchQuery.isEmpty else { return snapshot.entries }

        return snapshot.entries.filter { entry in
            entry.name.localizedCaseInsensitiveContains(trimmedIOSSearchQuery)
                || (entry.symlinkTarget?.localizedCaseInsensitiveContains(trimmedIOSSearchQuery) ?? false)
        }
    }

    var trimmedIOSSearchQuery: String {
        iOSSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func iOSEmptyStateContent(
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
            guard !trimmedIOSSearchQuery.isEmpty else {
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
                    trimmedIOSSearchQuery
                )
            )
        }

        return nil
    }

    func iOSBrowserMenu() -> some View {
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

    func iOSBottomToolbarButton(
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
