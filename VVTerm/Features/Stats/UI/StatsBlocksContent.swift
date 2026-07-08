import SwiftUI

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

private enum StatsGridLayoutSelection {
    // Mirrors the old ViewThatFits candidates: each column had to satisfy the
    // widest natural single-column card, currently the locked Docker upsell.
    static func minimumGridWidth(
        for columnCount: Int,
        style: StatsVisualStyle,
        includesLockedDockerCard: Bool
    ) -> CGFloat {
        let columnWidth = includesLockedDockerCard
            ? max(style.gridMinimumColumnWidth, LockedDockerCard.wideLayoutMinimumWidth)
            : style.gridMinimumColumnWidth
        return CGFloat(columnCount) * columnWidth
            + CGFloat(max(0, columnCount - 1)) * style.cardSpacing
    }

    static func columnCount(
        for availableWidth: CGFloat,
        style: StatsVisualStyle,
        includesLockedDockerCard: Bool
    ) -> Int {
        guard availableWidth > 0 else { return 1 }
        if availableWidth >= minimumGridWidth(
            for: 3,
            style: style,
            includesLockedDockerCard: includesLockedDockerCard
        ) {
            return 3
        }
        if availableWidth >= minimumGridWidth(
            for: 2,
            style: style,
            includesLockedDockerCard: includesLockedDockerCard
        ) {
            return 2
        }
        return 1
    }
}

struct StatsBlocksContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(StatsResolvedAppearance.storageKey) private var appearanceMode = "system"
    @State private var measuredGridWidth: CGFloat = 0

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
                responsiveGrid(style: style, availableWidth: measuredGridWidth)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { newWidth in
                        measuredGridWidth = newWidth
                    }

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
    private func responsiveGrid(style: StatsVisualStyle, availableWidth: CGFloat) -> some View {
        let columnCount = StatsGridLayoutSelection.columnCount(
            for: availableWidth,
            style: style,
            includesLockedDockerCard: includesLockedDockerCard
        )

        statsGrid(style: style, columnCount: columnCount)
            .frame(
                minWidth: columnCount > 1
                    ? StatsGridLayoutSelection.minimumGridWidth(
                        for: columnCount,
                        style: style,
                        includesLockedDockerCard: includesLockedDockerCard
                    )
                    : nil
            )
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

    private var includesLockedDockerCard: Bool {
        renderedBlocks.contains(.docker) && !isDockerUnlocked && dockerUpgradeAction != nil
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
