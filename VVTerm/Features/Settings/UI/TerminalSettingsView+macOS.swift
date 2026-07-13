#if os(macOS)
import AppKit
import SwiftUI

extension TerminalSettingsView {
    func loadSystemFonts() -> [String] {
        let fontManager = NSFontManager.shared
        return fontManager.availableFontFamilies.filter { familyName in
            guard let font = NSFont(name: familyName, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }

    var keyboardAccessorySection: some View {
        Section {
            Picker("Option as Alt", selection: optionAsAltModeBinding) {
                ForEach(TerminalOptionAsAltMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
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
        VStack(spacing: 0) {
            DialogSheetHeader(title: "Custom Themes") {
                dismiss()
            }

            Divider()

            if sortedThemes.isEmpty {
                customThemesEmptyState
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sortedThemes) { theme in
                            let assignment = assignmentLabel(for: theme.name)
                            CustomThemeManagerRow(
                                theme: theme,
                                assignment: assignment,
                                usePerAppearanceTheme: usePerAppearanceTheme,
                                isHovered: hoveredThemeID == theme.id,
                                isSelected: assignment != nil,
                                onApply: { target in
                                    applyThemeSelection(themeName: theme.name, applyTarget: target)
                                },
                                onEdit: {
                                    themePendingEdit = theme
                                },
                                onDeleteRequest: {
                                    themePendingDeletion = theme
                                }
                            )
                            .onHover { hovering in
                                hoveredThemeID = hovering ? theme.id : nil
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            Divider()

            HStack {
                Menu {
                    createThemeMenuItems
                } label: {
                    Label("New Custom Theme", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 400, height: 500)
    }
}

extension CustomThemeSaveSheet {
    var platformBody: some View {
        VStack(spacing: 0) {
            DialogSheetHeader(title: "Save Custom Theme") {
                dismiss()
            }

            Divider()

            formContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            macActionRow
        }
        .frame(width: 700, height: usePerAppearanceTheme ? 300 : 250)
    }

    private var macActionRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            Button("Cancel") {
                dismiss()
            }

            Button("Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

extension ThemeBuilderSheet {
    var platformBody: some View {
        VStack(spacing: 0) {
            DialogSheetHeader(title: LocalizedStringKey(title)) {
                dismiss()
            }

            Divider()

            formContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            macActionRow
        }
    }

    private var macActionRow: some View {
        HStack(spacing: 10) {
            if onDeleteRequest != nil {
                Button("Remove Theme", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            Spacer(minLength: 0)

            Button("Cancel") {
                dismiss()
            }

            Button("Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct CustomThemeManagerRow: View {
    let theme: TerminalTheme
    let assignment: String?
    let usePerAppearanceTheme: Bool
    let isHovered: Bool
    let isSelected: Bool
    let onApply: (CustomThemeApplyTarget) -> Void
    let onEdit: () -> Void
    let onDeleteRequest: () -> Void

    @Environment(\.controlActiveState) private var controlActiveState

    private var selectionFillColor: Color {
        let base = NSColor.unemphasizedSelectedContentBackgroundColor
        let alpha: Double = controlActiveState == .key ? 0.26 : 0.18
        return Color(nsColor: base).opacity(alpha)
    }

    private var selectedTextColor: Color {
        Color(nsColor: .selectedTextColor)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(theme.name)
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(isSelected ? selectedTextColor : .primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let assignment {
                PillBadge(text: assignment, color: .secondary)
            }

            if isHovered || isSelected {
                Menu {
                    applyMenuItems
                } label: {
                    Image(systemName: "paintbrush.pointed.fill")
                        .foregroundStyle(isSelected ? selectedTextColor.opacity(0.9) : .secondary)
                        .imageScale(.medium)
                }
                .menuStyle(.borderlessButton)

                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(isSelected ? selectedTextColor.opacity(0.9) : .secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? selectionFillColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if usePerAppearanceTheme {
                onApply(.both)
            } else {
                onApply(.dark)
            }
        }
        .contextMenu {
            applyMenuItems
            Divider()
            Button("Edit") {
                onEdit()
            }
            Button("Delete", role: .destructive) {
                onDeleteRequest()
            }
        }
    }

    @ViewBuilder
    private var applyMenuItems: some View {
        if usePerAppearanceTheme {
            Button("Apply to Dark") {
                onApply(.dark)
            }
            Button("Apply to Light") {
                onApply(.light)
            }
            Button("Apply to Both") {
                onApply(.both)
            }
        } else {
            Button("Use Theme") {
                onApply(.dark)
            }
        }
    }
}
#endif
