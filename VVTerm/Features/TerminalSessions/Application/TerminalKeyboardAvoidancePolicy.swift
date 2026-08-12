import CoreGraphics

enum TerminalKeyboardAvoidancePolicy {
    nonisolated enum KeyboardGeometry: Equatable {
        case hidden
        case docked(frame: CGRect)
        case floating(frame: CGRect)
    }

    nonisolated struct Layout: Equatable {
        var bottomInset: CGFloat
        var verticalOffset: CGFloat
        var preservesTerminalSurfaceSize: Bool

        static let unobstructed = Layout(
            bottomInset: 0,
            verticalOffset: 0,
            preservesTerminalSurfaceSize: false
        )
    }

    nonisolated static let defaultCursorClearance: CGFloat = 12

    /// How far below the grid bottom a caret rect may legitimately sit.
    /// The IME caret rect is computed with a slightly different cell height
    /// than the surface (font-metric rounding), and the two metrics can
    /// diverge by a few percent across runtimes (e.g. the CI simulator
    /// reports a caret ~4.7% taller than the grid). A proportional
    /// tolerance admits the grid-bottom caret on any runtime while still
    /// rejecting stale carets from scrollback navigation (the content caret
    /// sits orders of magnitude below the grid).
    nonisolated static let staleCaretToleranceFraction: CGFloat = 0.05

    nonisolated static func resolvedGeometry(
        screenFrame: CGRect,
        terminalFrame: CGRect,
        keyboardFrame: CGRect?
    ) -> KeyboardGeometry {
        guard let keyboardFrame,
              !screenFrame.isNull,
              !screenFrame.isEmpty,
              !screenFrame.isInfinite,
              !terminalFrame.isNull,
              !terminalFrame.isEmpty,
              !terminalFrame.isInfinite,
              !keyboardFrame.isNull,
              !keyboardFrame.isEmpty,
              !keyboardFrame.isInfinite,
              terminalFrame.intersects(keyboardFrame)
        else {
            return .hidden
        }

        let attachesToBottom = keyboardFrame.maxY >= screenFrame.maxY - 1
        let spansScreenWidth = keyboardFrame.width >= screenFrame.width * 0.8
        // The system may slide a full-width keyboard up the screen to follow
        // the focused input (iOS 26 focus-following keyboards, and the
        // full-width undocked state). A full-width keyboard is still
        // bottom-docked geometry: snapping it back to the bottom keeps the
        // lift computation from chasing the keyboard (lift → keyboard
        // follows up → bigger overlap → bigger lift → runaway until the
        // terminal is off-screen). Compact floating keyboards (iPad) keep
        // their frame.
        if spansScreenWidth {
            let snapped = CGRect(
                x: keyboardFrame.minX,
                y: screenFrame.maxY - keyboardFrame.height,
                width: keyboardFrame.width,
                height: keyboardFrame.height
            )
            return .docked(frame: snapped)
        }
        return attachesToBottom && spansScreenWidth
            ? .docked(frame: keyboardFrame)
            : .floating(frame: keyboardFrame)
    }

    nonisolated static func verticalOffset(
        terminalFrame: CGRect,
        cursorFrame: CGRect,
        keyboardFrame: CGRect?,
        cursorClearance: CGFloat = defaultCursorClearance,
        anchored: Bool = false
    ) -> CGFloat {
        guard let keyboardFrame,
              !keyboardFrame.isNull,
              !keyboardFrame.isEmpty,
              !keyboardFrame.isInfinite,
              !terminalFrame.isNull,
              !terminalFrame.isEmpty,
              !terminalFrame.isInfinite,
              !cursorFrame.isNull,
              !cursorFrame.isEmpty,
              !cursorFrame.isInfinite,
              // Reject stale caret rects: a caret that lies outside the
              // terminal grid (e.g. not revalidated after scrollback
              // navigation or a grid resize) must never lift the terminal.
              // The proportional bottom tolerance admits the grid-bottom
              // caret's font-metric overflow (up to a few percent of the
              // grid height across runtimes).
              cursorFrame.maxY <= terminalFrame.maxY * (1 + staleCaretToleranceFraction),
              cursorFrame.minY >= terminalFrame.minY - 1,
              terminalFrame.intersects(keyboardFrame)
        else {
            return 0
        }

        let cursorOverlapsKeyboardHorizontally = cursorFrame.maxX > keyboardFrame.minX
            && cursorFrame.minX < keyboardFrame.maxX
        guard cursorOverlapsKeyboardHorizontally else { return 0 }

        // The caret may extend a few points past the grid bottom (font
        // metrics); that part is not visible, so the lift is computed from
        // the caret clamped to the grid.
        let caretMaxY = min(cursorFrame.maxY, terminalFrame.maxY)
        let requiredLift = caretMaxY + max(cursorClearance, 0) - keyboardFrame.minY
        guard requiredLift > 0 else { return 0 }

        // The lift may never exceed the keyboard overlap with the terminal:
        // the terminal's top must never leave the visible area, even when the
        // caret sits far below the keyboard. The cursor clearance is part of
        // the required lift and may be included in the cap — otherwise a
        // caret at the grid bottom can never fully clear the keyboard.
        let keyboardOverlap = min(
            max(terminalFrame.maxY - keyboardFrame.minY, 0),
            max(terminalFrame.height, 0)
        )
        guard keyboardOverlap > 0 else { return 0 }

        let cap = keyboardOverlap + max(cursorClearance, 0)
        if anchored {
            // Anchored lift (docked keyboard in keep-size mode): whenever the
            // caret is ANYWHERE in the covered zone, the content is pinned so
            // its bottom row clears the keyboard — the lift is the full
            // overlap + clearance, NOT the caret's exact position. Chasing
            // the caret makes the whole terminal bounce on every caret move
            // in live TUIs (a running pi/htop session moves the cursor
            // row-by-row; the content jumped 16-32pt per move — the "content
            // jump when the keyboard is on" report). The lift changes only
            // when the caret crosses the keyboard-top boundary.
            return -cap
        }
        return -min(requiredLift, cap)
    }

    nonisolated static func layout(
        preservesTerminalSize: Bool,
        geometry: KeyboardGeometry,
        terminalFrame: CGRect,
        cursorFrame: CGRect,
        accessoryFrame: CGRect? = nil
    ) -> Layout {
        let accessoryInset = bottomAccessoryInset(
            terminalFrame: terminalFrame,
            accessoryFrame: accessoryFrame
        )

        switch geometry {
        case .hidden:
            if preservesTerminalSize {
                // Keep-size mode: transient chrome (the accessory still
                // detaching after the keyboard hides) must never resize the
                // grid — a resize sends TIOCSWINSZ to the remote, the zmx
                // daemon reflows and the whole screen redraws (the user's
                // 'scrollback reload' flash on every keyboard toggle). The
                // accessory may briefly overlay the bottom rows; that beats
                // a resize + reflow storm. Once the accessory detaches, the
                // grid returns to the natural full size — a no-op, since
                // the view is already at that size, so no resize happens
                // either way.
                guard accessoryInset > 0 else { return .unobstructed }
                return Layout(
                    bottomInset: 0,
                    verticalOffset: 0,
                    preservesTerminalSurfaceSize: true
                )
            }
            guard accessoryInset > 0 else { return .unobstructed }
            return Layout(
                bottomInset: accessoryInset,
                verticalOffset: 0,
                preservesTerminalSurfaceSize: false
            )
        case let .docked(frame):
            if preservesTerminalSize {
                return Layout(
                    bottomInset: 0,
                    verticalOffset: verticalOffset(
                        terminalFrame: terminalFrame,
                        cursorFrame: cursorFrame,
                        keyboardFrame: frame,
                        anchored: true
                    ),
                    preservesTerminalSurfaceSize: true
                )
            }
            let overlap = min(
                max(terminalFrame.maxY - max(frame.minY, terminalFrame.minY), 0),
                max(terminalFrame.height, 0)
            )
            return Layout(
                bottomInset: max(overlap, accessoryInset),
                verticalOffset: 0,
                preservesTerminalSurfaceSize: false
            )
        case let .floating(frame):
            guard preservesTerminalSize else {
                guard accessoryInset > 0 else { return .unobstructed }
                return Layout(
                    bottomInset: accessoryInset,
                    verticalOffset: 0,
                    preservesTerminalSurfaceSize: false
                )
            }
            let keyboardOffset = verticalOffset(
                terminalFrame: terminalFrame,
                cursorFrame: cursorFrame,
                keyboardFrame: frame
            )
            let accessoryOffset = verticalOffset(
                terminalFrame: terminalFrame,
                cursorFrame: cursorFrame,
                keyboardFrame: accessoryFrame
            )
            return Layout(
                bottomInset: 0,
                verticalOffset: min(keyboardOffset, accessoryOffset),
                preservesTerminalSurfaceSize: true
            )
        }
    }

    private nonisolated static func bottomAccessoryInset(
        terminalFrame: CGRect,
        accessoryFrame: CGRect?
    ) -> CGFloat {
        guard let accessoryFrame,
              !terminalFrame.isNull,
              !terminalFrame.isEmpty,
              !terminalFrame.isInfinite,
              !accessoryFrame.isNull,
              !accessoryFrame.isEmpty,
              !accessoryFrame.isInfinite,
              accessoryFrame.maxY >= terminalFrame.maxY - 1 else {
            return 0
        }

        let horizontalOverlap = min(terminalFrame.maxX, accessoryFrame.maxX)
            - max(terminalFrame.minX, accessoryFrame.minX)
        guard horizontalOverlap >= terminalFrame.width * 0.8 else { return 0 }

        return min(
            max(terminalFrame.maxY - max(accessoryFrame.minY, terminalFrame.minY), 0),
            max(terminalFrame.height, 0)
        )
    }
}

/// Pure rules for the keyboard-lift viewport shift (keep-size mode, docked
/// keyboard).
///
/// The anchored lift pins the content so its bottom row clears the keyboard;
/// the user can then pull the content back DOWN (finger-down pan) to reveal
/// the rows hidden by the lift — a bounded viewport shift of the rendered
/// grid, like the full-screen-zen edge overscroll — WITHOUT scrolling ghostty:
/// the TUI stays anchored to its live position (new output keeps flowing in
/// place; the “content starts flowing” regression). The shift range is
/// [0, maxLift] (0 = anchored, maxLift = the anchored lift = the natural
/// position); it is caret-INDEPENDENT so a live TUI moving its cursor
/// row-by-row cannot make the content bounce. Deltas beyond the range are
/// forwarded to ghostty (a deliberate scroll into history).
nonisolated enum TerminalKeyboardLiftPolicy {
    /// Resolves a vertical pan delta (points, finger-down positive) against
    /// the current lift shift. Returns the new shift and the portion that
    /// should be forwarded to ghostty.
    nonisolated static func resolvedShift(
        shift: CGFloat,
        delta: CGFloat,
        maxLift: CGFloat
    ) -> (shift: CGFloat, forwarded: CGFloat) {
        guard delta != 0, maxLift > 0 else { return (shift, delta) }
        let absorbed: CGFloat
        if delta > 0 {
            // Pulling the content down (un-lift): absorb up to the remaining
            // range; the excess forwards (deliberate scroll into history).
            absorbed = min(delta, max(0, maxLift - shift))
        } else {
            // Pushing the content up (re-lift): absorb back toward the
            // anchored position; the excess forwards to ghostty.
            absorbed = max(delta, -shift)
        }
        return (shift + absorbed, delta - absorbed)
    }
}
