import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct KnownHostsManagerTests {
    @Test
    func removeDeletesOnlyRequestedHostAndPort() {
        let manager = KnownHostsManager.shared
        manager.removeAll()
        defer { manager.removeAll() }

        manager.save(entry: KnownHostsManager.Entry(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:first",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        ))
        manager.save(entry: KnownHostsManager.Entry(
            host: "example.com",
            port: 2222,
            fingerprint: "SHA256:second",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        ))

        manager.remove(host: "example.com", port: 22)

        #expect(manager.entry(for: "example.com", port: 22) == nil)
        #expect(manager.entry(for: "example.com", port: 2222)?.fingerprint == "SHA256:second")
    }

    @Test
    func removeAllClearsSavedHosts() {
        let manager = KnownHostsManager.shared
        manager.removeAll()
        defer { manager.removeAll() }

        manager.save(entry: KnownHostsManager.Entry(
            host: "host.local",
            port: 22,
            fingerprint: "SHA256:host",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        ))

        #expect(manager.entries().count == 1)

        manager.removeAll()

        #expect(manager.entries().isEmpty)
    }

    // MARK: - Pending first-use entries

    @Test
    func pendingEntryIsNotPersistedUntilConfirmed() {
        let manager = KnownHostsManager.shared
        manager.removeAll()
        defer { manager.removeAll() }

        manager.recordPending(entry: KnownHostsManager.Entry(
            host: "new.example.com",
            port: 22,
            fingerprint: "SHA256:new",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        ))

        // The first-use key must not be trusted before the user confirms it.
        #expect(manager.entry(for: "new.example.com", port: 22) == nil)
        #expect(manager.pendingEntry(for: "new.example.com", port: 22)?.fingerprint == "SHA256:new")

        #expect(manager.confirmPending(host: "new.example.com", port: 22))
        #expect(manager.entry(for: "new.example.com", port: 22)?.fingerprint == "SHA256:new")
        #expect(manager.pendingEntry(for: "new.example.com", port: 22) == nil)
    }

    @Test
    func confirmingWithoutAPendingEntryDoesNothing() {
        let manager = KnownHostsManager.shared
        manager.removeAll()
        defer { manager.removeAll() }

        #expect(!manager.confirmPending(host: "missing.example.com", port: 22))
        #expect(manager.entry(for: "missing.example.com", port: 22) == nil)
    }

    @Test
    func discardPendingDropsTheFirstUseKey() {
        let manager = KnownHostsManager.shared
        manager.removeAll()
        defer { manager.removeAll() }

        manager.recordPending(entry: KnownHostsManager.Entry(
            host: "discard.example.com",
            port: 22,
            fingerprint: "SHA256:discard",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        ))
        manager.discardPending(host: "discard.example.com", port: 22)

        #expect(manager.pendingEntry(for: "discard.example.com", port: 22) == nil)
        #expect(manager.entry(for: "discard.example.com", port: 22) == nil)
    }
}
