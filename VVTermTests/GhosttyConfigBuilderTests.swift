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

    @Test
    func fontFamilyLinesEscapeQuotesBackslashesAndNewlines() {
        let lines = Ghostty.ConfigBuilder.fontFamilyLines(primaryFamily: "A\"B\\C\nD\rE")
            .split(separator: "\n")
            .map(String.init)

        #expect(lines.first == "font-family = \"A\\\"B\\\\CDE\"")
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
