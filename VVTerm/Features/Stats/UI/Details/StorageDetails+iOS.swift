#if os(iOS)
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
        NavigationStack {
            content()
                .navigationTitle(Text("Storage"))
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: Text("Search Volumes"))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        controls()
                    }
                }
                .statsSheetCloseToolbar(placement: .leading)
        }
        .presentationDetents([.large])
    }
}

extension View {
    func storageVolumeToggleLabelAlignment() -> some View { self }
}
#endif
