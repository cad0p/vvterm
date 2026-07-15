#if os(iOS)
import CoreGraphics
import Testing
@testable import VVTerm

struct TerminalKeyboardAvoidancePolicyTests {
    private let terminalFrame = CGRect(x: 0, y: 0, width: 390, height: 800)

    @Test
    func hiddenKeyboardDoesNotMoveTerminal() {
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 760, width: 8, height: 18),
            keyboardFrame: nil
        )

        #expect(offset == 0)
    }

    @Test
    func cursorAboveKeyboardDoesNotMoveTerminal() {
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 300, width: 8, height: 18),
            keyboardFrame: CGRect(x: 0, y: 500, width: 390, height: 300)
        )

        #expect(offset == 0)
    }

    @Test
    func coveredCursorMovesJustAboveKeyboard() {
        let cursor = CGRect(x: 8, y: 700, width: 8, height: 18)
        let keyboard = CGRect(x: 0, y: 500, width: 390, height: 300)
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: cursor,
            keyboardFrame: keyboard
        )

        #expect(offset == -230)
        #expect(cursor.maxY + offset + TerminalKeyboardAvoidancePolicy.defaultCursorClearance == keyboard.minY)
    }

    @Test
    func cursorClearanceCanMovePastCoveredTerminalHeight() {
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 790, width: 8, height: 18),
            keyboardFrame: CGRect(x: 0, y: 500, width: 390, height: 300),
            cursorClearance: 40
        )

        #expect(offset == -348)
    }

    @Test
    func liftNeverExceedsTerminalHeight() {
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 1_390, width: 8, height: 18),
            keyboardFrame: CGRect(x: 0, y: 500, width: 390, height: 300),
            cursorClearance: 40
        )

        #expect(offset == -800)
    }

    @Test
    func floatingKeyboardAwayFromCursorDoesNotMoveTerminal() {
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 16, y: 610, width: 8, height: 18),
            keyboardFrame: CGRect(x: 160, y: 480, width: 210, height: 220)
        )

        #expect(offset == 0)
    }

    @Test
    func floatingKeyboardCoveringCursorMovesTerminal() {
        let cursor = CGRect(x: 220, y: 610, width: 8, height: 18)
        let keyboard = CGRect(x: 160, y: 480, width: 210, height: 220)
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: cursor,
            keyboardFrame: keyboard
        )

        #expect(offset == -160)
    }

    @Test
    func dockedFloatingDockedTransitionsReplaceGeometryWithoutStalePreservation() {
        let docked = CGRect(x: 0, y: 500, width: 390, height: 300)
        let floating = CGRect(x: 160, y: 480, width: 210, height: 220)
        let geometries = [docked, floating, docked, nil].map {
            TerminalKeyboardAvoidancePolicy.resolvedGeometry(
                screenFrame: terminalFrame,
                terminalFrame: terminalFrame,
                keyboardFrame: $0
            )
        }

        #expect(
            geometries == [
                .docked(frame: docked),
                .floating(frame: floating),
                .docked(frame: docked),
                .hidden,
            ]
        )
        #expect(geometries.map(\.preservesTerminalSurfaceSize) == [true, false, true, false])
    }

    @Test
    func offWindowKeyboardGeometryIsHidden() {
        let geometry = TerminalKeyboardAvoidancePolicy.resolvedGeometry(
            screenFrame: terminalFrame,
            terminalFrame: terminalFrame,
            keyboardFrame: CGRect(x: 500, y: 480, width: 210, height: 220)
        )

        #expect(geometry == .hidden)
        #expect(!geometry.preservesTerminalSurfaceSize)
    }

    @Test
    func floatingKeyboardRemainsFloatingInNarrowAppWindow() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
        let narrowTerminalFrame = CGRect(x: 991, y: 0, width: 375, height: 1_024)
        let floating = CGRect(x: 1_046, y: 704, width: 320, height: 320)

        let geometry = TerminalKeyboardAvoidancePolicy.resolvedGeometry(
            screenFrame: screenFrame,
            terminalFrame: narrowTerminalFrame,
            keyboardFrame: floating
        )

        #expect(geometry == .floating(frame: floating))
        #expect(!geometry.preservesTerminalSurfaceSize)
    }
}
#endif
