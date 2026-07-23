import Testing
@testable import VVTerm

struct ThemeColorParserTests {
    @Test
    func darkSplitDividerUsesGhosttyDarkBackgroundFactor() throws {
        let components = try #require(
            ThemeColorParser.splitDividerComponents(for: "#204060")
        )

        #expect(abs(components.red - (32.0 / 255.0 * 0.6)) < 0.000_001)
        #expect(abs(components.green - (64.0 / 255.0 * 0.6)) < 0.000_001)
        #expect(abs(components.blue - (96.0 / 255.0 * 0.6)) < 0.000_001)
        #expect(components.alpha == 1)
    }

    @Test
    func lightSplitDividerUsesGhosttyLightBackgroundFactor() throws {
        let components = try #require(
            ThemeColorParser.splitDividerComponents(for: "#80C0FF")
        )

        #expect(abs(components.red - (128.0 / 255.0 * 0.92)) < 0.000_001)
        #expect(abs(components.green - (192.0 / 255.0 * 0.92)) < 0.000_001)
        #expect(abs(components.blue - 0.92) < 0.000_001)
        #expect(components.alpha == 1)
    }

    @Test
    func splitDividerSupportsShortAndAlphaHexColors() throws {
        let short = try #require(ThemeColorParser.splitDividerComponents(for: "#abc"))
        let alpha = try #require(ThemeColorParser.splitDividerComponents(for: "80ABCDEF"))

        #expect(abs(short.red - (170.0 / 255.0 * 0.92)) < 0.000_001)
        #expect(abs(short.green - (187.0 / 255.0 * 0.92)) < 0.000_001)
        #expect(abs(short.blue - (204.0 / 255.0 * 0.92)) < 0.000_001)
        #expect(abs(alpha.alpha - (128.0 / 255.0)) < 0.000_001)
    }

    @Test
    func splitDividerRejectsInvalidHex() {
        #expect(ThemeColorParser.splitDividerComponents(for: "not-a-color") == nil)
        #expect(ThemeColorParser.splitDividerComponents(for: "#12") == nil)
    }
}
