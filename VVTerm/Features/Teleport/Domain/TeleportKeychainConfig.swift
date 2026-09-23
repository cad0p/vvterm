// SPDX-License-Identifier: MIT
//
//  TeleportKeychainConfig.swift
//  VVTerm
//
//  The package-movable persistence config for the Teleport keyring: the
//  keychain service name and the `UserDefaults` store used for the cert /
//  metadata / cluster-TLS state.
//
//  The movable keyring file must not name `UserDefaults.standard` or the
//  literal `app.vivy.vvterm` service; the host passes both at the
//  composition root (`TeleportKeychainConfig.vvterm`), and package tests
//  pass a suite-scoped `UserDefaults`.
//

import Foundation

struct TeleportKeychainConfig: @unchecked Sendable {
    /// The keychain service used for the per-cluster ed25519 private key.
    let keychainService: String

    /// The defaults store holding the credential metadata + cluster TLS
    /// state. `UserDefaults` is thread-safe, hence the `@unchecked Sendable`
    /// on this config.
    let defaults: UserDefaults

    init(keychainService: String, defaults: UserDefaults) {
        self.keychainService = keychainService
        self.defaults = defaults
    }
}
