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
        guard windowOwnership != .notKey else {
            return .deactivate
        }

        switch sceneActivation {
        case .foregroundActive:
            return .activate
        case .foregroundInactive:
            return .preserve
        case .background:
            return .deactivate
        }
    }
}
#endif
