// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportKeyRingHost.swift
//  VVTerm
//
//  The single host-side Teleport keyring instance.
//
//  `TeleportKeyRing` is the credential owner (SEP key metadata + cert +
//  cluster TLS state). The movable keyring file must not carry a `static let
//  shared` singleton, so the host provider lives here and is the one
//  instance the whole app uses: the coordinators, the UI readiness reads,
//  and the `SSHSession` credential reads must all see the same object and
//  the same in-memory state (a second instance would split coordinator
//  writes from UI reads).
//

import Foundation

/// The app's single `TeleportKeyRing` instance, wired with the host logging
/// adapter. Constructed once; every host call site reads this provider.
@MainActor
enum TeleportKeyRingHost {
    static let shared = TeleportKeyRing(
        logging: AppTeleportLogging.shared,
        config: .vvterm
    )
}
