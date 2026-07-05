import Testing
@testable import VVTerm

struct TerminalHardwareTextInputRoutingPolicyTests {
    @Test
    func routesPrintableHardwareTextToSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            )
        )
    }

    @Test
    func routesCapsLockToggleToSystemTextInputEvenThoughItIsFallbackKey() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: true,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            )
        )
    }

    @Test
    func routesTextInputModifierOnlyKeysToSystemTextInputEvenThoughTheyAreFallbackKeys() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: true,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            )
        )
    }

    @Test
    func routesActiveCompositionThroughSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: true,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            )
        )
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: true,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: true,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            )
        )
    }

    @Test
    func keepsNavigationFallbackKeysOnDirectGhosttyPathWhenNotComposing() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: true
            ) == false
        )
    }

    @Test
    func keepsControlModifiedPrintableKeysOnDirectGhosttyPath() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: true,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            ) == false
        )
    }

    @Test
    func routesOptionModifiedPrintableKeysToSystemTextInputForDeadKeys() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            )
        )
    }

    @Test
    func keepsOptionModifiedNavigationKeysOnDirectGhosttyPath() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: true
            ) == false
        )
    }

    @Test
    func keepsCommandModifiedKeysOutOfSystemTextInputPolicy() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: true,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            ) == false
        )
    }

    @Test
    func recordsPlainPrintableHardwareKeysForInterpretedKeyEventCommit() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRecordPendingInterpretedHardwareKey(
                keyProducesText: true,
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false
            )
        )
    }

    @Test
    func doesNotRecordOptionTextAsPendingHardwareKey() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRecordPendingInterpretedHardwareKey(
                keyProducesText: true,
                hasControlModifier: false,
                hasAlternateModifier: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false
            ) == false
        )
    }

    @Test
    func doesNotRecordPrintableKeysDuringIMEComposition() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRecordPendingInterpretedHardwareKey(
                keyProducesText: true,
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: true,
                isSystemTextInputToggleKey: false
            ) == false
        )
    }

    @Test
    func mirrorsTextInputModifierOnlyKeysToTerminal() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldMirrorSystemTextInputModifierPressToTerminal(
                isTextInputModifierOnlyKey: true
            )
        )
    }

    @Test
    func doesNotMirrorPrintableSystemTextInputKeysToTerminal() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldMirrorSystemTextInputModifierPressToTerminal(
                isTextInputModifierOnlyKey: false
            ) == false
        )
    }
}

struct TerminalKeyboardFocusPolicyTests {
    @Test
    func startsAutomaticWithoutReconnectRestore() {
        let policy = TerminalKeyboardFocusPolicy()

        #expect(policy.allowsAutomaticFocus)
        #expect(policy.shouldRestoreOnReconnect == false)
    }

    @Test
    func userDismissalBlocksIncidentalFocusUntilExplicitRefocus() {
        var policy = TerminalKeyboardFocusPolicy()
        let initialActivationAllowed = policy.requestFocus(for: .initialActivation)

        #expect(initialActivationAllowed)
        policy.dismissForUser()

        #expect(policy.allowsAutomaticFocus == false)
        #expect(policy.shouldRestoreOnReconnect == false)
        let directTouchAllowed = policy.requestFocus(for: .directTouch)
        let selectionGestureAllowed = policy.requestFocus(for: .selectionGesture)
        #expect(directTouchAllowed == false)
        #expect(selectionGestureAllowed == false)

        let explicitUserRequestAllowed = policy.requestFocus(for: .explicitUserRequest)
        #expect(explicitUserRequestAllowed)

        #expect(policy.allowsAutomaticFocus)
        #expect(policy.shouldRestoreOnReconnect)
    }

    @Test
    func hardwareKeyboardFocusLeavesBrowseMode() {
        var policy = TerminalKeyboardFocusPolicy()
        let initialActivationAllowed = policy.requestFocus(for: .initialActivation)

        #expect(initialActivationAllowed)
        policy.dismissForUser()

        #expect(policy.allowsAutomaticFocus == false)

        let hardwareKeyboardAllowed = policy.requestFocus(for: .hardwareKeyboard)

        #expect(hardwareKeyboardAllowed)
        #expect(policy.allowsAutomaticFocus)
        #expect(policy.shouldRestoreOnReconnect)
    }

    @Test
    func reconnectRestoreStaysBlockedAfterManualDismissal() {
        var policy = TerminalKeyboardFocusPolicy()
        let initialActivationAllowed = policy.requestFocus(for: .initialActivation)

        #expect(initialActivationAllowed)
        policy.dismissForUser()
        policy.markForReconnect()

        #expect(policy.allowsAutomaticFocus == false)
        #expect(policy.shouldRestoreOnReconnect == false)
        let reconnectRestoreAllowed = policy.requestFocus(for: .reconnectRestore)
        #expect(reconnectRestoreAllowed == false)
    }

    @Test
    func clearingReconnectIntentPreservesCurrentFocusMode() {
        var policy = TerminalKeyboardFocusPolicy()
        let initialActivationAllowed = policy.requestFocus(for: .initialActivation)

        #expect(initialActivationAllowed)
        policy.clearReconnect()

        #expect(policy.allowsAutomaticFocus)
        #expect(policy.shouldRestoreOnReconnect == false)

        policy.dismissForUser()
        policy.clearReconnect()

        #expect(policy.allowsAutomaticFocus == false)
        #expect(policy.shouldRestoreOnReconnect == false)
    }

    @Test
    func reconnectRestoreRequiresSavedRestoreIntent() {
        var policy = TerminalKeyboardFocusPolicy()
        let initialReconnectRestoreAllowed = policy.requestFocus(for: .reconnectRestore)
        let initialActivationAllowed = policy.requestFocus(for: .initialActivation)

        #expect(initialReconnectRestoreAllowed == false)
        #expect(initialActivationAllowed)
        policy.clearReconnect()

        let reconnectRestoreWithoutIntent = policy.requestFocus(for: .reconnectRestore)
        #expect(reconnectRestoreWithoutIntent == false)

        policy.markForReconnect()

        let reconnectRestoreWithIntent = policy.requestFocus(for: .reconnectRestore)
        #expect(reconnectRestoreWithIntent)
    }
}
