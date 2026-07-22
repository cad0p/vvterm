nonisolated enum TerminalZenModePolicy {
    nonisolated static func canEnter(
        isTerminalSelected: Bool,
        hasActiveTerminal: Bool
    ) -> Bool {
        isTerminalSelected && hasActiveTerminal
    }

    nonisolated static func resolvedEnabled(
        requested: Bool,
        hasRouteContext: Bool
    ) -> Bool {
        requested && hasRouteContext
    }
}
