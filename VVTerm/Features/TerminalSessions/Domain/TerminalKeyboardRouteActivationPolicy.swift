#if os(iOS)
enum TerminalKeyboardRouteActivationPolicy {
    enum SceneActivation {
        case foregroundActive
        case foregroundInactive
        case background
    }

    enum Effect: Equatable {
        case activate
        /// Preserve the user's typing intent while relinquishing UIKit's
        /// first-responder ownership until this scene becomes locally active.
        case suspend
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
            return .suspend
        }
    }
}
#endif
