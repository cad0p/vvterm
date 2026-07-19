#if os(macOS)
import SwiftUI

struct StorageDetailsPlatformShell<Controls: View, Content: View>: View {
    @Binding var searchText: String
    let controls: () -> Controls
    let content: () -> Content

    init(
        searchText: Binding<String>,
        @ViewBuilder controls: @escaping () -> Controls,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _searchText = searchText
        self.controls = controls
        self.content = content
    }

    var body: some View {
        StatsDetailShell(
            String(localized: "Storage"),
            systemImage: "internaldrive",
            tint: .orange
        ) {
            controls()
        } content: {
            VStack(spacing: 0) {
                StatsSearchField(prompt: String(localized: "Search Volumes"), text: $searchText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
                content()
            }
        }
    }
}

extension View {
    func storageVolumeToggleLabelAlignment() -> some View {
        alignmentGuide(.firstTextBaseline) { dimensions in
            dimensions[VerticalAlignment.center]
        }
    }
}
#endif
