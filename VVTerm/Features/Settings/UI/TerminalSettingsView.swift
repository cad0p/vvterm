//
//  TerminalSettingsView.swift
//  VVTerm
//

import SwiftUI
import UniformTypeIdentifiers

enum CustomThemeApplyTarget: String, CaseIterable, Identifiable {
    case dark
    case light
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return String(localized: "Dark")
        case .light: return String(localized: "Light")
        case .both: return String(localized: "Both")
        }
    }
}

private struct PendingCustomThemeSource: Identifiable {
    let id = UUID()
    var suggestedName: String
    var content: String
}

private struct CursorStyleOptionView: View {
    let style: TerminalCursorStyle
    let isSelected: Bool
    let blinks: Bool
    let palette: TerminalThemePreviewPalette

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                TerminalCursorPreview(style: style, blinks: blinks, palette: palette)
                    .frame(width: 72, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
            }

            Text(style.displayName)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .contentShape(Rectangle())
    }
}

private struct TerminalCursorPreview: View {
    let style: TerminalCursorStyle
    let blinks: Bool
    let palette: TerminalThemePreviewPalette

    var body: some View {
        if blinks {
            TimelineView(.periodic(from: .now, by: 0.55)) { timeline in
                previewContent(isVisible: cursorIsVisible(at: timeline.date))
            }
        } else {
            previewContent(isVisible: true)
        }
    }

    private func cursorIsVisible(at date: Date) -> Bool {
        guard blinks else { return true }
        let tick = Int(date.timeIntervalSinceReferenceDate / 0.55)
        return tick.isMultiple(of: 2)
    }

    private func previewContent(isVisible: Bool) -> some View {
        HStack(spacing: 0) {
            Text("~ ")
                .foregroundStyle(palette.foreground.opacity(0.55))
            cursorSample(isVisible: isVisible)
        }
        .font(.system(size: 19, weight: .medium, design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.foreground.opacity(0.14), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func cursorSample(isVisible: Bool) -> some View {
        switch style {
        case .block:
            Text("A")
                .foregroundStyle(isVisible ? palette.cursorText : palette.foreground.opacity(0.75))
                .padding(.horizontal, 1)
                .background(
                    Rectangle()
                        .fill(isVisible ? palette.cursor : Color.clear)
                )
        case .bar:
            ZStack(alignment: .leading) {
                Text("A")
                    .foregroundStyle(palette.foreground.opacity(0.75))
                Rectangle()
                    .fill(isVisible ? palette.cursor : Color.clear)
                    .frame(width: 2, height: 23)
            }
        case .underline:
            ZStack(alignment: .bottom) {
                Text("A")
                    .foregroundStyle(palette.foreground.opacity(0.75))
                Rectangle()
                    .fill(isVisible ? palette.cursor : Color.clear)
                    .frame(width: 13, height: 2)
            }
        case .blockHollow:
            Text("A")
                .foregroundStyle(palette.foreground.opacity(0.75))
                .padding(.horizontal, 1)
                .overlay(
                    Rectangle()
                        .stroke(isVisible ? palette.cursor : Color.clear, lineWidth: 1.5)
                )
        }
    }
}

// MARK: - Terminal Settings View

struct TerminalSettingsView: View {
    @Binding var fontName: String
    @Binding var fontSize: Double

    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var themeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var themeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("terminalNotificationsEnabled") private var terminalNotificationsEnabled = true
    @AppStorage("terminalProgressEnabled") private var terminalProgressEnabled = true
    @AppStorage("terminalAccessoryCustomizationEnabled") var terminalAccessoryCustomizationEnabled = true
    @AppStorage("terminalKeyboardDismissButtonEnabled") var terminalKeyboardDismissButtonEnabled = true
    @AppStorage("terminalTmuxEnabledDefault") private var tmuxEnabledDefault = true
    @AppStorage("terminalTmuxStartupBehaviorDefault") private var tmuxStartupBehaviorDefaultRaw = TmuxStartupBehavior.askEveryTime.rawValue

    // Copy settings
    @AppStorage("terminalCopyTrimTrailingWhitespace") private var copyTrimTrailingWhitespace = true
    @AppStorage("terminalCopyCollapseBlankLines") private var copyCollapseBlankLines = false
    @AppStorage("terminalCopyStripShellPrompts") private var copyStripShellPrompts = false
    @AppStorage("terminalCopyFlattenCommands") private var copyFlattenCommands = false
    @AppStorage("terminalCopyRemoveBoxDrawing") private var copyRemoveBoxDrawing = false
    @AppStorage("terminalCopyStripAnsiCodes") private var copyStripAnsiCodes = true

    // Image paste settings
    @AppStorage("terminalImagePasteBehavior") private var imagePasteBehaviorRaw = ImagePasteBehavior.askOnce.rawValue

    // SSH settings
    @AppStorage("sshKeepAliveEnabled") private var keepAliveEnabled = true
    @AppStorage("sshKeepAliveInterval") private var keepAliveInterval = 30
    @AppStorage(TerminalDefaults.sshAutoReconnectKey) private var autoReconnect = true

    // Cursor settings
    @AppStorage(TerminalDefaults.cursorStyleKey) private var cursorStyleRaw = TerminalDefaults.defaultCursorStyle.rawValue
    @AppStorage(TerminalDefaults.cursorBlinkKey) private var cursorBlink = TerminalDefaults.defaultCursorBlink
    @AppStorage(TerminalDefaults.optionAsAltModeKey) private var optionAsAltModeRaw = TerminalOptionAsAltMode.none.rawValue

    @EnvironmentObject private var terminalThemeManager: TerminalThemeManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var availableFonts: [String] = []
    @State private var builtInThemeNames: [String] = []
    @State private var customThemeErrorMessage: String?
    @State private var showingCustomThemeManager = false
    @State private var showingResetKnownHostsConfirmation = false
    @State private var knownHostCount = 0

    private var builtInThemeOptions: [String] {
        Set(builtInThemeNames)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var customThemes: [TerminalTheme] {
        terminalThemeManager.customThemes
            .filter { !$0.isDeleted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var customThemeOptions: [String] {
        let builtIn = Set(builtInThemeOptions)
        return customThemes.map(\.name).filter { !builtIn.contains($0) }
    }

    private var allThemeNames: [String] {
        builtInThemeOptions + customThemeOptions
    }

    private var customThemeCountLabel: String {
        let count = Int64(customThemes.count)
        return count == 1
            ? String(format: String(localized: "%lld custom theme"), count)
            : String(format: String(localized: "%lld custom themes"), count)
    }

    private var tmuxStartupBehaviorDefaultBinding: Binding<TmuxStartupBehavior> {
        Binding(
            get: { TmuxStartupBehavior(rawValue: tmuxStartupBehaviorDefaultRaw) ?? .askEveryTime },
            set: { tmuxStartupBehaviorDefaultRaw = $0.rawValue }
        )
    }

    private var imagePasteBehavior: ImagePasteBehavior {
        ImagePasteBehavior(rawValue: imagePasteBehaviorRaw) ?? .askOnce
    }

    private var imagePasteBehaviorBinding: Binding<ImagePasteBehavior> {
        Binding(
            get: { imagePasteBehavior },
            set: { behavior in
                imagePasteBehaviorRaw = behavior.rawValue
            }
        )
    }

    private var tmuxStartupBehaviorDefault: TmuxStartupBehavior {
        TmuxStartupBehavior(rawValue: tmuxStartupBehaviorDefaultRaw) ?? .askEveryTime
    }

    private var selectedCursorStyle: TerminalCursorStyle {
        TerminalCursorStyle(rawValue: cursorStyleRaw) ?? TerminalDefaults.defaultCursorStyle
    }

    var optionAsAltModeBinding: Binding<TerminalOptionAsAltMode> {
        Binding(
            get: { TerminalOptionAsAltMode(rawValue: optionAsAltModeRaw) ?? .none },
            set: { optionAsAltModeRaw = $0.rawValue }
        )
    }

    private var cursorPreviewThemeName: String {
        guard usePerAppearanceTheme else { return themeName }

        switch appearanceMode {
        case "light":
            return themeNameLight
        case "dark":
            return themeName
        default:
            return colorScheme == .dark ? themeName : themeNameLight
        }
    }

    private var cursorPreviewPalette: TerminalThemePreviewPalette {
        ThemeColorParser.previewPalette(for: cursorPreviewThemeName)
    }

    private var customThemeErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { customThemeErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    customThemeErrorMessage = nil
                }
            }
        )
    }

    @ViewBuilder
    private var themePickerRows: some View {
        if !builtInThemeOptions.isEmpty {
            Section("Built-in") {
                ForEach(builtInThemeOptions, id: \.self) { theme in
                    Text(theme).tag(theme)
                }
            }
        }

        if !customThemeOptions.isEmpty {
            Section("Custom") {
                ForEach(customThemeOptions, id: \.self) { theme in
                    Text(theme).tag(theme)
                }
            }
        }
    }

    private var fontSection: some View {
        Section("Font") {
            Picker("Font Family", selection: $fontName) {
                ForEach(availableFonts, id: \.self) { font in
                    Text(font).tag(font)
                }
            }
            .disabled(availableFonts.isEmpty)

            HStack {
                Text(String(format: String(localized: "Size: %lldpt"), Int64(fontSize)))
                    .frame(width: 80, alignment: .leading)
                Slider(value: Binding(
                    get: { fontSize },
                    set: { fontSize = $0.rounded() }
                ), in: 4...32, step: 1)
                Stepper("", value: $fontSize, in: 4...32, step: 1)
                    .labelsHidden()
            }
        }
    }

    private var cursorSection: some View {
        Section("Cursor") {
            VStack(spacing: 16) {
                HStack(spacing: 0) {
                    ForEach(TerminalCursorStyle.allCases) { style in
                        CursorStyleOptionView(
                            style: style,
                            isSelected: selectedCursorStyle == style,
                            blinks: cursorBlink,
                            palette: cursorPreviewPalette
                        )
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            cursorStyleRaw = style.rawValue
                        }
                        .accessibilityLabel(style.displayName)
                    }
                }

                Divider()

                HStack {
                    Text("Blink")
                    Spacer()
                    Toggle("Blink", isOn: $cursorBlink)
                        .labelsHidden()
                }
            }
        }
    }

    private var themeSection: some View {
        Section("Theme") {
            Toggle("Use different themes for Light/Dark mode", isOn: $usePerAppearanceTheme)

            if usePerAppearanceTheme {
                Picker("Dark Mode Theme", selection: $themeName) {
                    themePickerRows
                }
                .disabled(allThemeNames.isEmpty)

                Picker("Light Mode Theme", selection: $themeNameLight) {
                    themePickerRows
                }
                .disabled(allThemeNames.isEmpty)
            } else {
                Picker("Theme", selection: $themeName) {
                    themePickerRows
                }
                .disabled(allThemeNames.isEmpty)
            }

            HStack(spacing: 10) {
                Button("Manage custom themes") {
                    showingCustomThemeManager = true
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Text(customThemeCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Clipboard content or imported files must be Ghostty-compatible theme text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var terminalBehaviorSection: some View {
        Section("Terminal Behavior") {
            Toggle("Enable terminal notifications", isOn: $terminalNotificationsEnabled)
            Toggle("Show progress overlays", isOn: $terminalProgressEnabled)
        }
    }

    private var sessionPersistenceSection: some View {
        Section {
            Toggle("Enable tmux by default", isOn: $tmuxEnabledDefault)

            if tmuxEnabledDefault {
                Picker("On connect", selection: tmuxStartupBehaviorDefaultBinding) {
                    ForEach(TmuxStartupBehavior.configCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                Text(tmuxStartupBehaviorDefault.descriptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Session Persistence")
        } footer: {
            Text("Choose the default behavior for new servers. You can still override per server in server settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var copyProcessingSection: some View {
        Section {
            Toggle("Trim trailing whitespace", isOn: $copyTrimTrailingWhitespace)
            Toggle("Collapse multiple blank lines", isOn: $copyCollapseBlankLines)
            Toggle("Strip shell prompts ($ #)", isOn: $copyStripShellPrompts)
            Toggle("Flatten multi-line commands", isOn: $copyFlattenCommands)
            Toggle("Remove box-drawing characters", isOn: $copyRemoveBoxDrawing)
            Toggle("Strip ANSI escape codes", isOn: $copyStripAnsiCodes)
        } header: {
            Text("Copy Text Processing")
        } footer: {
            Text("Transformations applied when copying text from terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var richClipboardSection: some View {
        Section {
            Picker("Behavior", selection: imagePasteBehaviorBinding) {
                Text(ImagePasteBehavior.automatic.settingsTitle)
                    .tag(ImagePasteBehavior.automatic)
                Text(ImagePasteBehavior.askOnce.settingsTitle)
                    .tag(ImagePasteBehavior.askOnce)
                Text(ImagePasteBehavior.disabled.settingsTitle)
                    .tag(ImagePasteBehavior.disabled)
            }
            .pickerStyle(.menu)
        } header: {
            Text("Image Paste")
        } footer: {
            Text(imagePasteSectionFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var imagePasteSectionFooter: String {
        switch imagePasteBehavior {
        case .disabled:
            return String(localized: "Image paste is turned off.")
        case .askOnce:
            return String(localized: "You’ll be asked before the image is uploaded.")
        case .automatic:
            return String(localized: "Images upload right away without showing the confirmation sheet.")
        }
    }

    private var sshConnectionSection: some View {
        Section("SSH Connection") {
            Toggle("Auto-reconnect on disconnect", isOn: $autoReconnect)
            Toggle("Send keep-alive packets", isOn: $keepAliveEnabled)

            if keepAliveEnabled {
                Stepper("Interval: \(keepAliveInterval)s", value: $keepAliveInterval, in: 10...120, step: 10)
            }
        }
    }

    private var dangerZoneSection: some View {
        Section {
            Button(role: .destructive) {
                showingResetKnownHostsConfirmation = true
            } label: {
                Label("Reset Trusted SSH Hosts", systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .tint(.red)
            .disabled(knownHostCount == 0)
        } header: {
            Text("Danger Zone")
        } footer: {
            Text(knownHostsFooterText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var knownHostsFooterText: String {
        let count = Int64(knownHostCount)
        if count == 1 {
            return String(localized: "VVTerm has 1 trusted SSH host on this device. Resetting trusted hosts makes VVTerm trust the host key presented on the next connection.")
        }
        return String(format: String(localized: "VVTerm has %lld trusted SSH hosts on this device. Resetting trusted hosts makes VVTerm trust the host key presented on the next connection."), count)
    }

    var body: some View {
        Form {
            fontSection
            cursorSection
            themeSection
            terminalBehaviorSection
            keyboardAccessorySection
            sessionPersistenceSection
            copyProcessingSection
            richClipboardSection
            sshConnectionSection
            dangerZoneSection
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .sheet(isPresented: $showingCustomThemeManager) {
            ManageCustomThemesSheet(
                customThemes: customThemes,
                darkThemeName: $themeName,
                lightThemeName: $themeNameLight,
                usePerAppearanceTheme: usePerAppearanceTheme,
                onSuggestThemeName: { source in
                    terminalThemeManager.suggestThemeName(from: source)
                },
                onCreateTheme: { name, content, applyTarget in
                    try createAndApplyCustomTheme(name: name, content: content, applyTarget: applyTarget)
                },
                onDelete: { themeID in
                    terminalThemeManager.deleteCustomTheme(id: themeID)
                    ensureThemeSelectionIsValid()
                },
                onSaveEdit: { themeID, name, content in
                    try terminalThemeManager.updateCustomTheme(
                        id: themeID,
                        name: name,
                        content: content
                    )
                    ensureThemeSelectionIsValid()
                }
            )
            .adaptiveSoftScrollEdges()
        }
        .alert("Custom Theme", isPresented: customThemeErrorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(customThemeErrorMessage ?? "")
        }
        .alert("Reset Trusted SSH Hosts", isPresented: $showingResetKnownHostsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                KnownHostsManager.shared.removeAll()
                refreshKnownHostCount()
            }
        } message: {
            Text("VVTerm will forget all saved SSH host fingerprints on this device. The next connection to each host will trust the key it presents.")
        }
        .onChange(of: themeName) { _ in
            ensureThemeSelectionIsValid()
        }
        .onChange(of: themeNameLight) { _ in
            ensureThemeSelectionIsValid()
        }
        .onChange(of: usePerAppearanceTheme) { _ in
            ensureThemeSelectionIsValid()
        }
        .onChange(of: terminalThemeManager.customThemes) { _ in
            ensureThemeSelectionIsValid()
        }
        .onAppear {
            if availableFonts.isEmpty {
                availableFonts = Self.fontListEnsuringCurrentFont(
                    systemFonts: loadSystemFonts(),
                    currentFontName: fontName
                )
            }
            if builtInThemeNames.isEmpty {
                builtInThemeNames = TerminalThemeManager.builtInThemeNames()
            }
            ensureThemeSelectionIsValid()
            refreshKnownHostCount()
        }
    }

    /// Ensures the current primary font appears in the picker list.
    /// If the stored font name is missing from the system font list
    /// (e.g., a previously-installed font was removed), it is prepended
    /// so the Picker can display the current selection without breaking.
    static func fontListEnsuringCurrentFont(systemFonts: [String], currentFontName: String) -> [String] {
        let trimmed = currentFontName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return systemFonts }
        guard !systemFonts.contains(trimmed) else { return systemFonts }
        return [trimmed] + systemFonts
    }

    private func refreshKnownHostCount() {
        knownHostCount = KnownHostsManager.shared.entries().count
    }

    private func ensureThemeSelectionIsValid() {
        let available = Set(allThemeNames)
        if !available.contains(themeName) {
            themeName = "Aizen Dark"
        }
        if !available.contains(themeNameLight) {
            themeNameLight = "Aizen Light"
        }
    }

    private func createAndApplyCustomTheme(name: String, content: String, applyTarget: CustomThemeApplyTarget) throws {
        let theme = try terminalThemeManager.createCustomTheme(name: name, content: content)
        applyThemeSelection(themeName: theme.name, applyTarget: applyTarget)
        ensureThemeSelectionIsValid()
    }

    private func applyThemeSelection(themeName: String, applyTarget: CustomThemeApplyTarget) {
        guard usePerAppearanceTheme else {
            self.themeName = themeName
            return
        }

        switch applyTarget {
        case .dark:
            self.themeName = themeName
        case .light:
            self.themeNameLight = themeName
        case .both:
            self.themeName = themeName
            self.themeNameLight = themeName
        }
    }
}

struct CustomThemeSaveSheet: View {
    let suggestedName: String
    let usePerAppearanceTheme: Bool
    let onSave: (String, CustomThemeApplyTarget) throws -> Void

    @Environment(\.dismiss) var dismiss
    @State private var name: String
    @State private var applyTarget: CustomThemeApplyTarget = .dark
    @State private var errorMessage: String?

    init(
        suggestedName: String,
        usePerAppearanceTheme: Bool,
        onSave: @escaping (String, CustomThemeApplyTarget) throws -> Void
    ) {
        self.suggestedName = suggestedName
        self.usePerAppearanceTheme = usePerAppearanceTheme
        self.onSave = onSave
        _name = State(initialValue: suggestedName)
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        platformBody
    }

    var formContent: some View {
        Form {
            Section {
                #if os(iOS)
                HStack(spacing: 10) {
                    Text("Name")
                    Spacer(minLength: 8)
                    TextField("", text: $name, prompt: Text("Custom Theme"))
                        .multilineTextAlignment(.trailing)
                }
                #else
                TextField("Name", text: $name, prompt: Text("Custom Theme"))
                #endif
            } header: {
                sectionHeader("Theme Name")
            }

            if usePerAppearanceTheme {
                Section {
                    Picker("Target", selection: $applyTarget) {
                        ForEach(CustomThemeApplyTarget.allCases) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    sectionHeader("Apply To")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        #if os(iOS)
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
        #else
        Text(title)
        #endif
    }

    func save() {
        do {
            try onSave(
                name.trimmingCharacters(in: .whitespacesAndNewlines),
                usePerAppearanceTheme ? applyTarget : .dark
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ManageCustomThemesSheet: View {
    let customThemes: [TerminalTheme]
    @Binding var darkThemeName: String
    @Binding var lightThemeName: String
    let usePerAppearanceTheme: Bool
    let onSuggestThemeName: (String) -> String
    let onCreateTheme: (String, String, CustomThemeApplyTarget) throws -> Void
    let onDelete: (UUID) -> Void
    let onSaveEdit: (UUID, String, String) throws -> Void

    @Environment(\.dismiss) var dismiss
    @State private var showingThemeImporter = false
    @State private var showingThemeBuilder = false
    @State private var pendingCustomThemeSource: PendingCustomThemeSource?
    @State private var customThemeErrorMessage: String?
    @State var themePendingDeletion: TerminalTheme?
    @State var themePendingEdit: TerminalTheme?
    @State var hoveredThemeID: UUID?

    var sortedThemes: [TerminalTheme] {
        customThemes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var deleteThemeAlertBinding: Binding<Bool> {
        Binding(
            get: { themePendingDeletion != nil },
            set: { newValue in
                if !newValue {
                    themePendingDeletion = nil
                }
            }
        )
    }

    private var editThemeSheetBinding: Binding<TerminalTheme?> {
        Binding(
            get: { themePendingEdit },
            set: { themePendingEdit = $0 }
        )
    }

    private var customThemeErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { customThemeErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    customThemeErrorMessage = nil
                }
            }
        )
    }

    var body: some View {
        platformBody
        .sheet(item: editThemeSheetBinding) { theme in
            ThemeBuilderSheet(
                usePerAppearanceTheme: false,
                showApplyTarget: false,
                title: String(
                    format: String(localized: "Edit \"%@\""),
                    theme.name
                ),
                initialName: theme.name,
                initialContent: theme.content,
                onDeleteRequest: {
                    onDelete(theme.id)
                    themePendingEdit = nil
                }
            ) { name, content, _ in
                try onSaveEdit(theme.id, name, content)
            }
            .adaptiveSoftScrollEdges()
            #if os(macOS)
            .frame(minWidth: 700, minHeight: 600)
            #endif
        }
        .fileImporter(
            isPresented: $showingThemeImporter,
            allowedContentTypes: [.text, .data],
            allowsMultipleSelection: false
        ) { result in
            handleThemeImport(result)
        }
        .sheet(item: $pendingCustomThemeSource) { source in
            CustomThemeSaveSheet(
                suggestedName: source.suggestedName,
                usePerAppearanceTheme: usePerAppearanceTheme
            ) { name, applyTarget in
                try onCreateTheme(name, source.content, applyTarget)
            }
            .adaptiveSoftScrollEdges()
        }
        .sheet(isPresented: $showingThemeBuilder) {
            ThemeBuilderSheet(usePerAppearanceTheme: usePerAppearanceTheme) { name, content, applyTarget in
                try onCreateTheme(name, content, applyTarget)
            }
            .adaptiveSoftScrollEdges()
            #if os(macOS)
            .frame(minWidth: 700, minHeight: 600)
            #endif
        }
        .alert("Delete Custom Theme?", isPresented: deleteThemeAlertBinding) {
            Button("Delete", role: .destructive) {
                if let themePendingDeletion {
                    onDelete(themePendingDeletion.id)
                }
                themePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                themePendingDeletion = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Custom Theme", isPresented: customThemeErrorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(customThemeErrorMessage ?? "")
        }
        .adaptiveSoftScrollEdges()
    }

    var customThemesEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "paintpalette")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)

            Text("No Custom Themes")
                .font(.headline.weight(.semibold))

            Text("Create your first custom theme from clipboard, file import, or builder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func assignmentLabel(for theme: String) -> String? {
        if usePerAppearanceTheme {
            let usesDark = darkThemeName == theme
            let usesLight = lightThemeName == theme

            switch (usesDark, usesLight) {
            case (true, true):
                return String(localized: "Dark + Light")
            case (true, false):
                return String(localized: "Dark")
            case (false, true):
                return String(localized: "Light")
            case (false, false):
                return nil
            }
        }

        return darkThemeName == theme ? String(localized: "Active") : nil
    }

    @ViewBuilder
    func applyMenuItems(themeName: String) -> some View {
        if usePerAppearanceTheme {
            Button("Apply to Dark") {
                applyThemeSelection(themeName: themeName, applyTarget: .dark)
            }
            Button("Apply to Light") {
                applyThemeSelection(themeName: themeName, applyTarget: .light)
            }
            Button("Apply to Both") {
                applyThemeSelection(themeName: themeName, applyTarget: .both)
            }
        } else {
            Button("Use Theme") {
                applyThemeSelection(themeName: themeName, applyTarget: .dark)
            }
        }
    }

    @ViewBuilder
    var createThemeMenuItems: some View {
        Button("Paste from Clipboard") {
            importThemeFromClipboard()
        }
        Button("Import from File") {
            showingThemeImporter = true
        }
        Button("Builder") {
            showingThemeBuilder = true
        }
    }

    private func importThemeFromClipboard() {
        guard let text = Clipboard.readString() else {
            customThemeErrorMessage = String(localized: "Clipboard does not contain text.")
            return
        }

        preparePendingCustomTheme(content: text, suggestedName: String(localized: "Pasted Theme"))
    }

    private func handleThemeImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                customThemeErrorMessage = String(localized: "Cannot access selected file.")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let suggestedName = url.deletingPathExtension().lastPathComponent
                preparePendingCustomTheme(content: content, suggestedName: suggestedName)
            } catch {
                customThemeErrorMessage = String(
                    format: String(localized: "Failed to import theme file: %@"),
                    error.localizedDescription
                )
            }
        case .failure(let error):
            customThemeErrorMessage = String(
                format: String(localized: "Failed to import theme file: %@"),
                error.localizedDescription
            )
        }
    }

    private func preparePendingCustomTheme(content: String, suggestedName: String) {
        do {
            let normalizedContent = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
            pendingCustomThemeSource = PendingCustomThemeSource(
                suggestedName: onSuggestThemeName(suggestedName),
                content: normalizedContent
            )
        } catch {
            customThemeErrorMessage = error.localizedDescription
        }
    }

    func applyThemeSelection(themeName: String, applyTarget: CustomThemeApplyTarget) {
        guard usePerAppearanceTheme else {
            darkThemeName = themeName
            return
        }

        switch applyTarget {
        case .dark:
            darkThemeName = themeName
        case .light:
            lightThemeName = themeName
        case .both:
            darkThemeName = themeName
            lightThemeName = themeName
        }
    }
}

struct ThemeBuilderSheet: View {
    let usePerAppearanceTheme: Bool
    let showApplyTarget: Bool
    let title: String
    let preservedExtraLines: [String]
    let onDeleteRequest: (() -> Void)?
    let onSave: (String, String, CustomThemeApplyTarget) throws -> Void

    @Environment(\.dismiss) var dismiss

    @State private var name: String
    @State private var background: String
    @State private var foreground: String
    @State private var cursorColor: String
    @State private var cursorText: String
    @State private var selectionBackground: String
    @State private var selectionForeground: String
    @State private var paletteColors: [String]
    @State private var applyTarget: CustomThemeApplyTarget
    @State private var errorMessage: String?
    @State var showingDeleteConfirmation = false

    private struct ParsedThemeValues {
        var background = "#101418"
        var foreground = "#D8E0EA"
        var cursorColor = "#F8B26A"
        var cursorText = "#101418"
        var selectionBackground = "#2E3A46"
        var selectionForeground = "#D8E0EA"
        var paletteColors = Array(repeating: "", count: 16)
        var extraLines: [String] = []
    }

    init(
        usePerAppearanceTheme: Bool,
        showApplyTarget: Bool? = nil,
        title: String = "Theme Builder",
        initialName: String = "Custom Theme",
        initialContent: String? = nil,
        initialApplyTarget: CustomThemeApplyTarget = .dark,
        onDeleteRequest: (() -> Void)? = nil,
        onSave: @escaping (String, String, CustomThemeApplyTarget) throws -> Void
    ) {
        self.usePerAppearanceTheme = usePerAppearanceTheme
        self.showApplyTarget = showApplyTarget ?? usePerAppearanceTheme
        self.title = title
        self.onDeleteRequest = onDeleteRequest
        self.onSave = onSave

        let parsed = Self.parseThemeValues(from: initialContent)
        self.preservedExtraLines = parsed.extraLines

        _name = State(initialValue: initialName)
        _background = State(initialValue: parsed.background)
        _foreground = State(initialValue: parsed.foreground)
        _cursorColor = State(initialValue: parsed.cursorColor)
        _cursorText = State(initialValue: parsed.cursorText)
        _selectionBackground = State(initialValue: parsed.selectionBackground)
        _selectionForeground = State(initialValue: parsed.selectionForeground)
        _paletteColors = State(initialValue: parsed.paletteColors)
        _applyTarget = State(initialValue: initialApplyTarget)
    }

    var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard TerminalThemeValidator.isValidHexColor(background) else { return false }
        guard TerminalThemeValidator.isValidHexColor(foreground) else { return false }
        guard cursorColor.isEmpty || TerminalThemeValidator.isValidHexColor(cursorColor) else { return false }
        guard cursorText.isEmpty || TerminalThemeValidator.isValidHexColor(cursorText) else { return false }
        guard selectionBackground.isEmpty || TerminalThemeValidator.isValidHexColor(selectionBackground) else { return false }
        guard selectionForeground.isEmpty || TerminalThemeValidator.isValidHexColor(selectionForeground) else { return false }
        guard paletteColors.allSatisfy({ $0.isEmpty || TerminalThemeValidator.isValidHexColor($0) }) else { return false }
        return true
    }

    private var previewBackground: Color {
        previewColor(for: background, fallback: Color.fromHex("#101418"))
    }

    private var previewForeground: Color {
        previewColor(for: foreground, fallback: Color.fromHex("#D8E0EA"))
    }

    private var previewCursorColor: Color {
        previewColor(for: cursorColor, fallback: Color.fromHex("#F8B26A"))
    }

    private var previewCursorText: Color {
        previewColor(for: cursorText, fallback: previewBackground)
    }

    private var previewSelectionBackground: Color {
        previewColor(for: selectionBackground, fallback: Color.fromHex("#2E3A46"))
    }

    private var previewSelectionForeground: Color {
        previewColor(for: selectionForeground, fallback: previewForeground)
    }

    var body: some View {
        platformBody
        .alert("Delete Custom Theme?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                onDeleteRequest?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .adaptiveSoftScrollEdges()
    }

    var formContent: some View {
        Form {
                Section {
                    #if os(iOS)
                    HStack(spacing: 10) {
                        Text("Name")
                        Spacer(minLength: 8)
                        TextField("", text: $name, prompt: Text("Custom Theme"))
                            .multilineTextAlignment(.trailing)
                    }
                    #else
                    TextField("Name", text: $name, prompt: Text("Custom Theme"))
                    #endif
                } header: {
                    sectionHeader("Theme")
                }

                Section {
                    colorField(String(localized: "Background"), text: $background, placeholder: "#101418", fallback: Color.fromHex("#101418"))
                    colorField(String(localized: "Foreground"), text: $foreground, placeholder: "#D8E0EA", fallback: Color.fromHex("#D8E0EA"))
                } header: {
                    sectionHeader("Required Colors")
                }

                Section {
                    colorField(String(localized: "Cursor"), text: $cursorColor, placeholder: "#F8B26A", fallback: Color.fromHex("#F8B26A"))
                    colorField(String(localized: "Cursor Text"), text: $cursorText, placeholder: "#101418", fallback: previewBackground)
                    colorField(String(localized: "Selection Background"), text: $selectionBackground, placeholder: "#2E3A46", fallback: Color.fromHex("#2E3A46"))
                    colorField(String(localized: "Selection Foreground"), text: $selectionForeground, placeholder: "#D8E0EA", fallback: Color.fromHex("#D8E0EA"))
                } header: {
                    sectionHeader("Optional Colors")
                } footer: {
                    Text("Leave optional values empty to keep defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(0..<16, id: \.self) { index in
                        colorField(
                            String(
                                format: String(localized: "Palette %lld"),
                                Int64(index)
                            ),
                            text: paletteColorBinding(index),
                            placeholder: paletteFallbackHex(index),
                            fallback: Color.fromHex(paletteFallbackHex(index))
                        )
                    }
                } header: {
                    sectionHeader("Palette (0-15)")
                } footer: {
                    Text("Optional ANSI palette entries. Leave empty to use Ghostty defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    terminalPreview
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 126)
                } header: {
                    sectionHeader("Preview")
                }

                if showApplyTarget {
                    Section {
                        Picker("Target", selection: $applyTarget) {
                            ForEach(CustomThemeApplyTarget.allCases) { target in
                                Text(target.title).tag(target)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        sectionHeader("Apply To")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
        .formStyle(.grouped)
    }

    private var terminalPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("restty@prod-web-01:~$ printenv APP_ENV")

            HStack(spacing: 6) {
                Text("APP_ENV=")
                    .foregroundStyle(previewForeground.opacity(0.78))
                Text("production")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(previewSelectionBackground)
                    .foregroundStyle(previewSelectionForeground)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            HStack(spacing: 6) {
                Text("cursor>")
                    .foregroundStyle(previewForeground.opacity(0.78))
                Text("A")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(previewCursorColor)
                    .foregroundStyle(previewCursorText)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text("selection")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(previewSelectionBackground)
                    .foregroundStyle(previewSelectionForeground)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Rectangle()
                .fill(previewForeground.opacity(0.16))
                .frame(height: 1)

            Text("ANSI Palette")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(previewForeground.opacity(0.82))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 26), spacing: 6), count: 8), spacing: 6) {
                ForEach(0..<16, id: \.self) { index in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(palettePreviewColor(index))
                            .frame(height: 18)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(previewForeground.opacity(0.18), lineWidth: 1)
                            )
                        Text("\(index)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(previewForeground.opacity(0.8))
                    }
                }
            }
        }
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .foregroundStyle(previewForeground)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(previewBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(previewForeground.opacity(0.15), lineWidth: 1)
        )
    }

    private func colorField(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        fallback: Color
    ) -> some View {
        #if os(iOS)
        HStack(spacing: 10) {
            Text(label)
                .lineLimit(1)

            Spacer(minLength: 8)

            TextField("", text: text, prompt: Text(placeholder))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 110, maxWidth: 170, alignment: .trailing)

            ThemeBuilderColorSwatchPicker(
                label: label,
                text: text,
                fallback: fallback
            )
        }
        #else
        HStack(spacing: 10) {
            ThemeBuilderColorSwatchPicker(
                label: label,
                text: text,
                fallback: fallback
            )

            TextField(label, text: text, prompt: Text(placeholder))
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                #endif
                .font(.system(.body, design: .monospaced))
        }
        #endif
    }

    private func paletteColorBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { paletteColors[index] },
            set: { paletteColors[index] = $0 }
        )
    }

    private func paletteFallbackHex(_ index: Int) -> String {
        let defaults = [
            "#1D1F21", "#CC6666", "#B5BD68", "#F0C674",
            "#81A2BE", "#B294BB", "#8ABEB7", "#C5C8C6",
            "#666666", "#D54E53", "#B9CA4A", "#E7C547",
            "#7AA6DA", "#C397D8", "#70C0B1", "#EAEAEA"
        ]
        guard defaults.indices.contains(index) else { return "#808080" }
        return defaults[index]
    }

    private func palettePreviewColor(_ index: Int) -> Color {
        guard paletteColors.indices.contains(index) else {
            return Color.fromHex(paletteFallbackHex(index))
        }
        return previewColor(
            for: paletteColors[index],
            fallback: Color.fromHex(paletteFallbackHex(index))
        )
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        #if os(iOS)
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
        #else
        Text(title)
        #endif
    }

    private static func parseThemeValues(from content: String?) -> ParsedThemeValues {
        guard let content, !content.isEmpty else {
            return ParsedThemeValues()
        }

        var parsed = ParsedThemeValues()
        for rawLine in content.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                parsed.extraLines.append(trimmed)
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            if key == "palette" {
                let paletteParts = value.split(separator: "=", maxSplits: 1)
                guard
                    paletteParts.count == 2,
                    let paletteIndex = Int(paletteParts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                    (0..<16).contains(paletteIndex),
                    let paletteColor = TerminalThemeValidator.normalizeHexColor(String(paletteParts[1]))
                else {
                    parsed.extraLines.append(trimmed)
                    continue
                }
                parsed.paletteColors[paletteIndex] = paletteColor
                continue
            }

            let normalized = TerminalThemeValidator.normalizeHexColor(value) ?? value

            switch key {
            case "background":
                parsed.background = normalized
            case "foreground":
                parsed.foreground = normalized
            case "cursor-color":
                parsed.cursorColor = normalized
            case "cursor-text":
                parsed.cursorText = normalized
            case "selection-background":
                parsed.selectionBackground = normalized
            case "selection-foreground":
                parsed.selectionForeground = normalized
            default:
                parsed.extraLines.append("\(key) = \(value)")
            }
        }

        return parsed
    }

    func save() {
        do {
            var lines: [String] = []
            lines.append("background = \(TerminalThemeValidator.normalizeHexColor(background) ?? background)")
            lines.append("foreground = \(TerminalThemeValidator.normalizeHexColor(foreground) ?? foreground)")

            if let value = TerminalThemeValidator.normalizeHexColor(cursorColor) {
                lines.append("cursor-color = \(value)")
            }
            if let value = TerminalThemeValidator.normalizeHexColor(cursorText) {
                lines.append("cursor-text = \(value)")
            }
            if let value = TerminalThemeValidator.normalizeHexColor(selectionBackground) {
                lines.append("selection-background = \(value)")
            }
            if let value = TerminalThemeValidator.normalizeHexColor(selectionForeground) {
                lines.append("selection-foreground = \(value)")
            }
            for index in 0..<paletteColors.count {
                if let value = TerminalThemeValidator.normalizeHexColor(paletteColors[index]) {
                    lines.append("palette = \(index)=\(value)")
                }
            }

            lines.append(contentsOf: preservedExtraLines)

            let content = lines.joined(separator: "\n") + "\n"
            let normalized = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
            try onSave(
                name.trimmingCharacters(in: .whitespacesAndNewlines),
                normalized,
                showApplyTarget ? applyTarget : .dark
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func previewColor(for value: String, fallback: Color) -> Color {
        guard TerminalThemeValidator.isValidHexColor(value) else { return fallback }
        return Color.fromHex(value)
    }
}

private struct ThemeBuilderColorSwatchPicker: View {
    let label: String
    @Binding var text: String
    let fallback: Color

    private var swatchColor: Color {
        guard TerminalThemeValidator.isValidHexColor(text) else { return fallback }
        return Color.fromHex(text)
    }

    var body: some View {
        let pickColorLabel = String(
            format: String(localized: "Pick %@ color"),
            label
        )

        ColorPicker(
            pickColorLabel,
            selection: Binding(
                get: { swatchColor },
                set: { selectedColor in
                    text = selectedColor.toHex()
                }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .accessibilityLabel(pickColorLabel)
    }
}
