import SwiftUI

private enum StorageHealthLoadState {
    case loading
    case loaded(StorageHealthResult)
    case failed
}

struct StorageHealthDetailsSheet: View {
    let volume: VolumeInfo
    let loadHealth: ((VolumeInfo) async throws -> StorageHealthResult)?

    @State private var loadState: StorageHealthLoadState = .loading
    @State private var reloadTrigger = false

    var body: some View {
        StorageHealthDetailsPlatformShell {
            healthList
        }
        .task(id: reloadTrigger) {
            await reload()
        }
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.stats.storage.health")
    }

    private var healthList: some View {
        List {
            Section(String(localized: "Volume")) {
                InfoRow(title: String(localized: "Mount Point"), value: volume.mountPoint)
                if !volume.fileSystem.isEmpty {
                    InfoRow(title: String(localized: "File System"), value: volume.fileSystem)
                }
                InfoRow(
                    title: String(localized: "Capacity"),
                    value: formatUsedCapacity(volume.used, total: volume.total)
                )
            }

            switch loadState {
            case .loading:
                Section(String(localized: "Health")) {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "Checking storage health"))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("vvterm.stats.storage.health.loading")
                }

            case .loaded(.unavailable(let reason)):
                unavailableSection(reason)

            case .loaded(.report(let report)):
                volumeReportSections(report)

            case .failed:
                Section(String(localized: "Health")) {
                    StorageHealthUnavailableRow(
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                        title: String(localized: "Could Not Check Health"),
                        message: String(localized: "The connection was interrupted while checking this drive.")
                    )
                    retryButton
                }
            }
        }
    }

    @ViewBuilder
    private func unavailableSection(_ reason: StorageHealthUnavailableReason) -> some View {
        Section(String(localized: "Health")) {
            StorageHealthUnavailableRow(
                systemImage: reason.systemImage,
                title: reason.title,
                message: reason.message
            )
            retryButton
        }
        .accessibilityIdentifier("vvterm.stats.storage.health.unavailable")
    }

    @ViewBuilder
    private func volumeReportSections(_ volumeReport: StorageHealthVolumeReport) -> some View {
        let findings = displayedFindings(for: volumeReport)
        Section(String(localized: "Health")) {
            StorageHealthStatusRow(state: volumeReport.state, findings: findings)

            if let firstFinding = findings.first(where: { $0.severity != .information }) ?? findings.first {
                Text(firstFinding.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("vvterm.stats.storage.health.reasonSummary")
            }

            if volumeReport.topology != .physicalDevice {
                InfoRow(title: String(localized: "Storage Type"), value: volumeReport.topology.title)
            }
            if let name = volumeReport.name, !name.isEmpty {
                InfoRow(title: String(localized: "Pool or File System"), value: name)
            }
            if volumeReport.coverage == .partial {
                Label(String(localized: "Some storage members could not be checked."), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("vvterm.stats.storage.health.partialCoverage")
            }
        }
        .accessibilityIdentifier("vvterm.stats.storage.health.report")

        if volumeReport.members.count == 1, let member = volumeReport.members.first {
            singleMemberSections(member)
        } else if !volumeReport.members.isEmpty {
            Section(String(localized: "Storage Members")) {
                ForEach(volumeReport.members) { member in
                    NavigationLink {
                        StorageHealthMemberDetailView(member: member)
                    } label: {
                        StorageHealthMemberRow(member: member)
                    }
                    .accessibilityIdentifier("vvterm.stats.storage.health.member.\(member.ordinal)")
                }
            }
        }

        Section {
            retryButton
        }
    }

    private func displayedFindings(for volumeReport: StorageHealthVolumeReport) -> [StorageHealthFinding] {
        var seenIDs: Set<String> = []
        let findings = volumeReport.findings + volumeReport.members.flatMap { member in
            let deviceFindings: [StorageHealthFinding]
            if case .report(let report) = member.result {
                deviceFindings = report.findings
            } else {
                deviceFindings = []
            }
            return member.findings + deviceFindings
        }
        return findings.filter { seenIDs.insert($0.id).inserted }
    }

    @ViewBuilder
    private func singleMemberSections(_ member: StorageHealthMemberReport) -> some View {
        switch member.result {
        case .unavailable(let reason):
            Section(String(localized: "Drive")) {
                StorageHealthUnavailableRow(
                    systemImage: reason.systemImage,
                    title: reason.title,
                    message: reason.message
                )
            }
        case .report(let report):
            StorageDeviceHealthSections(report: report, includesStatus: false)
        }
    }

    private var retryButton: some View {
        Button {
            reloadTrigger.toggle()
        } label: {
            Label(String(localized: "Check Again"), systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("vvterm.stats.storage.health.retry")
    }

    private func reload() async {
        loadState = .loading
        guard let loadHealth else {
            loadState = .loaded(.unavailable(.unsupported))
            return
        }

        do {
            loadState = .loaded(try await loadHealth(volume))
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed
        }
    }

}

private struct StorageDeviceHealthSections: View {
    let report: StorageHealthReport
    let includesStatus: Bool

    var body: some View {
        if includesStatus {
            Section(String(localized: "Health")) {
                StorageHealthStatusRow(state: report.state, findings: report.findings)
            }
        }

        Section(String(localized: "Drive")) {
            if let value = report.metrics.temperatureCelsius {
                InfoRow(title: String(localized: "Temperature"), value: temperatureLabel(value))
            }
            if let value = report.metrics.maximumTemperatureCelsius {
                InfoRow(title: String(localized: "Maximum Temperature"), value: temperatureLabel(value))
            }
            if let value = report.metrics.percentageUsed {
                InfoRow(title: String(localized: "Endurance Used"), value: percentLabel(value))
            }
            if let value = report.metrics.availableSparePercent {
                InfoRow(title: String(localized: "Available Spare"), value: percentLabel(value))
            }
            if let value = report.metrics.availableSpareThresholdPercent {
                InfoRow(title: String(localized: "Spare Threshold"), value: percentLabel(value))
            }
            InfoRow(title: String(localized: "Method"), value: sourceLabel)
        }

        if hasUsageMetrics {
            Section(String(localized: "Drive History")) {
                counter(String(localized: "Power-On Hours"), report.metrics.powerOnHours)
                counter(String(localized: "Power Cycles"), report.metrics.powerCycleCount)
                counter(String(localized: "Unsafe Shutdowns"), report.metrics.unsafeShutdownCount)
                counter(String(localized: "Media Errors"), report.metrics.mediaErrorCount)
                counter(String(localized: "Error Log Entries"), report.metrics.errorLogEntryCount)
                counter(String(localized: "Corrected Read Errors"), report.metrics.readErrorsCorrected)
                counter(String(localized: "Uncorrected Read Errors"), report.metrics.readErrorsUncorrected)
                counter(String(localized: "Corrected Write Errors"), report.metrics.writeErrorsCorrected)
                counter(String(localized: "Uncorrected Write Errors"), report.metrics.writeErrorsUncorrected)
                counter(String(localized: "Start/Stop Cycles"), report.metrics.startStopCycleCount)
                counter(String(localized: "Load/Unload Cycles"), report.metrics.loadUnloadCycleCount)
            }
        }

        if let emmc = report.metrics.emmc {
            Section {
                InfoRow(title: String(localized: "Pre-EOL Status"), value: emmc.preEOL.title)
                if let value = emmc.lifetimeTypeA {
                    InfoRow(title: String(localized: "Lifetime Estimate A"), value: value.title)
                }
                if let value = emmc.lifetimeTypeB {
                    InfoRow(title: String(localized: "Lifetime Estimate B"), value: value.title)
                }
            } header: {
                Text(String(localized: "eMMC Lifetime"))
            } footer: {
                Text(String(localized: "Lifetime values are coarse JEDEC usage estimates, not exact remaining-life percentages."))
            }
        }

        if !report.attributes.isEmpty {
            Section {
                DisclosureGroup(String(localized: "Advanced Diagnostics")) {
                    ForEach(report.attributes, id: \.key) { attribute in
                        InfoRow(title: attribute.localizedLabel, value: attribute.formattedValue)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func counter(_ title: String, _ value: UInt64?) -> some View {
        if let value { InfoRow(title: title, value: value.formatted()) }
    }

    private var hasUsageMetrics: Bool {
        let metrics = report.metrics
        return metrics.powerOnHours != nil
            || metrics.powerCycleCount != nil
            || metrics.unsafeShutdownCount != nil
            || metrics.mediaErrorCount != nil
            || metrics.errorLogEntryCount != nil
            || metrics.readErrorsCorrected != nil
            || metrics.readErrorsUncorrected != nil
            || metrics.writeErrorsCorrected != nil
            || metrics.writeErrorsUncorrected != nil
            || metrics.startStopCycleCount != nil
            || metrics.loadUnloadCycleCount != nil
    }

    private var sourceLabel: String {
        report.sources.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: " + ")
    }

    private func temperatureLabel(_ value: Double) -> String { String(format: "%.0f °C", value) }
    private func percentLabel(_ value: Double) -> String { String(format: "%.0f%%", value) }
}

private struct StorageHealthStatusRow: View {
    let state: StorageHealthState
    let findings: [StorageHealthFinding]

    var body: some View {
        if findings.isEmpty {
            statusLabel
                .accessibilityIdentifier("vvterm.stats.storage.health.status")
        } else {
            NavigationLink {
                StorageHealthFindingsView(findings: findings)
            } label: {
                statusLabel
            }
            .accessibilityIdentifier("vvterm.stats.storage.health.status")
        }
    }

    private var statusLabel: some View {
        Label {
            Text(state.title)
                .font(.headline)
        } icon: {
            Image(systemName: state.systemImage)
                .foregroundStyle(state.tint)
        }
    }
}

private struct StorageHealthFindingsView: View {
    let findings: [StorageHealthFinding]

    var body: some View {
        List(findings) { finding in
            VStack(alignment: .leading, spacing: 4) {
                Label(finding.title, systemImage: finding.systemImage)
                    .font(.headline)
                Text(finding.explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if finding.timing == .historical {
                    Text(String(localized: "Historical"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
        .navigationTitle(Text("Health Findings"))
        .accessibilityIdentifier("vvterm.stats.storage.health.findings")
    }
}

private struct StorageHealthMemberRow: View {
    let member: StorageHealthMemberReport

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String(localized: "Drive %lld"), Int64(member.ordinal)))
                Text(member.role.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if member.state == .unknown, case .unavailable = member.result {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Unavailable"))
            } else {
                Image(systemName: member.state.systemImage)
                    .foregroundStyle(member.state.tint)
                    .accessibilityLabel(member.state.title)
            }
        }
    }
}

private struct StorageHealthMemberDetailView: View {
    let member: StorageHealthMemberReport

    var body: some View {
        List {
            Section(String(localized: "Member")) {
                InfoRow(title: String(localized: "Role"), value: member.role.title)
            }
            Section(String(localized: "Health")) {
                StorageHealthStatusRow(state: member.state, findings: allFindings)
            }
            switch member.result {
            case .unavailable(let reason):
                Section(String(localized: "Drive")) {
                    StorageHealthUnavailableRow(
                        systemImage: reason.systemImage,
                        title: reason.title,
                        message: reason.message
                    )
                }
            case .report(let report):
                StorageDeviceHealthSections(report: report, includesStatus: false)
            }
        }
        .navigationTitle(String(format: String(localized: "Drive %lld"), Int64(member.ordinal)))
    }

    private var allFindings: [StorageHealthFinding] {
        let deviceFindings: [StorageHealthFinding]
        if case .report(let report) = member.result {
            deviceFindings = report.findings
        } else {
            deviceFindings = []
        }
        var seenIDs: Set<String> = []
        return (member.findings + deviceFindings).filter { seenIDs.insert($0.id).inserted }
    }
}

private struct StorageHealthUnavailableRow: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension StorageHealthUnavailableReason {
    var systemImage: String {
        switch self {
        case .networkVolume:
            return "network"
        case .virtualDevice:
            return "square.stack.3d.up.slash"
        case .permissionDenied:
            return "lock"
        case .toolMissing:
            return "wrench.and.screwdriver"
        case .unsupported, .unmapped, .invalidResponse:
            return "questionmark.circle"
        }
    }

    var title: String {
        switch self {
        case .unsupported:
            return String(localized: "Health Not Supported")
        case .toolMissing:
            return String(localized: "Health Tool Not Found")
        case .permissionDenied:
            return String(localized: "Permission Required")
        case .unmapped:
            return String(localized: "Physical Drive Unknown")
        case .virtualDevice:
            return String(localized: "Virtual Volume")
        case .networkVolume:
            return String(localized: "Network Volume")
        case .invalidResponse:
            return String(localized: "Health Data Unavailable")
        }
    }

    var message: String {
        switch self {
        case .unsupported:
            return String(localized: "This device does not expose supported storage health information.")
        case .toolMissing:
            return String(localized: "The server does not have a supported read-only storage health tool installed.")
        case .permissionDenied:
            return String(localized: "The connected account cannot read health information for this drive.")
        case .unmapped:
            return String(localized: "VVTerm could not safely map this volume to one physical drive.")
        case .virtualDevice:
            return String(localized: "This virtual or container volume does not expose physical drive health.")
        case .networkVolume:
            return String(localized: "Drive health is managed by the remote storage server for this network volume.")
        case .invalidResponse:
            return String(localized: "The server returned storage health data that VVTerm could not read.")
        }
    }
}

private extension StorageHealthState {
    var title: String {
        switch self {
        case .unknown:
            return String(localized: "Unknown")
        case .healthy:
            return String(localized: "Healthy")
        case .warning:
            return String(localized: "Needs Attention")
        case .failing:
            return String(localized: "Failing")
        }
    }

    var systemImage: String {
        switch self {
        case .unknown:
            return "questionmark.circle"
        case .healthy:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .failing:
            return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .unknown:
            return .secondary
        case .healthy:
            return .green
        case .warning:
            return .orange
        case .failing:
            return .red
        }
    }
}

private extension StorageHealthSource {
    var title: String {
        switch self {
        case .smartctl:
            return String(localized: "SMART")
        case .emmc:
            return String(localized: "eMMC")
        case .btrfs:
            return String(localized: "BTRFS")
        case .zfs:
            return String(localized: "ZFS")
        case .darwinDiskUtility:
            return String(localized: "Disk Utility")
        case .windowsStorage:
            return String(localized: "Windows Storage")
        case .bsdNative:
            return String(localized: "BSD Storage")
        }
    }
}

private extension StorageTopologyKind {
    var title: String {
        switch self {
        case .physicalDevice: String(localized: "Physical Drive")
        case .btrfs: String(localized: "BTRFS File System")
        case .zfs: String(localized: "ZFS Pool")
        }
    }
}

private extension StorageHealthMemberRole {
    var title: String {
        switch self {
        case .data: String(localized: "Data")
        case .cache: String(localized: "Cache")
        case .log: String(localized: "Log")
        case .spare: String(localized: "Spare")
        case .special: String(localized: "Special")
        }
    }
}

private extension StorageHealthFinding {
    var systemImage: String {
        switch severity {
        case .information: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .critical: "xmark.octagon"
        }
    }

    var title: String {
        switch kind {
        case .sourceReportedHealth(let status):
            return String(format: String(localized: "Storage reported: %@"), status)
        case .smartOverallFailure:
            return String(localized: "SMART reports imminent drive failure")
        case .smartCurrentPrefailThreshold:
            return String(localized: "A SMART pre-failure threshold is currently exceeded")
        case .smartPastThreshold:
            return String(localized: "A SMART threshold was exceeded in the past")
        case .smartErrorLog:
            return String(localized: "SMART error history is available")
        case .smartSelfTestLog:
            return String(localized: "A SMART self-test recorded an error")
        case .nvmeCriticalWarning:
            return String(localized: "NVMe reports a critical warning")
        case .ataAttribute(let name):
            return String(format: String(localized: "%@ needs attention"), name)
        case .scsiErrorHistory:
            return String(localized: "SCSI error history is available")
        case .emmcPreEOL(let status):
            return String(format: String(localized: "eMMC pre-EOL status is %@"), status.title)
        case .emmcLifetimeExceeded:
            return String(localized: "eMMC exceeded its maximum lifetime estimate")
        case .poolState(let state):
            return String(format: String(localized: "Storage pool is %@"), state)
        case .deviceErrors:
            return String(localized: "Storage member has I/O errors")
        case .missingMember:
            return String(localized: "A storage member is missing")
        case .partialCoverage:
            return String(localized: "Storage health coverage is partial")
        }
    }

    var explanation: String {
        switch kind {
        case .smartPastThreshold, .smartErrorLog, .smartSelfTestLog:
            return String(localized: "This is historical diagnostic information and does not by itself indicate a current failure.")
        case .nvmeCriticalWarning(let bit):
            return String(format: String(localized: "The NVMe critical-warning flag %lld is active."), Int64(bit))
        case .deviceErrors(let read, let write, let checksum):
            return String(
                format: String(localized: "Read: %llu, write: %llu, checksum: %llu."),
                read,
                write,
                checksum
            )
        case .scsiErrorHistory(let read, let write, let media):
            return String(
                format: String(localized: "Uncorrected read: %llu, uncorrected write: %llu, media: %llu."),
                read,
                write,
                media
            )
        case .partialCoverage:
            return String(localized: "At least one member could not be safely mapped or checked. The visible results do not cover the entire array.")
        case .missingMember:
            return String(localized: "The file system or pool reports a member that is not currently available.")
        case .poolState:
            return String(localized: "The pool manager reported a degraded or unavailable state. Open each member to review device-specific health.")
        case .smartOverallFailure:
            return String(localized: "SMART's current overall-health assessment reports that this drive is failing.")
        case .smartCurrentPrefailThreshold:
            return String(localized: "A current pre-failure SMART attribute has reached its vendor threshold.")
        case .ataAttribute:
            return String(localized: "SMART marked this attribute as currently failing. Review the drive and keep a current backup.")
        case .emmcPreEOL, .emmcLifetimeExceeded:
            return String(localized: "The eMMC device reports an active endurance warning.")
        case .sourceReportedHealth(let status):
            return String(format: String(localized: "The storage provider reported the current state as %@."), status)
        }
    }
}

private extension EMMCPreEOLStatus {
    var title: String {
        switch self {
        case .unknown:
            return String(localized: "Unknown")
        case .normal:
            return String(localized: "Normal")
        case .warning:
            return String(localized: "Warning")
        case .urgent:
            return String(localized: "Urgent")
        }
    }
}

private extension EMMCLifetimeEstimate {
    var title: String {
        switch bucket {
        case .unknown:
            return String(localized: "Unknown")
        case .estimatedUsage(let lowerPercent, let upperPercent):
            return String(
                format: String(localized: "About %lld–%lld%% used"),
                Int64(lowerPercent),
                Int64(upperPercent)
            )
        case .exceededMaximumEstimate:
            return String(localized: "Exceeded the maximum estimate")
        case .reserved:
            return String(localized: "Reserved value")
        }
    }
}

private extension StorageHealthAttribute {
    var localizedLabel: String {
        switch key {
        case "device.model":
            return String(localized: "Model")
        case "device.firmware":
            return String(localized: "Firmware")
        case "device.protocol":
            return String(localized: "Protocol")
        case "device.type":
            return String(localized: "Device Type")
        case "device.label":
            return String(localized: "Label")
        case "device.media_size":
            return String(localized: "Media Size")
        case "device.sector_size":
            return String(localized: "Sector Size")
        case "device.rotation_rate":
            return String(localized: "Rotation Rate")
        case "device.transport":
            return String(localized: "Connection")
        case "device.solid_state":
            return String(localized: "Solid State")
        case "device.internal":
            return String(localized: "Internal")
        case "device.virtual_or_physical":
            return String(localized: "Device Type")
        case "windows.operational_status":
            return String(localized: "Operational Status")
        case "windows.physical_operational_status":
            return String(localized: "Physical Disk Status")
        default:
            return label
        }
    }

    var formattedValue: String {
        let baseValue: String
        switch value {
        case .integer(let value):
            baseValue = value.formatted()
        case .decimal(let value):
            baseValue = value.formatted(.number.precision(.fractionLength(0...2)))
        case .text(let value):
            baseValue = value
        case .boolean(let value):
            baseValue = value ? String(localized: "Yes") : String(localized: "No")
        }

        guard let unit, !unit.isEmpty else { return baseValue }
        return "\(baseValue) \(unit)"
    }
}
