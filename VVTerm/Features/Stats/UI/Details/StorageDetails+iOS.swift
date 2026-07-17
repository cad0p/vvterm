#if os(iOS)
import SwiftUI

struct StorageDetailsPlatformShell<FilterControl: View, SelectionControl: View, ActionsControl: View, Content: View>: View {
    @Binding var searchText: String
    let filterControl: () -> FilterControl
    let selectionControl: () -> SelectionControl
    let actionsControl: () -> ActionsControl
    let content: () -> Content

    init(
        searchText: Binding<String>,
        @ViewBuilder filterControl: @escaping () -> FilterControl,
        @ViewBuilder selectionControl: @escaping () -> SelectionControl,
        @ViewBuilder actionsControl: @escaping () -> ActionsControl,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _searchText = searchText
        self.filterControl = filterControl
        self.selectionControl = selectionControl
        self.actionsControl = actionsControl
        self.content = content
    }

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(Text("Storage"))
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: Text("Search Volumes"))
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        filterControl()
                        selectionControl()
                        actionsControl()
                    }
                }
                .statsSheetCloseToolbar(placement: .leading)
        }
        .presentationDetents([.large])
    }
}
#endif
