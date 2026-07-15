import CoreGraphics

enum TerminalKeyboardAvoidancePolicy {
    enum KeyboardGeometry: Equatable {
        case hidden
        case docked(frame: CGRect)
        case floating(frame: CGRect)

        var frame: CGRect? {
            switch self {
            case .hidden:
                return nil
            case let .docked(frame), let .floating(frame):
                return frame
            }
        }

        var preservesTerminalSurfaceSize: Bool {
            if case .docked = self {
                return true
            }
            return false
        }
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
              !terminalFrame.isNull,
              !terminalFrame.isEmpty,
              !keyboardFrame.isNull,
              !keyboardFrame.isEmpty,
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
}
