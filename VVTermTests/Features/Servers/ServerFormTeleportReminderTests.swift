// SPDX-License-Identifier: MIT
//
//  ServerFormTeleportReminderTests.swift
//  VVTermTests
//
//  The #265 reminder gate: the "changing the Teleport user or host re-runs
//  Teleport setup on this device" caption is shown only for an existing
//  Teleport row being edited.
//

import XCTest
@testable import VVTerm

@MainActor
final class ServerFormTeleportReminderTests: XCTestCase {

    private func server(authMethod: AuthMethod) -> Server {
        Server(
            workspaceId: UUID(),
            name: "teleport-node",
            host: "teleport.example.com",
            username: "alice",
            authMethod: authMethod
        )
    }

    /// Add mode: no existing row, so there is no setup to re-run (#265's
    /// first acceptance case).
    func testAddModeNeverShowsTheReminder() {
        XCTAssertFalse(
            ServerFormTeleportReminder.showsReminder(
                existingServer: nil,
                selectedAuthMethod: .faceIDTeleport
            )
        )
    }

    /// Editing an existing Teleport row: the reminder's case (#265's second
    /// acceptance case).
    func testEditingATeleportRowShowsTheReminder() {
        XCTAssertTrue(
            ServerFormTeleportReminder.showsReminder(
                existingServer: server(authMethod: .faceIDTeleport),
                selectedAuthMethod: .faceIDTeleport
            )
        )
    }

    /// The distinguishing case: switching an existing password row to Face ID
    /// (Teleport) has nothing to re-run, so no reminder. This is the case a
    /// bare `isEditing` gate would get wrong, and it is the reason the gate
    /// consults the existing row's auth method.
    func testSwitchingAPasswordRowToTeleportDoesNotShowTheReminder() {
        XCTAssertFalse(
            ServerFormTeleportReminder.showsReminder(
                existingServer: server(authMethod: .password),
                selectedAuthMethod: .faceIDTeleport
            )
        )
    }

    /// Editing a Teleport row that is switched away from Teleport has nothing
    /// to remind about either.
    func testSwitchingATeleportRowAwayFromTeleportDoesNotShowTheReminder() {
        XCTAssertFalse(
            ServerFormTeleportReminder.showsReminder(
                existingServer: server(authMethod: .faceIDTeleport),
                selectedAuthMethod: .password
            )
        )
    }

    /// A password row left on password never shows the reminder.
    func testPasswordRowWithPasswordSelectionDoesNotShowTheReminder() {
        XCTAssertFalse(
            ServerFormTeleportReminder.showsReminder(
                existingServer: server(authMethod: .password),
                selectedAuthMethod: .password
            )
        )
    }
}
