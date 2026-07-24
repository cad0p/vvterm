import Foundation

// MARK: - Connection State

enum ConnectionState: Hashable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
    case idle

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        switch self {
        case .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var statusString: String {
        switch self {
        case .disconnected, .idle:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .reconnecting(let attempt):
            return "Reconnecting (\(attempt))..."
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}

enum TerminalConnectionAttemptPolicy {
    static func state(attempt: Int, hasEstablishedConnection: Bool) -> ConnectionState {
        if hasEstablishedConnection || attempt > 1 {
            return .reconnecting(attempt: attempt)
        }
        return .connecting
    }
}
