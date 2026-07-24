#if os(macOS)
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

            keyActionsMenu(for: key)
        }
        .contextMenu {
            keyActions(for: key)
        }
    }

    private func keyActionsMenu(for key: SSHKeyEntry) -> some View {
        Menu {
            keyActions(for: key)
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(String(localized: "Key Actions"))
    }
}
#endif
