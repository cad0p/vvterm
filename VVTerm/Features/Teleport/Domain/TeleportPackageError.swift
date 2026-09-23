// SPDX-License-Identifier: MIT
//
//  TeleportPackageError.swift
//  VVTerm
//
//  The package-movable error type for the Teleport feature.
//
//  The movable transports + keyring must not throw the host's `SSHError` /
//  `KeychainError`: after the package extraction those types do not exist in
//  the package. `TeleportPackageError` mirrors today's throws, and the host
//  maps it back at the seam boundary (`TeleportErrorMapping`), so the app's
//  `error as? SSHError` classification (disconnect-before-retry, diagnostics
//  rendering) keeps working.
//
//  `LocalizedError` descriptions are byte-identical to the host messages they
//  replace (`SSHError.connectionFailed` → "Connection failed: …",
//  `KeychainError.unhandled` → "Keychain error: …"), so every user-visible
//  string is preserved.
//

import Foundation

enum TeleportPackageError: Error, LocalizedError, Equatable {
    /// A transport-level failure. Mirrors `SSHError.connectionFailed`.
    case connectionFailed(String)
    /// A keychain `OSStatus` failure. Mirrors `KeychainError.unhandled`.
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message): return "Connection failed: \(message)"
        case .keychain(let status): return "Keychain error: \(status)"
        }
    }
}
