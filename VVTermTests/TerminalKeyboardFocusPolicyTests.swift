import Testing
@testable import VVTerm

struct TerminalKeyboardFocusPolicyTests {
    @Test
    func userDismissEntersBrowseModeUntilExplicitTypingIntent() {
        var policy = TerminalKeyboardFocusPolicy()

        let initialActivationAccepted = policy.requestFocus(for: .initialActivation)
        #expect(initialActivationAccepted)
        #expect(policy.allowsAutomaticFocus)
        #expect(!policy.isBrowsing)
        #expect(policy.shouldRestoreOnReconnect)

        policy.dismissForUser()
        #expect(!policy.allowsAutomaticFocus)
        #expect(policy.isBrowsing)
        #expect(!policy.shouldRestoreOnReconnect)

        let automaticActivationAccepted = policy.requestFocus(for: .initialActivation)
        let selectionGestureAccepted = policy.requestFocus(for: .selectionGesture)
        let reconnectRestoreAccepted = policy.requestFocus(for: .reconnectRestore)
        #expect(!automaticActivationAccepted)
        #expect(!selectionGestureAccepted)
        #expect(!reconnectRestoreAccepted)
        #expect(policy.isBrowsing)

        let directTouchAccepted = policy.requestFocus(for: .directTouch)
        #expect(directTouchAccepted)
        #expect(policy.allowsAutomaticFocus)
        #expect(!policy.isBrowsing)
        #expect(policy.shouldRestoreOnReconnect)
    }

    @Test
    func explicitShowAndHardwareFocusLeaveBrowseMode() {
        for reason in [TerminalKeyboardFocusReason.explicitUserRequest, .hardwareKeyboard] {
            var policy = TerminalKeyboardFocusPolicy()

            policy.dismissForUser()
            #expect(policy.isBrowsing)

            let requestAccepted = policy.requestFocus(for: reason)
            #expect(requestAccepted)
            #expect(policy.allowsAutomaticFocus)
            #expect(!policy.isBrowsing)
            #expect(policy.shouldRestoreOnReconnect)
        }
    }

    @Test
    func reconnectRestoreRequiresPriorTypingIntent() {
        var policy = TerminalKeyboardFocusPolicy()

        let reconnectBeforeTyping = policy.requestFocus(for: .reconnectRestore)
        #expect(!reconnectBeforeTyping)

        let explicitRequestAccepted = policy.requestFocus(for: .explicitUserRequest)
        let reconnectAfterTyping = policy.requestFocus(for: .reconnectRestore)
        #expect(explicitRequestAccepted)
        #expect(reconnectAfterTyping)

        policy.dismissForUser()
        let reconnectAfterDismiss = policy.requestFocus(for: .reconnectRestore)
        #expect(!reconnectAfterDismiss)
    }
}
