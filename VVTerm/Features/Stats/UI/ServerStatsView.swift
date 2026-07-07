import SwiftUI

// MARK: - Server Stats View

struct ServerStatsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(StatsResolvedAppearance.storageKey) private var appearanceMode = "system"

    let server: Server
    let isVisible: Bool
    let backgroundColor: Color
    var sharedClientProvider: () -> SSHClient? = { nil }

    @StateObject private var preferences = PreferencesStore.shared
    @StateObject private var storeManager = StoreManager.shared
    @State private var statsCollector: ServerStatsCollector
    @State private var isShowingAppearanceSettings = false
    @State private var isShowingDockerUpgrade = false

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
        _statsCollector = State(initialValue: statsCollector)
    }

    var body: some View {
        let currentPreferences = preferences.preferences
        let resolvedColorScheme = StatsResolvedAppearance.colorScheme(from: appearanceMode, fallback: colorScheme)

        ServerStatsDashboard(
            server: server,
            isVisible: isVisible,
            backgroundColor: backgroundColor,
            sharedClientProvider: sharedClientProvider,
            statsCollector: statsCollector,
            preferences: currentPreferences,
            isDockerUnlocked: storeManager.isPro
        ) {
            isShowingAppearanceSettings = true
        } showDockerUpgrade: {
            isShowingDockerUpgrade = true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            StatsBlocksContent.pageBackground(
                for: currentPreferences.style,
                backgroundColor: backgroundColor,
                colorScheme: resolvedColorScheme
            )
        )
        .proUpgradePresentation(isPresented: $isShowingDockerUpgrade, source: .dockerStats)
        .statsDetailPresentation(isPresented: $isShowingAppearanceSettings, size: StatsPresentationSize.large) {
            appearanceSettingsContent
        }
    }

    @ViewBuilder
    private var appearanceSettingsContent: some View {
        #if os(macOS)
        StatsMacDetailShell(
            String(localized: "Stats Appearance"),
            systemImage: "slider.horizontal.3",
            tint: .blue
        ) {
            AppearanceSettings()
        }
        #else
        NavigationStack {
            AppearanceSettings()
                .navigationTitle(Text("Stats Appearance"))
                .navigationBarTitleDisplayMode(.inline)
                .statsSheetCloseToolbar(placement: .leading)
        }
        .presentationDetents([.large])
        .adaptiveSoftScrollEdges()
        #endif
    }
}

private struct ServerStatsDashboard: View {
    let server: Server
    let isVisible: Bool
    let backgroundColor: Color
    var sharedClientProvider: () -> SSHClient?
    @ObservedObject var statsCollector: ServerStatsCollector
    let preferences: StatsPreferences
    let isDockerUnlocked: Bool
    let showAppearanceSettings: () -> Void
    let showDockerUpgrade: () -> Void

    var body: some View {
        let style = StatsVisualStyle(preferencesStyle: preferences.style)

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
                    dockerCPUHistory: statsCollector.dockerCPUHistory,
                    dockerMemoryHistory: statsCollector.dockerMemoryHistory,
                    preferences: preferences,
                    backgroundColor: backgroundColor,
                    surface: .dashboard,
                    constrainsWidth: true,
                    usesPagePadding: true,
                    isDockerUnlocked: isDockerUnlocked,
                    showsCustomizationEntryPoint: true,
                    customizeAction: showAppearanceSettings,
                    dockerUpgradeAction: showDockerUpgrade,
                    terminateProcess: { process in
                        try await statsCollector.terminateProcess(process)
                    },
                    loadProcesses: {
                        try await statsCollector.loadProcesses()
                    },
                    loadDockerStats: {
                        try await statsCollector.loadDockerStats()
                    },
                    performDockerAction: { action, container in
                        try await statsCollector.performDockerAction(action, on: container)
                    }
                )
            }

            if isVisible, let error = statsCollector.connectionError {
                ConnectionErrorOverlay(error: error, style: style) {
                    Task {
                        await statsCollector.startCollecting(
                            for: server,
                            using: sharedClientProvider(),
                            collectDocker: isDockerUnlocked
                        )
                    }
                }
                .padding()
            }
        }
        .task(id: makeTaskKey()) {
            if isVisible {
                await statsCollector.startCollecting(
                    for: server,
                    using: sharedClientProvider(),
                    collectDocker: isDockerUnlocked
                )
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
        return "\(server.id.uuidString)-\(isVisible)-\(clientId)-\(isDockerUnlocked)"
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
            dockerCPUHistory: StatsPreviewFixture.dockerCPUHistory,
            dockerMemoryHistory: StatsPreviewFixture.dockerMemoryHistory,
            preferences: preferences,
            backgroundColor: .clear,
            surface: .grouped,
            constrainsWidth: false,
            usesPagePadding: false,
            isDockerUnlocked: true,
            showsCustomizationEntryPoint: false,
            customizeAction: nil,
            dockerUpgradeAction: nil,
            terminateProcess: nil,
            loadProcesses: nil,
            loadDockerStats: nil,
            performDockerAction: nil
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

private struct StatsBlocksContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(StatsResolvedAppearance.storageKey) private var appearanceMode = "system"

    let serverName: String
    let stats: ServerStats
    let cpuHistory: [StatsPoint]
    let memoryHistory: [StatsPoint]
    let gpuHistories: [String: [StatsPoint]]
    let networkRxHistory: [StatsPoint]
    let networkTxHistory: [StatsPoint]
    let dockerCPUHistory: [StatsPoint]
    let dockerMemoryHistory: [StatsPoint]
    let preferences: StatsPreferences
    let backgroundColor: Color
    let surface: StatsVisualStyle.Surface
    let constrainsWidth: Bool
    let usesPagePadding: Bool
    let isDockerUnlocked: Bool
    let showsCustomizationEntryPoint: Bool
    let customizeAction: (() -> Void)?
    let dockerUpgradeAction: (() -> Void)?
    let terminateProcess: ((ProcessInfo) async throws -> Void)?
    let loadProcesses: (() async throws -> [ProcessInfo])?
    let loadDockerStats: (() async throws -> DockerStats)?
    let performDockerAction: ((DockerContainerAction, DockerContainer) async throws -> DockerStats)?

    static func pageBackground(
        for preferencesStyle: StatsPreferences.Style,
        backgroundColor: Color,
        colorScheme: ColorScheme = .dark
    ) -> Color {
        if preferencesStyle == .classic {
            return ClassicStatsCardSurfaceStyle.make(for: backgroundColor).pageBackground
        }
        #if os(macOS)
        return colorScheme == .light
            ? StatsVisualStyle(preferencesStyle: preferencesStyle, colorScheme: colorScheme).pageBackground
            : backgroundColor
        #else
        return StatsVisualStyle(preferencesStyle: preferencesStyle, colorScheme: colorScheme).pageBackground
        #endif
    }

    var body: some View {
        let resolvedColorScheme = StatsResolvedAppearance.colorScheme(from: appearanceMode, fallback: colorScheme)
        let style = StatsVisualStyle(
            preferencesStyle: preferences.style,
            surface: surface,
            colorScheme: resolvedColorScheme
        )
        let classicSurfaceStyle = ClassicStatsCardSurfaceStyle.make(for: backgroundColor)

        if preferences.style == .classic {
            ClassicStatsContent(
                serverName: serverName,
                stats: stats,
                visibleBlocks: preferences.visibleBlocks,
                surfaceStyle: classicSurfaceStyle,
                isDockerUnlocked: isDockerUnlocked,
                showsCustomizationEntryPoint: showsCustomizationEntryPoint,
                customizeAction: customizeAction,
                dockerUpgradeAction: dockerUpgradeAction,
                terminateProcess: terminateProcess,
                loadProcesses: loadProcesses,
                loadDockerStats: loadDockerStats,
                performDockerAction: performDockerAction
            )
            .padding(usesPagePadding ? 16 : 0)
            .drawingGroup()
            .frame(maxWidth: constrainsWidth ? nil : .infinity)
        } else {
            VStack(spacing: style.cardSpacing) {
                responsiveGrid(style: style)

                if showsCustomizationEntryPoint, let customizeAction {
                    StatsCustomizeButton(style: style, action: customizeAction)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, usesPagePadding ? style.horizontalPadding : 0)
            .padding(.top, usesPagePadding ? style.topPadding : 0)
            .padding(.bottom, usesPagePadding ? style.bottomPadding : 0)
            .frame(maxWidth: constrainsWidth ? style.gridMaximumWidth : .infinity)
            .frame(maxWidth: .infinity)
        }
    }

    private var renderedBlocks: [StatsPreferences.BlockID] {
        preferences.visibleBlocks.filter(shouldRenderBlock)
    }

    @ViewBuilder
    private func responsiveGrid(style: StatsVisualStyle) -> some View {
        ViewThatFits(in: .horizontal) {
            statsGrid(style: style, columnCount: 3)
                .frame(minWidth: minimumGridWidth(for: 3, style: style))
            statsGrid(style: style, columnCount: 2)
                .frame(minWidth: minimumGridWidth(for: 2, style: style))
            statsGrid(style: style, columnCount: 1)
        }
    }

    private func statsGrid(style: StatsVisualStyle, columnCount: Int) -> some View {
        let rows = gridRows(for: renderedBlocks, columnCount: columnCount)

        return Grid(alignment: .topLeading, horizontalSpacing: style.cardSpacing, verticalSpacing: style.cardSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow(alignment: .top) {
                    ForEach(row, id: \.self) { blockID in
                        statsBlock(blockID, style: style)
                            .gridCellColumns(gridSpan(for: blockID, columnCount: columnCount))
                    }

                    ForEach(0..<emptyCells(in: row, columnCount: columnCount), id: \.self) { _ in
                        Color.clear
                            .frame(minWidth: 0, minHeight: 0)
                            .gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func minimumGridWidth(for columnCount: Int, style: StatsVisualStyle) -> CGFloat {
        CGFloat(columnCount) * style.gridMinimumColumnWidth
            + CGFloat(max(0, columnCount - 1)) * style.cardSpacing
    }

    private func gridRows(for items: [StatsPreferences.BlockID], columnCount: Int) -> [[StatsPreferences.BlockID]] {
        var rows: [[StatsPreferences.BlockID]] = []
        var currentRow: [StatsPreferences.BlockID] = []
        var remainingColumns = columnCount

        for blockID in items {
            let span = gridSpan(for: blockID, columnCount: columnCount)

            if span > remainingColumns, !currentRow.isEmpty {
                rows.append(currentRow)
                currentRow = []
                remainingColumns = columnCount
            }

            currentRow.append(blockID)
            remainingColumns -= span

            if remainingColumns == 0 {
                rows.append(currentRow)
                currentRow = []
                remainingColumns = columnCount
            }
        }

        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }

    private func emptyCells(in row: [StatsPreferences.BlockID], columnCount: Int) -> Int {
        let occupiedColumns = row.reduce(0) { partialResult, blockID in
            partialResult + gridSpan(for: blockID, columnCount: columnCount)
        }
        return max(0, columnCount - occupiedColumns)
    }

    private func gridSpan(for blockID: StatsPreferences.BlockID, columnCount: Int) -> Int {
        switch blockID {
        case .docker:
            return isDockerUnlocked && columnCount >= 3 ? 2 : 1
        case .system, .cpu, .memory, .gpu, .network, .storage, .processes:
            return 1
        }
    }

    private func shouldRenderBlock(_ blockID: StatsPreferences.BlockID) -> Bool {
        switch blockID {
        case .gpu:
            return shouldShowGPU
        case .docker:
            return isDockerUnlocked || dockerUpgradeAction != nil
        case .system, .cpu, .memory, .network, .storage, .processes:
            return true
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
        case .docker:
            if isDockerUnlocked {
                DockerCard(
                    docker: stats.docker,
                    cpuHistory: dockerCPUHistory,
                    memoryHistory: dockerMemoryHistory,
                    style: style,
                    loadDockerStats: loadDockerStats,
                    performDockerAction: performDockerAction
                )
            } else if let dockerUpgradeAction {
                LockedDockerCard(style: style, action: dockerUpgradeAction)
            }
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
        stats.docker = DockerStats(
            availability: .available,
            containers: [
                DockerContainer(
                    id: "f0a1b2c3d4e5f6",
                    name: "ollama",
                    image: "ollama/ollama:latest",
                    command: "ollama serve",
                    state: .running,
                    status: "Up 2 hours (healthy)",
                    health: .healthy,
                    createdAt: "2026-07-06 09:00:00 +0000 UTC",
                    runningFor: "2 hours",
                    ports: "11434/tcp",
                    cpuPercent: 42,
                    memoryPercent: 28,
                    memoryUsed: 4 * gigabyte,
                    memoryLimit: 14 * gigabyte,
                    networkRx: 820 * 1_048_576,
                    networkTx: 210 * 1_048_576,
                    blockRead: 18 * gigabyte,
                    blockWrite: 6 * gigabyte,
                    pids: 22
                ),
                DockerContainer(
                    id: "a0b1c2d3e4f5a6",
                    name: "postgres",
                    image: "postgres:16",
                    command: "docker-entrypoint.sh",
                    state: .running,
                    status: "Up 3 days",
                    health: .none,
                    createdAt: "2026-07-03 12:00:00 +0000 UTC",
                    runningFor: "3 days",
                    ports: "5432/tcp",
                    cpuPercent: 6,
                    memoryPercent: 12,
                    memoryUsed: 1 * gigabyte,
                    memoryLimit: 8 * gigabyte,
                    networkRx: 220 * 1_048_576,
                    networkTx: 180 * 1_048_576,
                    blockRead: 9 * gigabyte,
                    blockWrite: 24 * gigabyte,
                    pids: 16
                ),
                DockerContainer(
                    id: "b0c1d2e3f4a5b6",
                    name: "redis",
                    image: "redis:7",
                    command: "redis-server",
                    state: .exited,
                    status: "Exited (0) 1 hour ago",
                    health: .none,
                    createdAt: "2026-07-01 10:00:00 +0000 UTC",
                    runningFor: "",
                    ports: "6379/tcp",
                    cpuPercent: 0,
                    memoryPercent: 0,
                    memoryUsed: nil,
                    memoryLimit: nil,
                    networkRx: nil,
                    networkTx: nil,
                    blockRead: nil,
                    blockWrite: nil,
                    pids: nil
                )
            ],
            timestamp: now
        )
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

    static var dockerCPUHistory: [StatsPoint] {
        makeHistory([12, 18, 26, 48, 35, 55, 42, 38, 51, 48])
    }

    static var dockerMemoryHistory: [StatsPoint] {
        makeHistory([20, 22, 24, 28, 30, 31, 32, 35, 37, 36])
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
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
            .background(style.cardFill, in: RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous)
                    .stroke(style.cardStroke, lineWidth: 1)
            }
    }
}

private struct StatsCustomizeButton: View {
    let style: StatsVisualStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline.weight(.bold))
                Text(String(localized: "Customize"))
                    .font(.subheadline.weight(.bold))

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(StatsCardButtonStyle())
        .accessibilityLabel(Text("Customize Stats"))
    }
}

private struct StatsCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Classic Layout

private struct ClassicStatsContent: View {
    let serverName: String
    let stats: ServerStats
    let visibleBlocks: [StatsPreferences.BlockID]
    let surfaceStyle: ClassicStatsCardSurfaceStyle
    let isDockerUnlocked: Bool
    let showsCustomizationEntryPoint: Bool
    let customizeAction: (() -> Void)?
    let dockerUpgradeAction: (() -> Void)?
    let terminateProcess: ((ProcessInfo) async throws -> Void)?
    let loadProcesses: (() async throws -> [ProcessInfo])?
    let loadDockerStats: (() async throws -> DockerStats)?
    let performDockerAction: ((DockerContainerAction, DockerContainer) async throws -> DockerStats)?

    var body: some View {
        LazyVStack(spacing: 16) {
            ForEach(visibleBlocks, id: \.self) { blockID in
                classicBlock(blockID)
            }

            if showsCustomizationEntryPoint, let customizeAction {
                ClassicStatsCustomizeCard(surfaceStyle: surfaceStyle, action: customizeAction)
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
        case .docker:
            if isDockerUnlocked {
                ClassicDockerStatsCard(
                    docker: stats.docker,
                    surfaceStyle: surfaceStyle,
                    loadDockerStats: loadDockerStats,
                    performDockerAction: performDockerAction
                )
            } else if let dockerUpgradeAction {
                ClassicLockedDockerCard(surfaceStyle: surfaceStyle, action: dockerUpgradeAction)
            }
        }
    }
}

private struct ClassicStatsCustomizeCard: View {
    let surfaceStyle: ClassicStatsCardSurfaceStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Customize Stats")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Cards, order, visibility")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 10)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(surfaceStyle.fill.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        style: StrokeStyle(
                            lineWidth: 1.5,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [6, 6]
                        )
                    )
                    .foregroundStyle(Color.secondary.opacity(0.55))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Customize Stats"))
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
            .statsDetailPresentation(isPresented: $showingProcesses, size: StatsPresentationSize.large) {
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

private struct ClassicDockerStatsCard: View {
    let docker: DockerStats
    let surfaceStyle: ClassicStatsCardSurfaceStyle
    let loadDockerStats: (() async throws -> DockerStats)?
    let performDockerAction: ((DockerContainerAction, DockerContainer) async throws -> DockerStats)?
    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        ClassicStatLabel(color: .blue, label: String(localized: "RUNNING"), value: "\(docker.runningCount)")
                        ClassicStatLabel(color: .secondary, label: String(localized: "STOPPED"), value: "\(docker.stoppedCount)")
                    }

                    HStack(spacing: 16) {
                        ClassicStatLabel(color: .pink, label: String(localized: "CPU"), value: formatPercent(docker.aggregateCPUPercent))
                        ClassicStatLabel(color: .blue, label: String(localized: "MEM"), value: formatPercent(docker.memoryPercent))
                    }
                }

                Spacer()

                ZStack {
                    ClassicCircularGauge(value: docker.memoryPercent / 100, color: .blue)
                    Image(systemName: "shippingbox")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .frame(width: 50, height: 50)
            }
            .padding()
            .classicStatsCardSurface(surfaceStyle)
        }
        .buttonStyle(.plain)
        .statsDetailPresentation(isPresented: $showingDetails, size: StatsPresentationSize.large) {
            DockerDetailsSheet(
                docker: docker,
                loadDockerStats: loadDockerStats,
                performDockerAction: performDockerAction
            )
        }
    }
}

private struct ClassicLockedDockerCard: View {
    let surfaceStyle: ClassicStatsCardSurfaceStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
                    .background(Color.blue.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(String(localized: "Docker"))
                            .font(.headline)
                        ProBadge(compact: true)
                    }
                    Text(String(localized: "Unlock Docker monitoring"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 10)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .classicStatsCardSurface(surfaceStyle)
        }
        .buttonStyle(.plain)
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
        .statsDetailPresentation(isPresented: $showingDetails) {
            SystemDetailsSheet(stats: stats)
        }
    }

    private var displayName: String {
        serverName.isEmpty ? String(localized: "System") : serverName
    }

    private var subtitle: String {
        if !stats.hostname.isEmpty, !stats.osInfo.isEmpty, stats.hostname != serverName {
            return "\(stats.hostname)\n\(stats.osInfo)"
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
                footer: footer,
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
        .statsDetailPresentation(isPresented: $showingDetails) {
            CPUDetailsSheet(stats: stats)
        }
    }

    private var cpuCountTitle: String {
        let count = max(stats.cpuCoreSamples.count, stats.cpuCores)
        if count <= 0 { return "" }
        if count == 1 { return String(localized: "1 core") }
        return String(format: String(localized: "%lld cores"), Int64(count))
    }

    private var footer: String {
        style.density == .detailed ? "" : compactFooter
    }

    private var compactFooter: String {
        String(
            format: String(localized: "User %@  System %@  Idle %@"),
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
            footer: formatUsedCapacity(stats.memoryUsed, total: stats.memoryTotal),
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
        .statsDetailPresentation(isPresented: $showingDetails) {
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
            return formatUsedCapacity(vram.used, total: vram.total)
        }
        let memoryTotal = sample?.memoryTotal ?? device?.memoryTotal ?? 0
        if let memoryUsed = sample?.memoryUsed, memoryTotal > 0 {
            return formatUsedCapacity(memoryUsed, total: memoryTotal)
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
            return String(format: String(localized: "%.0f W  %.0f C"), power, temp)
        }
        if let memoryUsed = sample?.memoryUsed {
            let memoryTotal = sample?.memoryTotal ?? device.memoryTotal
            if memoryTotal > 0 {
                return formatUsedCapacity(memoryUsed, total: memoryTotal)
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

                        if !footer.isEmpty {
                            Text(footer)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(style.secondaryText)
                                .lineLimit(2)
                                .minimumScaleFactor(0.78)
                        }
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
                    EmptyCardState(
                        icon: "internaldrive",
                        title: String(localized: "No Data"),
                        message: String(localized: "No volumes reported"),
                        color: .orange,
                        style: style
                    )
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
                        EmptyCardState(
                            icon: "list.bullet.rectangle",
                            title: String(localized: "No Data"),
                            message: String(localized: "No processes reported"),
                            color: .purple,
                            style: style
                        )
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
        .statsDetailPresentation(isPresented: $showingProcesses, size: StatsPresentationSize.large) {
            ProcessesSheet(
                processes: processes,
                processCount: processCount,
                terminateProcess: terminateProcess,
                loadProcesses: loadProcesses
            )
        }
    }
}

private struct DockerCard: View {
    let docker: DockerStats
    let cpuHistory: [StatsPoint]
    let memoryHistory: [StatsPoint]
    let style: StatsVisualStyle
    let loadDockerStats: (() async throws -> DockerStats)?
    let performDockerAction: ((DockerContainerAction, DockerContainer) async throws -> DockerStats)?
    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            AppleCard(style: style, minHeight: style.metricMinHeight) {
                VStack(alignment: .leading, spacing: 18) {
                    CardHeader(
                        icon: "shippingbox",
                        title: String(localized: "Docker"),
                        titleColor: .blue,
                        trailing: trailing,
                        showsChevron: true,
                        style: style
                    )

                    HStack(alignment: .bottom, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(metricLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(style.secondaryText)

                            Text(metricValue)
                                .font(.system(size: style.metricValueSize, weight: .bold, design: .rounded))
                                .foregroundStyle(style.primaryText)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)

                            Text(footer)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(style.secondaryText)
                                .lineLimit(2)
                                .minimumScaleFactor(0.78)
                        }

                        Spacer(minLength: 8)

                        MetricPreviewChart(
                            history: chartHistory,
                            color: .blue,
                            yDomain: chartYDomain,
                            style: style
                        )
                        .frame(width: style.metricPreviewWidth, height: style.metricPreviewHeight)
                    }

                    if style.density == .detailed {
                        MetricDetailGrid(items: detailItems, style: style)

                        if docker.isAvailable, !docker.topContainers.isEmpty {
                            VStack(spacing: 12) {
                                ForEach(docker.topContainers.prefix(3)) { container in
                                    DockerContainerCardRow(container: container, style: style)
                                }
                            }
                        }
                    }
                }
                .padding(style.cardPadding)
            }
        }
        .buttonStyle(.plain)
        .statsDetailPresentation(isPresented: $showingDetails, size: StatsPresentationSize.large) {
            DockerDetailsSheet(
                docker: docker,
                loadDockerStats: loadDockerStats,
                performDockerAction: performDockerAction
            )
        }
    }

    private var trailing: String {
        guard docker.isAvailable else { return String(localized: "Unavailable") }
        if docker.runningCount == 1 { return String(localized: "1 running") }
        return String(format: String(localized: "%lld running"), Int64(docker.runningCount))
    }

    private var metricLabel: String {
        docker.isAvailable ? String(localized: "Running") : String(localized: "Status")
    }

    private var metricValue: String {
        guard docker.isAvailable else { return String(localized: "No Data") }
        return "\(docker.runningCount)"
    }

    private var footer: String {
        guard docker.isAvailable else { return docker.availability.message }
        if docker.totalCount == 0 {
            return String(localized: "No containers reported")
        }
        return String(
            format: String(localized: "%lld containers reported"),
            Int64(docker.totalCount)
        )
    }

    private var chartHistory: [StatsPoint] {
        docker.isAvailable ? cpuHistory : memoryHistory
    }

    private var chartYDomain: ClosedRange<Double> {
        guard docker.isAvailable else { return 0...100 }
        let highestValue = chartHistory.reduce(docker.aggregateCPUPercent) { partialResult, point in
            max(partialResult, point.value)
        }
        let upperBound = max(100, (highestValue / 100).rounded(.up) * 100)
        return 0...upperBound
    }

    private var detailItems: [MetricDetailItem] {
        [
            MetricDetailItem(title: String(localized: "CPU"), value: formatPercent(docker.aggregateCPUPercent), color: .pink),
            MetricDetailItem(title: String(localized: "Memory"), value: formatPercent(docker.memoryPercent), color: .blue),
            MetricDetailItem(title: String(localized: "Stopped"), value: "\(docker.stoppedCount)", color: .secondary),
            MetricDetailItem(title: String(localized: "Unhealthy"), value: "\(docker.unhealthyCount)", color: .red)
        ]
    }
}

private struct LockedDockerCard: View {
    let style: StatsVisualStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AppleCard(style: style) {
                ViewThatFits(in: .horizontal) {
                    wideLayout
                        .frame(minWidth: 560, alignment: .topLeading)
                    compactLayout
                }
                .padding(style.cardPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .buttonStyle(StatsCardButtonStyle())
        .accessibilityLabel(Text("Unlock Docker monitoring"))
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                header

                Text(String(localized: "Inspect containers, catch unhealthy services, and control Docker without leaving your session."))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(style.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                unlockPill
            }
            .frame(maxWidth: 360, alignment: .leading)

            VStack(alignment: .leading, spacing: 13) {
                featureRows
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                header
                Spacer(minLength: 8)
                compactUnlockPill
            }

            Text(String(localized: "Inspect containers, catch unhealthy services, and control Docker."))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(style.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                featureRows
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 13) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.blue)
                    .frame(width: 46, height: 46)
                    .background(Color.blue.opacity(0.14), in: Circle())

                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Color.blue, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(style.cardFill, lineWidth: 2)
                    }
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(String(localized: "Docker"))
                        .font(.headline.weight(.bold))
                    ProBadge(compact: true)
                }
                .foregroundStyle(style.primaryText)

                Text(String(localized: "Pro monitoring"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.secondaryText)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var unlockPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.open")
                .font(.caption.weight(.bold))
            Text(String(localized: "Unlock Docker"))
                .font(.subheadline.weight(.bold))
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(Color.blue)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.12), in: Capsule())
    }

    private var compactUnlockPill: some View {
        ViewThatFits(in: .horizontal) {
            unlockPill
            HStack(spacing: 6) {
                Image(systemName: "lock.open")
                    .font(.caption.weight(.bold))
                Text(String(localized: "Unlock"))
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(Color.blue)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder
    private var featureRows: some View {
        LockedDockerFeature(
            systemImage: "list.bullet.rectangle",
            title: String(localized: "Containers"),
            subtitle: String(localized: "Search, sort, and inspect state"),
            color: .blue,
            style: style
        )
        LockedDockerFeature(
            systemImage: "waveform.path.ecg",
            title: String(localized: "Health"),
            subtitle: String(localized: "Spot unhealthy services fast"),
            color: .green,
            style: style
        )
        LockedDockerFeature(
            systemImage: "power",
            title: String(localized: "Actions"),
            subtitle: String(localized: "Start, stop, and restart"),
            color: .orange,
            style: style
        )
    }
}

private struct LockedDockerFeature: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.primaryText)
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(style.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

private struct DockerContainerCardRow: View {
    let container: DockerContainer
    let style: StatsVisualStyle

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(dockerStatusColor(container))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(container.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(container.image)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            ProcessBadge(
                title: String(localized: "CPU"),
                value: container.cpuPercent,
                color: .pink,
                style: style
            )

            ProcessBadge(
                title: String(localized: "MEM"),
                value: container.memoryPercent,
                color: .blue,
                style: style
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

            Text(formatUsedCapacity(volume.used, total: volume.total))
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
                Text(formatPercent(value))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(style.primaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(style.secondaryText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.68)

            MiniMeter(value: min(value / 100, 1), color: color, style: style)
                .frame(width: 54)
        }
        .frame(width: 62, alignment: .trailing)
    }
}

private struct EmptyCardState: View {
    let icon: String
    let title: String
    let message: String
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 48, height: 48)
                .background(color.opacity(0.14), in: Circle())

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(style.primaryText)

                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(style.secondaryText)
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, minHeight: 142, maxHeight: .infinity, alignment: .center)
        .padding(.vertical, style.density == .detailed ? 18 : 12)
    }
}
