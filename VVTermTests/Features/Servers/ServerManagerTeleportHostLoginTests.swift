// SPDX-License-Identifier: MIT
//
//  ServerManagerTeleportHostLoginTests.swift
//  VVTermTests
//
//  Persistence coverage for `Server.teleportHostLogin` through
//  `ServerManager`'s field-rebuild paths:
//    - a name-only `updateServer` edit preserves the stored login (and other
//      fields — `isFavorite`, `cloudflareAppDomainOverride` — so a future
//      field drop is caught);
//    - `addServer` persists the login it was given;
//    - `setTeleportHostLogin` is the one persist API the setup picker calls.
//
//  Uses the shared manager (there is no composition-root injection today) and
//  disables iCloud sync for the duration so the test never attempts a
//  network drain.
//

import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct ServerManagerTeleportHostLoginTests {

    /// Runs `body` with sync disabled, the manager's in-memory server list
    /// restored afterwards, and the persisted `servers`/`workspaces` keys
    /// snapshotted and restored so the fixtures never leak into other suites.
    private func withIsolatedManager<T>(_ body: (ServerManager) async throws -> T) async rethrows -> T {
        let manager = ServerManager.shared
        let savedServers = manager.servers
        let savedSyncFlag = UserDefaults.standard.object(forKey: CloudKitSyncConstants.syncEnabledKey)
        let savedServersData = UserDefaults.standard.object(forKey: CloudKitSyncConstants.serverStorageKey)
        let savedWorkspacesData = UserDefaults.standard.object(forKey: CloudKitSyncConstants.workspaceStorageKey)
        UserDefaults.standard.set(false, forKey: CloudKitSyncConstants.syncEnabledKey)
        defer {
            if let savedSyncFlag {
                UserDefaults.standard.set(savedSyncFlag, forKey: CloudKitSyncConstants.syncEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: CloudKitSyncConstants.syncEnabledKey)
            }
            manager.servers = savedServers
            Self.restore(savedServersData, forKey: CloudKitSyncConstants.serverStorageKey)
            Self.restore(savedWorkspacesData, forKey: CloudKitSyncConstants.workspaceStorageKey)
        }
        return try await body(manager)
    }

    private static func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeFixture(teleportHostLogin: String? = "deploy") -> Server {
        Server(
            id: UUID(),
            workspaceId: UUID(),
            name: "host-login-fixture",
            host: "teleport.example.com",
            port: 443,
            username: "pier",
            teleportHostLogin: teleportHostLogin,
            authMethod: .faceIDTeleport,
            cloudflareAppDomainOverride: "app.example.com",
            isFavorite: true
        )
    }

    @Test
    func updateServerNameOnlyEditPreservesTeleportHostLoginAndOtherFields() async throws {
        try await withIsolatedManager { manager in
            let server = makeFixture()
            manager.servers = [server]
            try await manager.updateServer(server)

            var renamed = try #require(manager.servers.first(where: { $0.id == server.id }))
            renamed.name = "host-login-fixture-renamed"
            try await manager.updateServer(renamed)

            let stored = try #require(manager.servers.first(where: { $0.id == server.id }))
            #expect(stored.name == "host-login-fixture-renamed")
            #expect(
                stored.teleportHostLogin == "deploy",
                "a name-only edit must not drop the stored host login (the rebuild list must carry it)"
            )
            #expect(stored.isFavorite, "unrelated fields must survive the rebuild")
            #expect(stored.cloudflareAppDomainOverride == "app.example.com")
        }
    }

    @Test
    func addServerPersistsTeleportHostLogin() async throws {
        try await withIsolatedManager { manager in
            manager.servers = []
            let server = makeFixture()
            try await manager.addServer(server, credentials: ServerCredentials(serverId: server.id))

            let stored = try #require(manager.servers.first(where: { $0.id == server.id }))
            #expect(stored.teleportHostLogin == "deploy")
        }
    }

    @Test
    func setTeleportHostLoginPersistsThePickedLoginAndRejectsInvalidValues() async throws {
        try await withIsolatedManager { manager in
            var server = makeFixture(teleportHostLogin: nil)
            manager.servers = [server]
            try await manager.updateServer(server)

            try await manager.setTeleportHostLogin("root", for: server.id)

            server = try #require(manager.servers.first(where: { $0.id == server.id }))
            #expect(server.teleportHostLogin == "root")

            // A shape-invalid value must be rejected, never persisted, and
            // must not clear the previously stored login.
            do {
                try await manager.setTeleportHostLogin("  ", for: server.id)
                Issue.record("a shape-invalid host login must not persist")
            } catch {
                // expected
            }
            server = try #require(manager.servers.first(where: { $0.id == server.id }))
            #expect(server.teleportHostLogin == "root")
        }
    }

    @Test
    func setTeleportHostLoginThrowsForAnUnknownRow() async throws {
        try await withIsolatedManager { manager in
            manager.servers = []
            do {
                try await manager.setTeleportHostLogin("root", for: UUID())
                Issue.record("an unknown row must not report success")
            } catch {
                // expected: the caller keeps the sheet open on failure
            }
        }
    }
}
