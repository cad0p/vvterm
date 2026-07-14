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
    func onlyCurrentPaneClientCanContinueConnecting() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pending")
            installTab(tab, in: manager)
            let activeClient = SSHClient()
            let staleClient = SSHClient()

            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: activeClient))
            #expect(manager.isCurrentShellOwner(for: tab.rootPaneId, client: activeClient))
            #expect(!manager.isCurrentShellOwner(for: tab.rootPaneId, client: staleClient))

            await manager.unregisterSSHClient(for: tab.rootPaneId)

            #expect(!manager.isCurrentShellOwner(for: tab.rootPaneId, client: activeClient))
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
    func managedTmuxEndClosesItsLastPaneAndTab() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Managed tmux")
            installTab(tab, in: manager, connectionState: .connected)
            manager.tmuxResolver.sessionNames[tab.rootPaneId] = "vvterm_test"
            manager.tmuxResolver.sessionOwnership[tab.rootPaneId] = .managed
            manager.updatePaneTmuxStatus(tab.rootPaneId, status: .foreground)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .tmuxEnded(.managed))

            #expect(manager.tabs(for: tab.serverId).isEmpty)
            #expect(manager.paneStates[tab.rootPaneId] == nil)
            #expect(manager.tmuxResolver.sessionNames[tab.rootPaneId] == nil)
        }
    }

    @Test
    func managedTmuxEndClosesOnlyItsPaneInSplitTab() async {
        await withCleanManager { manager in
            let secondPaneId = UUID()
            var tab = TerminalTab(serverId: UUID(), title: "Split tmux")
            tab.layout = .split(.init(
                direction: .horizontal,
                ratio: 0.5,
                left: .leaf(paneId: tab.rootPaneId),
                right: .leaf(paneId: secondPaneId)
            ))
            installTab(tab, in: manager, connectionState: .connected)
            manager.paneStates[secondPaneId] = TerminalPaneState(
                paneId: secondPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )
            manager.tmuxResolver.sessionNames[secondPaneId] = "vvterm_second"
            manager.tmuxResolver.sessionOwnership[secondPaneId] = .managed
            manager.updatePaneTmuxStatus(secondPaneId, status: .background)

            manager.handleShellEnd(for: secondPaneId, reason: .tmuxEnded(.managed))

            let remainingTab = manager.tabs(for: tab.serverId).first
            #expect(remainingTab?.allPaneIds == [tab.rootPaneId])
            #expect(manager.paneStates[tab.rootPaneId] != nil)
            #expect(manager.paneStates[secondPaneId] == nil)
        }
    }

    @Test
    func managedTmuxDetachPreservesPaneAndSuppressesAutomaticReconnect() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Detached tmux")
            installTab(tab, in: manager, connectionState: .connected)
            manager.tmuxResolver.sessionNames[tab.rootPaneId] = "vvterm_test"
            manager.tmuxResolver.sessionOwnership[tab.rootPaneId] = .managed
            manager.updatePaneTmuxStatus(tab.rootPaneId, status: .foreground)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .tmuxDetached(.managed))

            #expect(manager.tabs(for: tab.serverId) == [tab])
            #expect(manager.paneStates[tab.rootPaneId]?.connectionState == .disconnected)
            #expect(manager.paneStates[tab.rootPaneId]?.disconnectReason == .tmuxDetached)
            #expect(manager.paneStates[tab.rootPaneId]?.disconnectReason?.allowsAutomaticReconnect == false)
            #expect(manager.tmuxResolver.sessionNames[tab.rootPaneId] == "vvterm_test")
            #expect(manager.tmuxResolver.hasConfirmedManagedSession(for: tab.rootPaneId))
        }
    }

    @Test
    func managedReattachRequiresExplicitSessionConfirmation() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Unconfirmed tmux")
            installTab(tab, in: manager, connectionState: .connected)
            manager.tmuxResolver.sessionNames[tab.rootPaneId] = "vvterm_test"
            manager.tmuxResolver.sessionOwnership[tab.rootPaneId] = .managed

            #expect(!manager.shouldReattachManagedTmuxSession(for: tab.rootPaneId))

            manager.tmuxResolver.confirmManagedSession(for: tab.rootPaneId)

            #expect(manager.shouldReattachManagedTmuxSession(for: tab.rootPaneId))
        }
    }

    @Test
    func managedSessionConfirmationRoundTripsWithoutPromotingUnconfirmedSessions() async {
        await withCleanManager { manager in
            let confirmedTab = TerminalTab(serverId: UUID(), title: "Confirmed tmux")
            let unconfirmedTab = TerminalTab(serverId: UUID(), title: "Unconfirmed tmux")
            installTab(confirmedTab, in: manager, connectionState: .connected)
            installTab(unconfirmedTab, in: manager, connectionState: .connected)

            manager.tmuxResolver.sessionNames[confirmedTab.rootPaneId] = "vvterm_confirmed"
            manager.tmuxResolver.sessionOwnership[confirmedTab.rootPaneId] = .managed
            manager.tmuxResolver.confirmManagedSession(for: confirmedTab.rootPaneId)
            manager.tmuxResolver.sessionNames[unconfirmedTab.rootPaneId] = "vvterm_unconfirmed"
            manager.tmuxResolver.sessionOwnership[unconfirmedTab.rootPaneId] = .managed

            manager.persistAndRestoreSnapshotForTesting()

            #expect(manager.shouldReattachManagedTmuxSession(for: confirmedTab.rootPaneId))
            #expect(!manager.shouldReattachManagedTmuxSession(for: unconfirmedTab.rootPaneId))
        }
    }

    @Test
    func managedTmuxCreationFailurePreservesPaneAndClearsUnprovenAttachment() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Failed tmux")
            installTab(tab, in: manager, connectionState: .connected)
            manager.tmuxResolver.sessionNames[tab.rootPaneId] = "vvterm_test"
            manager.tmuxResolver.sessionOwnership[tab.rootPaneId] = .managed
            manager.updatePaneTmuxStatus(tab.rootPaneId, status: .foreground)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .tmuxCreationFailed)

            #expect(manager.tabs(for: tab.serverId) == [tab])
            #expect(
                manager.paneStates[tab.rootPaneId]?.connectionState
                    == .failed(String(localized: "Unable to start tmux session."))
            )
            #expect(manager.paneStates[tab.rootPaneId]?.tmuxStatus == .unknown)
            #expect(manager.tmuxResolver.sessionNames[tab.rootPaneId] == nil)
            #expect(manager.tmuxResolver.sessionOwnership[tab.rootPaneId] == nil)
        }
    }

    @Test
    func successfulTmuxInstallTriggersExplicitReconnect() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Installed tmux")
            installTab(tab, in: manager, connectionState: .connected)
            manager.paneStates[tab.rootPaneId]?.disconnectReason = .tmuxDetached
            var reconnectRequested = false

            manager.completeTmuxInstall(
                for: tab.rootPaneId,
                sessionName: "vvterm_installed",
                onInstalled: { reconnectRequested = true }
            )

            #expect(reconnectRequested)
            #expect(manager.tmuxResolver.sessionNames[tab.rootPaneId] == "vvterm_installed")
            #expect(manager.tmuxResolver.sessionOwnership[tab.rootPaneId] == .managed)
        }
    }

    @Test
    func transportEndPreservesPaneAndAllowsAutomaticReconnect() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Dropped transport")
            installTab(tab, in: manager, connectionState: .connected)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .transportEnded)

            #expect(manager.tabs(for: tab.serverId) == [tab])
            #expect(manager.paneStates[tab.rootPaneId]?.connectionState == .disconnected)
            #expect(manager.paneStates[tab.rootPaneId]?.disconnectReason == .transportEnded)
            #expect(manager.paneStates[tab.rootPaneId]?.disconnectReason?.allowsAutomaticReconnect == true)
        }
    }

    @Test
    func staleShellEndCannotDisconnectReplacementShell() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Replacement")
            installTab(tab, in: manager, connectionState: .connected)
            let activeClient = SSHClient()
            let activeShellId = UUID()
            manager.registerSSHClient(
                activeClient,
                shellId: activeShellId,
                for: tab.rootPaneId,
                serverId: tab.serverId,
                skipTmuxLifecycle: true
            )

            manager.handleShellEnd(
                for: tab.rootPaneId,
                client: SSHClient(),
                shellId: UUID(),
                reason: .transportEnded
            )

            #expect(manager.paneStates[tab.rootPaneId]?.connectionState == .connected)
            #expect(manager.paneStates[tab.rootPaneId]?.disconnectReason == nil)
            #expect(manager.shellId(for: tab.rootPaneId) == activeShellId)
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
