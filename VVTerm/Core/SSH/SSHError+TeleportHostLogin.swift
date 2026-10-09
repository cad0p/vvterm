// SPDX-License-Identifier: MIT
//
//  SSHError+TeleportHostLogin.swift
//  VVTerm
//
//  The connect-time route for a fail-closed Teleport host-login failure.
//
//  A `TeleportHostLoginFailure` means the SSH username cannot be resolved
//  against the certificate being sent. The connect path must clear the row's
//  credential (so readiness flips to `.needsBootstrap` and the setup sheet —
//  with the picker — becomes reachable again) and then fail with the named
//  error. Split out so the clear-on-failure guarantee is unit-testable without
//  a live SSH session.
//
//  This route returns the host's `SSHError`, so it lives in the app target
//  (`Core/SSH`) rather than next to the pure resolver in
//  `Features/Teleport/Domain`: the resolver + failure enum stay package-movable
//  for `cad0p/swift-teleport`, whose package does not know `SSHError`.
//

import Foundation
import TeleportCore

enum TeleportHostLoginFailureRoute {
    /// Clear the credential and produce the connect-path error.
    static func clearAndFail(
        _ failure: TeleportHostLoginFailure,
        store: any TeleportCredentialStore,
        clusterId: UUID
    ) async -> SSHError {
        await store.clear(for: clusterId)
        return .teleportHostLoginUnresolvable(failure)
    }
}
