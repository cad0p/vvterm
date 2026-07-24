#if os(macOS)
import SwiftUI

struct StorageHealthDetailsPlatformShell<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        StatsDetailShell(
            String(localized: "Storage Health"),
            systemImage: "internaldrive",
            tint: .orange
        ) {
            content()
                .listStyle(.plain)
        }
    }
}
#endif
