import Foundation
import MoshCore
import Testing
@testable import VVTerm

private final class InMemoryMoshResumeSecretStore: MoshResumeSecretStoring {
    private var values: [String: Data] = [:]

    func set(_ data: Data, forKey key: String, iCloudSync: Bool) throws {
        values[key] = data
    }

    func get(_ key: String) throws -> Data? {
        values[key]
    }

    func delete(_ key: String) throws {
        values.removeValue(forKey: key)
    }
}

private final class InMemoryMoshResumeStore: MoshResumeStoring {
    private var snapshots: [UUID: MoshSnapshot] = [:]

    func snapshot(for paneId: UUID) throws -> MoshSnapshot? {
        snapshots[paneId]
    }

    func hasSnapshot(for paneId: UUID) -> Bool {
        snapshots[paneId] != nil
    }

    func save(_ snapshot: MoshSnapshot, for paneId: UUID) throws {
        snapshots[paneId] = snapshot
    }

    func deleteSnapshot(for paneId: UUID) throws {
        snapshots.removeValue(forKey: paneId)
    }
}

@Suite(.serialized)
@MainActor
struct MoshResumeStoreTests {
    private func snapshot() -> MoshSnapshot {
        MoshSnapshot(
            endpoint: MoshEndpoint(
                host: "example.com",
                port: 60001,
                keyBase64_22: "abcdefghijklmnopqrstuv"
            ),
            transportState: Data("protocol-state".utf8),
            createdAtMs: 42,
            schemaVersion: 2
        )
    }

    @Test
    func snapshotSeparatesSecretFromProtectedCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vvterm-mosh-checkpoint-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let secretStore = InMemoryMoshResumeSecretStore()
        let store = MoshResumeStore(
            keychain: secretStore,
            checkpointDirectory: directory
        )
        let paneId = UUID()
        let expected = snapshot()

        #expect(!store.hasSnapshot(for: paneId))
        try store.save(expected, for: paneId)
        #expect(store.hasSnapshot(for: paneId))
        #expect(try store.snapshot(for: paneId) == expected)

        let file = try #require(FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first)
        let checkpointData = try Data(contentsOf: file)
        #expect(!checkpointData.contains(Data(expected.endpoint.keyBase64_22.utf8)))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
            as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test
    func keychainReferenceIsStableAndContainsNoSecret() throws {
        let paneId = try #require(
            UUID(uuidString: "50E3AEE5-FD59-4DA0-A07D-67093EFF6AA2")
        )
        let key = MoshResumeStore.key(for: paneId)

        #expect(key == "terminal.mosh.resume.50e3aee5-fd59-4da0-a07d-67093eff6aa2")
        #expect(!key.contains(snapshot().endpoint.keyBase64_22))
    }

    @Test
    func explicitCloseDeletesSnapshotButApplicationTerminationPreservesIt() async throws {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()

        do {
            let store = InMemoryMoshResumeStore()
            manager.setMoshResumeStoreForTesting(store)
            let serverId = UUID()

            let closedTab = TerminalTab(serverId: serverId, title: "Close")
            manager.tabsByServer[serverId] = [closedTab]
            manager.selectedTabByServer[serverId] = closedTab.id
            manager.paneStates[closedTab.rootPaneId] = TerminalPaneState(
                paneId: closedTab.rootPaneId,
                tabId: closedTab.id,
                serverId: serverId
            )
            try store.save(snapshot(), for: closedTab.rootPaneId)

            manager.closeTab(closedTab)
            #expect(try store.snapshot(for: closedTab.rootPaneId) == nil)

            let preservedTab = TerminalTab(serverId: serverId, title: "Terminate")
            manager.tabsByServer[serverId] = [preservedTab]
            manager.selectedTabByServer[serverId] = preservedTab.id
            manager.paneStates[preservedTab.rootPaneId] = TerminalPaneState(
                paneId: preservedTab.rootPaneId,
                tabId: preservedTab.id,
                serverId: serverId
            )
            let expected = snapshot()
            try store.save(expected, for: preservedTab.rootPaneId)

            await manager.beginApplicationTermination().value

            #expect(try store.snapshot(for: preservedTab.rootPaneId) == expected)
            #expect(manager.tabs(for: serverId).map(\.id) == [preservedTab.id])
        } catch {
            await manager.resetForTesting()
            throw error
        }
        await manager.resetForTesting()
    }

    @Test
    func onlyPermanentlyInvalidSnapshotsAreDiscarded() {
        #expect(MoshResumePolicy.shouldDiscardSnapshot(after: .invalidEndpoint))
        #expect(MoshResumePolicy.shouldDiscardSnapshot(after: .badSnapshotSchema(99)))
        #expect(MoshResumePolicy.shouldDiscardSnapshot(after: .decodeFailure))
        #expect(MoshResumePolicy.shouldDiscardSnapshot(
            after: .sessionFailed(.authenticationFailure("invalid key"))
        ))
        #expect(!MoshResumePolicy.shouldDiscardSnapshot(
            after: .sessionFailed(.transportFailure("offline"))
        ))
        #expect(!MoshResumePolicy.shouldDiscardSnapshot(after: .notStarted))
    }
}
