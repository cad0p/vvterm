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
//  seeing `SSHError`.
//

import Foundation

extension SSHError {
    /// Map a package error across the seam. `connectionFailed` keeps its
    /// payload verbatim (byte-identical `errorDescription`); the keychain
    /// case has no `SSHError` counterpart and renders as `.unknown` with the
    /// same message.
    init(teleportPackageError: TeleportPackageError) {
        switch teleportPackageError {
        case .connectionFailed(let message):
            self = .connectionFailed(message)
        case .keychain(let status):
            self = .unknown("Keychain error: \(status)")
        }
    }
}

enum TeleportErrorMapping {
    /// Map any error thrown by package code into the host error space.
    /// Non-package errors pass through unchanged.
    static func map(_ error: Error) -> Error {
        guard let packageError = error as? TeleportPackageError else { return error }
        return SSHError(teleportPackageError: packageError)
    }
}
