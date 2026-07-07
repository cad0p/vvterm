#if os(iOS)
import SwiftUI
import Foundation

struct ZenModePanel: View {
    let width: CGFloat
    let serverName: String
    let selectedView: String
    let selectedViewBinding: Binding<String>
    let viewTabs: [ConnectionViewTab]
    let sessions: [ConnectionSession]
    let selectedSessionId: Binding<UUID?>
    let sessionTitle: (ConnectionSession) -> String
    let onCloseSession: (ConnectionSession) -> Void
    let fileTabs: [RemoteFileTab]
    let selectedFileTabId: Binding<UUID?>
    let fileTabTitle: (RemoteFileTab) -> String
    let onSelectFileTab: (RemoteFileTab) -> Void
    let onCloseFileTab: (RemoteFileTab) -> Void
    let onNewTerminalTab: () -> Void
    let onNewFileTab: () -> Void
    let onOpenSettings: () -> Void
    let onEditServer: (() -> Void)?
    let onDisconnect: () -> Void
    let onBack: () -> Void
    let onExitZen: () -> Void

    var body: some View {
        ZenModePanelCard(width: width) {
            ZenModeStatusLine(
                title: serverName,
                subtitle: statusText,
                indicatorColor: sessions.first?.connectionState.statusTintColor ?? .secondary
            )

            ZenModeSection("View") {
                HStack(spacing: 8) {
                    ForEach(viewTabs) { tab in
                        ZenModeChoiceChip(
                            title: LocalizedStringKey(tab.localizedKey),
                            systemImage: tab.icon,
                            isSelected: selectedView == tab.id
                        ) {
                            selectedViewBinding.wrappedValue = tab.id
                        }
                    }
                }
            }

            ZenModeSection("Tabs") {
                ZenModeActionButton(title: "New Tab", systemImage: "plus") {
                    if selectedView == ConnectionViewTab.files.id {
                        onNewFileTab()
                    } else {
                        onNewTerminalTab()
                    }
                }

                if selectedView == ConnectionViewTab.files.id {
                    if fileTabs.isEmpty {
                        Text("No file tabs open.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(fileTabs) { tab in
                                fileTabRow(tab)
                            }
                        }
                    }
                } else if sessions.isEmpty {
                    Text("No terminals open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }

            ZenModeSection("Server") {
                ZenModeActionButton(title: "Settings", systemImage: "gear") {
                    onOpenSettings()
                }

                if let onEditServer {
                    ZenModeActionButton(title: "Edit Server", systemImage: "pencil") {
                        onEditServer()
                    }
                }

                ZenModeActionButton(title: "Back", systemImage: "chevron.left") {
                    onBack()
                }
            }

            ZenModeSection("Session") {
                ZenModeActionButton(
                    title: "Disconnect",
                    systemImage: "xmark.circle",
                    tint: .red
                ) {
                    onDisconnect()
                }
            }

            ZenModeSection("Zen") {
                ZenModeActionButton(
                    title: "Exit Zen Mode",
                    systemImage: "arrow.down.right.and.arrow.up.left"
                ) {
                    onExitZen()
                }
            }
        }
    }

    private func sessionRow(_ session: ConnectionSession) -> some View {
        let isSelected = selectedSessionId.wrappedValue == session.id

        return HStack(spacing: 8) {
            Button {
                selectedViewBinding.wrappedValue = "terminal"
                selectedSessionId.wrappedValue = session.id
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(session.connectionState.statusTintColor)
                        .frame(width: 7, height: 7)

                    Text(sessionTitle(session))
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.14 : 0.07))
                )
            }
            .buttonStyle(.plain)

            Button {
                onCloseSession(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.12))
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func fileTabRow(_ tab: RemoteFileTab) -> some View {
        let isSelected = selectedFileTabId.wrappedValue == tab.id

        return HStack(spacing: 8) {
            Button {
                selectedViewBinding.wrappedValue = ConnectionViewTab.files.id
                selectedFileTabId.wrappedValue = tab.id
                onSelectFileTab(tab)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)

                    Text(fileTabTitle(tab))
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.14 : 0.07))
                )
            }
            .buttonStyle(.plain)

            Button {
                onCloseFileTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.12))
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var statusText: String {
        if selectedView == ConnectionViewTab.files.id {
            return fileTabs.isEmpty
                ? String(localized: "No open file tabs")
                : String(format: String(localized: "%lld open file tabs"), Int64(fileTabs.count))
        }

        return sessions.isEmpty
            ? String(localized: "No open terminals")
            : String(format: String(localized: "%lld open tabs"), Int64(sessions.count))
    }
}
#endif
