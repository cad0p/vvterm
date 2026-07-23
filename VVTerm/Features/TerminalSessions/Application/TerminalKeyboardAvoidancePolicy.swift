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
              !cursorFrame.isInfinite,
              terminalFrame.intersects(keyboardFrame)
        else {
            return 0
        }

        let cursorOverlapsKeyboardHorizontally = cursorFrame.maxX > keyboardFrame.minX
            && cursorFrame.minX < keyboardFrame.maxX
        guard cursorOverlapsKeyboardHorizontally else { return 0 }

        let requiredLift = cursorFrame.maxY + max(cursorClearance, 0) - keyboardFrame.minY
        guard requiredLift > 0 else { return 0 }

        let maximumLift = max(terminalFrame.height, 0)
        guard maximumLift > 0 else { return 0 }

        return -min(requiredLift, maximumLift)
    }

    nonisolated static func layout(
        preservesTerminalSize: Bool,
        geometry: KeyboardGeometry,
        terminalFrame: CGRect,
        cursorFrame: CGRect
    ) -> Layout {
        switch geometry {
        case .hidden:
            return .unobstructed
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
                bottomInset: overlap,
                verticalOffset: 0,
                preservesTerminalSurfaceSize: false
            )
        case let .floating(frame):
            guard preservesTerminalSize else { return .unobstructed }
            return Layout(
                bottomInset: 0,
                verticalOffset: verticalOffset(
                    terminalFrame: terminalFrame,
                    cursorFrame: cursorFrame,
                    keyboardFrame: frame
                ),
                preservesTerminalSurfaceSize: false
            )
        }
    }
}
