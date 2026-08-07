import Foundation

enum TerminalPointerButton: Equatable {
    case left
    case right
    case middle
}

enum TerminalPointerInputRoutingPolicy {
    /// Direct-touch taps are routed to the terminal whenever input is
    /// available and no selection interaction is active — REGARDLESS of
    /// whether the foreground app has mouse reporting enabled.
    ///
    /// Mouse capture used to gate this, which silently killed OSC 8 link
    /// clicks in plain shells / zmx sessions (no mouse mode → tap dropped
    /// before the core ever saw it). The core itself is safe to receive
    /// taps in non-captured apps: a tap on a link activates it (and is
    /// swallowed), any other tap is a no-op (no mouse report is emitted
    /// when the app isn't capturing; prompt-click is gated on OSC 9;9
    /// semantic prompts + cursor_click_to_move).
    static func shouldSendDirectTouchClick(
        terminalInputAvailable: Bool,
        selectionInteractionActive: Bool
    ) -> Bool {
        terminalInputAvailable && !selectionInteractionActive
    }

    static func pointerButton(
        isPrimaryPressed: Bool,
        isSecondaryPressed: Bool,
        isMiddlePressed: Bool,
        hasControlModifier: Bool
    ) -> TerminalPointerButton? {
        if isSecondaryPressed {
            return .right
        }

        if isMiddlePressed {
            return .middle
        }

        if isPrimaryPressed {
            return hasControlModifier ? .right : .left
        }

        return nil
    }

    static func shouldShowHostContextMenu(
        button: TerminalPointerButton,
        terminalHandledButtonPress: Bool,
        terminalMouseCaptured: Bool
    ) -> Bool {
        button == .right
            && !terminalHandledButtonPress
            && !terminalMouseCaptured
    }

    static func shouldAllowScrollGesture(
        isIndirectPointer: Bool,
        isPointerButtonPressed: Bool,
        hasActiveTerminalPointerButton: Bool
    ) -> Bool {
        guard isIndirectPointer else { return true }
        return !isPointerButtonPressed && !hasActiveTerminalPointerButton
    }
}

enum TerminalSelectionRoutingPolicy {
    static func shouldAllowHostSelection(terminalMouseCaptured: Bool) -> Bool {
        !terminalMouseCaptured
    }
}

struct TerminalSelectionAutoscrollDecision: Equatable {
    enum Edge: Equatable {
        case top
        case bottom
    }

    let edge: Edge
    let scrollDelta: Double
}

enum TerminalSelectionAutoscrollPolicy {
    static func decision(
        locationY: Double,
        viewportHeight: Double,
        edgeInset: Double,
        maximumScrollDelta: Double
    ) -> TerminalSelectionAutoscrollDecision? {
        guard viewportHeight > 0, edgeInset > 0, maximumScrollDelta > 0 else {
            return nil
        }

        if locationY < edgeInset {
            let distance = min(max(edgeInset - locationY, 0), edgeInset)
            let intensity = max(distance / edgeInset, 0.1)
            return TerminalSelectionAutoscrollDecision(
                edge: .top,
                scrollDelta: maximumScrollDelta * intensity
            )
        }

        let bottomEdge = viewportHeight - edgeInset
        if locationY > bottomEdge {
            let distance = min(max(locationY - bottomEdge, 0), edgeInset)
            let intensity = max(distance / edgeInset, 0.1)
            return TerminalSelectionAutoscrollDecision(
                edge: .bottom,
                scrollDelta: -maximumScrollDelta * intensity
            )
        }

        return nil
    }
}

#if os(iOS)
import UIKit

extension TerminalPointerButton {
    var ghosttyMouseButton: Ghostty.Input.MouseButton {
        switch self {
        case .left:
            .left
        case .right:
            .right
        case .middle:
            .middle
        }
    }
}

extension TerminalPointerInputRoutingPolicy {
    static func ghosttyModifiers(from flags: UIKeyModifierFlags) -> Ghostty.Input.Mods {
        Ghostty.Input.Mods(uiKeyModifiers: flags)
    }

    static func pointerButton(
        for buttonMask: UIEvent.ButtonMask,
        modifiers: UIKeyModifierFlags
    ) -> TerminalPointerButton? {
        pointerButton(
            isPrimaryPressed: buttonMask.contains(.primary),
            isSecondaryPressed: buttonMask.contains(.secondary),
            isMiddlePressed: buttonMask.contains(.button(3)),
            hasControlModifier: modifiers.contains(.control)
        )
    }
}
#endif
