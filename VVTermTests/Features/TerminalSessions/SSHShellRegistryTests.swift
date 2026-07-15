import Foundation
import Testing
@testable import VVTerm

struct SSHShellRegistryTests {
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
