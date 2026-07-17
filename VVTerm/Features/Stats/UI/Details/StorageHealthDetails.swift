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
                reportSections(report)

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
    private func reportSections(_ report: StorageHealthReport) -> some View {
        Section(String(localized: "Health")) {
            StorageHealthStatusRow(state: report.state)

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
            InfoRow(title: String(localized: "Method"), value: sourceLabel(report.sources))
        }
        .accessibilityIdentifier("vvterm.stats.storage.health.report")

        if hasUsageMetrics(report.metrics) {
            Section(String(localized: "Drive History")) {
                optionalCounter(String(localized: "Power-On Hours"), report.metrics.powerOnHours)
                optionalCounter(String(localized: "Power Cycles"), report.metrics.powerCycleCount)
                optionalCounter(String(localized: "Unsafe Shutdowns"), report.metrics.unsafeShutdownCount)
                optionalCounter(String(localized: "Media Errors"), report.metrics.mediaErrorCount)
                optionalCounter(String(localized: "Error Log Entries"), report.metrics.errorLogEntryCount)
                optionalCounter(String(localized: "Corrected Read Errors"), report.metrics.readErrorsCorrected)
                optionalCounter(String(localized: "Uncorrected Read Errors"), report.metrics.readErrorsUncorrected)
                optionalCounter(String(localized: "Corrected Write Errors"), report.metrics.writeErrorsCorrected)
                optionalCounter(String(localized: "Uncorrected Write Errors"), report.metrics.writeErrorsUncorrected)
                optionalCounter(String(localized: "Start/Stop Cycles"), report.metrics.startStopCycleCount)
                optionalCounter(String(localized: "Load/Unload Cycles"), report.metrics.loadUnloadCycleCount)
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
            Section(String(localized: "Device Details")) {
                ForEach(report.attributes, id: \.key) { attribute in
                    InfoRow(title: attribute.localizedLabel, value: attribute.formattedValue)
                }
            }
        }

        Section {
            retryButton
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

    @ViewBuilder
    private func optionalCounter(_ title: String, _ value: UInt64?) -> some View {
        if let value {
            InfoRow(title: title, value: value.formatted())
        }
    }

    private func hasUsageMetrics(_ metrics: StorageHealthMetrics) -> Bool {
        metrics.powerOnHours != nil
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

    private func temperatureLabel(_ value: Double) -> String {
        String(format: "%.0f °C", value)
    }

    private func percentLabel(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func sourceLabel(_ sources: Set<StorageHealthSource>) -> String {
        sources.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: " + ")
    }
}

private struct StorageHealthStatusRow: View {
    let state: StorageHealthState

    var body: some View {
        Label {
            Text(state.title)
                .font(.headline)
        } icon: {
            Image(systemName: state.systemImage)
                .foregroundStyle(state.tint)
        }
        .accessibilityIdentifier("vvterm.stats.storage.health.status")
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
        case .darwinDiskUtility:
            return String(localized: "Disk Utility")
        case .windowsStorage:
            return String(localized: "Windows Storage")
        case .bsdNative:
            return String(localized: "BSD Storage")
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
