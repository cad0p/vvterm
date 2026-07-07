#if os(iOS)
import SwiftUI

extension ConnectionTerminalContainer {
    var platformBody: some View {
        sharedBody
    }

    func platformChrome<Content: View>(
        _ content: Content,
        backgroundColor: Color
    ) -> some View {
        content
    }

    @ViewBuilder
    var terminalLayer: some View {
        if selectedView == "terminal" && serverTabs.isEmpty {
            TerminalEmptyStateView(server: server) {
                openNewTab()
            }
        }
    }
}
#endif
