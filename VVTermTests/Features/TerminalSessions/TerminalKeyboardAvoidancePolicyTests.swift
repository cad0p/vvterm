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
    func cursorClearanceLiftIsCappedAtKeyboardOverlap() {
        // The caret (valid, inside the grid) sits far below the keyboard top
        // and the requested clearance would push the lift past the covered
        // height. The lift is capped at the keyboard overlap with the
        // terminal (800 - 500 = 300), never at the old full-height cap.
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 780, width: 8, height: 18),
            keyboardFrame: CGRect(x: 0, y: 500, width: 390, height: 300),
            cursorClearance: 40
        )

        #expect(offset == -300)
    }

    @Test
    func liftNeverExceedsKeyboardOverlapWhenCaretIsFarBelowKeyboard() {
        // Caret far below the keyboard but still inside the terminal grid:
        // the offset is -(keyboard overlap), NOT -(terminalHeight - 1).
        let cursor = CGRect(x: 8, y: 780, width: 8, height: 18)
        let keyboard = CGRect(x: 0, y: 500, width: 390, height: 300)
        let overlap = terminalFrame.maxY - keyboard.minY
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: cursor,
            keyboardFrame: keyboard
        )

        #expect(offset == -overlap)
        #expect(offset != -(terminalFrame.height - 1))
        #expect(cursor.maxY + offset <= keyboard.minY)
    }

    @Test
    func staleCaretBelowTerminalGridDoesNotLiftTerminal() {
        // Stale caret below the visible grid (issue #122): the caret rect was
        // never revalidated after a scrollback navigation or grid resize and
        // lies outside the terminal frame. No lift may happen. The previous
        // expectation (-799, the full-height cap) encoded the bug.
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 1_390, width: 8, height: 18),
            keyboardFrame: CGRect(x: 0, y: 500, width: 390, height: 300),
            cursorClearance: 40
        )

        #expect(offset == 0)
        #expect(terminalFrame.height + offset == terminalFrame.height)
    }

    @Test
    func caretAtVisibleBottomEdgeLiftsByCappedOverlap() {
        // After the reveal scroll the caret sits at the bottom edge of the
        // visible grid (maxY == terminalFrame.maxY). The lift must bring it
        // exactly above the keyboard, capped at the keyboard overlap.
        let cursor = CGRect(x: 8, y: 782, width: 8, height: 18)
        let keyboard = CGRect(x: 0, y: 500, width: 390, height: 300)
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: cursor,
            keyboardFrame: keyboard
        )

        #expect(cursor.maxY == terminalFrame.maxY)
        #expect(offset == -(terminalFrame.maxY - keyboard.minY))
        #expect(cursor.maxY + offset == keyboard.minY)
    }

    @Test
    func revealOffsetMovesBelowVisibleCaretToVisibleBottom() {
        // Preserve mode: the grid (54 rows) is taller than the visible view
        // (52 rows). A caret on the last grid row sits below the visible
        // area; the reveal must shift the grid content up by exactly the
        // overflow so the caret lands at the visible bottom edge.
        let grid = CGRect(x: 0, y: 0, width: 390, height: 880)
        let visible = CGRect(x: 0, y: 0, width: 390, height: 840)
        let caret = CGRect(x: 8, y: 864, width: 8, height: 16)

        let reveal = TerminalKeyboardAvoidancePolicy.revealOffset(
            caretFrame: caret,
            visibleFrame: visible,
            gridFrame: grid
        )

        #expect(reveal == 40)
        #expect(caret.maxY - reveal == visible.maxY)
    }

    @Test
    func revealOffsetClampsAtGridOverflow() {
        // A caret beyond the grid itself (truly stale, e.g. after a grid
        // shrink) must not over-scroll: the reveal is capped at the grid's
        // overflow below the visible area.
        let grid = CGRect(x: 0, y: 0, width: 390, height: 880)
        let visible = CGRect(x: 0, y: 0, width: 390, height: 840)
        let staleCaret = CGRect(x: 8, y: 1_000, width: 8, height: 16)

        let reveal = TerminalKeyboardAvoidancePolicy.revealOffset(
            caretFrame: staleCaret,
            visibleFrame: visible,
            gridFrame: grid
        )

        #expect(reveal == grid.height - visible.height)
        #expect(staleCaret.maxY - reveal > visible.maxY)
    }

    @Test
    func revealOffsetIsZeroWhenCaretIsVisibleOrGridFits() {
        // Caret inside the visible area: nothing to reveal.
        let grid = CGRect(x: 0, y: 0, width: 390, height: 880)
        let visible = CGRect(x: 0, y: 0, width: 390, height: 840)
        let visibleCaret = CGRect(x: 8, y: 800, width: 8, height: 16)

        #expect(
            TerminalKeyboardAvoidancePolicy.revealOffset(
                caretFrame: visibleCaret,
                visibleFrame: visible,
                gridFrame: grid
            ) == 0
        )

        // Grid fits the visible view: the caret cannot be legitimately below
        // the visible area, so a below-view caret is stale and must not
        // scroll the grid.
        let fittingGrid = CGRect(x: 0, y: 0, width: 390, height: 840)
        #expect(
            TerminalKeyboardAvoidancePolicy.revealOffset(
                caretFrame: visibleCaret.offsetBy(dx: 0, dy: 32),
                visibleFrame: visible,
                gridFrame: fittingGrid
            ) == 0
        )

        // Empty caret rects never reveal.
        #expect(
            TerminalKeyboardAvoidancePolicy.revealOffset(
                caretFrame: .zero,
                visibleFrame: visible,
                gridFrame: grid
            ) == 0
        )
    }

    @Test
    func staleCaretAboveTerminalGridDoesNotLiftTerminal() {
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: -10, width: 8, height: 18),
            keyboardFrame: CGRect(x: 0, y: 500, width: 390, height: 300)
        )

        #expect(offset == 0)
    }

    @Test
    func emptyCursorRectDoesNotLiftTerminal() {
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: .zero,
            keyboardFrame: CGRect(x: 0, y: 500, width: 390, height: 300)
        )

        #expect(offset == 0)
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
    }

    @Test
    func defaultLayoutResizesOnlyForDockedKeyboard() {
        let docked = TerminalKeyboardAvoidancePolicy.layout(
            preservesTerminalSize: false,
            geometry: .docked(frame: CGRect(x: 0, y: 500, width: 390, height: 300)),
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 700, width: 8, height: 18)
        )
        let floating = TerminalKeyboardAvoidancePolicy.layout(
            preservesTerminalSize: false,
            geometry: .floating(frame: CGRect(x: 160, y: 480, width: 210, height: 220)),
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 220, y: 610, width: 8, height: 18)
        )

        #expect(docked == .init(bottomInset: 300, verticalOffset: 0, preservesTerminalSurfaceSize: false))
        #expect(floating == .unobstructed)
    }

    @Test
    func floatingKeyboardInsetsOnlyTheBottomDockedAccessory() {
        let layout = TerminalKeyboardAvoidancePolicy.layout(
            preservesTerminalSize: false,
            geometry: .floating(frame: CGRect(x: 160, y: 480, width: 210, height: 220)),
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 700, width: 8, height: 18),
            accessoryFrame: CGRect(x: 0, y: 752, width: 390, height: 48)
        )

        #expect(
            layout == .init(
                bottomInset: 48,
                verticalOffset: 0,
                preservesTerminalSurfaceSize: false
            )
        )
    }

    @Test
    func accessoryAttachedToFloatingKeyboardDoesNotCreateBottomInset() {
        let layout = TerminalKeyboardAvoidancePolicy.layout(
            preservesTerminalSize: false,
            geometry: .floating(frame: CGRect(x: 160, y: 480, width: 210, height: 220)),
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 700, width: 8, height: 18),
            accessoryFrame: CGRect(x: 160, y: 432, width: 210, height: 48)
        )

        #expect(layout == .unobstructed)
    }

    @Test
    func preservedLayoutMovesWithoutLeavingDockedInsetBehind() {
        let docked = TerminalKeyboardAvoidancePolicy.layout(
            preservesTerminalSize: true,
            geometry: .docked(frame: CGRect(x: 0, y: 500, width: 390, height: 300)),
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 700, width: 8, height: 18)
        )
        let floating = TerminalKeyboardAvoidancePolicy.layout(
            preservesTerminalSize: true,
            geometry: .floating(frame: CGRect(x: 160, y: 480, width: 210, height: 220)),
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 220, y: 610, width: 8, height: 18)
        )

        #expect(docked.bottomInset == 0)
        #expect(docked.verticalOffset == -230)
        #expect(docked.preservesTerminalSurfaceSize)
        #expect(floating.bottomInset == 0)
        #expect(floating.verticalOffset == -160)
        #expect(floating.preservesTerminalSurfaceSize)
    }

    @Test
    func offWindowKeyboardGeometryIsHidden() {
        let geometry = TerminalKeyboardAvoidancePolicy.resolvedGeometry(
            screenFrame: terminalFrame,
            terminalFrame: terminalFrame,
            keyboardFrame: CGRect(x: 500, y: 480, width: 210, height: 220)
        )

        #expect(geometry == .hidden)
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
    }
}
#endif
