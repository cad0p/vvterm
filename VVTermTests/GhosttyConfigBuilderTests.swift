import Foundation
import Testing
@testable import VVTerm

struct GhosttyConfigBuilderTests {
    #if os(macOS)
    @Test
    func macOSConfigContentMapsOptionAsAltModesToGhosttyValues() {
        let expectedValues: [(TerminalOptionAsAltMode, String)] = [
            (.none, "false"),
            (.left, "left"),
            (.right, "right"),
            (.both, "true")
        ]

        for (mode, expectedValue) in expectedValues {
            let content = Ghostty.ConfigBuilder.configContent(
                primaryFontFamily: "Menlo",
                fontSize: 13,
                shellName: "fish",
                theme: "/tmp/vvterm-themes/Aizen Light",
                optionAsAltMode: mode
            )

            #expect(content.contains("macos-option-as-alt = \(expectedValue)"))
        }
    }

    @Test
    func macOSFontFamilyLinesUseDeterministicFallbackStack() {
        let lines = Ghostty.ConfigBuilder.fontFamilyLines(primaryFamily: "Menlo")
            .split(separator: "\n")
            .map(String.init)

        #expect(lines == [
            "font-family = \"Menlo\"",
            "font-family = \"Apple SD Gothic Neo\"",
            "font-family = \"JetBrainsMono Nerd Font\""
        ])
    }

    @Test
    func macOSFontFamilyLinesTrimWhitespaceAndDeduplicateFamilies() {
        let appleFallback = TerminalDefaults.macOSFallbackFontFamilies[0]
        let lines = Ghostty.ConfigBuilder.fontFamilyLines(primaryFamily: "  \(appleFallback)  ")
            .split(separator: "\n")
            .map(String.init)

        #expect(lines == [
            "font-family = \"Apple SD Gothic Neo\"",
            "font-family = \"JetBrainsMono Nerd Font\""
        ])
    }
    #endif

    @Test
    func fontFamilyLinesIgnoreBlankPrimaryFamily() {
        let lines = Ghostty.ConfigBuilder.fontFamilyLines(primaryFamily: "   \n  ")
            .split(separator: "\n")
            .map(String.init)

        #if os(macOS)
        #expect(lines == [
            "font-family = \"Apple SD Gothic Neo\"",
            "font-family = \"JetBrainsMono Nerd Font\""
        ])
        #else
        #expect(lines.isEmpty)
        #endif
    }

    /// Ghostty's line parser strips the surrounding quotes and never decodes
    /// escapes, so a quote or backslash inside a family name must be emitted
    /// verbatim — escaping it would make the loader look for a font whose name
    /// literally contains the backslash. Newlines are still removed because
    /// they would break the line structure.
    @Test
    func fontFamilyLinesEmitValuesVerbatimAndStripLineBreaks() {
        let lines = Ghostty.ConfigBuilder.fontFamilyLines(primaryFamily: "A\"B\\C\nD\rE")
            .split(separator: "\n")
            .map(String.init)

        #expect(lines.first == "font-family = \"A\"B\\CDE\"")
    }

    #if os(iOS)
    @Test
    func iOSConfigContentPreservesSingleFamilyBehavior() {
        let content = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: "  JetBrainsMono Nerd Font  ",
            fontSize: 9,
            shellName: "zsh",
            theme: "/tmp/vvterm-themes/Aizen Dark"
        )

        let fontFamilyLines = content
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("font-family =") }

        #expect(fontFamilyLines == ["font-family = \"JetBrainsMono Nerd Font\""])
        #expect(!content.contains("macos-option-as-alt"))
    }
    #endif

    @Test
    func configContentKeepsNonFontLinesStable() {
        let themesDirectory = "/tmp/vvterm-themes"
        let content = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: "Menlo",
            fontSize: 13,
            shellName: "fish",
            theme: "\(themesDirectory)/Aizen Light"
        )

        #expect(content.contains("font-size = 13"))
        #expect(content.contains("window-inherit-font-size = false"))
        #expect(content.contains("shell-integration = fish"))
        #expect(content.contains("theme = \"\(themesDirectory)/Aizen Light\""))
        #expect(!content.contains("theme = Aizen Light"))
        #expect(content.contains("cursor-style = block"))
        #expect(content.contains("cursor-style-blink = true"))
        // `scrollback-limit` is a deprecated alias for `scrollback-limit-bytes`
        // (bytes, not lines), so the generated config must use the line-based key.
        #expect(content.contains("scrollback-limit-lines = 10000"))
        #expect(!content.contains("scrollback-limit = 10000"))
        // `audible-bell` was removed upstream; emitting it as a directive is an
        // "unknown field" diagnostic. The audible bell is off by the
        // `bell-features` default, so the key must not come back. (The comment
        // above the scrollback block names the key, so only non-comment lines
        // are checked.)
        let directives = content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }
        #expect(!directives.contains { $0.hasPrefix("audible-bell") })
        #expect(content.contains("keybind = shift+enter=text:\\n"))
    }

    /// Regression coverage for issue #225: libghostty is handed the theme as an
    /// absolute path so the config loader never has to resolve it through
    /// `XDG_CONFIG_HOME`/`getenv` (whose environment snapshot is invalidated by
    /// environment mutation after `ghostty_init`).
    @Test
    func themeIsEmittedAsQuotedAbsolutePath() {
        let themesDirectory = "/var/folders/xy/T/.config/ghostty/themes"
        let content = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: "Menlo",
            fontSize: 13,
            shellName: "zsh",
            theme: "\(themesDirectory)/Aizen Dark"
        )

        // Quoting matters: bundled theme names contain spaces (e.g. "Aizen Dark").
        #expect(content.contains("theme = \"\(themesDirectory)/Aizen Dark\""))
        #expect(!content.contains("theme = Aizen Dark"))
    }

    /// Ghostty's line parser strips the surrounding quotes and never decodes
    /// escapes, so a backslash or quote inside the value must be emitted
    /// verbatim — escaping it would make the loader look for a file whose name
    /// literally contains the backslash. Newlines are still removed because
    /// they would break the line structure.
    @Test
    func themeValueIsEmittedVerbatimAndNewlinesAreStripped() {
        let content = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: "Menlo",
            fontSize: 13,
            shellName: "zsh",
            theme: "/tmp/vvterm-themes/A\\B\"C\nD"
        )

        #expect(content.contains("theme = \"/tmp/vvterm-themes/A\\B\"CD\""))
        #expect(!content.contains("theme = \"/tmp/vvterm-themes/A\\\\B"))
    }

    /// The theme falls back to the bare name when the copy in the themes
    /// directory is missing, so ghostty can still resolve it through its
    /// resources-directory search instead of failing on a dangling absolute path.
    @Test
    func themeConfigValuePrefersTheAbsolutePathAndFallsBackToTheBareName() {
        let directory = "/var/folders/xy/T/.config/ghostty/themes"

        let present = Ghostty.ConfigBuilder.themeConfigValue(
            themeName: "Aizen Dark",
            themesDirectory: directory,
            isFile: { _ in true }
        )
        #expect(present == "\(directory)/Aizen Dark")

        let missing = Ghostty.ConfigBuilder.themeConfigValue(
            themeName: "Aizen Dark",
            themesDirectory: directory,
            isFile: { _ in false }
        )
        #expect(missing == "Aizen Dark")
    }

    /// `FileManager.fileExists` is true for directories too, so the call site
    /// must use a regular-file check: otherwise a theme name that resolves to
    /// the themes directory itself would be emitted as the theme value.
    @Test
    func isRegularFileRejectsDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-theme-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("Aizen Dark")
        try "theme".write(to: file, atomically: true, encoding: .utf8)

        #expect(Ghostty.ConfigBuilder.isRegularFile(file.path))
        #expect(!Ghostty.ConfigBuilder.isRegularFile(directory.path))
        #expect(!Ghostty.ConfigBuilder.isRegularFile(directory.appendingPathComponent("missing").path))
    }

    /// An empty theme name resolves to the themes directory, so it must not be
    /// emitted as a `theme` directive at all.
    @Test
    func emptyThemeNameEmitsNoThemeDirective() {
        let resolved = Ghostty.ConfigBuilder.themeConfigValue(
            themeName: "",
            themesDirectory: "/var/folders/xy/T/.config/ghostty/themes",
            isFile: { _ in true }
        )
        #expect(resolved.isEmpty)

        let content = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: "Menlo",
            fontSize: 13,
            shellName: "zsh",
            theme: resolved
        )
        #expect(!content.contains("theme = "))
    }

    /// Documents the parser boundary rather than pretending it is handled:
    /// ghostty routes a theme value containing `,`, `:` or `=` through its
    /// light/dark pair parser, so such a name is mis-parsed today for bare names
    /// and absolute paths alike. The emitted line stays well-formed either way.
    @Test
    func themeValueWithPairSeparatorsIsStillEmittedAsOneQuotedValue() {
        let content = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: "Menlo",
            fontSize: 13,
            shellName: "zsh",
            theme: "/tmp/vvterm-themes/Dark,Light"
        )

        #expect(content.contains("theme = \"/tmp/vvterm-themes/Dark,Light\""))
    }

    @Test
    func configContentIncludesCursorSettings() {
        let content = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: "Menlo",
            fontSize: 13,
            shellName: "fish",
            theme: "/tmp/vvterm-themes/Aizen Light",
            cursorStyle: .bar,
            cursorBlink: false
        )

        #expect(content.contains("cursor-style = bar"))
        #expect(content.contains("cursor-style-blink = false"))
    }
}
