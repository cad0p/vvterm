// SPDX-License-Identifier: MIT
//
//  ServerFormTeleportReminder.swift
//  VVTerm
//
//  When the server form shows the "changing the Teleport user or host re-runs
//  Teleport setup on this device" reminder (#265).
//

import Foundation

/// The reminder is about **re-running** Teleport setup, so it requires a row
/// that already has Teleport setup: an existing `.faceIDTeleport` server.
///
/// A new server (Add) has no setup to re-run, and switching an existing
/// password row to Face ID (Teleport) has nothing to re-run either — which is
/// why the gate is the *existing* row's auth method, not `isEditing` alone.
/// Kept as a pure rule so the whole case matrix is unit-testable (the UI tests
/// only cover Add and edit-a-Teleport-row, the two acceptance cases).
enum ServerFormTeleportReminder {
    static func showsReminder(
        existingServer: Server?,
        selectedAuthMethod: AuthMethod
    ) -> Bool {
        selectedAuthMethod == .faceIDTeleport && existingServer?.authMethod == .faceIDTeleport
    }
}
