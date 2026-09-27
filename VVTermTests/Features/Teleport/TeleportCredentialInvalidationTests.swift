// SPDX-License-Identifier: MIT
//
//  TeleportCredentialInvalidationTests.swift
//  VVTermTests
//
//  Coverage for the Teleport credential invalidation rule:
//    - the pure policy (host change clears; same-host rename back to the
//      credential's own user keeps; node-name/port never clears; a row with no
//      credential is untouched);
//    - the local `updateServer` trigger;
//    - both CloudKit merge paths (full fetch + incremental upsert);
//    - both delete paths (`deleteServer` + the sync `removeServers`).
//

#if DEBUG
import Foundation
import Testing
@testable import VVTerm

/// A recording `TeleportCredentialInvalidating` fake. `credentials` maps a
/// server id to the credential's cert keyID (nil = record without a cert, as a
/// reuse-seeded record has).
@MainActor
final class RecordingTeleportCredentialInvalidator: TeleportCredentialInvalidating {
    private(set) var credentials: [UUID: String?] = [:]
    private(set) var cleared: [UUID] = []

    func seedCredential(for serverId: UUID, certKeyID: String?) {
        credentials[serverId] = certKeyID
    }

    func hasCredential(for serverId: UUID) -> Bool {
        credentials.keys.contains(serverId)
    }

    func certKeyID(for serverId: UUID) -> String? {
        credentials[serverId] ?? nil
    }

    func clearCredential(for serverId: UUID) {
        cleared.append(serverId)
        credentials.removeValue(forKey: serverId)
    }
}

struct TeleportCredentialInvalidationPolicyTests {

    @Test
    func noCredentialNeverClears() {
        #expect(
            !TeleportCredentialInvalidationPolicy.shouldClearCredential(
                oldHost: "old.example.com",
                newHost: "new.example.com",
                oldUsername: "pier",
                newUsername: "deploy",
                hasCredential: false,
                certKeyID: "pier"
            )
        )
    }

    @Test
    func hostChangeClears() {
        #expect(
            TeleportCredentialInvalidationPolicy.shouldClearCredential(
                oldHost: "old.example.com",
                newHost: "new.example.com",
                oldUsername: "pier",
                newUsername: "pier",
                hasCredential: true,
                certKeyID: "pier"
            )
        )
    }

    @Test
    func usernameChangeToADifferentUserClears() {
        #expect(
            TeleportCredentialInvalidationPolicy.shouldClearCredential(
                oldHost: "teleport.example.com",
                newHost: "teleport.example.com",
                oldUsername: "pier",
                newUsername: "someone-else",
                hasCredential: true,
                certKeyID: "pier"
            )
        )
    }

    @Test
    func usernameChangeWithNoCertClears() {
        // A seeded record has no cert keyID; a username edit must still clear.
        #expect(
            TeleportCredentialInvalidationPolicy.shouldClearCredential(
                oldHost: "teleport.example.com",
                newHost: "teleport.example.com",
                oldUsername: "pier",
                newUsername: "someone-else",
                hasCredential: true,
                certKeyID: nil
            )
        )
    }

    @Test
    func sameHostRenameBackToTheCredentialsOwnUserKeeps() {
        #expect(
            !TeleportCredentialInvalidationPolicy.shouldClearCredential(
                oldHost: "teleport.example.com",
                newHost: "teleport.example.com",
                oldUsername: "typo",
                newUsername: "pier",
                hasCredential: true,
                certKeyID: "pier"
            )
        )
    }

    @Test
    func nodeNameOrPortChangesNeverClear() {
        // The policy only sees host/username; a node-name or port edit leaves
        // both unchanged.
        #expect(
            !TeleportCredentialInvalidationPolicy.shouldClearCredential(
                oldHost: "teleport.example.com",
                newHost: "teleport.example.com",
                oldUsername: "pier",
                newUsername: "pier",
                hasCredential: true,
                certKeyID: "pier"
            )
        )
    }
}

@Suite(.serialized)
@MainActor
struct TeleportCredentialInvalidationWiringTests {

    /// A manager with a recording invalidator, iCloud sync disabled for the
    /// duration, and an empty server list to start from.
    private func withManager<T>(
        _ body: (ServerManager, RecordingTeleportCredentialInvalidator) async throws -> T
    ) async rethrows -> T {
        let savedSyncFlag = UserDefaults.standard.object(forKey: CloudKitSyncConstants.syncEnabledKey)
        UserDefaults.standard.set(false, forKey: CloudKitSyncConstants.syncEnabledKey)
        defer {
            if let savedSyncFlag {
                UserDefaults.standard.set(savedSyncFlag, forKey: CloudKitSyncConstants.syncEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: CloudKitSyncConstants.syncEnabledKey)
            }
        }
        let invalidator = RecordingTeleportCredentialInvalidator()
        let manager = ServerManager(teleportCredentialInvalidator: invalidator)
        let savedServers = manager.servers
        manager.servers = []
        defer { manager.servers = savedServers }
        return try await body(manager, invalidator)
    }

    private func makeServer(
        id: UUID = UUID(),
        name: String = "fixture",
        host: String = "teleport.example.com",
        username: String = "pier"
    ) -> Server {
        Server(
            id: id,
            workspaceId: UUID(),
            name: name,
            host: host,
            port: 443,
            username: username,
            teleportHostLogin: "deploy",
            authMethod: .faceIDTeleport
        )
    }

    @Test
    func updateServerHostChangeClearsTheCredential() async throws {
        try await withManager { manager, invalidator in
            let server = makeServer()
            manager.servers = [server]
            invalidator.seedCredential(for: server.id, certKeyID: "pier")

            var edited = server
            edited.host = "other.example.com"
            try await manager.updateServer(edited)

            #expect(invalidator.cleared == [server.id])
        }
    }

    @Test
    func updateServerNameOnlyChangeKeepsTheCredential() async throws {
        try await withManager { manager, invalidator in
            let server = makeServer()
            manager.servers = [server]
            invalidator.seedCredential(for: server.id, certKeyID: "pier")

            var edited = server
            edited.name = "renamed-node"
            edited.port = 3023
            try await manager.updateServer(edited)

            #expect(invalidator.cleared.isEmpty)
        }
    }

    @Test
    func fullFetchMergeHostChangeClearsTheCredential() async throws {
        try await withManager { manager, invalidator in
            let server = makeServer()
            manager.servers = [server]
            invalidator.seedCredential(for: server.id, certKeyID: "pier")

            var remote = server
            remote.host = "remote-edited.example.com"
            manager.applyCloudKitChanges(
                CloudKitChanges(
                    servers: [remote],
                    workspaces: [],
                    deletedServerIDs: [],
                    deletedWorkspaceIDs: [],
                    isFullFetch: true
                )
            )

            #expect(invalidator.cleared == [server.id])
            #expect(manager.servers.first?.host == "remote-edited.example.com")
        }
    }

    @Test
    func incrementalMergeUsernameChangeClearsTheCredential() async throws {
        try await withManager { manager, invalidator in
            let server = makeServer()
            manager.servers = [server]
            invalidator.seedCredential(for: server.id, certKeyID: "pier")

            var remote = server
            remote.username = "someone-else"
            manager.applyCloudKitChanges(
                CloudKitChanges(
                    servers: [remote],
                    workspaces: [],
                    deletedServerIDs: [],
                    deletedWorkspaceIDs: [],
                    isFullFetch: false
                )
            )

            #expect(invalidator.cleared == [server.id])
        }
    }

    @Test
    func incrementalMergeSameHostRenameBackKeepsTheCredential() async throws {
        try await withManager { manager, invalidator in
            let server = makeServer(username: "typo")
            manager.servers = [server]
            invalidator.seedCredential(for: server.id, certKeyID: "pier")

            var remote = server
            remote.username = "pier"
            manager.applyCloudKitChanges(
                CloudKitChanges(
                    servers: [remote],
                    workspaces: [],
                    deletedServerIDs: [],
                    deletedWorkspaceIDs: [],
                    isFullFetch: false
                )
            )

            #expect(invalidator.cleared.isEmpty)
        }
    }

    @Test
    func deleteServerClearsTheCredentialRecord() async throws {
        try await withManager { manager, invalidator in
            let server = makeServer()
            manager.servers = [server]
            invalidator.seedCredential(for: server.id, certKeyID: "pier")

            try await manager.deleteServer(server)

            #expect(invalidator.cleared == [server.id])
        }
    }

    @Test
    func syncRemovalClearsTheCredentialRecord() async throws {
        try await withManager { manager, invalidator in
            let server = makeServer()
            manager.servers = [server]
            invalidator.seedCredential(for: server.id, certKeyID: "pier")

            manager.applyCloudKitChanges(
                CloudKitChanges(
                    servers: [],
                    workspaces: [],
                    deletedServerIDs: [server.id],
                    deletedWorkspaceIDs: [],
                    isFullFetch: false
                )
            )

            #expect(invalidator.cleared == [server.id])
            #expect(manager.servers.isEmpty)
        }
    }
}
#endif
