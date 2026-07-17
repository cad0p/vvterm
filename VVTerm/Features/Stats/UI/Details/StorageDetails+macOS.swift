#if os(macOS)
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
        StatsDetailShell(
            String(localized: "Storage"),
            systemImage: "internaldrive",
            tint: .orange
        ) {
            HStack(spacing: 8) {
                filterControl()
                selectionControl()
                actionsControl()
            }
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
#endif
