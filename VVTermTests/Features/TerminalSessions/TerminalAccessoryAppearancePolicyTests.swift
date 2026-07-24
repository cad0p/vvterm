import CoreGraphics
import Testing
@testable import VVTerm

struct TerminalAccessoryAppearancePolicyTests {
    @Test
    func classifiesThemeBackgroundLuminance() {
        #expect(TerminalAccessoryAppearancePolicy.isDarkBackground(
            red: 0.04,
            green: 0.05,
            blue: 0.06
        ))
        #expect(!TerminalAccessoryAppearancePolicy.isDarkBackground(
            red: 0.95,
            green: 0.96,
            blue: 0.97
        ))
    }
}
