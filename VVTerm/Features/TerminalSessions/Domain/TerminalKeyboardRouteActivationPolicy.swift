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
        sceneActivation: SceneActivation
    ) -> Effect {
        guard routeVisible, terminalSelected else {
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
