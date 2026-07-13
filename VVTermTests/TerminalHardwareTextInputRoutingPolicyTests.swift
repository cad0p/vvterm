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
    func keepsConfiguredOptionAsAltKeysOnDirectGhosttyPath() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: true,
                usesAlternateModifierAsTerminalAlt: true,
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
    func keepsConfiguredOptionModifierPressOutOfSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: true,
                usesAlternateModifierAsTerminalAlt: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: true,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            ) == false
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

    @Test
    func consumesShiftAndAltForInterpretedTextButKeepsControlAndCommandUnconsumed() {
        let consumed = TerminalKeyInputModifierPolicy.consumedModifiers(
            for: [.shift, .alt, .ctrl, .super]
        )

        #expect(consumed.contains(.shift))
        #expect(consumed.contains(.alt))
        #expect(consumed.contains(.ctrl) == false)
        #expect(consumed.contains(.super) == false)
    }
}
