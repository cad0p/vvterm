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

    static func effect(
        routeVisible: Bool,
        terminalSelected: Bool,
        sceneActivation: SceneActivation,
        contentObscured: Bool = false
    ) -> Effect {
        guard routeVisible, terminalSelected, !contentObscured else {
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
