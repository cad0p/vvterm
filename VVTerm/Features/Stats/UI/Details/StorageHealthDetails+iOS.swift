#if os(iOS)
import SwiftUI

struct StorageHealthDetailsPlatformShell<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(Text("Storage Health"))
                .navigationBarTitleDisplayMode(.inline)
                .statsSheetCloseToolbar()
        }
        .presentationDetents([.large])
    }
}
#endif
