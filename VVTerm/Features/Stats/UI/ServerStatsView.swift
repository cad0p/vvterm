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
            StatsAppearanceSettingsSheet()
        }
    }
}
