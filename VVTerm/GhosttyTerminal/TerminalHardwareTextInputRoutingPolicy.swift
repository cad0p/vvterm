import Foundation

enum TerminalHardwareTextInputRoutingPolicy {
    static func shouldRoutePressToSystemTextInput(
        hasControlModifier: Bool,
        hasAlternateModifier: Bool,
        hasCommandModifier: Bool,
        hasActiveIMEComposition: Bool,
        isSystemTextInputToggleKey: Bool,
        isTextInputModifierOnlyKey: Bool,
        hasTerminalFallbackKey: Bool,
        keyProducesText: Bool
    ) -> Bool {
        if hasCommandModifier {
            return false
        }
        if isTextInputModifierOnlyKey {
            return true
        }
        if hasActiveIMEComposition {
            return true
        }
        if hasControlModifier {
            return false
        }
        if isSystemTextInputToggleKey {
            return true
        }
        if hasTerminalFallbackKey {
            return false
        }
        if hasAlternateModifier {
            return keyProducesText
        }
        if keyProducesText {
            return true
        }
        return false
    }

    static func shouldRecordPendingInterpretedHardwareKey(
        keyProducesText: Bool,
        hasControlModifier: Bool,
        hasAlternateModifier: Bool,
        hasCommandModifier: Bool,
        hasActiveIMEComposition: Bool,
        isSystemTextInputToggleKey: Bool
    ) -> Bool {
        keyProducesText
            && !hasActiveIMEComposition
            && !hasControlModifier
            && !hasAlternateModifier
            && !hasCommandModifier
            && !isSystemTextInputToggleKey
    }

    static func shouldMirrorSystemTextInputModifierPressToTerminal(
        isTextInputModifierOnlyKey: Bool
    ) -> Bool {
        isTextInputModifierOnlyKey
    }
}
