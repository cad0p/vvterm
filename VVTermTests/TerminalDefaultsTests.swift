import Foundation
import Testing
@testable import VVTerm

struct TerminalDefaultsTests {
    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "TerminalDefaultsTests.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test
    func macOSDefaultsExposeMenloAndTwelvePointSize() throws {
        #if os(macOS)
        #expect(TerminalDefaults.defaultFontName == "Menlo")
        #expect(TerminalDefaults.defaultPrimaryFontName == "Menlo")
        #expect(TerminalDefaults.defaultFontSize == 12.0)
        #expect(TerminalDefaults.legacyDefaultFontName == "JetBrainsMono Nerd Font")
        #expect(
            TerminalDefaults.macOSFallbackFontFamilies == ["Apple SD Gothic Neo", "JetBrainsMono Nerd Font"]
        )
        #else
        return
        #endif
    }

    @Test
    func applyIfNeededSeedsUnsetFontDefaults() {
        let defaults = makeDefaults()

        TerminalDefaults.applyIfNeeded(defaults: defaults)

        #if os(macOS)
        #expect(defaults.string(forKey: TerminalDefaults.fontNameKey) == "Menlo")
        #expect(defaults.object(forKey: TerminalDefaults.fontSizeKey) as? Double == 12.0)
        #else
        #expect(defaults.string(forKey: TerminalDefaults.fontNameKey) == TerminalDefaults.defaultFontName)
        #expect(defaults.object(forKey: TerminalDefaults.fontSizeKey) as? Double == TerminalDefaults.defaultFontSize)
        #endif
        #expect(defaults.object(forKey: ImagePasteBehavior.userDefaultsKey) as? String == ImagePasteBehavior.askOnce.rawValue)
    }

    @Test
    func optionAsAltModeDefaultsToNeitherAndResolvesStoredSides() {
        let defaults = makeDefaults()

        #expect(TerminalDefaults.optionAsAltMode(defaults: defaults) == .none)
        defaults.set(TerminalOptionAsAltMode.left.rawValue, forKey: TerminalDefaults.optionAsAltModeKey)
        #expect(TerminalDefaults.optionAsAltMode(defaults: defaults) == .left)
        #expect(TerminalOptionAsAltMode.left.usesOptionKeyAsAlt(.left))
        #expect(!TerminalOptionAsAltMode.left.usesOptionKeyAsAlt(.right))
        #expect(TerminalOptionAsAltMode.both.usesOptionKeyAsAlt(.left))
        #expect(TerminalOptionAsAltMode.both.usesOptionKeyAsAlt(.right))
    }

    @Test
    func applyIfNeededNormalizesBlankFontNameWithoutOverwritingExistingFontSize() {
        let defaults = makeDefaults()

        defaults.set("   \n", forKey: TerminalDefaults.fontNameKey)
        defaults.set(14.0, forKey: TerminalDefaults.fontSizeKey)

        TerminalDefaults.applyIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: TerminalDefaults.fontNameKey) == TerminalDefaults.defaultFontName)
        #expect(defaults.object(forKey: TerminalDefaults.fontSizeKey) as? Double == 14.0)
    }

    @Test
    func applyIfNeededPreservesCustomMacOSFontValues() throws {
        #if os(macOS)
        let defaults = makeDefaults()

        defaults.set("Menlo", forKey: TerminalDefaults.fontNameKey)
        defaults.set(15.0, forKey: TerminalDefaults.fontSizeKey)

        TerminalDefaults.applyIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: TerminalDefaults.fontNameKey) == "Menlo")
        #expect(defaults.object(forKey: TerminalDefaults.fontSizeKey) as? Double == 15.0)
        #else
        return
        #endif
    }

    @Test
    func applyIfNeededPreservesExactLegacyMacOSFontValues() throws {
        #if os(macOS)
        let normalizedFontName = TerminalDefaults.normalizedMacOSFontName(
            storedFontName: TerminalDefaults.legacyDefaultFontName,
            fontAvailability: { _ in true }
        )

        #expect(normalizedFontName == TerminalDefaults.legacyDefaultFontName)
        #else
        return
        #endif
    }

    @Test
    func applyIfNeededNormalizesExactLegacyMacOSFontValuesWhenFontIsUnavailable() throws {
        #if os(macOS)
        let normalizedFontName = TerminalDefaults.normalizedMacOSFontName(
            storedFontName: TerminalDefaults.legacyDefaultFontName,
            fontAvailability: { _ in false }
        )

        #expect(normalizedFontName == TerminalDefaults.defaultPrimaryFontName)
        #else
        return
        #endif
    }

    @Test
    func applyIfNeededPreservesInstalledMacOSFontsDuringNormalization() throws {
        #if os(macOS)
        let normalizedFontName = TerminalDefaults.normalizedMacOSFontName(
            storedFontName: "Installed But Misclassified Font",
            fontAvailability: { _ in true }
        )

        #expect(normalizedFontName == "Installed But Misclassified Font")
        #else
        return
        #endif
    }

    @Test
    func applyIfNeededNormalizesInvalidStoredMacOSFontName() throws {
        #if os(macOS)
        let defaults = makeDefaults()

        defaults.set("DefinitelyNotARealFixedPitchFont", forKey: TerminalDefaults.fontNameKey)
        defaults.set(16.0, forKey: TerminalDefaults.fontSizeKey)

        TerminalDefaults.applyIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: TerminalDefaults.fontNameKey) == TerminalDefaults.defaultPrimaryFontName)
        #expect(defaults.object(forKey: TerminalDefaults.fontSizeKey) as? Double == 16.0)
        #else
        return
        #endif
    }
}
