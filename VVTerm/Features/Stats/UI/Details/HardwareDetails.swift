import SwiftUI

struct CPUDetailsSheet: View {
    let stats: ServerStats

    var body: some View {
        sheetContent
            .adaptiveSoftScrollEdges()
    }

    @ViewBuilder
    private var sheetContent: some View {
        #if os(macOS)
        StatsDetailShell(
            String(localized: "CPU Details"),
            systemImage: "cpu",
            tint: .pink
        ) {
            cpuDetailsList
        }
        #else
        NavigationStack {
            cpuDetailsList
            .navigationTitle(Text("CPU Details"))
            .navigationBarTitleDisplayMode(.inline)
            .statsSheetCloseToolbar()
        }
        #endif
    }

    private var cpuDetailsList: some View {
        List {
            Section(String(localized: "Overview")) {
                InfoRow(title: String(localized: "Usage"), value: formatPercent(stats.cpuUsage))
                InfoRow(title: String(localized: "User"), value: formatPercent(stats.cpuUser))
                InfoRow(title: String(localized: "System"), value: formatPercent(stats.cpuSystem))
                InfoRow(title: String(localized: "I/O Wait"), value: formatPercent(stats.cpuIowait))
                InfoRow(title: String(localized: "Steal"), value: formatPercent(stats.cpuSteal))
                InfoRow(title: String(localized: "Idle"), value: formatPercent(stats.cpuIdle))
                InfoRow(title: String(localized: "Load Average"), value: loadAverageLabel)
            }

            Section(String(localized: "Processor")) {
                InfoRow(title: String(localized: "Model"), value: stats.hardware.cpuModel)
                InfoRow(title: String(localized: "Vendor"), value: stats.hardware.cpuVendor)
                InfoRow(title: String(localized: "Physical Cores"), value: integerLabel(stats.hardware.cpuCores))
                InfoRow(title: String(localized: "Logical Cores"), value: integerLabel(stats.hardware.cpuThreads > 0 ? stats.hardware.cpuThreads : stats.cpuCores))
            }

            Section(String(localized: "Cores")) {
                if stats.cpuCoreSamples.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if stats.cpuCores > 1 {
                            Text(String(format: String(localized: "%lld logical cores detected"), Int64(stats.cpuCores)))
                                .font(.headline)
                        }
                        Text(String(localized: "Per-core usage samples unavailable"))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(stats.cpuCoreSamples) { sample in
                        CPUCoreDetailRow(sample: sample)
                    }
                }
            }
        }
    }

    private var loadAverageLabel: String {
        String(format: "%.2f / %.2f / %.2f", stats.loadAverage.0, stats.loadAverage.1, stats.loadAverage.2)
    }

    private func integerLabel(_ value: Int) -> String {
        value > 0 ? "\(value)" : ""
    }
}

private struct CPUCoreDetailRow: View {
    let sample: CPUCoreSample

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(sample.displayName)
                    .font(.headline)
                Spacer(minLength: 12)
                Text(formatPercent(sample.usagePercent))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.pink)
            }

            ProgressView(value: min(max(sample.usagePercent / 100, 0), 1))
                .tint(.pink)

            HStack(spacing: 12) {
                Text(String(format: String(localized: "User %@"), formatPercent(sample.userPercent)))
                Text(String(format: String(localized: "System %@"), formatPercent(sample.systemPercent)))
                Text(String(format: String(localized: "Idle %@"), formatPercent(sample.idlePercent)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 4)
    }
}

struct GPUDetailsSheet: View {
    let stats: ServerStats
    let devices: [GPUDevice]

    var body: some View {
        sheetContent
            .adaptiveSoftScrollEdges()
    }

    @ViewBuilder
    private var sheetContent: some View {
        #if os(macOS)
        StatsDetailShell(
            String(localized: "GPU Details"),
            systemImage: "display",
            tint: .green
        ) {
            gpuDetailsList
        }
        #else
        NavigationStack {
            gpuDetailsList
            .navigationTitle(Text("GPU Details"))
            .navigationBarTitleDisplayMode(.inline)
            .statsSheetCloseToolbar()
        }
        #endif
    }

    private var gpuDetailsList: some View {
        List {
            if devices.isEmpty {
                Section {
                    Text(String(localized: "No GPU reported"))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(devices) { device in
                    Section(device.displayName) {
                        GPUDeviceDetailRows(
                            device: device,
                            sample: sample(for: device)
                        )
                    }
                }
            }
        }
    }

    private func sample(for device: GPUDevice) -> GPUSample? {
        stats.gpuSamples.first { $0.deviceID == device.id }
    }
}

private struct GPUDeviceDetailRows: View {
    let device: GPUDevice
    let sample: GPUSample?

    var body: some View {
        InfoRow(title: String(localized: "Vendor"), value: device.vendor)
        InfoRow(title: String(localized: "Driver"), value: device.driverVersion)
        InfoRow(title: String(localized: "Source"), value: sourceLabel(sample?.source ?? device.source))
        InfoRow(title: String(localized: "Utilization"), value: optionalPercent(sample?.utilizationPercent))
        InfoRow(title: String(localized: "VRAM"), value: memoryLabel)
        InfoRow(title: String(localized: "Temperature"), value: temperatureLabel)
        InfoRow(title: String(localized: "Power"), value: powerLabel)

        if let sample, !sample.processes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Compute Processes"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(sample.processes) { process in
                    GPUProcessDetailRow(process: process)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var memoryLabel: String {
        if let used = sample?.memoryUsed {
            let total = sample?.memoryTotal ?? device.memoryTotal
            if total > 0 {
                return String(format: String(localized: "%@ of %@"), formatBytes(used), formatBytes(total))
            }
            return formatBytes(used)
        }
        if device.memoryTotal > 0 {
            return formatBytes(device.memoryTotal)
        }
        return ""
    }

    private var temperatureLabel: String {
        guard let value = sample?.temperatureCelsius else { return "" }
        return String(format: String(localized: "%.0f C"), value)
    }

    private var powerLabel: String {
        guard let value = sample?.powerWatts else { return "" }
        return String(format: String(localized: "%.0f W"), value)
    }

    private func optionalPercent(_ value: Double?) -> String {
        guard let value else { return "" }
        return formatPercent(value)
    }

    private func sourceLabel(_ source: GPUSource) -> String {
        switch source {
        case .nvidiaSMI:
            return "nvidia-smi"
        case .rocmSMI:
            return "rocm-smi"
        case .intelGPU:
            return "intel_gpu_top"
        case .systemProfiler:
            return "system_profiler"
        case .powerMetrics:
            return "powermetrics"
        case .wmi:
            return "WMI"
        case .unknown:
            return ""
        }
    }
}

private struct GPUProcessDetailRow: View {
    let process: GPUProcess

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(process.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(String(format: String(localized: "PID %lld"), Int64(process.pid)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                if let utilization = process.utilizationPercent {
                    Text(formatPercent(utilization))
                }
                if let memoryUsed = process.memoryUsed {
                    Text(formatBytes(memoryUsed))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

struct SystemDetailsSheet: View {
    let stats: ServerStats

    private var profile: HardwareProfile {
        stats.hardware
    }

    var body: some View {
        sheetContent
            .adaptiveSoftScrollEdges()
    }

    @ViewBuilder
    private var sheetContent: some View {
        #if os(macOS)
        StatsDetailShell(
            String(localized: "System Details"),
            systemImage: "server.rack",
            tint: .cyan
        ) {
            systemDetailsList
        }
        #else
        NavigationStack {
            systemDetailsList
            .navigationTitle(Text("System Details"))
            .navigationBarTitleDisplayMode(.inline)
            .statsSheetCloseToolbar()
        }
        #endif
    }

    private var systemDetailsList: some View {
        List {
            Section(String(localized: "System")) {
                InfoRow(title: String(localized: "Hostname"), value: nonEmpty(profile.hostname, fallback: stats.hostname))
                InfoRow(title: String(localized: "OS"), value: nonEmpty(profile.osInfo, fallback: stats.osInfo))
                InfoRow(title: String(localized: "Architecture"), value: profile.architecture)
                InfoRow(title: String(localized: "Kernel"), value: profile.kernelVersion)
                InfoRow(title: String(localized: "Uptime"), value: formatUptimeDetail(stats.uptime))
            }

            Section(String(localized: "Processor")) {
                InfoRow(title: String(localized: "Model"), value: profile.cpuModel)
                InfoRow(title: String(localized: "Vendor"), value: profile.cpuVendor)
                InfoRow(title: String(localized: "Cores"), value: integerLabel(profile.cpuCores))
                InfoRow(title: String(localized: "Threads"), value: integerLabel(profile.cpuThreads > 0 ? profile.cpuThreads : stats.cpuCores))
                InfoRow(title: String(localized: "Current Load"), value: formatPercent(stats.cpuUsage))
            }

            Section(String(localized: "Memory")) {
                InfoRow(title: String(localized: "Installed"), value: formatBytes(max(profile.memoryTotal, stats.memoryTotal)))
                InfoRow(title: String(localized: "Used"), value: formatBytes(stats.memoryUsed))
                InfoRow(title: String(localized: "Cached"), value: formatBytes(stats.memoryCached))
            }

            if !profile.gpus.isEmpty {
                Section(String(localized: "GPU")) {
                    ForEach(profile.gpus) { gpu in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(gpu.displayName)
                                .font(.headline)
                            InfoRow(title: String(localized: "Vendor"), value: gpu.vendor)
                            InfoRow(title: String(localized: "Driver"), value: gpu.driverVersion)
                            InfoRow(title: String(localized: "VRAM"), value: gpu.memoryTotal > 0 ? formatBytes(gpu.memoryTotal) : "")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func nonEmpty(_ value: String, fallback: String) -> String {
        value.isEmpty ? fallback : value
    }

    private func integerLabel(_ value: Int) -> String {
        value > 0 ? "\(value)" : ""
    }
}
