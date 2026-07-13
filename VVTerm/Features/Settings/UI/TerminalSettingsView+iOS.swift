#if os(iOS)
import SwiftUI
import UIKit

extension TerminalSettingsView {
    func loadSystemFonts() -> [String] {
        var fonts = ["Menlo", "SF Mono", "Courier New"]
        let nerdFonts = [
            "JetBrainsMono Nerd Font",
            "Hack Nerd Font",
            "FiraCode Nerd Font",
            "MesloLGS Nerd Font"
        ]

        for fontFamily in nerdFonts where UIFont(name: fontFamily, size: 12) != nil {
            fonts.append(fontFamily)
        }

        return fonts.sorted()
    }

    @ViewBuilder
    var keyboardAccessorySection: some View {
        TerminalKeyboardSettingsSection(
            accessoryCustomizationEnabled: terminalAccessoryCustomizationEnabled,
            keyboardDismissButtonEnabled: $terminalKeyboardDismissButtonEnabled
        )
    }
}

private struct TerminalKeyboardSettingsSection: View {
    let accessoryCustomizationEnabled: Bool
    @Binding var keyboardDismissButtonEnabled: Bool
    @AppStorage(TerminalDefaults.optionAsAltModeKey) private var optionAsAltModeRaw = TerminalOptionAsAltMode.none.rawValue

    private var optionAsAltModeBinding: Binding<TerminalOptionAsAltMode> {
        Binding(
            get: { TerminalOptionAsAltMode(rawValue: optionAsAltModeRaw) ?? .none },
            set: { optionAsAltModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Section {
            Picker("Option as Alt", selection: optionAsAltModeBinding) {
                ForEach(TerminalOptionAsAltMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            if accessoryCustomizationEnabled {
                Toggle("Show keyboard dismiss button", isOn: $keyboardDismissButtonEnabled)

                NavigationLink {
                    TerminalAccessoryCustomizationView()
                } label: {
                    Text("Customize Accessory Bar")
                }

                NavigationLink {
                    TerminalCustomActionLibraryView()
                } label: {
                    Text("Manage Custom Actions")
                }
            }
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Choose which physical Option key sends Alt to terminal apps. Other Option keys remain available for keyboard-layout characters.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension ManageCustomThemesSheet {
    var platformBody: some View {
        NavigationStack {
            Group {
                if sortedThemes.isEmpty {
                    customThemesEmptyState
                } else {
                    List {
                        ForEach(sortedThemes) { theme in
                            themeRow(theme)
                        }
                    }
                }
            }
            .navigationTitle("Custom Themes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        createThemeMenuItems
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private func themeRow(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(theme.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                if let assignment = assignmentLabel(for: theme.name) {
                    Text(assignment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Menu {
                applyMenuItems(themeName: theme.name)

                Divider()

                Button("Edit") {
                    themePendingEdit = theme
                }

                Button("Delete", role: .destructive) {
                    themePendingDeletion = theme
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Edit") {
                themePendingEdit = theme
            }
            .tint(.blue)

            Button("Delete", role: .destructive) {
                themePendingDeletion = theme
            }
        }
    }
}

extension CustomThemeSaveSheet {
    var platformBody: some View {
        NavigationStack {
            formContent
                .navigationTitle("Save Custom Theme")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save()
                        }
                        .disabled(!canSave)
                    }
                }
        }
        .adaptiveSoftScrollEdges()
    }
}

extension ThemeBuilderSheet {
    var platformBody: some View {
        NavigationStack {
            formContent
                .environment(\.defaultMinListRowHeight, 34)
                .modifier(ThemeBuilderCompactListSectionSpacingModifier())
                .modifier(ThemeBuilderTransparentNavigationBarModifier())
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarAppearance(
                    backgroundColor: .clear,
                    isTranslucent: true,
                    shadowColor: .clear
                )
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .tint(.secondary)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save()
                        }
                        .disabled(!canSave)
                    }
                    if onDeleteRequest != nil {
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button("Remove Theme", role: .destructive) {
                                showingDeleteConfirmation = true
                            }
                            .tint(.red)

                            Spacer(minLength: 0)
                        }
                    }
                }
        }
    }
}

private struct ThemeBuilderCompactListSectionSpacingModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.listSectionSpacing(.compact)
        } else {
            content
        }
    }
}

private struct ThemeBuilderTransparentNavigationBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
        }
    }
}
#endif
