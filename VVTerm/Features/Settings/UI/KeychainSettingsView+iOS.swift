#if os(iOS)
import SwiftUI

extension KeychainSettingsView {
    @ViewBuilder
    func platformKeyRow(for key: SSHKeyEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                keyToShowDetails = key
            } label: {
                SSHKeyRow(key: key)
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            keyActions(for: key)
        }
    }
}
#endif
