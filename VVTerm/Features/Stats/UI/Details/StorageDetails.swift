import Foundation
import SwiftUI

enum StorageVolumeFilter: String, CaseIterable, Identifiable {
    case all
    case visible
    case hidden
    case container

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return String(localized: "All Volumes")
        case .visible:
            return String(localized: "Visible")
        case .hidden:
            return String(localized: "Hidden")
        case .container:
            return String(localized: "Container Mounts")
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "internaldrive"
        case .visible:
            return "eye"
        case .hidden:
            return "eye.slash"
        case .container:
            return "shippingbox"
        }
    }
}

enum StorageVolumeSelectionMode {
    case browsing
    case selecting

    var isSelecting: Bool { self == .selecting }
}

enum StorageVolumeListPolicy {
    static func filteredVolumes(
        _ volumes: [VolumeInfo],
        hiddenVolumeIDs: Set<VolumeIdentity>,
        filter: StorageVolumeFilter,
        searchText: String
    ) -> [VolumeInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return VolumeVisibilityPolicy.normalized(volumes).filter { volume in
            guard filter.includes(volume, hiddenVolumeIDs: hiddenVolumeIDs) else { return false }
            guard !query.isEmpty else { return true }

            return volume.mountPoint.lowercased().contains(query)
                || volume.source.lowercased().contains(query)
                || volume.fileSystem.lowercased().contains(query)
        }
    }

    static func selectedVolumes(
        in volumes: [VolumeInfo],
        selectedVolumeIDs: Set<VolumeIdentity>
    ) -> [VolumeInfo] {
        VolumeVisibilityPolicy.normalized(volumes).filter { selectedVolumeIDs.contains($0.identity) }
    }
}

enum StorageVolumePresentationPolicy {
    static func visibleVolumes(
        from volumes: [VolumeInfo],
        hiddenVolumeIDs: Set<VolumeIdentity>
    ) -> [VolumeInfo] {
        VolumeVisibilityPolicy.visibleVolumes(
            from: volumes,
            hiddenVolumeIDs: hiddenVolumeIDs
        )
    }

    static func cardVolumes(from visibleVolumes: [VolumeInfo], limit: Int) -> [VolumeInfo] {
        Array(visibleVolumes.prefix(max(0, limit)))
    }
}

private extension StorageVolumeFilter {
    func includes(_ volume: VolumeInfo, hiddenVolumeIDs: Set<VolumeIdentity>) -> Bool {
        switch self {
        case .all:
            return true
        case .visible:
            return !hiddenVolumeIDs.contains(volume.identity)
        case .hidden:
            return hiddenVolumeIDs.contains(volume.identity)
        case .container:
            return volume.kind == .container
        }
    }
}

struct StorageDetailsSheet: View {
    let volumes: [VolumeInfo]
    let hiddenVolumeIDs: Set<VolumeIdentity>
    let loadStorageHealth: ((VolumeInfo) async throws -> StorageHealthResult)?
    let setVolumeVisibility: (VolumeInfo, Bool) -> Void
    let setVolumesVisibility: ([VolumeInfo], Bool) -> Void
    let showOnlyVolumes: ([VolumeInfo]) -> Void

    @State private var searchText = ""
    @State private var filter: StorageVolumeFilter = .all
    @State private var selectionMode: StorageVolumeSelectionMode = .browsing
    @State private var selectedVolumeIDs: Set<VolumeIdentity> = []
    @State private var selectedHealthVolume: VolumeInfo?

    var body: some View {
        StorageDetailsPlatformShell(
            searchText: $searchText,
            filterControl: { filterMenu },
            selectionControl: { selectionButton },
            actionsControl: { bulkActionsMenu },
            content: { volumeList }
        )
            .onChange(of: volumes.map(\.identity)) { volumeIDs in
                selectedVolumeIDs.formIntersection(volumeIDs)
            }
            .adaptiveSoftScrollEdges()
            .accessibilityIdentifier("vvterm.stats.storage.details")
            .statsDetailPresentation(item: $selectedHealthVolume) { volume in
                StorageHealthDetailsSheet(volume: volume, loadHealth: loadStorageHealth)
            }
    }

    private var volumeList: some View {
        List {
            Section {
                if filteredVolumes.isEmpty {
                    StorageVolumeEmptyRow(
                        hasVolumes: !volumes.isEmpty,
                        isFiltered: filter != .all || !normalizedSearchText.isEmpty
                    )
                } else {
                    ForEach(filteredVolumes) { volume in
                        if selectionMode.isSelecting {
                            selectionRow(for: volume)
                        } else {
                            visibilityRow(for: volume)
                        }
                    }
                }
            } footer: {
                Text(summaryTitle)
            }
        }
        .accessibilityIdentifier("vvterm.stats.storage.volumeList")
    }

    private func visibilityRow(for volume: VolumeInfo) -> some View {
        HStack(spacing: 10) {
            Button {
                selectedHealthVolume = volume
            } label: {
                HStack(spacing: 8) {
                    StorageVolumeSummaryRow(volume: volume)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(format: String(localized: "Storage health for %@"), volume.mountPoint)))
            .accessibilityIdentifier(volumeAccessibilityIdentifier(volume, suffix: "health"))

            Button {
                setVolumeVisibility(volume, hiddenVolumeIDs.contains(volume.identity))
            } label: {
                Image(systemName: hiddenVolumeIDs.contains(volume.identity) ? "eye.slash" : "eye")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(hiddenVolumeIDs.contains(volume.identity) ? Color.secondary : Color.orange)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hiddenVolumeIDs.contains(volume.identity) ? Text("Show Volume") : Text("Hide Volume"))
            .accessibilityIdentifier(volumeAccessibilityIdentifier(volume, suffix: "visibility"))
            .accessibilityValue(hiddenVolumeIDs.contains(volume.identity) ? Text("Hidden") : Text("Visible"))
        }
    }

    private func selectionRow(for volume: VolumeInfo) -> some View {
        let isSelected = selectedVolumeIDs.contains(volume.identity)

        return Button {
            if isSelected {
                selectedVolumeIDs.remove(volume.identity)
            } else {
                selectedVolumeIDs.insert(volume.identity)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                StorageVolumeSummaryRow(volume: volume)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(volumeAccessibilityIdentifier(volume, suffix: "selection"))
        .accessibilityValue(isSelected ? Text("Selected") : Text("Not Selected"))
    }

    private var filterMenu: some View {
        Menu {
            Picker(String(localized: "Filter"), selection: $filter) {
                ForEach(StorageVolumeFilter.allCases) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option)
                }
            }
        } label: {
            #if os(macOS)
            Label(filter.title, systemImage: filter.systemImage)
            #else
            Image(systemName: filter.systemImage)
                .font(.system(size: 16, weight: .semibold))
            #endif
        }
        .accessibilityLabel(Text("Filter Volumes"))
        .accessibilityIdentifier("vvterm.stats.storage.filter")
    }

    private var selectionButton: some View {
        Button(selectionMode.isSelecting ? String(localized: "Done") : String(localized: "Select")) {
            toggleSelectionMode()
        }
        .disabled(volumes.isEmpty)
        .accessibilityIdentifier("vvterm.stats.storage.selectionMode")
    }

    private var bulkActionsMenu: some View {
        Menu {
            Button {
                setVolumesVisibility(volumes, true)
            } label: {
                Label(String(localized: "Show All Volumes"), systemImage: "eye")
            }
            .disabled(volumes.isEmpty)
            .accessibilityIdentifier("vvterm.stats.storage.showAll")

            if !containerVolumes.isEmpty {
                Button {
                    setVolumesVisibility(containerVolumes, false)
                } label: {
                    Label(String(localized: "Hide Container Mounts"), systemImage: "eye.slash")
                }
                .accessibilityIdentifier("vvterm.stats.storage.hideContainers")

                Button {
                    setVolumesVisibility(containerVolumes, true)
                } label: {
                    Label(String(localized: "Show Container Mounts"), systemImage: "eye")
                }
                .accessibilityIdentifier("vvterm.stats.storage.showContainers")
            }

            if selectionMode.isSelecting {
                Divider()

                Button {
                    selectedVolumeIDs.formUnion(filteredVolumes.map(\.identity))
                } label: {
                    Label(String(localized: "Select All Matching"), systemImage: "checkmark.circle")
                }
                .disabled(filteredVolumes.isEmpty)
                .accessibilityIdentifier("vvterm.stats.storage.selectAllMatching")

                Button {
                    selectedVolumeIDs.removeAll()
                } label: {
                    Label(String(localized: "Clear Selection"), systemImage: "xmark.circle")
                }
                .disabled(selectedVolumeIDs.isEmpty)
                .accessibilityIdentifier("vvterm.stats.storage.clearSelection")

                Divider()

                Button {
                    applySelectionVisibility(false)
                } label: {
                    Label(String(localized: "Hide Selected"), systemImage: "eye.slash")
                }
                .disabled(selectedVolumes.isEmpty)
                .accessibilityIdentifier("vvterm.stats.storage.hideSelected")

                Button {
                    applySelectionVisibility(true)
                } label: {
                    Label(String(localized: "Show Selected"), systemImage: "eye")
                }
                .disabled(selectedVolumes.isEmpty)
                .accessibilityIdentifier("vvterm.stats.storage.showSelected")

                Button {
                    showOnlyVolumes(selectedVolumes)
                    finishSelection()
                } label: {
                    Label(String(localized: "Show Only Selected"), systemImage: "checkmark.circle")
                }
                .disabled(selectedVolumes.isEmpty)
                .accessibilityIdentifier("vvterm.stats.storage.showOnlySelected")
            }
        } label: {
            #if os(macOS)
            Label(String(localized: "Actions"), systemImage: "ellipsis.circle")
            #else
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
            #endif
        }
        .accessibilityLabel(Text("Volume Actions"))
        .accessibilityIdentifier("vvterm.stats.storage.actions")
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredVolumes: [VolumeInfo] {
        StorageVolumeListPolicy.filteredVolumes(
            volumes,
            hiddenVolumeIDs: hiddenVolumeIDs,
            filter: filter,
            searchText: searchText
        )
    }

    private var selectedVolumes: [VolumeInfo] {
        StorageVolumeListPolicy.selectedVolumes(
            in: volumes,
            selectedVolumeIDs: selectedVolumeIDs
        )
    }

    private var containerVolumes: [VolumeInfo] {
        let containerVolumeIDs = VolumeVisibilityPolicy.containerVolumeIDs(in: volumes)
        return volumes.filter { containerVolumeIDs.contains($0.identity) }
    }

    private var visibleVolumeCount: Int {
        volumes.lazy.filter { !hiddenVolumeIDs.contains($0.identity) }.count
    }

    private var summaryTitle: String {
        let hiddenCount = max(0, volumes.count - visibleVolumeCount)
        return String(
            format: String(localized: "%lld visible, %lld hidden"),
            Int64(visibleVolumeCount),
            Int64(hiddenCount)
        )
    }

    private func toggleSelectionMode() {
        if selectionMode.isSelecting {
            finishSelection()
        } else {
            selectedVolumeIDs.removeAll()
            selectionMode = .selecting
        }
    }

    private func applySelectionVisibility(_ isVisible: Bool) {
        setVolumesVisibility(selectedVolumes, isVisible)
        finishSelection()
    }

    private func finishSelection() {
        selectionMode = .browsing
        selectedVolumeIDs.removeAll()
    }
}

private struct StorageVolumeSummaryRow: View {
    let volume: VolumeInfo

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: volume.kind.systemImage)
                .font(.headline)
                .foregroundStyle(volume.kind.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(volume.mountPoint)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !metadataTitle.isEmpty {
                    Text(metadataTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                ProgressView(value: min(max(volume.percent / 100, 0), 1))
                    .tint(volume.usageTint)
            }

            Spacer(minLength: 8)

            Text(formatUsedCapacity(volume.used, total: volume.total))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var metadataTitle: String {
        [volume.source, volume.fileSystem]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

private struct StorageVolumeEmptyRow: View {
    let hasVolumes: Bool
    let isFiltered: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle" : "internaldrive")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var title: String {
        if isFiltered { return String(localized: "No Matching Volumes") }
        return String(localized: "No Volumes")
    }

    private var message: String {
        if isFiltered, hasVolumes {
            return String(localized: "Change the filter or search to see other volumes.")
        }
        return String(localized: "No volumes reported")
    }
}

private extension VolumeKind {
    var systemImage: String {
        switch self {
        case .physical:
            return "internaldrive"
        case .container:
            return "shippingbox"
        case .network:
            return "network"
        case .virtual:
            return "externaldrive.badge.questionmark"
        case .unknown:
            return "externaldrive"
        }
    }

    var tint: Color {
        switch self {
        case .physical:
            return .orange
        case .container:
            return .blue
        case .network:
            return .cyan
        case .virtual, .unknown:
            return .secondary
        }
    }
}

private extension VolumeInfo {
    var usageTint: Color {
        if percent > 90 { return .red }
        if percent > 80 { return .orange }
        return .green
    }
}

private func volumeAccessibilityIdentifier(_ volume: VolumeInfo, suffix: String) -> String {
    let identity: String
    switch volume.identity {
    case .stable(let platform, let fileSystemID, let mountPoint):
        identity = "stable|\(platform.rawValue)|\(fileSystemID)|\(mountPoint)"
    case .fallback(let platform, let source, let mountPoint, let fileSystem):
        identity = "fallback|\(platform.rawValue)|\(source)|\(mountPoint)|\(fileSystem)"
    }

    let token = Data(identity.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "vvterm.stats.storage.volume.\(token).\(suffix)"
}
