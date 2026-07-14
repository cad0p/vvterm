import Foundation

enum TmuxSessionOwnership: String, Codable, Hashable, Sendable {
    case managed
    case external
}

struct TmuxShellLifecycleContext: Hashable, Sendable {
    let ownership: TmuxSessionOwnership
    let markerToken: String
    let presenceProbe: TmuxSessionPresenceProbe
}

struct TmuxSessionPresenceProbe: Hashable, Sendable {
    let command: String
    let existsMarker: String
    let missingMarker: String

    nonisolated func sessionExists(in output: String) -> Bool? {
        if output.contains(existsMarker) {
            return true
        }
        if output.contains(missingMarker) {
            return false
        }
        return nil
    }
}

struct TerminalShellStartupPlan: Sendable {
    let command: String?
    let skipTmuxLifecycle: Bool
    let tmuxLifecycle: TmuxShellLifecycleContext?

    static let plainShell = TerminalShellStartupPlan(
        command: nil,
        skipTmuxLifecycle: true,
        tmuxLifecycle: nil
    )
}

enum TerminalShellEndReason: Hashable, Sendable {
    case transportEnded
    case tmuxDetached(TmuxSessionOwnership)
    case tmuxEnded(TmuxSessionOwnership)
    case tmuxCreationFailed

    nonisolated static func resolve(
        tmuxLifecycle: TmuxShellLifecycleContext?,
        markerEvent: TmuxLifecycleEvent?,
        sessionExists: Bool?
    ) -> Self {
        guard let tmuxLifecycle else {
            return .transportEnded
        }

        switch markerEvent {
        case .detached:
            return .tmuxDetached(tmuxLifecycle.ownership)
        case .ended:
            return .tmuxEnded(tmuxLifecycle.ownership)
        case .creationFailed:
            return .tmuxCreationFailed
        case nil:
            switch sessionExists {
            case true:
                return .tmuxDetached(tmuxLifecycle.ownership)
            case false:
                return .tmuxEnded(tmuxLifecycle.ownership)
            case nil:
                return .transportEnded
            }
        }
    }
}

enum TerminalDisconnectReason: String, Codable, Hashable, Sendable {
    case transportEnded
    case tmuxDetached
    case externalTmuxEnded

    var allowsAutomaticReconnect: Bool {
        self == .transportEnded
    }
}

enum ManagedTmuxCleanupDisposition {
    case terminate
    case alreadyTerminated
}
