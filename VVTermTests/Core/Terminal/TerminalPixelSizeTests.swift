import CoreGraphics
import Testing
@testable import VVTerm

struct TerminalPixelSizeTests {
    @Test
    func acceptsPositiveFiniteWireDimensions() throws {
        let size = try #require(TerminalPixelSize(width: 2_796.9, height: 1_290.2))

        #expect(size == TerminalPixelSize(size: CGSize(width: 2_796, height: 1_290)))
        #expect(size.width == 2_796)
        #expect(size.height == 1_290)
    }

    @Test
    func rejectsZeroNonFiniteAndOverflowingDimensions() {
        #expect(TerminalPixelSize(width: 0, height: 100) == nil)
        #expect(TerminalPixelSize(width: 0.5, height: 100) == nil)
        #expect(TerminalPixelSize(width: 100, height: .infinity) == nil)
        #expect(TerminalPixelSize(width: CGFloat(Int32.max) + 1, height: 100) == nil)
    }
}
