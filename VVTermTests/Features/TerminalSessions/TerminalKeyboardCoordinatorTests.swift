#if os(iOS)
import Testing
@testable import VVTerm

struct TerminalKeyboardCoordinatorTests {
    @Test
    func desiredInputSessionAndKeyboardPresentationContract() {
        struct Case {
            let name: String
            let inputs: TerminalKeyboardCoordinator.StateInputs
            let expectedInputSessionActive: Bool
            let expectedKeyboardVisible: Bool
        }

        let visible = TerminalKeyboardCoordinator.StateInputs(
            viewActive: true,
            activePaneConnected: true,
            activePaneWindowAttached: true,
            userHidKeyboard: false,
            findNavigatorActive: false
        )

        let cases = [
            Case(
                name: "connected active attached",
                inputs: visible,
                expectedInputSessionActive: true,
                expectedKeyboardVisible: true
            ),
            Case(
                name: "user hidden",
                inputs: .init(
                    viewActive: true,
                    activePaneConnected: true,
                    activePaneWindowAttached: true,
                    userHidKeyboard: true,
                    findNavigatorActive: false
                ),
                expectedInputSessionActive: true,
                expectedKeyboardVisible: false
            ),
            Case(
                name: "user shown again",
                inputs: visible,
                expectedInputSessionActive: true,
                expectedKeyboardVisible: true
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
                expectedInputSessionActive: false,
                expectedKeyboardVisible: false
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
                expectedInputSessionActive: false,
                expectedKeyboardVisible: false
            ),
            Case(
                name: "window attached after mount",
                inputs: visible,
                expectedInputSessionActive: true,
                expectedKeyboardVisible: true
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
                expectedInputSessionActive: false,
                expectedKeyboardVisible: false
            ),
            Case(
                name: "reconnect restores when visible before",
                inputs: visible,
                expectedInputSessionActive: true,
                expectedKeyboardVisible: true
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
                expectedInputSessionActive: true,
                expectedKeyboardVisible: false
            ),
        ]

        for testCase in cases {
            #expect(
                TerminalKeyboardCoordinator.desiredInputSessionActive(inputs: testCase.inputs) == testCase.expectedInputSessionActive,
                "\(testCase.name) input session"
            )
            #expect(
                TerminalKeyboardCoordinator.desiredKeyboardVisible(inputs: testCase.inputs) == testCase.expectedKeyboardVisible,
                "\(testCase.name) keyboard presentation"
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

    @Test
    func presentationAlreadyInProgressIsNotRebuilt() {
        #expect(
            TerminalKeyboardCoordinator.presentationRefreshAction(
                keyboardPresentationDesired: true,
                refreshRequested: true,
                softwareInputActive: true,
                softwareKeyboardVisible: false,
                presentationVerificationPending: true,
                refreshAttemptCount: 0,
                refreshAttemptLimit: 2
            ) == .deferUntilVerification
        )
    }

    @Test
    func settledMissingPresentationCanBeRebuiltWithinAttemptLimit() {
        #expect(
            TerminalKeyboardCoordinator.presentationRefreshAction(
                keyboardPresentationDesired: true,
                refreshRequested: true,
                softwareInputActive: true,
                softwareKeyboardVisible: false,
                presentationVerificationPending: false,
                refreshAttemptCount: 0,
                refreshAttemptLimit: 2
            ) == .rebuild
        )
        #expect(
            TerminalKeyboardCoordinator.presentationRefreshAction(
                keyboardPresentationDesired: true,
                refreshRequested: true,
                softwareInputActive: true,
                softwareKeyboardVisible: false,
                presentationVerificationPending: false,
                refreshAttemptCount: 2,
                refreshAttemptLimit: 2
            ) == .none
        )
    }

    @Test
    func visibleKeyboardSupersedesPendingRefresh() {
        #expect(
            TerminalKeyboardCoordinator.presentationRefreshAction(
                keyboardPresentationDesired: true,
                refreshRequested: true,
                softwareInputActive: true,
                softwareKeyboardVisible: true,
                presentationVerificationPending: true,
                refreshAttemptCount: 0,
                refreshAttemptLimit: 2
            ) == .none
        )
    }
}
#endif
