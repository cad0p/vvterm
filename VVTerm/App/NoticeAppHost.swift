import SwiftUI

struct NoticeAppHost<Content: View>: View {
    @ObservedObject private var networkMonitor: NetworkMonitor = .shared
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var topBannerNotice: NoticeItem? {
        guard !networkMonitor.isConnected else { return nil }

        return NoticeItem(
            id: "app-offline",
            lane: .topBanner,
            level: .warning,
            leading: .icon("wifi.slash"),
            title: String(localized: "Offline"),
            message: String(localized: "No network connection. Network-dependent features are paused.")
        )
    }

    var body: some View {
        NoticeHost(topBanner: topBannerNotice, topInsetBehavior: .safeAreaTop) {
            content
        }
        .animation(.easeInOut(duration: 0.2), value: networkMonitor.isConnected)
    }
}
