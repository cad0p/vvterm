import Testing
@testable import VVTerm

struct TerminalSplitShortcutTests {
    @Test
    func recognizesCreationCloseAndZoomCommands() {
        #expect(command(for: "d", modifiers: [.command]) == .splitRight)
        #expect(command(for: "D", modifiers: [.command, .shift]) == .splitDown)
        #expect(command(for: "w", modifiers: [.command]) == .closeFocusedPane)
        #expect(command(for: "\r", modifiers: [.command, .shift]) == .toggleZoom)
    }

    @Test
    func recognizesFocusNavigationCommands() {
        #expect(command(for: "[", modifiers: [.command]) == .selectPrevious)
        #expect(command(for: "]", modifiers: [.command]) == .selectNext)
        #expect(command(for: TerminalSplitShortcutRouting.upArrow, modifiers: [.command, .alternate]) == .selectAbove)
        #expect(command(for: TerminalSplitShortcutRouting.downArrow, modifiers: [.command, .alternate]) == .selectBelow)
        #expect(command(for: TerminalSplitShortcutRouting.leftArrow, modifiers: [.command, .alternate]) == .selectLeft)
        #expect(command(for: TerminalSplitShortcutRouting.rightArrow, modifiers: [.command, .alternate]) == .selectRight)
    }

    @Test
    func recognizesResizeCommands() {
        #expect(command(for: "=", modifiers: [.command, .control]) == .equalize)
        #expect(command(for: TerminalSplitShortcutRouting.upArrow, modifiers: [.command, .control]) == .moveDividerUp)
        #expect(command(for: TerminalSplitShortcutRouting.downArrow, modifiers: [.command, .control]) == .moveDividerDown)
        #expect(command(for: TerminalSplitShortcutRouting.leftArrow, modifiers: [.command, .control]) == .moveDividerLeft)
        #expect(command(for: TerminalSplitShortcutRouting.rightArrow, modifiers: [.command, .control]) == .moveDividerRight)
    }

    @Test
    func requiresExactModifierCombinations() {
        #expect(command(for: "d", modifiers: []) == nil)
        #expect(command(for: "w", modifiers: [.command, .shift]) == nil)
        #expect(command(for: "d", modifiers: [.command, .control]) == nil)
        #expect(command(for: "=", modifiers: [.command]) == nil)
        #expect(command(for: TerminalSplitShortcutRouting.upArrow, modifiers: [.command]) == nil)
        #expect(command(for: "x", modifiers: [.command]) == nil)
    }

    private func command(
        for input: String,
        modifiers: TerminalSplitShortcutModifiers
    ) -> TerminalSplitCommand? {
        TerminalSplitShortcutRouting.command(for: input, modifiers: modifiers)
    }
}
