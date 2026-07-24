#if os(iOS)
enum TerminalKeyboardRouteActivationPolicy {
    enum SceneActivation {
        case foregroundActive
        case foregroundInactive
        case background
    }

    enum Effect: Equatable {
        case activate
        case preserve
        case deactivate
    }

    enum WindowOwnership: Equatable {
        case unknown
        case key
        case notKey
    }

    enum PresentationOwnership: Equatable {
        case terminal
        case routeModal
    }

    static func effect(
        routeVisible: Bool,
        terminalSelected: Bool,
        sceneActivation: SceneActivation,
        windowOwnership: WindowOwnership = .unknown,
        presentationOwnership: PresentationOwnership = .terminal,
        contentObscured: Bool = false
    ) -> Effect {
        guard routeVisible,
              terminalSelected,
              presentationOwnership == .terminal,
              !contentObscured else {
            return .deactivate
        }
        switch sceneActivation {
        case .foregroundActive:
            return windowOwnership == .notKey ? .deactivate : .activate
        case .foregroundInactive, .background:
            // UIKit preserves a native text field's first-responder ownership
            // while its app is inactive or backgrounded. Keep the terminal's
            // input session equally stable and let the system move InputUI.
            return .preserve
        }
    }
}
#endif
