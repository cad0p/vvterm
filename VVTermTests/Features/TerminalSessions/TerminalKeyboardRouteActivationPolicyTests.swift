#if os(iOS)
import Testing
@testable import VVTerm

struct TerminalKeyboardRouteActivationPolicyTests {
    @Test(arguments: [false, true])
    func temporarySystemOverlayPreservesKeyboardIntent(userHidKeyboard: Bool) {
        let effects = [
            TerminalKeyboardRouteActivationPolicy.effect(
                routeVisible: true,
                terminalSelected: true,
                sceneActivation: .foregroundActive
            ),
            TerminalKeyboardRouteActivationPolicy.effect(
                routeVisible: true,
                terminalSelected: true,
                sceneActivation: .foregroundInactive
            ),
            TerminalKeyboardRouteActivationPolicy.effect(
                routeVisible: true,
                terminalSelected: true,
                sceneActivation: .foregroundActive
            ),
        ]

        #expect(effects == [.activate, .preserve, .activate])

        let restoredInputs = TerminalKeyboardCoordinator.StateInputs(
            viewActive: true,
            activePaneConnected: true,
            activePaneWindowAttached: true,
            userHidKeyboard: userHidKeyboard,
            findNavigatorActive: false
        )
        #expect(TerminalKeyboardCoordinator.desiredInputSessionActive(inputs: restoredInputs))
        #expect(
            TerminalKeyboardCoordinator.desiredKeyboardVisible(inputs: restoredInputs)
                == !userHidKeyboard
        )
    }

    @Test
    func realBackgroundDeactivatesTerminalInput() {
        let effect = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: true,
            terminalSelected: true,
            sceneActivation: .background
        )

        #expect(effect == .deactivate)
    }

    @Test
    func leavingTerminalDeactivatesEvenDuringTemporaryOverlay() {
        let effect = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: false,
            terminalSelected: true,
            sceneActivation: .foregroundInactive
        )

        #expect(effect == .deactivate)
    }
}
#endif
