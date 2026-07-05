import SwiftUI
import Charts
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private struct ClassicStatsCardSurfaceStyle: Equatable {
    let fill: Color
    let stroke: Color
    let pageBackground: Color

    static func make(for backgroundColor: Color) -> ClassicStatsCardSurfaceStyle {
        #if os(iOS)
        ClassicStatsCardSurfaceStyle(
            fill: Color(UIColor.secondarySystemGroupedBackground),
            stroke: .clear,
            pageBackground: Color(UIColor.systemGroupedBackground)
        )
        #else
        ClassicStatsCardSurfaceStyle(
            fill: Color.primary.opacity(0.06),
            stroke: Color.primary.opacity(0.08),
            pageBackground: backgroundColor
        )
        #endif
    }
}

private struct ClassicStatsCardModifier: ViewModifier {
    let surfaceStyle: ClassicStatsCardSurfaceStyle

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .background(surfaceStyle.fill, in: shape)
            .overlay {
                shape.stroke(surfaceStyle.stroke, lineWidth: 1)
            }
    }
}

private extension View {
    func classicStatsCardSurface(_ surfaceStyle: ClassicStatsCardSurfaceStyle) -> some View {
        modifier(ClassicStatsCardModifier(surfaceStyle: surfaceStyle))
    }
}

private enum StatsIcon {
    static let gpu = "display"
}

private struct StatsVisualStyle {
    enum Density {
        case compact
        case detailed
        case classic
    }

    enum Surface {
        case dashboard
        case grouped
    }

    let density: Density
    let pageBackground: Color
    let cardFill: Color
    let cardStroke: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let meterTrack: Color

    init(
        preferencesStyle: StatsPreferences.Style = .cardsCompact,
        surface: Surface = .dashboard
    ) {
        switch preferencesStyle {
        case .cardsCompact:
            density = .compact
        case .cardsDetailed:
            density = .detailed
        case .classic:
            density = .classic
        }

        switch surface {
        case .dashboard:
            pageBackground = Color.black
            if preferencesStyle == .classic {
                cardFill = Color.white.opacity(0.08)
                cardStroke = Color.white.opacity(0.06)
            } else {
                cardFill = Color(red: 0.11, green: 0.11, blue: 0.12)
                cardStroke = Color.white.opacity(0.04)
            }
            primaryText = Color.white
            secondaryText = Color.white.opacity(0.58)
            tertiaryText = Color.white.opacity(0.34)
            meterTrack = Color.white.opacity(0.10)
        case .grouped:
            pageBackground = Self.nativeGroupedBackground
            cardFill = Self.nativeGroupedCardFill
            cardStroke = Self.nativeGroupedCardStroke
            primaryText = Color.primary
            secondaryText = Color.secondary
            tertiaryText = Color.secondary.opacity(0.35)
            meterTrack = Color.primary.opacity(0.10)
        }
    }

    var cardSpacing: CGFloat {
        density == .detailed ? 18 : 14
    }

    var horizontalPadding: CGFloat {
        density == .detailed ? 18 : 14
    }

    var topPadding: CGFloat {
        density == .detailed ? 22 : 16
    }

    var bottomPadding: CGFloat {
        density == .detailed ? 28 : 22
    }

    var cardPadding: CGFloat {
        density == .detailed ? 22 : 18
    }

    var cardCornerRadius: CGFloat {
        density == .classic ? 22 : 28
    }

    var titleSize: CGFloat {
        density == .detailed ? 44 : 38
    }

    var prominentValueSize: CGFloat {
        density == .detailed ? 44 : 38
    }

    var metricValueSize: CGFloat {
        density == .detailed ? 44 : 38
    }

    var networkValueSize: CGFloat {
        density == .detailed ? 34 : 30
    }

    var metricPreviewWidth: CGFloat {
        density == .detailed ? 168 : 136
    }

    var metricPreviewHeight: CGFloat {
        density == .detailed ? 118 : 92
    }

    var overviewMinHeight: CGFloat {
        density == .detailed ? 164 : 136
    }

    var metricMinHeight: CGFloat {
        density == .detailed ? 196 : 164
    }

    var networkMinHeight: CGFloat {
        density == .detailed ? 246 : 222
    }

    var networkChartHeight: CGFloat {
        density == .detailed ? 142 : 122
    }

    var networkValuesWidth: CGFloat {
        density == .detailed ? 150 : 132
    }

    var processLimit: Int {
        density == .detailed ? 5 : 4
    }

    var volumeLimit: Int {
        density == .detailed ? 6 : 4
    }

    private static var nativeGroupedBackground: Color {
        #if os(iOS)
        Color(UIColor.systemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.clear
        #endif
    }

    private static var nativeGroupedCardFill: Color {
        #if os(iOS)
        Color(UIColor.secondarySystemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.primary.opacity(0.06)
        #endif
    }

    private static var nativeGroupedCardStroke: Color {
        #if os(iOS)
        Color(UIColor.separator).opacity(0.28)
        #elseif os(macOS)
        Color(nsColor: .separatorColor).opacity(0.45)
        #else
        Color.primary.opacity(0.08)
        #endif
    }
}

// MARK: - Server Stats View

struct ServerStatsView: View {
    let server: Server
    let isVisible: Bool
    let backgroundColor: Color
    var sharedClientProvider: () -> SSHClient? = { nil }

    @StateObject private var statsCollector: ServerStatsCollector
    @StateObject private var preferences = PreferencesStore.shared

    init(
        server: Server,
        isVisible: Bool,
        backgroundColor: Color,
        sharedClientProvider: @escaping () -> SSHClient? = { nil },
        statsCollector: ServerStatsCollector
    ) {
        self.server = server
        self.isVisible = isVisible
        self.backgroundColor = backgroundColor
        self.sharedClientProvider = sharedClientProvider
        _statsCollector = StateObject(wrappedValue: statsCollector)
    }

    var body: some View {
        let currentPreferences = preferences.preferences
        let style = StatsVisualStyle(preferencesStyle: currentPreferences.style)

        ZStack {
            ScrollView {
                StatsBlocksContent(
                    serverName: server.name,
                    stats: statsCollector.stats,
                    cpuHistory: statsCollector.cpuHistory,
                    memoryHistory: statsCollector.memoryHistory,
                    gpuHistories: statsCollector.gpuUtilizationHistoryByDeviceID,
                    networkRxHistory: statsCollector.networkRxHistory,
                    networkTxHistory: statsCollector.networkTxHistory,
                    preferences: currentPreferences,
                    backgroundColor: backgroundColor,
                    surface: .dashboard,
                    constrainsWidth: true,
                    usesPagePadding: true,
                    terminateProcess: { process in
                        try await statsCollector.terminateProcess(process)
                    },
                    loadProcesses: {
                        try await statsCollector.loadProcesses()
                    }
                )
            }

            if isVisible, let error = statsCollector.connectionError {
                ConnectionErrorOverlay(error: error, style: style) {
                    Task {
                        await statsCollector.startCollecting(for: server, using: sharedClientProvider())
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StatsBlocksContent.pageBackground(for: currentPreferences.style, backgroundColor: backgroundColor))
        .task(id: makeTaskKey()) {
            if isVisible {
                await statsCollector.startCollecting(for: server, using: sharedClientProvider())
            } else {
                statsCollector.stopCollecting()
            }
        }
        .onDisappear {
            statsCollector.stopCollecting()
        }
    }

    private func makeTaskKey() -> String {
        let clientId = sharedClientProvider().map { ObjectIdentifier($0).hashValue } ?? 0
        return "\(server.id.uuidString)-\(isVisible)-\(clientId)"
    }
}

struct StatsAppearancePreviewContent: View {
    let preferences: StatsPreferences

    var body: some View {
        StatsBlocksContent(
            serverName: String(localized: "demo-server"),
            stats: StatsPreviewFixture.stats,
            cpuHistory: StatsPreviewFixture.cpuHistory,
            memoryHistory: StatsPreviewFixture.memoryHistory,
            gpuHistories: StatsPreviewFixture.gpuHistories,
            networkRxHistory: StatsPreviewFixture.networkRxHistory,
            networkTxHistory: StatsPreviewFixture.networkTxHistory,
            preferences: preferences,
            backgroundColor: .clear,
            surface: .grouped,
            constrainsWidth: false,
            usesPagePadding: false,
            terminateProcess: nil,
            loadProcesses: nil
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

private struct StatsBlocksContent: View {
    let serverName: String
    let stats: ServerStats
    let cpuHistory: [StatsPoint]
    let memoryHistory: [StatsPoint]
    let gpuHistories: [String: [StatsPoint]]
    let networkRxHistory: [StatsPoint]
    let networkTxHistory: [StatsPoint]
    let preferences: StatsPreferences
    let backgroundColor: Color
    let surface: StatsVisualStyle.Surface
    let constrainsWidth: Bool
    let usesPagePadding: Bool
    let terminateProcess: ((ProcessInfo) async throws -> Void)?
    let loadProcesses: (() async throws -> [ProcessInfo])?

    static func pageBackground(for preferencesStyle: StatsPreferences.Style, backgroundColor: Color) -> Color {
        if preferencesStyle == .classic {
            return ClassicStatsCardSurfaceStyle.make(for: backgroundColor).pageBackground
        }
        return StatsVisualStyle(preferencesStyle: preferencesStyle).pageBackground
    }

    var body: some View {
        let style = StatsVisualStyle(preferencesStyle: preferences.style, surface: surface)
        let classicSurfaceStyle = ClassicStatsCardSurfaceStyle.make(for: backgroundColor)

        if preferences.style == .classic {
            ClassicStatsContent(
                serverName: serverName,
                stats: stats,
                visibleBlocks: preferences.visibleBlocks,
                surfaceStyle: classicSurfaceStyle,
                terminateProcess: terminateProcess,
                loadProcesses: loadProcesses
            )
            .padding(usesPagePadding ? 16 : 0)
            .drawingGroup()
            .frame(maxWidth: constrainsWidth ? nil : .infinity)
        } else {
            LazyVStack(alignment: .leading, spacing: style.cardSpacing) {
                ForEach(preferences.visibleBlocks, id: \.self) { blockID in
                    statsBlock(blockID, style: style)
                }
            }
            .padding(.horizontal, usesPagePadding ? style.horizontalPadding : 0)
            .padding(.top, usesPagePadding ? style.topPadding : 0)
            .padding(.bottom, usesPagePadding ? style.bottomPadding : 0)
            .frame(maxWidth: constrainsWidth ? 820 : .infinity)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func statsBlock(_ blockID: StatsPreferences.BlockID, style: StatsVisualStyle) -> some View {
        switch blockID {
        case .system:
            SystemOverviewCard(
                serverName: serverName,
                stats: stats,
                style: style
            )
        case .cpu:
            CPUCard(
                stats: stats,
                history: cpuHistory,
                style: style
            )
        case .memory:
            MemoryCard(
                stats: stats,
                history: memoryHistory,
                style: style
            )
        case .gpu:
            if shouldShowGPU {
                GPUCard(
                    stats: stats,
                    histories: gpuHistories,
                    style: style
                )
            }
        case .network:
            NetworkCard(
                stats: stats,
                rxHistory: networkRxHistory,
                txHistory: networkTxHistory,
                style: style
            )
        case .storage:
            StorageCard(
                volumes: stats.volumes,
                style: style
            )
        case .processes:
            ProcessesCard(
                processes: stats.topProcesses,
                processCount: stats.processCount,
                style: style,
                terminateProcess: terminateProcess,
                loadProcesses: loadProcesses
            )
        }
    }

    private var shouldShowGPU: Bool {
        !stats.hardware.gpus.isEmpty || !stats.gpuSamples.isEmpty
    }
}

private enum StatsPreviewFixture {
    static let now = Date(timeIntervalSinceReferenceDate: 804_000_000)
    static let gigabyte = UInt64(1_073_741_824)

    static var stats: ServerStats {
        let gpu = GPUDevice(
            id: "gpu-0",
            name: "NVIDIA RTX 4090",
            vendor: "NVIDIA",
            kind: .nvidia,
            driverVersion: "555.42",
            memoryTotal: 24 * gigabyte,
            source: .nvidiaSMI
        )
        let secondGPU = GPUDevice(
            id: "gpu-1",
            name: "NVIDIA RTX 4090",
            vendor: "NVIDIA",
            kind: .nvidia,
            driverVersion: "555.42",
            memoryTotal: 24 * gigabyte,
            source: .nvidiaSMI
        )

        var stats = ServerStats()
        stats.hostname = "demo-server"
        stats.osInfo = "Ubuntu 24.04 LTS"
        stats.hardware = HardwareProfile(
            hostname: "demo-server",
            osInfo: "Ubuntu 24.04 LTS",
            architecture: "arm64",
            kernelVersion: "6.8.0",
            cpuModel: "Ampere Altra",
            cpuVendor: "Ampere",
            cpuCores: 8,
            cpuThreads: 8,
            memoryTotal: 16 * gigabyte,
            gpus: [gpu, secondGPU],
            collectedAt: now
        )
        stats.cpuCores = 8
        stats.cpuUsage = 42
        stats.cpuUser = 31
        stats.cpuSystem = 11
        stats.cpuIowait = 1
        stats.cpuSteal = 0
        stats.cpuIdle = 58
        stats.cpuCoreSamples = [
            CPUCoreSample(identifier: "cpu0", displayName: "CPU 1", usagePercent: 24, userPercent: 17, systemPercent: 6, iowaitPercent: 1, stealPercent: 0, idlePercent: 76),
            CPUCoreSample(identifier: "cpu1", displayName: "CPU 2", usagePercent: 67, userPercent: 52, systemPercent: 14, iowaitPercent: 1, stealPercent: 0, idlePercent: 33),
            CPUCoreSample(identifier: "cpu2", displayName: "CPU 3", usagePercent: 42, userPercent: 31, systemPercent: 10, iowaitPercent: 1, stealPercent: 0, idlePercent: 58),
            CPUCoreSample(identifier: "cpu3", displayName: "CPU 4", usagePercent: 18, userPercent: 12, systemPercent: 5, iowaitPercent: 1, stealPercent: 0, idlePercent: 82)
        ]
        stats.memoryTotal = 16 * gigabyte
        stats.memoryUsed = UInt64(Double(16 * gigabyte) * 0.68)
        stats.memoryFree = stats.memoryTotal - stats.memoryUsed
        stats.memoryCached = UInt64(Double(16 * gigabyte) * 0.18)
        stats.memoryBuffers = UInt64(Double(16 * gigabyte) * 0.04)
        stats.networkRxSpeed = 12 * 1_048_576
        stats.networkTxSpeed = 4 * 1_048_576
        stats.networkRxTotal = 382 * gigabyte
        stats.networkTxTotal = 147 * gigabyte
        stats.volumes = [
            VolumeInfo(mountPoint: "/", used: 681 * gigabyte, total: 926 * gigabyte),
            VolumeInfo(mountPoint: "/srv/models", used: 824 * gigabyte, total: 1_862 * gigabyte),
            VolumeInfo(mountPoint: "/Volumes/backup", used: 232 * gigabyte, total: 1_862 * gigabyte)
        ]
        stats.loadAverage = (0.82, 1.14, 1.04)
        stats.uptime = 178_200
        stats.processCount = 638
        stats.topProcesses = [
            ProcessInfo(pid: 1124, name: "python", cpuPercent: 62.4, memoryPercent: 18.2),
            ProcessInfo(pid: 2048, name: "ollama", cpuPercent: 18.0, memoryPercent: 24.9),
            ProcessInfo(pid: 364, name: "logd", cpuPercent: 1.5, memoryPercent: 0.2),
            ProcessInfo(pid: 1, name: "launchd", cpuPercent: 1.0, memoryPercent: 0.1)
        ]
        stats.gpuSamples = [
            GPUSample(
                deviceID: gpu.id,
                utilizationPercent: 76,
                memoryUsed: 14 * gigabyte,
                memoryTotal: gpu.memoryTotal,
                temperatureCelsius: 62,
                powerWatts: 284,
                processes: [
                    GPUProcess(pid: 1124, name: "python", memoryUsed: 12 * gigabyte, utilizationPercent: 71)
                ],
                source: .nvidiaSMI,
                timestamp: now
            ),
            GPUSample(
                deviceID: secondGPU.id,
                utilizationPercent: 41,
                memoryUsed: 8 * gigabyte,
                memoryTotal: secondGPU.memoryTotal,
                temperatureCelsius: 55,
                powerWatts: 176,
                processes: [
                    GPUProcess(pid: 2048, name: "ollama", memoryUsed: 7 * gigabyte, utilizationPercent: 38)
                ],
                source: .nvidiaSMI,
                timestamp: now
            )
        ]
        stats.timestamp = now
        return stats
    }

    static var cpuHistory: [StatsPoint] {
        makeHistory([18, 24, 52, 47, 42, 67, 58, 41, 44, 42])
    }

    static var memoryHistory: [StatsPoint] {
        makeHistory([54, 56, 59, 60, 64, 65, 66, 70, 69, 68])
    }

    static var networkRxHistory: [StatsPoint] {
        makeHistory([1, 2, 4, 11, 7, 12, 8, 5, 9, 12].map { Double($0) * 1_048_576 })
    }

    static var networkTxHistory: [StatsPoint] {
        makeHistory([0.4, 1.2, 2.0, 3.8, 2.4, 4.2, 2.8, 1.7, 3.0, 4.0].map { $0 * 1_048_576 })
    }

    static var gpuHistories: [String: [StatsPoint]] {
        [
            "gpu-0": makeHistory([28, 36, 61, 79, 71, 84, 76, 66, 72, 76]),
            "gpu-1": makeHistory([11, 18, 27, 45, 39, 52, 47, 44, 38, 41])
        ]
    }

    private static func makeHistory(_ values: [Double]) -> [StatsPoint] {
        values.enumerated().map { index, value in
            StatsPoint(
                timestamp: now.addingTimeInterval(Double(index - values.count) * 30),
                value: value
            )
        }
    }
}

private struct AppleCard<Content: View>: View {
    let style: StatsVisualStyle
    let minHeight: CGFloat?
    let content: () -> Content

    init(
        style: StatsVisualStyle,
        minHeight: CGFloat? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.style = style
        self.minHeight = minHeight
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(style.cardFill, in: RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous)
                    .stroke(style.cardStroke, lineWidth: 1)
            }
    }
}

// MARK: - Classic Layout

private struct ClassicStatsContent: View {
    let serverName: String
    let stats: ServerStats
    let visibleBlocks: [StatsPreferences.BlockID]
    let surfaceStyle: ClassicStatsCardSurfaceStyle
    let terminateProcess: ((ProcessInfo) async throws -> Void)?
    let loadProcesses: (() async throws -> [ProcessInfo])?

    var body: some View {
        LazyVStack(spacing: 16) {
            ForEach(visibleBlocks, id: \.self) { blockID in
                classicBlock(blockID)
            }
        }
    }

    @ViewBuilder
    private func classicBlock(_ blockID: StatsPreferences.BlockID) -> some View {
        switch blockID {
        case .system:
            ClassicServerHeaderCard(
                serverName: serverName,
                osInfo: stats.osInfo,
                surfaceStyle: surfaceStyle
            )
        case .cpu:
            ClassicCPUStatsCard(
                usage: stats.cpuUsage,
                user: stats.cpuUser,
                system: stats.cpuSystem,
                iowait: stats.cpuIowait,
                steal: stats.cpuSteal,
                idle: stats.cpuIdle,
                cores: stats.cpuCores,
                uptime: stats.uptime,
                loadAverage: stats.loadAverage,
                surfaceStyle: surfaceStyle
            )
        case .memory:
            ClassicMemoryStatsCard(
                used: stats.memoryUsed,
                free: stats.memoryFree,
                cached: stats.memoryCached,
                total: stats.memoryTotal,
                percent: stats.memoryPercent,
                surfaceStyle: surfaceStyle
            )
        case .gpu:
            if !stats.hardware.gpus.isEmpty || !stats.gpuSamples.isEmpty {
                ClassicGPUStatsCard(
                    device: stats.hardware.gpus.first,
                    sample: stats.gpuSamples.first,
                    surfaceStyle: surfaceStyle
                )
            }
        case .network:
            ClassicNetworkStatsCard(
                txSpeed: stats.networkTxSpeed,
                rxSpeed: stats.networkRxSpeed,
                txTotal: stats.networkTxTotal,
                rxTotal: stats.networkRxTotal,
                surfaceStyle: surfaceStyle
            )
        case .storage:
            ClassicVolumesCard(volumes: stats.volumes, surfaceStyle: surfaceStyle)
        case .processes:
            ClassicProcessesCard(
                processes: stats.topProcesses,
                surfaceStyle: surfaceStyle,
                terminateProcess: terminateProcess,
                loadProcesses: loadProcesses
            )
        }
    }
}

private struct ClassicServerHeaderCard: View, Equatable {
    let serverName: String
    let osInfo: String
    let surfaceStyle: ClassicStatsCardSurfaceStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(serverName)
                .font(.title2)
                .fontWeight(.bold)

            if !osInfo.isEmpty {
                Text(osInfo)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .classicStatsCardSurface(surfaceStyle)
    }
}

private struct ClassicCPUStatsCard: View, Equatable {
    let usage: Double
    let user: Double
    let system: Double
    let iowait: Double
    let steal: Double
    let idle: Double
    let cores: Int
    let uptime: TimeInterval
    let loadAverage: (Double, Double, Double)
    let surfaceStyle: ClassicStatsCardSurfaceStyle

    static func == (lhs: ClassicCPUStatsCard, rhs: ClassicCPUStatsCard) -> Bool {
        lhs.usage == rhs.usage && lhs.user == rhs.user && lhs.system == rhs.system &&
        lhs.iowait == rhs.iowait && lhs.steal == rhs.steal && lhs.idle == rhs.idle &&
        lhs.cores == rhs.cores && lhs.uptime == rhs.uptime &&
        lhs.loadAverage.0 == rhs.loadAverage.0 && lhs.loadAverage.1 == rhs.loadAverage.1 &&
        lhs.loadAverage.2 == rhs.loadAverage.2 && lhs.surfaceStyle == rhs.surfaceStyle
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        ClassicStatLabel(color: .pink, label: String(localized: "SYS"), value: String(format: String(localized: "%lld %%"), Int64(system)))
                        ClassicStatLabel(color: .green, label: String(localized: "USER"), value: String(format: String(localized: "%lld %%"), Int64(user)))
                    }
                    HStack(spacing: 16) {
                        ClassicStatLabel(color: .yellow, label: String(localized: "IOWAIT"), value: String(format: String(localized: "%lld %%"), Int64(iowait)))
                        ClassicStatLabel(color: .purple, label: String(localized: "STEAL"), value: String(format: String(localized: "%lld %%"), Int64(steal)))
                    }
                }

                Spacer()

                ZStack {
                    ClassicCircularGauge(value: usage / 100, color: cpuColor)
                    Text(String(format: String(localized: "%lld%%"), Int64(usage)))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 36)
                }
                .frame(width: 50, height: 50)
            }

            Divider()

            HStack(spacing: 0) {
                ClassicStatColumn(label: String(localized: "CORES"), value: "\(cores)")
                ClassicStatColumn(label: String(localized: "IDLE"), value: String(format: String(localized: "%lld %%"), Int64(idle)))
                ClassicStatColumn(label: String(localized: "UPTIME"), value: formatUptime(uptime))
                ClassicStatColumn(label: String(localized: "LOAD"), value: String(format: "%.1f,%.1f,%.1f", loadAverage.0, loadAverage.1, loadAverage.2))
            }
        }
        .padding()
        .classicStatsCardSurface(surfaceStyle)
    }

    private var cpuColor: Color {
        if usage > 90 { return .red }
        if usage > 70 { return .orange }
        return .green
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        if days > 0 { return String(format: String(localized: "%lld D"), days) }
        return String(format: String(localized: "%lld H"), hours)
    }
}

private struct ClassicMemoryStatsCard: View, Equatable {
    let used: UInt64
    let free: UInt64
    let cached: UInt64
    let total: UInt64
    let percent: Double
    let surfaceStyle: ClassicStatsCardSurfaceStyle

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    ClassicStatLabel(color: .secondary, label: String(localized: "FREE_MEMORY"), value: formatBytes(free))
                    ClassicStatLabel(color: .green, label: String(localized: "USED"), value: formatBytes(used))
                }
                HStack(spacing: 16) {
                    ClassicStatLabel(color: .blue, label: String(localized: "CACHED"), value: formatBytes(cached))
                    ClassicStatLabel(color: .secondary, label: String(localized: "TOTAL"), value: formatBytes(total))
                }
            }

            Spacer()

            ZStack {
                ClassicCircularGauge(value: percent / 100, color: memoryColor)
                Text(String(format: String(localized: "%lld%%"), Int64(percent)))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .frame(width: 36)
            }
            .frame(width: 50, height: 50)
        }
        .padding()
        .classicStatsCardSurface(surfaceStyle)
    }

    private var memoryColor: Color {
        if percent > 90 { return .red }
        if percent > 70 { return .orange }
        return .green
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f G", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f M", mb)
    }
}

private struct ClassicGPUStatsCard: View, Equatable {
    let device: GPUDevice?
    let sample: GPUSample?
    let surfaceStyle: ClassicStatsCardSurfaceStyle

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    ClassicStatLabel(color: .green, label: String(localized: "UTIL"), value: utilizationLabel)
                    ClassicStatLabel(color: .blue, label: String(localized: "VRAM"), value: memoryLabel)
                }

                HStack(spacing: 16) {
                    ClassicStatLabel(color: .orange, label: String(localized: "TEMP"), value: temperatureLabel)
                    ClassicStatLabel(color: .yellow, label: String(localized: "POWER"), value: powerLabel)
                }

                if let displayName = device?.displayName, !displayName.isEmpty {
                    Text(displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            ZStack {
                ClassicCircularGauge(value: utilizationValue / 100, color: .green)
                Image(systemName: StatsIcon.gpu)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(width: 50, height: 50)
        }
        .padding()
        .classicStatsCardSurface(surfaceStyle)
    }

    private var utilizationValue: Double {
        sample?.utilizationPercent ?? 0
    }

    private var utilizationLabel: String {
        guard let value = sample?.utilizationPercent else { return "-" }
        return String(format: "%.0f %%", value)
    }

    private var memoryLabel: String {
        guard let used = sample?.memoryUsed else {
            if let total = sample?.memoryTotal ?? device?.memoryTotal, total > 0 {
                return formatBytes(total)
            }
            return "-"
        }

        let total = sample?.memoryTotal ?? device?.memoryTotal ?? 0
        if total > 0 {
            return String(format: "%@/%@", formatBytes(used), formatBytes(total))
        }
        return formatBytes(used)
    }

    private var temperatureLabel: String {
        guard let temperature = sample?.temperatureCelsius else { return "-" }
        return String(format: "%.0f C", temperature)
    }

    private var powerLabel: String {
        guard let power = sample?.powerWatts else { return "-" }
        return String(format: "%.0f W", power)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f G", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f M", mb)
    }
}

private struct ClassicNetworkStatsCard: View, Equatable {
    let txSpeed: UInt64
    let rxSpeed: UInt64
    let txTotal: UInt64
    let rxTotal: UInt64
    let surfaceStyle: ClassicStatsCardSurfaceStyle

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    ClassicStatLabel(color: .green, label: String(localized: "↑/S"), value: formatSpeed(txSpeed))
                    ClassicStatLabel(color: .orange, label: String(localized: "↓/S"), value: formatSpeed(rxSpeed))
                }
                HStack(spacing: 16) {
                    ClassicStatLabel(color: .green, label: String(localized: "↑ TOTAL"), value: formatBytes(txTotal))
                    ClassicStatLabel(color: .orange, label: String(localized: "↓ TOTAL"), value: formatBytes(rxTotal))
                }
            }

            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.3), lineWidth: 4)
                    .frame(width: 50, height: 50)
                Circle()
                    .trim(from: 0, to: min(Double(rxSpeed) / 10_000_000, 1))
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(-90))

                Circle()
                    .stroke(Color.green.opacity(0.3), lineWidth: 4)
                    .frame(width: 36, height: 36)
                Circle()
                    .trim(from: 0, to: min(Double(txSpeed) / 10_000_000, 1))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding()
        .classicStatsCardSurface(surfaceStyle)
    }

    private func formatSpeed(_ bytesPerSec: UInt64) -> String {
        let mbps = Double(bytesPerSec) / 1_048_576
        if mbps >= 1 { return String(format: "%.1f M/s", mbps) }
        let kbps = Double(bytesPerSec) / 1024
        if kbps >= 1 { return String(format: "%.0f K/s", kbps) }
        return "0 B/s"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f G", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0f M", mb) }
        let kb = Double(bytes) / 1024
        return String(format: "%.0f K", kb)
    }
}

private struct ClassicVolumesCard: View {
    let volumes: [VolumeInfo]
    let surfaceStyle: ClassicStatsCardSurfaceStyle

    var body: some View {
        if !volumes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Volumes")
                    .font(.headline)
                    .padding(.horizontal)

                ForEach(volumes) { volume in
                    ClassicVolumeRow(volume: volume)
                }
            }
            .padding(.vertical)
            .classicStatsCardSurface(surfaceStyle)
        }
    }
}

private struct ClassicVolumeRow: View {
    let volume: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)

                Text(volume.mountPoint)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer()

                Text(String(format: String(localized: "%@/%@"), formatBytes(volume.used), formatBytes(volume.total)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))

                RoundedRectangle(cornerRadius: 4)
                    .fill(volumeColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: min(volume.percent / 100, 1), y: 1, anchor: .leading)
            }
            .frame(height: 8)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
    }

    private var volumeColor: Color {
        if volume.percent > 90 { return .red }
        if volume.percent > 80 { return .orange }
        return .green
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let tb = Double(bytes) / 1_099_511_627_776
        if tb >= 1 { return String(format: "%.1fT", tb) }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.0fG", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0fM", mb)
    }
}

private struct ClassicProcessesCard: View {
    let processes: [ProcessInfo]
    let surfaceStyle: ClassicStatsCardSurfaceStyle
    let terminateProcess: ((ProcessInfo) async throws -> Void)?
    let loadProcesses: (() async throws -> [ProcessInfo])?
    @State private var showingProcesses = false

    var body: some View {
        if !processes.isEmpty {
            Button {
                showingProcesses = true
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Top Processes")
                            .font(.headline)

                        Spacer()

                        HStack(spacing: 20) {
                            Text("CPU")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .trailing)
                            Text("MEM")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Divider()

                    ForEach(processes.prefix(5)) { process in
                        HStack {
                            Text(process.name)
                                .font(.subheadline)
                                .lineLimit(1)

                            Spacer()

                            Text(String(format: "%.1f%%", process.cpuPercent))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(process.cpuPercent > 50 ? .orange : .secondary)
                                .frame(width: 50, alignment: .trailing)

                            Text(String(format: "%.1f%%", process.memoryPercent))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(process.memoryPercent > 50 ? .orange : .secondary)
                                .frame(width: 50, alignment: .trailing)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding()
                .classicStatsCardSurface(surfaceStyle)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingProcesses) {
                ProcessesSheet(
                    processes: processes,
                    processCount: processes.count,
                    terminateProcess: terminateProcess,
                    loadProcesses: loadProcesses
                )
            }
        }
    }
}

private struct ClassicStatLabel: View, Equatable {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
                .frame(minWidth: 40, alignment: .leading)
        }
    }
}

private struct ClassicStatColumn: View, Equatable {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ClassicCircularGauge: View, Equatable {
    let value: Double
    let color: Color
    var lineWidth: CGFloat = 6

    static func == (lhs: ClassicCircularGauge, rhs: ClassicCircularGauge) -> Bool {
        lhs.value == rhs.value && lhs.lineWidth == rhs.lineWidth
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: min(value, 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: value)
        }
    }
}

// MARK: - Summary

private struct SystemOverviewCard: View {
    let serverName: String
    let stats: ServerStats
    let style: StatsVisualStyle
    @State private var showingDetails = false

    var body: some View {
        AppleCard(style: style, minHeight: style.overviewMinHeight) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "server.rack")
                                .font(.headline.weight(.bold))
                            Text(displayName)
                                .font(.title3.weight(.bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .foregroundStyle(Color.cyan)

                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(style.secondaryText)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    Button {
                        showingDetails = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(style.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("System Details"))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(formatUptimeDetail(stats.uptime))
                        .font(.system(size: style.prominentValueSize, weight: .bold, design: .rounded))
                        .foregroundStyle(style.primaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    Text(String(localized: "Uptime"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(style.secondaryText)
                }

                HStack(spacing: 18) {
                    FooterValue(
                        title: String(localized: "Load"),
                        value: String(format: "%.2f", stats.loadAverage.0),
                        color: .orange,
                        style: style
                    )

                    FooterValue(
                        title: String(localized: "Processes"),
                        value: stats.processCount > 0 ? "\(stats.processCount)" : "-",
                        color: .purple,
                        style: style
                    )
                }
            }
            .padding(style.cardPadding)
        }
        .sheet(isPresented: $showingDetails) {
            SystemDetailsSheet(stats: stats)
        }
    }

    private var displayName: String {
        serverName.isEmpty ? String(localized: "System") : serverName
    }

    private var subtitle: String {
        if !stats.hostname.isEmpty, !stats.osInfo.isEmpty, stats.hostname != serverName {
            return "\(stats.hostname) - \(stats.osInfo)"
        }
        if !stats.osInfo.isEmpty {
            return stats.osInfo
        }
        if !stats.hostname.isEmpty, stats.hostname != serverName {
            return stats.hostname
        }
        return ""
    }
}

// MARK: - Metric Cards

private struct CPUCard: View {
    let stats: ServerStats
    let history: [StatsPoint]
    let style: StatsVisualStyle
    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            AppleMetricCard(
                icon: "cpu",
                title: String(localized: "CPU"),
                titleColor: .pink,
                trailing: cpuCountTitle,
                value: formatPercent(stats.cpuUsage),
                unit: "",
                footer: compactFooter,
                detailItems: [
                    MetricDetailItem(title: String(localized: "User"), value: formatPercent(stats.cpuUser), color: .pink),
                    MetricDetailItem(title: String(localized: "System"), value: formatPercent(stats.cpuSystem), color: .orange),
                    MetricDetailItem(title: String(localized: "I/O Wait"), value: formatPercent(stats.cpuIowait), color: .yellow),
                    MetricDetailItem(title: String(localized: "Idle"), value: formatPercent(stats.cpuIdle), color: .green)
                ],
                showsChevron: true,
                style: style
            ) {
                MetricPreviewChart(
                    history: history,
                    color: .pink,
                    yDomain: 0...100,
                    style: style
                )
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingDetails) {
            CPUDetailsSheet(stats: stats)
        }
    }

    private var cpuCountTitle: String {
        let count = max(stats.cpuCoreSamples.count, stats.cpuCores)
        if count <= 0 { return "" }
        if count == 1 { return String(localized: "1 core") }
        return String(format: String(localized: "%lld cores"), Int64(count))
    }

    private var compactFooter: String {
        String(
            format: String(localized: "User %@ - System %@ - Idle %@"),
            formatPercent(stats.cpuUser),
            formatPercent(stats.cpuSystem),
            formatPercent(stats.cpuIdle)
        )
    }
}

private struct MemoryCard: View {
    let stats: ServerStats
    let history: [StatsPoint]
    let style: StatsVisualStyle

    var body: some View {
        AppleMetricCard(
            icon: "memorychip",
            title: String(localized: "Memory"),
            titleColor: .blue,
            trailing: String(localized: "Today"),
            value: formatPercent(stats.memoryPercent),
            unit: "",
            footer: String(format: String(localized: "%@ of %@ used"), formatBytes(stats.memoryUsed), formatBytes(stats.memoryTotal)),
            detailItems: [
                MetricDetailItem(title: String(localized: "Used"), value: formatBytes(stats.memoryUsed), color: .blue),
                MetricDetailItem(title: String(localized: "Free"), value: formatBytes(stats.memoryFree), color: .green),
                MetricDetailItem(title: String(localized: "Cached"), value: formatBytes(stats.memoryCached), color: .cyan),
                MetricDetailItem(title: String(localized: "Buffers"), value: formatBytes(stats.memoryBuffers), color: .orange)
            ],
            style: style
        ) {
            MetricPreviewChart(
                history: history,
                color: .blue,
                yDomain: 0...100,
                style: style
            )
        }
    }
}

private struct GPUCard: View {
    let stats: ServerStats
    let histories: [String: [StatsPoint]]
    let style: StatsVisualStyle
    @State private var showingDetails = false

    private var devices: [GPUDevice] {
        if !stats.hardware.gpus.isEmpty {
            return stats.hardware.gpus
        }
        return stats.gpuSamples.map { sample in
            GPUDevice(
                id: sample.deviceID,
                name: sample.deviceID,
                vendor: "",
                kind: .unknown,
                driverVersion: "",
                memoryTotal: sample.memoryTotal ?? 0,
                source: sample.source
            )
        }
    }

    private var primaryDevice: GPUDevice? {
        if let primarySample {
            return devices.first { $0.id == primarySample.deviceID }
        }
        return devices.first
    }

    private var primarySample: GPUSample? {
        stats.gpuSamples.max { lhs, rhs in
            (lhs.utilizationPercent ?? -1) < (rhs.utilizationPercent ?? -1)
        }
    }

    private var primaryHistory: [StatsPoint] {
        guard let sample = primarySample else { return [] }
        return histories[sample.deviceID] ?? []
    }

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            AppleCard(style: style, minHeight: style.metricMinHeight) {
                VStack(alignment: .leading, spacing: 18) {
                    CardHeader(
                        icon: StatsIcon.gpu,
                        title: String(localized: "GPU"),
                        titleColor: .green,
                        trailing: deviceCountTitle,
                        showsChevron: true,
                        style: style
                    )

                    HStack(alignment: .bottom, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "Utilization"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(style.secondaryText)

                            Text(utilizationLabel(primarySample))
                                .font(.system(size: style.metricValueSize, weight: .bold, design: .rounded))
                                .foregroundStyle(style.primaryText)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)

                            Text(footerLabel(device: primaryDevice, sample: primarySample))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(style.secondaryText)
                                .lineLimit(2)
                                .minimumScaleFactor(0.78)
                        }

                        Spacer(minLength: 8)

                        MetricPreviewChart(
                            history: primaryHistory,
                            color: .green,
                            yDomain: 0...100,
                            style: style
                        )
                        .frame(width: style.metricPreviewWidth, height: style.metricPreviewHeight)
                    }

                    if style.density == .detailed {
                        VStack(spacing: 12) {
                            ForEach(devices.prefix(3)) { device in
                                GPUDeviceRow(
                                    device: device,
                                    sample: stats.gpuSamples.first { $0.deviceID == device.id },
                                    style: style
                                )
                            }
                        }
                    }
                }
                .padding(style.cardPadding)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingDetails) {
            GPUDetailsSheet(stats: stats, devices: devices)
        }
    }

    private var deviceCountTitle: String {
        if devices.isEmpty {
            return ""
        }
        if devices.count == 1 {
            return String(localized: "1 device")
        }
        return String(format: String(localized: "%lld devices"), Int64(devices.count))
    }

    private func utilizationLabel(_ sample: GPUSample?) -> String {
        guard let utilization = sample?.utilizationPercent else {
            return String(localized: "No Data")
        }
        return formatPercent(utilization)
    }

    private func footerLabel(device: GPUDevice?, sample: GPUSample?) -> String {
        if let vram = aggregateVRAMUsage {
            return String(format: String(localized: "VRAM %@ of %@ used"), formatBytes(vram.used), formatBytes(vram.total))
        }
        let memoryTotal = sample?.memoryTotal ?? device?.memoryTotal ?? 0
        if let memoryUsed = sample?.memoryUsed, memoryTotal > 0 {
            return String(format: String(localized: "VRAM %@ of %@ used"), formatBytes(memoryUsed), formatBytes(memoryTotal))
        }
        if let temperature = sample?.temperatureCelsius {
            return String(format: String(localized: "%.0f C"), temperature)
        }
        if let device, !device.displayName.isEmpty {
            return device.displayName
        }
        return String(localized: "Waiting for telemetry")
    }

    private var aggregateVRAMUsage: (used: UInt64, total: UInt64)? {
        var devicesByID: [String: GPUDevice] = [:]
        for device in devices {
            devicesByID[device.id] = device
        }

        var sampledDeviceIDs = Set<String>()
        var used: UInt64 = 0
        var total: UInt64 = 0
        var hasUsedSample = false

        for sample in stats.gpuSamples {
            sampledDeviceIDs.insert(sample.deviceID)
            if let memoryUsed = sample.memoryUsed {
                used += memoryUsed
                hasUsedSample = true
            }
            total += sample.memoryTotal ?? devicesByID[sample.deviceID]?.memoryTotal ?? 0
        }

        for device in devices where !sampledDeviceIDs.contains(device.id) {
            total += device.memoryTotal
        }

        guard hasUsedSample, total > 0 else { return nil }
        return (used, total)
    }
}

private struct GPUDeviceRow: View {
    let device: GPUDevice
    let sample: GPUSample?
    let style: StatsVisualStyle

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(detail)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 8)

            ProcessBadge(
                title: String(localized: "GPU"),
                value: sample?.utilizationPercent ?? 0,
                color: .green,
                style: style
            )
        }
    }

    private var detail: String {
        if let power = sample?.powerWatts, let temp = sample?.temperatureCelsius {
            return String(format: String(localized: "%.0f W - %.0f C"), power, temp)
        }
        if let memoryUsed = sample?.memoryUsed {
            let memoryTotal = sample?.memoryTotal ?? device.memoryTotal
            if memoryTotal > 0 {
                return String(format: String(localized: "%@ of %@ VRAM"), formatBytes(memoryUsed), formatBytes(memoryTotal))
            }
            return String(format: String(localized: "%@ VRAM used"), formatBytes(memoryUsed))
        }
        if device.memoryTotal > 0 {
            return String(format: String(localized: "%@ VRAM"), formatBytes(device.memoryTotal))
        }
        return device.vendor.isEmpty ? String(localized: "GPU") : device.vendor
    }
}

private struct NetworkCard: View {
    let stats: ServerStats
    let rxHistory: [StatsPoint]
    let txHistory: [StatsPoint]
    let style: StatsVisualStyle

    var body: some View {
        AppleCard(style: style, minHeight: style.networkMinHeight) {
            VStack(alignment: .leading, spacing: 18) {
                CardHeader(
                    icon: "arrow.up.arrow.down",
                    title: String(localized: "Network"),
                    titleColor: .cyan,
                    trailing: String(localized: "Live"),
                    style: style
                )

                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        NetworkValue(
                            symbol: "arrow.down",
                            title: String(localized: "Download"),
                            value: formatSpeed(stats.networkRxSpeed),
                            color: .cyan,
                            style: style
                        )

                        NetworkValue(
                            symbol: "arrow.up",
                            title: String(localized: "Upload"),
                            value: formatSpeed(stats.networkTxSpeed),
                            color: .orange,
                            style: style
                        )
                    }
                    .frame(width: style.networkValuesWidth, alignment: .leading)

                    NetworkLineChart(
                        rxHistory: rxHistory,
                        txHistory: txHistory,
                        style: style
                    )
                    .frame(maxWidth: .infinity, minHeight: style.networkChartHeight, maxHeight: style.networkChartHeight)
                }

                HStack(spacing: 18) {
                    FooterValue(
                        title: String(localized: "Received"),
                        value: formatBytes(stats.networkRxTotal),
                        color: .cyan,
                        style: style
                    )
                    FooterValue(
                        title: String(localized: "Sent"),
                        value: formatBytes(stats.networkTxTotal),
                        color: .orange,
                        style: style
                    )
                }
            }
            .padding(style.cardPadding)
        }
    }
}

private struct AppleMetricCard<Preview: View>: View {
    let icon: String
    let title: String
    let titleColor: Color
    let trailing: String
    let value: String
    let unit: String
    let footer: String
    let detailItems: [MetricDetailItem]
    let showsChevron: Bool
    let style: StatsVisualStyle
    let preview: () -> Preview

    init(
        icon: String,
        title: String,
        titleColor: Color,
        trailing: String,
        value: String,
        unit: String,
        footer: String,
        detailItems: [MetricDetailItem] = [],
        showsChevron: Bool = false,
        style: StatsVisualStyle,
        @ViewBuilder preview: @escaping () -> Preview
    ) {
        self.icon = icon
        self.title = title
        self.titleColor = titleColor
        self.trailing = trailing
        self.value = value
        self.unit = unit
        self.footer = footer
        self.detailItems = detailItems
        self.showsChevron = showsChevron
        self.style = style
        self.preview = preview
    }

    var body: some View {
        AppleCard(style: style, minHeight: style.metricMinHeight) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.headline.weight(.bold))
                    Text(title)
                        .font(.headline.weight(.bold))

                    Spacer()

                    Text(trailing)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(style.secondaryText)

                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(style.secondaryText)
                    }
                }
                .foregroundStyle(titleColor)

                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(value)
                                .font(.system(size: style.metricValueSize, weight: .bold, design: .rounded))
                                .foregroundStyle(style.primaryText)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)

                            if !unit.isEmpty {
                                Text(unit)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(style.secondaryText)
                                    .lineLimit(1)
                            }
                        }

                        Text(footer)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(style.secondaryText)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                    }

                    Spacer(minLength: 8)

                    preview()
                        .frame(width: style.metricPreviewWidth, height: style.metricPreviewHeight)
                }

                if style.density == .detailed, !detailItems.isEmpty {
                    MetricDetailGrid(items: detailItems, style: style)
                }
            }
            .padding(style.cardPadding)
        }
    }
}

private struct MetricDetailItem: Identifiable {
    let title: String
    let value: String
    let color: Color

    var id: String { title }
}

private struct MetricDetailGrid: View {
    let items: [MetricDetailItem]
    let style: StatsVisualStyle

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 6, height: 6)
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(style.secondaryText)
                    }

                    Text(item.value)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(style.primaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }
}

private struct NetworkValue: View {
    let symbol: String
    let title: String
    let value: String
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(color)

            Text(value)
                .font(.system(size: style.networkValueSize, weight: .bold, design: .rounded))
                .foregroundStyle(style.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.58)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FooterValue: View {
    let title: String
    let value: String
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(style.secondaryText)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(style.primaryText)
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

// MARK: - Detail Cards

private struct StorageCard: View {
    let volumes: [VolumeInfo]
    let style: StatsVisualStyle

    var body: some View {
        AppleCard(style: style) {
            VStack(alignment: .leading, spacing: 18) {
                CardHeader(
                    icon: "internaldrive",
                    title: String(localized: "Storage"),
                    titleColor: .orange,
                    trailing: volumeCountTitle,
                    style: style
                )

                if volumes.isEmpty {
                    EmptyCardState(title: String(localized: "No volumes reported"), style: style)
                } else {
                    VStack(spacing: 14) {
                        ForEach(volumes.prefix(style.volumeLimit)) { volume in
                            VolumeCardRow(volume: volume, style: style)
                        }
                    }
                }
            }
            .padding(style.cardPadding)
        }
    }

    private var volumeCountTitle: String {
        if volumes.isEmpty { return "" }
        if volumes.count == 1 { return String(localized: "1 volume") }
        return String(format: String(localized: "%lld volumes"), Int64(volumes.count))
    }
}

private struct ProcessesCard: View {
    let processes: [ProcessInfo]
    let processCount: Int
    let style: StatsVisualStyle
    let terminateProcess: ((ProcessInfo) async throws -> Void)?
    let loadProcesses: (() async throws -> [ProcessInfo])?
    @State private var showingProcesses = false

    var body: some View {
        Button {
            if !processes.isEmpty {
                showingProcesses = true
            }
        } label: {
            AppleCard(style: style) {
                VStack(alignment: .leading, spacing: 18) {
                    ProcessCardHeader(
                        processCount: processCount,
                        style: style,
                        showsChevron: !processes.isEmpty
                    )

                    if processes.isEmpty {
                        EmptyCardState(title: String(localized: "No processes reported"), style: style)
                    } else {
                        VStack(spacing: 16) {
                            ForEach(processes.prefix(style.processLimit)) { process in
                                ProcessCardRow(process: process, style: style)
                            }
                        }
                    }
                }
                .padding(style.cardPadding)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingProcesses) {
            ProcessesSheet(
                processes: processes,
                processCount: processCount,
                terminateProcess: terminateProcess,
                loadProcesses: loadProcesses
            )
        }
    }
}

private struct ProcessCardHeader: View {
    let processCount: Int
    let style: StatsVisualStyle
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.headline.weight(.bold))
            Text(String(localized: "Processes"))
                .font(.headline.weight(.bold))

            Spacer()

            if processCount > 0 {
                Text("\(processCount)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(style.secondaryText)
                    .monospacedDigit()
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(style.secondaryText)
            }
        }
        .foregroundStyle(Color.purple)
    }
}

private struct CardHeader: View {
    let icon: String
    let title: String
    let titleColor: Color
    let trailing: String
    var showsChevron = false
    let style: StatsVisualStyle

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.headline.weight(.bold))
            Text(title)
                .font(.headline.weight(.bold))

            Spacer()

            if !trailing.isEmpty {
                Text(trailing)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(style.secondaryText)
                    .monospacedDigit()
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(style.secondaryText)
            }
        }
        .foregroundStyle(titleColor)
    }
}

private struct VolumeCardRow: View {
    let volume: VolumeInfo
    let style: StatsVisualStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(volume.mountPoint)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Text(formatPercent(volume.percent))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(volumeColor)
                    .monospacedDigit()
            }

            SegmentedCapacityBar(
                segments: [
                    CapacitySegment(value: Double(volume.used), color: volumeColor),
                    CapacitySegment(value: Double(volume.total > volume.used ? volume.total - volume.used : 0), color: style.tertiaryText)
                ],
                total: Double(max(volume.total, 1)),
                style: style
            )

            Text(String(format: String(localized: "%@ of %@ used"), formatBytes(volume.used), formatBytes(volume.total)))
                .font(.caption.weight(.medium))
                .foregroundStyle(style.secondaryText)
                .lineLimit(1)
        }
    }

    private var volumeColor: Color {
        if volume.percent > 90 { return .red }
        if volume.percent > 80 { return .orange }
        return .green
    }
}

private struct ProcessCardRow: View {
    let process: ProcessInfo
    let style: StatsVisualStyle

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(process.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(String(format: String(localized: "PID %lld"), Int64(process.pid)))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(style.secondaryText)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            ProcessBadge(
                title: String(localized: "CPU"),
                value: process.cpuPercent,
                color: .pink,
                style: style
            )

            ProcessBadge(
                title: String(localized: "MEM"),
                value: process.memoryPercent,
                color: .blue,
                style: style
            )
        }
    }
}

private struct ProcessBadge: View {
    let title: String
    let value: Double
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", value))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(style.primaryText)
                    .monospacedDigit()
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(style.secondaryText)
            }

            MiniMeter(value: min(value / 100, 1), color: color, style: style)
                .frame(width: 54)
        }
        .frame(width: 62, alignment: .trailing)
    }
}

private struct ProcessesSheet: View {
    let processes: [ProcessInfo]
    let processCount: Int
    let terminateProcess: ((ProcessInfo) async throws -> Void)?
    let loadProcesses: (() async throws -> [ProcessInfo])?

    @State private var displayedProcesses: [ProcessInfo] = []
    @State private var isLoadingProcesses = false
    @State private var pendingKill: ProcessInfo?
    @State private var killingPID: Int?
    @State private var errorMessage = ""
    @State private var showingError = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isLoadingProcesses {
                        ProgressView()
                    }

                    ForEach(displayedProcesses) { process in
                        ProcessSheetRow(
                            process: process,
                            isKilling: killingPID == process.pid,
                            canKill: terminateProcess != nil
                        ) {
                            pendingKill = process
                        }
                    }
                }
            }
            .navigationTitle(Text("Processes"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .statsSheetCloseToolbar()
            .confirmationDialog(
                String(localized: "Kill Process?"),
                isPresented: Binding(
                    get: { pendingKill != nil },
                    set: { if !$0 { pendingKill = nil } }
                ),
                presenting: pendingKill
            ) { process in
                Button(String(localized: "Kill"), role: .destructive) {
                    Task {
                        await kill(process)
                    }
                }
            } message: { process in
                Text(String(format: String(localized: "Send SIGTERM to %@ (PID %lld)."), process.name, Int64(process.pid)))
            }
            .alert(String(localized: "Could Not Kill Process"), isPresented: $showingError) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
        .onAppear {
            if displayedProcesses.isEmpty {
                displayedProcesses = processes
            }
            Task {
                await loadFullProcessesIfNeeded()
            }
        }
        .onChange(of: processes.map(\.pid)) { _ in
            guard !isLoadingProcesses else { return }
            displayedProcesses = processes
        }
        .adaptiveSoftScrollEdges()
    }

    private func loadFullProcessesIfNeeded() async {
        guard let loadProcesses else { return }

        isLoadingProcesses = true
        defer { isLoadingProcesses = false }

        do {
            let loadedProcesses = try await loadProcesses()
            if !loadedProcesses.isEmpty {
                displayedProcesses = loadedProcesses
            }
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func kill(_ process: ProcessInfo) async {
        guard let terminateProcess else { return }

        pendingKill = nil
        killingPID = process.pid
        defer { killingPID = nil }

        do {
            try await terminateProcess(process)
            displayedProcesses.removeAll { $0.pid == process.pid }
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

private struct StatsSheetCloseToolbarModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    private var closePlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .confirmationAction
        #endif
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: closePlacement) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("Close"))
                }
            }
    }
}

private extension View {
    func statsSheetCloseToolbar() -> some View {
        modifier(StatsSheetCloseToolbarModifier())
    }
}

private struct ProcessSheetRow: View {
    let process: ProcessInfo
    let isKilling: Bool
    let canKill: Bool
    let kill: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(process.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(String(format: String(localized: "PID %lld"), Int64(process.pid)))
                    if !process.user.isEmpty {
                        Text(process.user)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                if !process.command.isEmpty, process.command != process.name {
                    Text(process.command)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(String(format: "%.1f CPU", process.cpuPercent))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                Text(String(format: "%.1f MEM", process.memoryPercent))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 72, alignment: .trailing)

            Button(role: .destructive, action: kill) {
                if isKilling {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "xmark.octagon")
                }
            }
            .buttonStyle(.borderless)
            .disabled(!canKill || isKilling)
            .accessibilityLabel(Text("Kill Process"))
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyCardState: View {
    let title: String
    let style: StatsVisualStyle

    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(style.primaryText)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
    }
}

// MARK: - Details

private struct CPUDetailsSheet: View {
    let stats: ServerStats

    var body: some View {
        NavigationStack {
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
            .navigationTitle(Text("CPU Details"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .statsSheetCloseToolbar()
        }
        .adaptiveSoftScrollEdges()
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

private struct GPUDetailsSheet: View {
    let stats: ServerStats
    let devices: [GPUDevice]

    var body: some View {
        NavigationStack {
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
            .navigationTitle(Text("GPU Details"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .statsSheetCloseToolbar()
        }
        .adaptiveSoftScrollEdges()
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

private struct SystemDetailsSheet: View {
    let stats: ServerStats

    private var profile: HardwareProfile {
        stats.hardware
    }

    var body: some View {
        NavigationStack {
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
            .navigationTitle(Text("System Details"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .statsSheetCloseToolbar()
        }
        .adaptiveSoftScrollEdges()
    }

    private func nonEmpty(_ value: String, fallback: String) -> String {
        value.isEmpty ? fallback : value
    }

    private func integerLabel(_ value: Int) -> String {
        value > 0 ? "\(value)" : ""
    }
}

private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Charts

private struct MetricPreviewChart: View {
    let history: [StatsPoint]
    let color: Color
    let yDomain: ClosedRange<Double>
    let style: StatsVisualStyle

    var body: some View {
        if history.count < 2 {
            PreviewPlaceholder(color: color, style: style)
        } else {
            Chart {
                ForEach(history) { point in
                    AreaMark(
                        x: .value(String(localized: "Time"), point.timestamp),
                        y: .value(String(localized: "Value"), point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.30), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value(String(localized: "Time"), point.timestamp),
                        y: .value(String(localized: "Value"), point.value)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: yDomain)
        }
    }
}

private struct NetworkLineChart: View {
    let rxHistory: [StatsPoint]
    let txHistory: [StatsPoint]
    let style: StatsVisualStyle

    private var rxSamples: [StatsPoint] {
        Array(rxHistory.suffix(30)).sorted { $0.timestamp < $1.timestamp }
    }

    private var txSamples: [StatsPoint] {
        Array(txHistory.suffix(30)).sorted { $0.timestamp < $1.timestamp }
    }

    private var chartMax: Double {
        let maxValue = max(
            rxSamples.map(\.value).max() ?? 0,
            txSamples.map(\.value).max() ?? 0
        )
        return max(maxValue * 1.15, 1)
    }

    var body: some View {
        if rxSamples.count < 2, txSamples.count < 2 {
            NetworkLinePlaceholder()
        } else {
            GeometryReader { proxy in
                let plotRect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 2, dy: 8)

                ZStack {
                    Path { path in
                        let y = plotRect.midY
                        path.move(to: CGPoint(x: plotRect.minX, y: y))
                        path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
                    }
                    .stroke(style.tertiaryText.opacity(0.30), lineWidth: 1)

                    samplePath(for: rxSamples, in: plotRect, maxValue: chartMax)
                        .stroke(Color.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                    samplePath(for: txSamples, in: plotRect, maxValue: chartMax)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func samplePath(for samples: [StatsPoint], in rect: CGRect, maxValue: Double) -> Path {
        Path { path in
            guard samples.count >= 2 else { return }

            for (index, point) in samples.enumerated() {
                let progress = CGFloat(index) / CGFloat(max(samples.count - 1, 1))
                let normalizedValue = max(0, min(point.value / maxValue, 1))
                let x = rect.minX + (rect.width * progress)
                let y = rect.maxY - (rect.height * CGFloat(normalizedValue))
                let cgPoint = CGPoint(x: x, y: y)

                if index == 0 {
                    path.move(to: cgPoint)
                } else {
                    path.addLine(to: cgPoint)
                }
            }
        }
    }
}

private struct NetworkLinePlaceholder: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: width * 0.02, y: height * 0.72))
                    path.addLine(to: CGPoint(x: width * 0.28, y: height * 0.44))
                    path.addLine(to: CGPoint(x: width * 0.54, y: height * 0.56))
                    path.addLine(to: CGPoint(x: width * 0.78, y: height * 0.34))
                    path.addLine(to: CGPoint(x: width * 0.98, y: height * 0.48))
                }
                .stroke(Color.cyan.opacity(0.42), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                Path { path in
                    path.move(to: CGPoint(x: width * 0.02, y: height * 0.84))
                    path.addLine(to: CGPoint(x: width * 0.24, y: height * 0.66))
                    path.addLine(to: CGPoint(x: width * 0.52, y: height * 0.76))
                    path.addLine(to: CGPoint(x: width * 0.76, y: height * 0.58))
                    path.addLine(to: CGPoint(x: width * 0.98, y: height * 0.68))
                }
                .stroke(Color.orange.opacity(0.34), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PreviewPlaceholder: View {
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(0..<6, id: \.self) { index in
                Capsule()
                    .fill(index == 4 ? color : style.tertiaryText)
                    .frame(width: 10, height: CGFloat([28, 50, 35, 76, 44, 18][index]))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 6)
        .padding(.bottom, 6)
    }
}

// MARK: - Meters

private struct CapacitySegment {
    let value: Double
    let color: Color
}

private struct SegmentedCapacityBar: View {
    let segments: [CapacitySegment]
    let total: Double
    let style: StatsVisualStyle

    private var visibleSegments: [CapacitySegment] {
        segments.filter { $0.value > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing = CGFloat(max(visibleSegments.count - 1, 0)) * 3
            let availableWidth = max(proxy.size.width - spacing, 0)
            let effectiveTotal = max(total, visibleSegments.map(\.value).reduce(0, +), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(style.meterTrack)

                HStack(spacing: 3) {
                    ForEach(Array(visibleSegments.enumerated()), id: \.offset) { _, segment in
                        Capsule()
                            .fill(segment.color)
                            .frame(width: max(availableWidth * CGFloat(segment.value / effectiveTotal), 2))
                    }
                }
            }
        }
        .frame(height: 9)
    }
}

private struct MiniMeter: View {
    let value: Double
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(style.meterTrack)

            Capsule()
                .fill(color)
                .scaleEffect(x: min(max(value, 0), 1), y: 1, anchor: .leading)
        }
        .frame(height: 6)
    }
}

// MARK: - Error

private struct ConnectionErrorOverlay: View {
    let error: String
    let style: StatsVisualStyle
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.red)

            Text(String(localized: "Connection Failed"))
                .font(.headline)
                .foregroundStyle(style.primaryText)

            Text(error)
                .font(.caption)
                .foregroundStyle(style.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(String(localized: "Retry"), action: retry)
                .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Formatting

private func formatPercent(_ value: Double) -> String {
    String(format: "%.0f%%", value)
}

private func formatSpeed(_ bytesPerSecond: UInt64) -> String {
    let mbps = Double(bytesPerSecond) / 1_048_576
    if mbps >= 1 {
        return String(format: "%.1f MB/s", mbps)
    }

    let kbps = Double(bytesPerSecond) / 1_024
    if kbps >= 1 {
        return String(format: "%.0f KB/s", kbps)
    }

    return "0 B/s"
}

private func formatUptimeDetail(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(Int(seconds), 0)
    let days = totalSeconds / 86_400
    let hours = (totalSeconds % 86_400) / 3_600
    let minutes = (totalSeconds % 3_600) / 60

    if days > 0 {
        return String(format: String(localized: "%lldd %lldh"), Int64(days), Int64(hours))
    }
    if hours > 0 {
        return String(format: String(localized: "%lldh %lldm"), Int64(hours), Int64(minutes))
    }
    return String(format: String(localized: "%lldm"), Int64(minutes))
}

private func formatBytes(_ bytes: UInt64) -> String {
    let tb = Double(bytes) / 1_099_511_627_776
    if tb >= 1 {
        return String(format: "%.1f TB", tb)
    }

    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 {
        return String(format: "%.1f GB", gb)
    }

    let mb = Double(bytes) / 1_048_576
    if mb >= 1 {
        return String(format: "%.0f MB", mb)
    }

    let kb = Double(bytes) / 1_024
    if kb >= 1 {
        return String(format: "%.0f KB", kb)
    }

    return "\(bytes) B"
}
