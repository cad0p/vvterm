import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct ConnectionLifecycleIntegrationTests {
    private func makeServer(
        id: UUID = UUID(),
        workspaceId: UUID = UUID(),
        name: String = "Test",
        connectionMode: SSHConnectionMode = .cloudflare
    ) -> Server {
        Server(
            id: id,
            workspaceId: workspaceId,
            name: name,
            host: "ssh.example.com",
            username: "root",
            connectionMode: connectionMode
        )
    }

    private func makeCredentials(serverId: UUID) -> ServerCredentials {
        ServerCredentials(
            serverId: serverId,
            password: nil,
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: nil,
            cloudflareClientSecret: nil
        )
    }

    private func withCleanConnectionManager(
        _ body: @MainActor (ConnectionSessionManager) async throws -> Void
    ) async rethrows {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
        }
    }

    private func withServerList<T>(
        _ servers: [Server],
        _ body: @MainActor () async throws -> T
    ) async rethrows -> T {
        let serverManager = ServerManager.shared
        let originalServers = serverManager.servers
        serverManager.servers = servers
        defer { serverManager.servers = originalServers }
        return try await body()
    }

    private func withCleanTabManager(
        _ body: @MainActor (TerminalTabManager) async throws -> Void
    ) async rethrows {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
        }
    }

    @Test
    func connectionManagerRejectsStaleRegistrationFromDifferentClient() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Session A",
                connectionState: .connecting
            )
            manager.sessions = [session]

            let activeClient = SSHClient()
            let staleClient = SSHClient()

            #expect(manager.tryBeginShellStart(for: session.id, client: activeClient))

            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            #expect(manager.shellId(for: session.id) == nil)
            #expect(manager.isShellStartInFlight(for: session.id))

            manager.finishShellStart(for: session.id, client: staleClient)
            #expect(manager.isShellStartInFlight(for: session.id))

            manager.finishShellStart(for: session.id, client: activeClient)
            #expect(!manager.isShellStartInFlight(for: session.id))
        }
    }

    @Test
    func connectionManagerUnregisterWithoutShellClearsPendingStart() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Session B",
                connectionState: .connecting
            )
            manager.sessions = [session]

            let firstClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: session.id, client: firstClient))

            await manager.unregisterSSHClient(for: session.id)
            #expect(!manager.isShellStartInFlight(for: session.id))
            #expect(manager.shellId(for: session.id) == nil)

            let nextClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: session.id, client: nextClient))
            manager.finishShellStart(for: session.id, client: nextClient)
        }
    }

    @Test
    func tabManagerRejectsStaleRegistrationFromDifferentClient() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let tabId = UUID()
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: tabId,
                serverId: serverId
            )

            let activeClient = SSHClient()
            let staleClient = SSHClient()

            #expect(manager.tryBeginShellStart(for: paneId, client: activeClient))

            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: paneId,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            #expect(manager.shellId(for: paneId) == nil)
            #expect(manager.isShellStartInFlight(for: paneId))

            manager.finishShellStart(for: paneId, client: staleClient)
            #expect(manager.isShellStartInFlight(for: paneId))

            manager.finishShellStart(for: paneId, client: activeClient)
            #expect(!manager.isShellStartInFlight(for: paneId))
        }
    }

    @Test
    func tabManagerUnregisterWithoutShellClearsPendingStart() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: UUID(),
                serverId: serverId
            )

            let firstClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: paneId, client: firstClient))

            await manager.unregisterSSHClient(for: paneId)
            #expect(!manager.isShellStartInFlight(for: paneId))
            #expect(manager.shellId(for: paneId) == nil)

            let nextClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: paneId, client: nextClient))
            manager.finishShellStart(for: paneId, client: nextClient)
        }
    }

    @Test
    func connectionManagerTryBeginShellStartFailsWhenSessionIsMissing() async {
        await withCleanConnectionManager { manager in
            let missingSessionId = UUID()
            #expect(!manager.tryBeginShellStart(for: missingSessionId, client: SSHClient()))
            #expect(!manager.isShellStartInFlight(for: missingSessionId))
        }
    }

    @Test
    func connectionManagerTracksSelectedSessionPerServer() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let first = ConnectionSession(
                serverId: serverId,
                title: "First",
                connectionState: .disconnected
            )
            let second = ConnectionSession(
                serverId: serverId,
                title: "Second",
                connectionState: .disconnected
            )

            manager.sessions = [first, second]
            manager.selectSession(second)

            #expect(manager.selectedSessionId == second.id)
            #expect(manager.selectedSessionByServer[serverId] == second.id)
        }
    }

    @Test
    func openConnectionDoesNotSeedWorkingDirectoryFromSelectedDifferentServer() async throws {
        try await withCleanConnectionManager { manager in
            let firstServer = makeServer(name: "First")
            let secondServer = makeServer(name: "Second")

            try await withServerList([firstServer, secondServer]) {
                let firstSession = ConnectionSession(
                    serverId: firstServer.id,
                    title: "First",
                    connectionState: .disconnected,
                    workingDirectory: "/srv/first"
                )
                manager.sessions = [firstSession]
                manager.selectedSessionId = firstSession.id
                manager.selectedSessionByServer[firstServer.id] = firstSession.id

                let newSession = try await manager.openConnection(to: secondServer, forceNew: true)

                #expect(newSession.serverId == secondServer.id)
                #expect(newSession.workingDirectory == nil)
            }
        }
    }

    @Test
    func openConnectionSeedsWorkingDirectoryFromSameServerSession() async throws {
        try await withCleanConnectionManager { manager in
            let firstServer = makeServer(name: "First")
            let secondServer = makeServer(name: "Second")

            try await withServerList([firstServer, secondServer]) {
                let firstSession = ConnectionSession(
                    serverId: firstServer.id,
                    title: "First",
                    connectionState: .disconnected,
                    workingDirectory: "/srv/first"
                )
                let secondSession = ConnectionSession(
                    serverId: secondServer.id,
                    title: "Second",
                    connectionState: .disconnected,
                    workingDirectory: "/srv/second"
                )
                manager.sessions = [firstSession, secondSession]
                manager.selectedSessionId = firstSession.id
                manager.selectedSessionByServer[firstServer.id] = firstSession.id
                manager.selectedSessionByServer[secondServer.id] = secondSession.id

                let newSession = try await manager.openConnection(to: secondServer, forceNew: true)

                #expect(newSession.serverId == secondServer.id)
                #expect(newSession.workingDirectory == "/srv/second")
            }
        }
    }

    @Test
    func connectionManagerDisconnectServerLeavesOtherServersConnected() async {
        await withCleanConnectionManager { manager in
            let firstServerId = UUID()
            let secondServerId = UUID()
            let first = ConnectionSession(
                serverId: firstServerId,
                title: "First Server",
                connectionState: .connected
            )
            let second = ConnectionSession(
                serverId: secondServerId,
                title: "Second Server",
                connectionState: .connected
            )

            manager.sessions = [first, second]
            manager.selectedSessionId = first.id
            manager.connectedServerIds = [firstServerId, secondServerId]

            manager.disconnectServer(firstServerId)

            #expect(manager.sessions.count == 1)
            #expect(manager.sessions.first?.id == second.id)
            #expect(manager.selectedSessionId == second.id)
            #expect(manager.connectedServerIds == [secondServerId])
        }
    }

    @Test
    func connectionManagerSuspendAllForBackgroundPreservesTabsAndClearsShells() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Background Session",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            manager.connectedServerIds = [serverId]

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            var suspendCalls = 0
            manager.registerShellSuspendHandler({
                suspendCalls += 1
            }, for: session.id)

            await manager.suspendAllForBackground()

            #expect(manager.sessions.count == 1)
            #expect(manager.sessions.first?.id == session.id)
            #expect(manager.sessions.first?.connectionState == .disconnected)
            #expect(manager.shellId(for: session.id) == nil)
            #expect(manager.consumeTerminalReconnectReset(for: session.id))
            #expect(manager.connectedServerIds.isEmpty)
            #expect(suspendCalls == 1)
            #expect(!manager.isSuspendingForBackground)
        }
    }

    @Test
    func connectionManagerHandleShellExitMarksTerminalForReconnectReset() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Reconnect Reset",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.connectedServerIds = [serverId]

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            manager.handleShellExit(for: session.id)

            #expect(manager.sessions.first?.connectionState == .disconnected)
            #expect(manager.consumeTerminalReconnectReset(for: session.id))
            #expect(!manager.consumeTerminalReconnectReset(for: session.id))
        }
    }

    @Test
    func connectionManagerReconnectDoesNothingWhileBackgroundSuspendIsActive() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: "Reconnect Guard",
                connectionState: .disconnected
            )

            await withServerList([server]) {
                manager.sessions = [session]
                manager.setBackgroundSuspendInProgressForTesting(true)
                defer { manager.setBackgroundSuspendInProgressForTesting(false) }

                try? await manager.reconnect(session: session)

                #expect(manager.sessions.first?.connectionState == .disconnected)
                #expect(manager.shellId(for: session.id) == nil)
            }
        }
    }

    @Test
    func tabManagerTryBeginShellStartFailsWhenPaneIsMissing() async {
        await withCleanTabManager { manager in
            let missingPaneId = UUID()
            #expect(!manager.tryBeginShellStart(for: missingPaneId, client: SSHClient()))
            #expect(!manager.isShellStartInFlight(for: missingPaneId))
        }
    }

    @Test
    func connectionManagerSharedStatsClientSkipsMoshTransport() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .mosh)
            let session = ConnectionSession(
                serverId: server.id,
                title: "Mosh Session",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            manager.selectedSessionByServer[server.id] = session.id

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: session.id,
                serverId: server.id,
                transport: .mosh,
                skipTmuxLifecycle: true
            )

            #expect(manager.sshClient(for: server.id) != nil)
            #expect(manager.sharedStatsClient(for: server.id) == nil)
        }
    }

    @Test
    func tabManagerSharedStatsClientSkipsMoshTransport() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .mosh)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                transport: .mosh,
                skipTmuxLifecycle: true
            )

            #expect(manager.sshClient(for: server.id) != nil)
            #expect(manager.sharedStatsClient(for: server.id) == nil)
        }
    }

    @Test
    func splitPaneUsesLatestTabStateWhenViewTabIsStale() async {
        await withCleanTabManager { manager in
            let wasPro = StoreManager.shared.isPro
            StoreManager.shared.isPro = true
            defer { StoreManager.shared.isPro = wasPro }

            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)

            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id

            guard let firstSplitPane = manager.splitHorizontal(tab: tab, paneId: tab.rootPaneId) else {
                Issue.record("First split failed unexpectedly")
                return
            }

            // Intentionally pass a stale snapshot (the original `tab` value) to simulate
            // view-state lag while still targeting a pane created by the first split.
            guard let secondSplitPane = manager.splitVertical(tab: tab, paneId: firstSplitPane) else {
                Issue.record("Second split failed unexpectedly")
                return
            }

            guard let latestTab = manager.tabs(for: server.id).first else {
                Issue.record("Expected tab to exist after split")
                return
            }

            let paneIds = Set(latestTab.allPaneIds)
            #expect(paneIds.contains(tab.rootPaneId))
            #expect(paneIds.contains(firstSplitPane))
            #expect(paneIds.contains(secondSplitPane))
            #expect(paneIds.count == 3)
        }
    }
}
