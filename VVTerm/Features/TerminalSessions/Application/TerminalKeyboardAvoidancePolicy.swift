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
        return attachesToBottom && spansScreenWidth
            ? .docked(frame: keyboardFrame)
            : .floating(frame: keyboardFrame)
    }

    nonisolated static func verticalOffset(
        terminalFrame: CGRect,
        cursorFrame: CGRect,
        keyboardFrame: CGRect?,
        cursorClearance: CGFloat = defaultCursorClearance
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
              cursorFrame.maxY <= terminalFrame.maxY + 1,
              cursorFrame.minY >= terminalFrame.minY - 1,
              terminalFrame.intersects(keyboardFrame)
        else {
            return 0
        }

        let cursorOverlapsKeyboardHorizontally = cursorFrame.maxX > keyboardFrame.minX
            && cursorFrame.minX < keyboardFrame.maxX
        guard cursorOverlapsKeyboardHorizontally else { return 0 }

        let requiredLift = cursorFrame.maxY + max(cursorClearance, 0) - keyboardFrame.minY
        guard requiredLift > 0 else { return 0 }

        // The lift may never exceed the keyboard overlap with the terminal:
        // the terminal's top must never leave the visible area, even when the
        // caret sits far below the keyboard or the clearance is large.
        let keyboardOverlap = min(
            max(terminalFrame.maxY - keyboardFrame.minY, 0),
            max(terminalFrame.height, 0)
        )
        guard keyboardOverlap > 0 else { return 0 }

        return -min(requiredLift, keyboardOverlap)
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
                        keyboardFrame: frame
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

    /// Amount (in points) the preserved grid content must shift up so the
    /// caret becomes visible again.
    ///
    /// In preserve mode the surface keeps its pre-keyboard grid while the
    /// visible view is shorter: a caret on a row below the visible area is
    /// legitimate (it is the cursor of the preserved grid, e.g. sitting on
    /// the bottom row), not stale. Ghostty's viewport cannot scroll further
    /// once it reaches the active area, so the app reveals the caret by
    /// translating the rendered grid within the view. The reveal is capped
    /// at the grid's overflow below the visible area: a caret beyond the
    /// grid itself (truly stale, after a grid shrink or scrollback
    /// navigation) yields zero and keeps the stale-caret rejection in
    /// `verticalOffset` as the safety net.
    nonisolated static func revealOffset(
        caretFrame: CGRect,
        visibleFrame: CGRect,
        gridFrame: CGRect
    ) -> CGFloat {
        guard !caretFrame.isNull,
              !caretFrame.isEmpty,
              !caretFrame.isInfinite,
              !visibleFrame.isNull,
              !visibleFrame.isEmpty,
              !visibleFrame.isInfinite,
              !gridFrame.isNull,
              !gridFrame.isEmpty,
              !gridFrame.isInfinite else {
            return 0
        }
        let overflow = caretFrame.maxY - visibleFrame.maxY
        guard overflow > 0 else { return 0 }
        let maxReveal = max(0, gridFrame.height - visibleFrame.height)
        return min(overflow, maxReveal)
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
