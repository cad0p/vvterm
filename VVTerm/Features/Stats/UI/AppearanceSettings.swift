import SwiftUI

struct AppearanceSettings: View {
    @StateObject private var store = PreferencesStore.shared

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Presentation"), selection: styleBinding) {
                    ForEach(StatsPreferences.Style.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(String(localized: "Layout")) {
                ForEach(store.preferences.orderedBlocks) { block in
                    Toggle(isOn: visibilityBinding(for: block.id)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(block.id.title)
                                Text(visibilitySubtitle(for: block))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: block.id.systemImage)
                                .foregroundStyle(block.id.tint)
                        }
                    }
                    .disabled(block.id == .system)
                }
                .onMove { source, destination in
                    store.moveBlocks(fromOffsets: source, toOffset: destination)
                }
            }

            Section(String(localized: "Preview")) {
                StatsAppearancePreviewContent(preferences: store.preferences)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .toolbar {
            EditButton()
        }
        #endif
    }

    private var styleBinding: Binding<StatsPreferences.Style> {
        Binding(
            get: { store.preferences.style },
            set: { store.setStyle($0) }
        )
    }

    private func visibilityBinding(for id: StatsPreferences.BlockID) -> Binding<Bool> {
        Binding(
            get: { store.preferences.isBlockVisible(id) },
            set: { store.setBlockVisibility(id, isVisible: $0) }
        )
    }

    private func visibilitySubtitle(for block: StatsPreferences.Block) -> String {
        if block.id == .system {
            return String(localized: "Required")
        }
        return block.isVisible ? String(localized: "Visible") : String(localized: "Hidden")
    }
}

private extension StatsPreferences.Style {
    var title: String {
        switch self {
        case .cardsCompact:
            return String(localized: "Cards Compact")
        case .cardsDetailed:
            return String(localized: "Cards Detailed")
        case .classic:
            return String(localized: "Classic")
        }
    }
}

private extension StatsPreferences.BlockID {
    var title: String {
        switch self {
        case .system:
            return String(localized: "System")
        case .cpu:
            return String(localized: "CPU")
        case .memory:
            return String(localized: "Memory")
        case .gpu:
            return String(localized: "GPU")
        case .network:
            return String(localized: "Network")
        case .storage:
            return String(localized: "Storage")
        case .processes:
            return String(localized: "Processes")
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            return "server.rack"
        case .cpu:
            return "cpu"
        case .memory:
            return "memorychip"
        case .gpu:
            return "display"
        case .network:
            return "arrow.up.arrow.down"
        case .storage:
            return "internaldrive"
        case .processes:
            return "list.bullet.rectangle"
        }
    }

    var tint: Color {
        switch self {
        case .system:
            return .cyan
        case .cpu:
            return .pink
        case .memory:
            return .blue
        case .gpu:
            return .green
        case .network:
            return .cyan
        case .storage:
            return .orange
        case .processes:
            return .purple
        }
    }
}
