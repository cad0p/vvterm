#if os(iOS)
import Testing
@testable import VVTerm

struct TerminalKeyboardCoordinatorTests {
    @Test
    func desiredKeyboardVisibleContract() {
        struct Case {
            let name: String
            let inputs: TerminalKeyboardCoordinator.StateInputs
            let expected: Bool
        }

        let visible = TerminalKeyboardCoordinator.StateInputs(
            viewActive: true,
            activePaneConnected: true,
            activePaneWindowAttached: true,
            userHidKeyboard: false,
            findNavigatorActive: false
        )

        let cases = [
            Case(name: "connected active attached", inputs: visible, expected: true),
            Case(
                name: "user hidden",
                inputs: .init(
                    viewActive: true,
                    activePaneConnected: true,
                    activePaneWindowAttached: true,
                    userHidKeyboard: true,
                    findNavigatorActive: false
                ),
                expected: false
            ),
            Case(
                name: "user shown again",
                inputs: visible,
                expected: true
            ),
            Case(
                name: "left terminal view",
                inputs: .init(
                    viewActive: false,
                    activePaneConnected: true,
                    activePaneWindowAttached: true,
                    userHidKeyboard: false,
                    findNavigatorActive: false
                ),
                expected: false
            ),
            Case(
                name: "window not attached",
                inputs: .init(
                    viewActive: true,
                    activePaneConnected: true,
                    activePaneWindowAttached: false,
                    userHidKeyboard: false,
                    findNavigatorActive: false
                ),
                expected: false
            ),
            Case(
                name: "window attached after mount",
                inputs: visible,
                expected: true
            ),
            Case(
                name: "find navigator active",
                inputs: .init(
                    viewActive: true,
                    activePaneConnected: true,
                    activePaneWindowAttached: true,
                    userHidKeyboard: false,
                    findNavigatorActive: true
                ),
                expected: false
            ),
            Case(
                name: "reconnect restores when visible before",
                inputs: visible,
                expected: true
            ),
            Case(
                name: "reconnect stays hidden when hidden before",
                inputs: .init(
                    viewActive: true,
                    activePaneConnected: true,
                    activePaneWindowAttached: true,
                    userHidKeyboard: true,
                    findNavigatorActive: false
                ),
                expected: false
            ),
        ]

        for testCase in cases {
            #expect(
                TerminalKeyboardCoordinator.desiredKeyboardVisible(inputs: testCase.inputs) == testCase.expected,
                "\(testCase.name)"
            )
        }
    }

    @Test
    @MainActor
    func directTouchDoesNotRestoreKeyboardAfterUserHide() {
        let coordinator = TerminalKeyboardCoordinator()

        coordinator.userRequestedHide()
        #expect(coordinator.isUserHidden)

        coordinator.directTouchOnTerminal(isFocusTap: false)
        #expect(coordinator.isUserHidden)

        coordinator.directTouchOnTerminal(isFocusTap: true)
        #expect(coordinator.isUserHidden)
    }

    @Test
    @MainActor
    func explicitShowRestoresKeyboardAfterUserHide() {
        let coordinator = TerminalKeyboardCoordinator()

        coordinator.userRequestedHide()
        #expect(coordinator.isUserHidden)

        coordinator.userRequestedShow()
        #expect(!coordinator.isUserHidden)
    }
}
#endif
