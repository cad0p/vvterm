import Foundation

// MARK: - Terminal Connection Attempt Policy
//
// `ConnectionState` itself is defined in `ConnectionSession.swift`.
// This file originally duplicated it (causing "'ConnectionState' is ambiguous"
// compile errors); the duplicate has been removed. Only the policy helper
// remains here.

enum TerminalConnectionAttemptPolicy {
    static func state(attempt: Int, hasEstablishedConnection: Bool) -> ConnectionState {
        if hasEstablishedConnection || attempt > 1 {
            return .reconnecting(attempt: attempt)
        }
        return .connecting
    }
}
