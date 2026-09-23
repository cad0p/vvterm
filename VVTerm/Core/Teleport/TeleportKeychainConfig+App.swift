// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportKeychainConfig+App.swift
//  VVTerm
//
//  The host-side `TeleportKeychainConfig` for the app: the same keychain
//  service the app has always used and `UserDefaults.standard`.
//

import Foundation

extension TeleportKeychainConfig {
    /// The app's production config. The keychain service matches
    /// `KeychainManager`'s service (the per-cluster ed25519 key lives under
    /// it), and the defaults store is the standard app domain.
    static let vvterm = TeleportKeychainConfig(
        keychainService: "app.vivy.vvterm",
        defaults: .standard
    )
}
