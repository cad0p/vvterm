import Foundation
import Testing
@testable import VVTerm

private actor BackgroundCleanupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isWaiting = false
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked(timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if isWaiting {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return isWaiting
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ForegroundReadinessProbe {
    private(set) var started = false
    private(set) var result: Bool?

    func markStarted() {
        started = true
    }

    func waitUntilStarted(timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if started {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return started
    }

    func finish(with result: Bool) {
        self.result = result
    }
}

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

            #expect(!(await manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: serverId,
                skipTmuxLifecycle: true
            )))

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
            #expect(manager.tryBeginShellStart(for: firstTab.rootPaneId, client: firstClient))
            #expect(await manager.registerSSHClient(
                firstClient,
                shellId: UUID(),
                for: firstTab.rootPaneId,
                serverId: firstTab.serverId,
                skipTmuxLifecycle: true
            ))
            #expect(manager.tryBeginShellStart(for: secondTab.rootPaneId, client: secondClient))
            #expect(await manager.registerSSHClient(
                secondClient,
                shellId: UUID(),
                for: secondTab.rootPaneId,
                serverId: secondTab.serverId,
                skipTmuxLifecycle: true
            ))
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
            #expect(manager.tryBeginShellStart(for: liveTab.rootPaneId, client: liveClient))
            #expect(await manager.registerSSHClient(
                liveClient,
                shellId: UUID(),
                for: liveTab.rootPaneId,
                serverId: serverId,
                skipTmuxLifecycle: true
            ))
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
        }
    }

    @Test
    func staleShellCannotReplaceForegroundStartAfterBackgroundDrain() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Stale background start")
            installTab(tab, in: manager)
            let staleClient = SSHClient()
            let staleShellId = UUID()

            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: staleClient))

            await manager.suspendAllForBackground()
            manager.noteForegroundActivation()
            #expect(await manager.prepareForForegroundReconnect())
            let replacementClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: replacementClient))

            #expect(!(await manager.registerSSHClient(
                staleClient,
                shellId: staleShellId,
                for: tab.rootPaneId,
                serverId: tab.serverId,
                skipTmuxLifecycle: true
            )))

            #expect(manager.shellId(for: tab.rootPaneId) == nil)
            #expect(manager.paneStates[tab.rootPaneId]?.connectionState == .disconnected)
            #expect(!manager.isCurrentShellOwner(for: tab.rootPaneId, client: staleClient))
            #expect(manager.isCurrentShellOwner(for: tab.rootPaneId, client: replacementClient))
            manager.finishShellStart(for: tab.rootPaneId, client: replacementClient)
        }
    }

    @Test
    func staleShellOnSharedClientDoesNotDisconnectSiblingPane() async {
        await withCleanManager { manager in
            let siblingTab = TerminalTab(serverId: UUID(), title: "Sibling")
            let pendingTab = TerminalTab(serverId: UUID(), title: "Pending")
            installTab(siblingTab, in: manager)
            installTab(pendingTab, in: manager)

            let sharedClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: siblingTab.rootPaneId, client: sharedClient))
            #expect(await manager.registerSSHClient(
                sharedClient,
                shellId: UUID(),
                for: siblingTab.rootPaneId,
                serverId: siblingTab.serverId,
                skipTmuxLifecycle: true
            ))

            let pendingClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: pendingTab.rootPaneId, client: pendingClient))
            #expect(!(await manager.registerSSHClient(
                sharedClient,
                shellId: UUID(),
                for: pendingTab.rootPaneId,
                serverId: pendingTab.serverId,
                skipTmuxLifecycle: true
            )))

            #expect(!(await sharedClient.isAborted))
            #expect(manager.isCurrentShellOwner(for: siblingTab.rootPaneId, client: sharedClient))
            #expect(manager.isCurrentShellOwner(for: pendingTab.rootPaneId, client: pendingClient))
        }
    }

    @Test
    func foregroundReconnectWaitsForBackgroundCleanup() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Foreground barrier")
            installTab(tab, in: manager)
            let gate = BackgroundCleanupGate()
            let probe = ForegroundReadinessProbe()

            manager.beginBackgroundSuspensionForTesting {
                await gate.wait()
            }
            guard await gate.waitUntilBlocked() else {
                Issue.record("Background cleanup did not reach the test gate")
                return
            }
            manager.noteForegroundActivation()

            let readiness = Task { @MainActor in
                await probe.markStarted()
                let result = await manager.prepareForForegroundReconnect()
                await probe.finish(with: result)
            }
            guard await probe.waitUntilStarted() else {
                Issue.record("Foreground readiness task did not start")
                await gate.open()
                return
            }
            await Task.yield()

            #expect(await probe.result == nil)
            #expect(!manager.tryBeginShellStart(for: tab.rootPaneId, client: SSHClient()))

            await gate.open()
            await readiness.value

            #expect(await probe.result == true)
            let client = SSHClient()
            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: client))
            manager.finishShellStart(for: tab.rootPaneId, client: client)
        }
    }

    @Test
    func laterBackgroundEventCancelsPendingForegroundReconnect() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Retargeted barrier")
            installTab(tab, in: manager)
            let gate = BackgroundCleanupGate()
            let probe = ForegroundReadinessProbe()

            manager.beginBackgroundSuspensionForTesting {
                await gate.wait()
            }
            guard await gate.waitUntilBlocked() else {
                Issue.record("Background cleanup did not reach the test gate")
                return
            }
            manager.noteForegroundActivation()

            let readiness = Task { @MainActor in
                await probe.markStarted()
                let result = await manager.prepareForForegroundReconnect()
                await probe.finish(with: result)
            }
            guard await probe.waitUntilStarted() else {
                Issue.record("Foreground readiness task did not start")
                await gate.open()
                return
            }
            await Task.yield()
            manager.beginBackgroundSuspension()

            await gate.open()
            await readiness.value

            #expect(await probe.result == false)
            #expect(!manager.tryBeginShellStart(for: tab.rootPaneId, client: SSHClient()))

            manager.noteForegroundActivation()
            #expect(await manager.prepareForForegroundReconnect())
        }
    }

    @Test
    func foregroundReconnectWaitsForCleanupAlreadyRemovedFromRegistry() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "In-flight unregister")
            installTab(tab, in: manager)
            let client = SSHClient()
            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: client))
            #expect(await manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: tab.serverId,
                skipTmuxLifecycle: true
            ))

            let cleanupGate = BackgroundCleanupGate()
            let cleanup = Task { @MainActor in
                await manager.unregisterSSHClientForTesting(for: tab.rootPaneId) {
                    await cleanupGate.wait()
                }
            }
            guard await cleanupGate.waitUntilBlocked() else {
                Issue.record("Unregister cleanup did not reach the test gate")
                await cleanupGate.open()
                await cleanup.value
                return
            }

            manager.beginBackgroundSuspension()
            manager.noteForegroundActivation()

            let probe = ForegroundReadinessProbe()
            let readiness = Task { @MainActor in
                await probe.markStarted()
                let result = await manager.prepareForForegroundReconnect()
                await probe.finish(with: result)
            }
            guard await probe.waitUntilStarted() else {
                Issue.record("Foreground readiness task did not start")
                await cleanupGate.open()
                return
            }
            for _ in 0..<100 {
                await Task.yield()
            }

            #expect(await probe.result == nil)

            await cleanupGate.open()
            await cleanup.value
            await readiness.value
            #expect(await probe.result == true)
        }
    }

    @Test
    func foregroundReconnectWaitsForCleanupAddedAfterBackgroundDrain() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Late cleanup")
            installTab(tab, in: manager)
            let backgroundGate = BackgroundCleanupGate()
            let lateCleanupGate = BackgroundCleanupGate()

            manager.beginBackgroundSuspensionForTesting {
                await backgroundGate.wait()
            }
            guard await backgroundGate.waitUntilBlocked() else {
                Issue.record("Background cleanup did not reach the test gate")
                await backgroundGate.open()
                return
            }
            manager.noteForegroundActivation()

            let lateCleanup = Task { @MainActor in
                await manager.trackConnectionCleanupForTesting(for: SSHClient()) {
                    await lateCleanupGate.wait()
                }
            }
            guard await lateCleanupGate.waitUntilBlocked() else {
                Issue.record("Late connection cleanup did not reach the test gate")
                await backgroundGate.open()
                await lateCleanupGate.open()
                await lateCleanup.value
                return
            }

            let probe = ForegroundReadinessProbe()
            let readiness = Task { @MainActor in
                await probe.markStarted()
                let result = await manager.prepareForForegroundReconnect()
                await probe.finish(with: result)
            }
            guard await probe.waitUntilStarted() else {
                Issue.record("Foreground readiness task did not start")
                await backgroundGate.open()
                await lateCleanupGate.open()
                await lateCleanup.value
                return
            }

            await backgroundGate.open()
            for _ in 0..<100 {
                await Task.yield()
            }
            #expect(await probe.result == nil)

            await lateCleanupGate.open()
            await lateCleanup.value
            await readiness.value
            #expect(await probe.result == true)
        }
    }

    @Test
    func foregroundReconnectWaitsForDrainedShellStartCompletion() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Drained shell start")
            installTab(tab, in: manager)
            let client = SSHClient()
            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: client))

            let backgroundGate = BackgroundCleanupGate()
            manager.beginBackgroundSuspensionForTesting {
                await backgroundGate.wait()
            }
            guard await backgroundGate.waitUntilBlocked() else {
                Issue.record("Background cleanup did not reach the test gate")
                await backgroundGate.open()
                return
            }
            manager.noteForegroundActivation()

            let probe = ForegroundReadinessProbe()
            let readiness = Task { @MainActor in
                await probe.markStarted()
                let result = await manager.prepareForForegroundReconnect()
                await probe.finish(with: result)
            }
            guard await probe.waitUntilStarted() else {
                Issue.record("Foreground readiness task did not start")
                await backgroundGate.open()
                return
            }

            await backgroundGate.open()
            for _ in 0..<100 {
                await Task.yield()
            }
            #expect(await probe.result == nil)

            manager.finishShellStart(for: tab.rootPaneId, client: client)
            await readiness.value
            #expect(await probe.result == true)
        }
    }

    @Test
    func shellExitLifecycleDisconnectsPaneAndClearsRegistration() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Shell Exit")
            installTab(tab, in: manager)

            let client = SSHClient()
            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: client))
            #expect(await manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: tab.serverId,
                skipTmuxLifecycle: true
            ))
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
            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: activeClient))
            #expect(await manager.registerSSHClient(
                activeClient,
                shellId: activeShellId,
                for: tab.rootPaneId,
                serverId: tab.serverId,
                skipTmuxLifecycle: true
            ))

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
            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: client))
            #expect(await manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                transport: .mosh,
                skipTmuxLifecycle: true
            ))

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
