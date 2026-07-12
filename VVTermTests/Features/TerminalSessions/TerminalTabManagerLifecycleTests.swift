import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct TerminalTabManagerLifecycleTests {
    private func makeServer(
        id: UUID = UUID(),
        name: String = "Test",
        connectionMode: SSHConnectionMode = .standard
    ) -> Server {
        Server(
            id: id,
            workspaceId: UUID(),
            name: name,
            host: "ssh.example.com",
            username: "root",
            connectionMode: connectionMode
        )
    }

    private func withCleanManager(
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

    private func installTab(
        _ tab: TerminalTab,
        in manager: TerminalTabManager,
        connectionState: ConnectionState = .connecting
    ) {
        manager.tabsByServer[tab.serverId, default: []].append(tab)
        manager.selectedTabByServer[tab.serverId] = tab.id
        manager.paneStates[tab.rootPaneId] = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        )
        manager.updatePaneState(tab.rootPaneId, connectionState: connectionState)
    }

    @Test
    func staleRegistrationFromDifferentClientDoesNotReplacePendingStart() async {
        await withCleanManager { manager in
            let serverId = UUID()
            let tab = TerminalTab(serverId: serverId, title: "Pending")
            installTab(tab, in: manager)

            let activeClient = SSHClient()
            let staleClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: activeClient))

            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            #expect(manager.shellId(for: tab.rootPaneId) == nil)
            #expect(manager.isShellStartInFlight(for: tab.rootPaneId))

            manager.finishShellStart(for: tab.rootPaneId, client: staleClient)
            #expect(manager.isShellStartInFlight(for: tab.rootPaneId))

            manager.finishShellStart(for: tab.rootPaneId, client: activeClient)
            #expect(!manager.isShellStartInFlight(for: tab.rootPaneId))
        }
    }

    @Test
    func unregisterWithoutShellClearsPendingStart() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pending")
            installTab(tab, in: manager)

            let firstClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: firstClient))

            await manager.unregisterSSHClient(for: tab.rootPaneId)

            #expect(!manager.isShellStartInFlight(for: tab.rootPaneId))
            #expect(manager.shellId(for: tab.rootPaneId) == nil)

            let nextClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: nextClient))
            manager.finishShellStart(for: tab.rootPaneId, client: nextClient)
        }
    }

    @Test
    func shellStartFailsWhenPaneIsMissing() async {
        await withCleanManager { manager in
            let missingPaneId = UUID()

            #expect(!manager.tryBeginShellStart(for: missingPaneId, client: SSHClient()))
            #expect(!manager.isShellStartInFlight(for: missingPaneId))
        }
    }

    @Test
    func disconnectServerLeavesOtherServerTabsAndShellsConnected() async {
        await withCleanManager { manager in
            let firstTab = TerminalTab(serverId: UUID(), title: "First")
            let secondTab = TerminalTab(serverId: UUID(), title: "Second")
            installTab(firstTab, in: manager)
            installTab(secondTab, in: manager)

            let firstClient = SSHClient()
            let secondClient = SSHClient()
            manager.registerSSHClient(
                firstClient,
                shellId: UUID(),
                for: firstTab.rootPaneId,
                serverId: firstTab.serverId,
                skipTmuxLifecycle: true
            )
            manager.registerSSHClient(
                secondClient,
                shellId: UUID(),
                for: secondTab.rootPaneId,
                serverId: secondTab.serverId,
                skipTmuxLifecycle: true
            )
            manager.updatePaneState(firstTab.rootPaneId, connectionState: .connected)
            manager.updatePaneState(secondTab.rootPaneId, connectionState: .connected)

            manager.disconnectServer(firstTab.serverId)

            #expect(manager.tabs(for: firstTab.serverId).isEmpty)
            #expect(manager.paneStates[firstTab.rootPaneId] == nil)
            #expect(!manager.connectedServerIds.contains(firstTab.serverId))
            #expect(manager.tabs(for: secondTab.serverId) == [secondTab])
            #expect(manager.paneStates[secondTab.rootPaneId]?.connectionState == .connected)
            #expect(manager.shellId(for: secondTab.rootPaneId) != nil)
            #expect(manager.connectedServerIds == [secondTab.serverId])
        }
    }

    @Test
    func backgroundSuspensionPreservesTabsAndClearsLiveAndPendingShells() async {
        await withCleanManager { manager in
            let serverId = UUID()
            let liveTab = TerminalTab(serverId: serverId, title: "Live")
            let pendingTab = TerminalTab(serverId: serverId, title: "Pending")
            installTab(liveTab, in: manager)
            installTab(pendingTab, in: manager)

            let liveClient = SSHClient()
            manager.registerSSHClient(
                liveClient,
                shellId: UUID(),
                for: liveTab.rootPaneId,
                serverId: serverId,
                skipTmuxLifecycle: true
            )
            manager.updatePaneState(liveTab.rootPaneId, connectionState: .connected)

            let pendingClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: pendingTab.rootPaneId, client: pendingClient))
            #expect(manager.connectedServerIds == [serverId])

            await manager.suspendAllForBackground()

            #expect(manager.tabs(for: serverId) == [liveTab, pendingTab])
            #expect(manager.paneStates[liveTab.rootPaneId]?.connectionState == .disconnected)
            #expect(manager.paneStates[pendingTab.rootPaneId]?.connectionState == .disconnected)
            #expect(manager.shellId(for: liveTab.rootPaneId) == nil)
            #expect(!manager.isShellStartInFlight(for: pendingTab.rootPaneId))
            #expect(manager.connectedServerIds.isEmpty)
            #expect(!manager.isSuspendingForBackground)
        }
    }

    @Test
    func shellExitLifecycleDisconnectsPaneAndClearsRegistration() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Shell Exit")
            installTab(tab, in: manager)

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: tab.serverId,
                skipTmuxLifecycle: true
            )
            manager.updatePaneState(tab.rootPaneId, connectionState: .connected)

            manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
            await manager.unregisterSSHClient(for: tab.rootPaneId)

            #expect(manager.tabs(for: tab.serverId) == [tab])
            #expect(manager.paneStates[tab.rootPaneId]?.connectionState == .disconnected)
            #expect(manager.shellId(for: tab.rootPaneId) == nil)
            #expect(!manager.connectedServerIds.contains(tab.serverId))
            #expect(!TerminalConnectionStartPolicy.shouldStart(connectionState: .disconnected))
        }
    }

    @Test
    func openingTabSeedsWorkingDirectoryOnlyFromSelectedTabOnSameServer() async throws {
        try await withCleanManager { manager in
            let firstServer = makeServer(name: "First")
            let secondServer = makeServer(name: "Second")

            let firstTab = try await manager.openTab(for: firstServer)
            manager.updatePaneWorkingDirectory(firstTab.rootPaneId, rawDirectory: "/srv/first")

            let otherServerTab = try await manager.openTab(for: secondServer)
            #expect(manager.workingDirectory(for: otherServerTab.rootPaneId) == nil)
            #expect(manager.paneStates[otherServerTab.rootPaneId]?.seedPaneId == nil)

            let secondFirstServerTab = try await manager.openTab(for: firstServer)
            #expect(manager.workingDirectory(for: secondFirstServerTab.rootPaneId) == "/srv/first")
            #expect(manager.paneStates[secondFirstServerTab.rootPaneId]?.seedPaneId == firstTab.rootPaneId)
        }
    }

    @Test
    func sharedStatsClientSkipsSelectedMoshTransport() async {
        await withCleanManager { manager in
            let server = makeServer(connectionMode: .mosh)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            installTab(tab, in: manager)

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                transport: .mosh,
                skipTmuxLifecycle: true
            )

            #expect(manager.sshClient(for: server.id) === client)
            #expect(manager.sharedStatsClient(for: server.id) == nil)
        }
    }

    @Test
    func splitPaneUsesLatestManagerStateWhenViewTabIsStale() async {
        await withCleanManager { manager in
            let wasPro = StoreManager.shared.isPro
            StoreManager.shared.isPro = true
            defer { StoreManager.shared.isPro = wasPro }

            let tab = TerminalTab(serverId: UUID(), title: "Split")
            installTab(tab, in: manager)

            guard let firstSplitPane = manager.splitHorizontal(tab: tab, paneId: tab.rootPaneId) else {
                Issue.record("First split failed unexpectedly")
                return
            }

            guard let secondSplitPane = manager.splitVertical(tab: tab, paneId: firstSplitPane) else {
                Issue.record("Second split failed unexpectedly")
                return
            }

            guard let latestTab = manager.tabs(for: tab.serverId).first else {
                Issue.record("Expected tab to exist after split")
                return
            }

            #expect(Set(latestTab.allPaneIds) == [tab.rootPaneId, firstSplitPane, secondSplitPane])
        }
    }
}
