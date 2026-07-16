import Foundation
import Testing
@testable import VVTerm

struct SSHShellRegistryTests {
    @Test
    func shellStartExpiresAtStaleThreshold() {
        let paneId = UUID()
        let serverId = UUID()
        let client = SSHClient()
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var registry = SSHShellRegistry(staleThreshold: 120)

        #expect(registry.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: client,
            now: startedAt
        ).started)

        let beforeThreshold = registry.isStartInFlight(
            for: paneId,
            now: startedAt.addingTimeInterval(119.999)
        )
        #expect(beforeThreshold.inFlight)
        #expect(beforeThreshold.staleContext == nil)

        let atThreshold = registry.isStartInFlight(
            for: paneId,
            now: startedAt.addingTimeInterval(120)
        )
        #expect(!atThreshold.inFlight)
        #expect(atThreshold.staleContext?.client === client)
        #expect(!registry.ownsConnection(client: client, for: paneId))
    }

    @Test
    func connectionClientIncludesPendingShellStart() {
        let paneId = UUID()
        let client = SSHClient()
        var registry = SSHShellRegistry(staleThreshold: 120)

        #expect(registry.tryBeginStart(
            for: paneId,
            serverId: UUID(),
            client: client
        ).started)
        #expect(registry.client(for: paneId) == nil)
        #expect(registry.connectionClient(for: paneId) === client)
    }

    @Test
    func drainingBackgroundShellsDoesNotOwnReplacementStart() {
        let paneId = UUID()
        let serverId = UUID()
        let oldClient = SSHClient()
        let replacementClient = SSHClient()
        var registry = SSHShellRegistry(staleThreshold: 120)

        #expect(registry.tryBeginStart(for: paneId, serverId: serverId, client: oldClient).started)
        _ = registry.register(
            client: oldClient,
            shellId: UUID(),
            for: paneId,
            serverId: serverId,
            transport: .ssh,
            fallbackReason: nil
        )

        let detached = registry.drain()
        let replacement = registry.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: replacementClient
        )
        let staleRegistration = registry.register(
            client: oldClient,
            shellId: UUID(),
            for: paneId,
            serverId: serverId,
            transport: .ssh,
            fallbackReason: nil
        )

        #expect(detached.registrations.count == 1)
        #expect(detached.pendingStarts.isEmpty)
        #expect(staleRegistration == .stale)
        #expect(replacement.started)
        #expect(registry.ownsConnection(client: replacementClient, for: paneId))
        #expect(!registry.ownsConnection(client: oldClient, for: paneId))
    }
}
