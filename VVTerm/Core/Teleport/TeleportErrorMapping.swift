// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportErrorMapping.swift
//  VVTerm
//
//  The host-side mapping from the package-movable `TeleportPackageError`
//  into the app error space.
//
//  Applied at every `SSHSession` call into package code so no
//  `TeleportPackageError` escapes into the app's error handling: the
//  `SSHConnectionRunner` classification (`error as? SSHError` →
//  disconnect-before-retry) and `SSHErrorDiagnostics` rendering depend on
//  seeing the host error type the package error replaced.
//

import Foundation

enum TeleportErrorMapping {
    /// Map any error thrown by package code into the host error space.
    /// Non-package errors pass through unchanged.
    ///
    /// Each case maps back to the exact host error it replaced on
    /// `origin/main` — `SSHError.connectionFailed` for the transport, and
    /// `KeychainError.unhandled` for the keychain — so `errorDescription`
    /// stays byte-identical on every path (including the currently-dead
    /// keychain path).
    static func map(_ error: Error) -> Error {
        guard let packageError = error as? TeleportPackageError else { return error }
        switch packageError {
        case .connectionFailed(let message):
            return SSHError.connectionFailed(message)
        case .keychain(let status):
            return KeychainError.unhandled(status)
        }
    }
}
