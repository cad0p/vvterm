enum TerminalKeyboardFocusReason {
    case explicitUserRequest
    case initialActivation
    case reconnectRestore
    case directTouch
    case selectionGesture
    case hardwareKeyboard
}

struct TerminalKeyboardFocusPolicy {
    private enum Mode {
        case typing
        case browse
    }

    private var mode: Mode = .typing
    private(set) var shouldRestoreOnReconnect = false

    var allowsAutomaticFocus: Bool {
        mode == .typing
    }

    var isBrowsing: Bool {
        mode == .browse
    }

    mutating func requestFocus(for reason: TerminalKeyboardFocusReason) -> Bool {
        switch reason {
        case .explicitUserRequest, .hardwareKeyboard:
            mode = .typing
            shouldRestoreOnReconnect = true
            return true
        case .initialActivation, .directTouch, .selectionGesture:
            guard mode == .typing else { return false }
            shouldRestoreOnReconnect = true
            return true
        case .reconnectRestore:
            return mode == .typing && shouldRestoreOnReconnect
        }
    }

    mutating func dismissForUser() {
        mode = .browse
        shouldRestoreOnReconnect = false
    }

    mutating func markForReconnect() {
        guard mode == .typing else { return }
        shouldRestoreOnReconnect = true
    }

    mutating func clearReconnect() {
        shouldRestoreOnReconnect = false
    }
}
