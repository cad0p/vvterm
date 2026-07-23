import Foundation

nonisolated enum TerminalSplitCommand: Equatable, Sendable {
    case splitRight
    case splitDown
    case closeFocusedPane
    case toggleZoom
    case selectPrevious
    case selectNext
    case selectAbove
    case selectBelow
    case selectLeft
    case selectRight
    case equalize
    case moveDividerUp
    case moveDividerDown
    case moveDividerLeft
    case moveDividerRight

    var createsPane: Bool {
        self == .splitRight || self == .splitDown
    }
}

enum TerminalSplitCommandOutcome: Equatable {
    case performed
    case unavailable
    case requiresUpgrade
    case requiresCloseConfirmation
}

nonisolated struct TerminalSplitShortcutModifiers: OptionSet, Sendable {
    let rawValue: UInt8

    static let command = Self(rawValue: 1 << 0)
    static let shift = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let alternate = Self(rawValue: 1 << 3)
}

nonisolated enum TerminalSplitShortcutKey: Equatable, Sendable {
    case character(String)
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
}

nonisolated enum TerminalSplitShortcutRouting {
    static let upArrow = "\u{F700}"
    static let downArrow = "\u{F701}"
    static let leftArrow = "\u{F702}"
    static let rightArrow = "\u{F703}"

    nonisolated static func command(
        for input: String,
        modifiers: TerminalSplitShortcutModifiers
    ) -> TerminalSplitCommand? {
        command(for: key(for: input), modifiers: modifiers)
    }

    nonisolated static func command(
        for key: TerminalSplitShortcutKey,
        modifiers: TerminalSplitShortcutModifiers
    ) -> TerminalSplitCommand? {
        switch (key, modifiers) {
        case (.character("d"), [.command]):
            return .splitRight
        case (.character("d"), [.command, .shift]):
            return .splitDown
        case (.character("w"), [.command]):
            return .closeFocusedPane
        case (.character("\r"), [.command, .shift]),
             (.character("\n"), [.command, .shift]):
            return .toggleZoom
        case (.character("["), [.command]):
            return .selectPrevious
        case (.character("]"), [.command]):
            return .selectNext
        case (.upArrow, [.command, .alternate]):
            return .selectAbove
        case (.downArrow, [.command, .alternate]):
            return .selectBelow
        case (.leftArrow, [.command, .alternate]):
            return .selectLeft
        case (.rightArrow, [.command, .alternate]):
            return .selectRight
        case (.character("="), [.command, .control]):
            return .equalize
        case (.upArrow, [.command, .control]):
            return .moveDividerUp
        case (.downArrow, [.command, .control]):
            return .moveDividerDown
        case (.leftArrow, [.command, .control]):
            return .moveDividerLeft
        case (.rightArrow, [.command, .control]):
            return .moveDividerRight
        default:
            return nil
        }
    }

    private nonisolated static func key(for input: String) -> TerminalSplitShortcutKey {
        switch input {
        case upArrow, "UIKeyInputUpArrow":
            return .upArrow
        case downArrow, "UIKeyInputDownArrow":
            return .downArrow
        case leftArrow, "UIKeyInputLeftArrow":
            return .leftArrow
        case rightArrow, "UIKeyInputRightArrow":
            return .rightArrow
        default:
            return .character(input.lowercased())
        }
    }
}
