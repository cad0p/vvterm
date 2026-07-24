import SwiftUI

struct TerminalEmptyStateView: View {
    let server: Server?
    let onNewTerminal: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text(server?.name ?? String(localized: "Terminal"))
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("No terminals open")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onNewTerminal) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("New Terminal")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.tint, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
