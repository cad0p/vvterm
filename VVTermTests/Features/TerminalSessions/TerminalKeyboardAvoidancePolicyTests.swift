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
    func hiddenKeyboardWithAccessoryKeepsPreservedGridInKeepSizeMode() {
        // Issue #120: on keyboard close the accessory detaches a moment
        // after the keyboard frame leaves; in keep-size mode that transient
        // must NOT resize the grid (a resize sends TIOCSWINSZ, the zmx
        // daemon reflows, and the whole screen redraws).
        let layout = TerminalKeyboardAvoidancePolicy.layout(
            preservesTerminalSize: true,
            geometry: .hidden,
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 760, width: 8, height: 18),
            accessoryFrame: CGRect(x: 0, y: 752, width: 390, height: 48)
        )

        #expect(
            layout == .init(
                bottomInset: 0,
                verticalOffset: 0,
                preservesTerminalSurfaceSize: true
            )
        )
    }

    @Test
    func hiddenKeyboardWithoutAccessoryReleasesPreservationInKeepSizeMode() {
        // Once the accessory detaches (the steady state after a keyboard
        // hide), keep-size mode releases the grid — a no-op size-wise since
        // the view is already at the natural size, so no resize/reflow
        // happens.
        let layout = TerminalKeyboardAvoidancePolicy.layout(
            preservesTerminalSize: true,
            geometry: .hidden,
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 760, width: 8, height: 18),
            accessoryFrame: nil
        )

        #expect(layout == .unobstructed)
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
        // terminal plus the requested clearance (800 - 500 + 40 = 340), so
        // the caret can still fully clear the keyboard.
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: CGRect(x: 8, y: 780, width: 8, height: 18),
            keyboardFrame: CGRect(x: 0, y: 500, width: 390, height: 300),
            cursorClearance: 40
        )

        #expect(offset == -338)
    }

    @Test
    func liftNeverExceedsKeyboardOverlapWhenCaretIsFarBelowKeyboard() {
        // Caret far below the keyboard but still inside the terminal grid:
        // the offset is -(keyboard overlap + clearance), NOT
        // -(terminalHeight - 1).
        let cursor = CGRect(x: 8, y: 780, width: 8, height: 18)
        let keyboard = CGRect(x: 0, y: 500, width: 390, height: 300)
        let overlap = terminalFrame.maxY - keyboard.minY
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: cursor,
            keyboardFrame: keyboard
        )

        // Required lift 798 + 12 - 500 = 310, below the cap (overlap 300 +
        // clearance 12 = 312): the required lift wins.
        #expect(offset == -(cursor.maxY + TerminalKeyboardAvoidancePolicy.defaultCursorClearance - keyboard.minY))
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
        // Caret at the bottom edge of the grid (maxY == terminalFrame.maxY,
        // the grid frame — not the view). The lift must bring it exactly
        // above the keyboard, capped at the keyboard overlap.
        let cursor = CGRect(x: 8, y: 782, width: 8, height: 18)
        let keyboard = CGRect(x: 0, y: 500, width: 390, height: 300)
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: cursor,
            keyboardFrame: keyboard
        )

        #expect(cursor.maxY == terminalFrame.maxY)
        let overlap = terminalFrame.maxY - keyboard.minY
        #expect(offset == -(overlap + TerminalKeyboardAvoidancePolicy.defaultCursorClearance))
        #expect(cursor.maxY + offset == keyboard.minY - TerminalKeyboardAvoidancePolicy.defaultCursorClearance)
    }


    @Test
    func staleCaretAboveTerminalGridDoesNotLiftTerminal() {
        // Stale caret above the visible grid (mirror of the below-grid
        // rejection): a caret rect that was never revalidated and lies
        // above the terminal frame must not lift the terminal.
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
    func fullWidthKeyboardSlidUpByFocusFollowIsSnappedToBottom() {
        // iOS 26 focus-following: a docked keyboard slides up the screen
        // when the terminal is lifted (lift → keyboard follows up → bigger
        // overlap → bigger lift → runaway until the terminal is off-screen).
        // A full-width keyboard is still docked geometry; snap it back to
        // the bottom so the lift stays bounded.
        let screenFrame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let terminalFrame = CGRect(x: 0, y: 101, width: 390, height: 709)
        let slidUpKeyboard = CGRect(x: 0, y: 221, width: 390, height: 349)
        let offTopKeyboard = CGRect(x: 0, y: -53, width: 390, height: 349)
        let compactFloating = CGRect(x: 160, y: 480, width: 210, height: 220)

        let slidUp = TerminalKeyboardAvoidancePolicy.resolvedGeometry(
            screenFrame: screenFrame,
            terminalFrame: terminalFrame,
            keyboardFrame: slidUpKeyboard
        )
        let offTop = TerminalKeyboardAvoidancePolicy.resolvedGeometry(
            screenFrame: screenFrame,
            terminalFrame: terminalFrame,
            keyboardFrame: offTopKeyboard
        )
        let floating = TerminalKeyboardAvoidancePolicy.resolvedGeometry(
            screenFrame: screenFrame,
            terminalFrame: terminalFrame,
            keyboardFrame: compactFloating
        )

        #expect(
            slidUp == .docked(
                frame: CGRect(x: 0, y: 495, width: 390, height: 349)
            )
        )
        #expect(
            offTop == .docked(
                frame: CGRect(x: 0, y: 495, width: 390, height: 349)
            )
        )
        #expect(floating == .floating(frame: compactFloating))
    }

    @Test
    func fullWidthFollowKeyboardKeepsLiftBounded() {
        // The runaway repro: the docked keyboard slides up to 221 while the
        // terminal lifts; the lift must be computed against the snapped
        // bottom-docked frame (495) and stay capped at the terminal
        // overlap, never pushing the terminal off-screen.
        let screenFrame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let terminalFrame = CGRect(x: 0, y: 101, width: 390, height: 709)
        let slidUpKeyboard = CGRect(x: 0, y: 221, width: 390, height: 349)
        let caret = CGRect(x: 11, y: 741, width: 7.33, height: 16)

        let geometry = TerminalKeyboardAvoidancePolicy.resolvedGeometry(
            screenFrame: screenFrame,
            terminalFrame: terminalFrame,
            keyboardFrame: slidUpKeyboard
        )
        let resolvedKeyboardFrame: CGRect = switch geometry {
        case .docked(let frame), .floating(let frame): frame
        case .hidden: CGRect.zero
        }
        let offset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: terminalFrame,
            cursorFrame: caret,
            keyboardFrame: resolvedKeyboardFrame
        )

        // Caret maxY 757 vs snapped keyboard top 495: required lift 274,
        // capped at the overlap (810 - 495 = 315).
        #expect(offset == -274)
        #expect(terminalFrame.maxY + offset >= 0)
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

extension TerminalKeyboardAvoidancePolicyTests {
    @Test
    func harnessRepro_LiftAppliesWithBottomCaret() {
        // Exact harness numbers from the failing CI test:
        // grid (0,0,393,874) = 54 rows, caret at the grid bottom
        // (8,864,8,16) — 6pt below grid.maxY via IME font-metric overflow,
        // keyboard (0,518,393,356), accessory (0,792,393,48).
        let terminalFrame = CGRect(x: 0, y: 0, width: 393, height: 874)
        let caret = CGRect(x: 8, y: 864, width: 8, height: 16)
        let keyboard = CGRect(x: 0, y: 518, width: 393, height: 356)

        let geometry = TerminalKeyboardAvoidancePolicy.resolvedGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 393, height: 874),
            terminalFrame: terminalFrame,
            keyboardFrame: keyboard
        )
        let layout = TerminalKeyboardAvoidancePolicy.layout(
            preservesTerminalSize: true,
            geometry: geometry,
            terminalFrame: terminalFrame,
            cursorFrame: caret,
            accessoryFrame: CGRect(x: 0, y: 792, width: 393, height: 48)
        )

        #expect(layout.preservesTerminalSurfaceSize)
        // Caret maxY 880 vs keyboard top 518: required lift 374. The caret
        // sits 6pt below the grid bottom (874, IME font-metric overflow), so
        // the stale-caret tolerance admits it; the cap is the overlap
        // (874 - 518 = 356) plus the clearance (12) = 368.
        #expect(layout.verticalOffset == -368)
    }
}
