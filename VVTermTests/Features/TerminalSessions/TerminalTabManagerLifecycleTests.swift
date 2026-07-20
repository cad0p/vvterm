import Foundation
import Testing
@testable import VVTerm

private actor TmuxAvailabilityGate {
    private var continuation: CheckedContinuation<RemoteTmuxAvailability, Never>?

    func waitForResolution() async -> RemoteTmuxAvailability {
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked(timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if continuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return continuation != nil
    }

    func resolve(_ availability: RemoteTmuxAvailability) {
        continuation?.resume(returning: availability)
        continuation = nil
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

    private func withTmuxEnabled(
        _ body: @MainActor () async throws -> Void
    ) async rethrows {
        let defaults = UserDefaults.standard
        let key = "terminalTmuxEnabledDefault"
        let previousValue = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try await body()
    }

    @Test
    func reconnectClearsMoshFallbackDiagnostics() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Fallback")
            installTab(tab, in: manager, connectionState: .connected)
            manager.paneStates[tab.rootPaneId]?.activeTransport = .sshFallback
            manager.paneStates[tab.rootPaneId]?.moshFallbackReason = .udpTimeout
            manager.paneStates[tab.rootPaneId]?.moshFallbackDiagnostics = .make(
                reason: .udpTimeout,
                events: [],
                appContext: .init(version: "test", platform: "test")
            )

            manager.clearMoshFallbackDiagnostics(for: tab.rootPaneId)

            #expect(manager.paneStates[tab.rootPaneId]?.activeTransport == .sshFallback)
            #expect(manager.paneStates[tab.rootPaneId]?.moshFallbackReason == .udpTimeout)
            #expect(manager.paneStates[tab.rootPaneId]?.moshFallbackDiagnostics == nil)

            manager.updatePaneState(tab.rootPaneId, connectionState: .reconnecting(attempt: 1))
            #expect(manager.paneStates[tab.rootPaneId]?.activeTransport == .ssh)
            #expect(manager.paneStates[tab.rootPaneId]?.moshFallbackReason == nil)
        }
    }

    @Test
    func successfulMoshRegistrationReplacesFallbackDiagnostics() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Mosh recovery")
            installTab(tab, in: manager, connectionState: .connected)
            manager.paneStates[tab.rootPaneId]?.activeTransport = .sshFallback
            manager.paneStates[tab.rootPaneId]?.moshFallbackReason = .udpTimeout
            manager.paneStates[tab.rootPaneId]?.moshFallbackDiagnostics = .make(
                reason: .udpTimeout,
                events: [],
                appContext: .init(version: "test", platform: "test")
            )

            let client = SSHClient()
            #expect(await startAndRegisterShell(
                client,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                transport: .mosh,
                in: manager
            ))
            #expect(manager.paneStates[tab.rootPaneId]?.activeTransport == .mosh)
            #expect(manager.paneStates[tab.rootPaneId]?.moshFallbackReason == nil)
            #expect(manager.paneStates[tab.rootPaneId]?.moshFallbackDiagnostics == nil)
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
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

    private func startAndRegisterShell(
        _ client: SSHClient,
        shellId: UUID = UUID(),
        paneId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        in manager: TerminalTabManager
    ) async -> Bool {
        guard let startToken = manager.beginShellStart(for: paneId, client: client) else {
            return false
        }
        return await manager.registerSSHClient(
            client,
            shellId: shellId,
            startToken: startToken,
            for: paneId,
            serverId: serverId,
            transport: transport
        )
    }

    @Test
    func reconnectPreparationHasOnePaneGlobalOwner() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Reconnect owner")
            installTab(tab, in: manager, connectionState: .disconnected)

            let first = manager.beginReconnectPreparation(for: tab.rootPaneId)
            #expect(first != nil)
            #expect(manager.beginReconnectPreparation(for: tab.rootPaneId) == nil)

            guard let first else { return }
            manager.finishReconnectPreparation(first)
            let second = manager.beginReconnectPreparation(for: tab.rootPaneId)
            #expect(second != nil)
            guard let second else { return }
            manager.finishReconnectPreparation(second)
        }
    }

    @Test
    func staleExitCannotUnregisterReplacementShell() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Replacement shell")
            installTab(tab, in: manager)
            let oldClient = SSHClient()
            let oldShellId = UUID()

            #expect(await startAndRegisterShell(
                oldClient,
                shellId: oldShellId,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                in: manager
            ))
            await manager.unregisterSSHClient(for: tab.rootPaneId)

            let replacementClient = SSHClient()
            let replacementShellId = UUID()
            #expect(await startAndRegisterShell(
                replacementClient,
                shellId: replacementShellId,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                in: manager
            ))

            await manager.unregisterSSHClient(
                for: tab.rootPaneId,
                ifOwnedBy: oldClient,
                shellId: oldShellId
            )

            #expect(manager.shellId(for: tab.rootPaneId) == replacementShellId)
            #expect(manager.getSSHClient(for: tab.rootPaneId) === replacementClient)
        }
    }

    @Test
    func currentSurfaceExitCancelsPendingStartWithoutRemovingReplacement() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pending surface exit")
            installTab(tab, in: manager)
            let exitedSurfaceClient = SSHClient()

            guard let exitedStartToken = manager.beginShellStart(
                for: tab.rootPaneId,
                client: exitedSurfaceClient
            ), let exitedConnectionToken = manager.connectionStartToken(for: tab.rootPaneId) else {
                Issue.record("Expected the exiting surface to own a shell start")
                return
            }
            #expect(exitedConnectionToken == exitedStartToken)
            #expect(manager.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: exitedSurfaceClient,
                startToken: exitedStartToken
            ))

            await manager.unregisterSSHClient(
                for: tab.rootPaneId,
                ifOwnedBy: exitedConnectionToken
            )
            #expect(!manager.isShellStartInFlight(for: tab.rootPaneId))

            guard let replacementStartToken = manager.beginShellStart(
                for: tab.rootPaneId,
                client: exitedSurfaceClient
            ) else {
                Issue.record("Expected a same-client replacement shell start")
                return
            }

            await manager.unregisterSSHClient(
                for: tab.rootPaneId,
                ifOwnedBy: exitedConnectionToken
            )
            #expect(manager.isShellStartInFlight(for: tab.rootPaneId))
            #expect(manager.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: exitedSurfaceClient,
                startToken: replacementStartToken
            ))
        }
    }

    @Test
    func staleRegistrationFromDifferentClientDoesNotReplacePendingStart() async {
        await withCleanManager { manager in
            let serverId = UUID()
            let tab = TerminalTab(serverId: serverId, title: "Pending")
            installTab(tab, in: manager)

            let activeClient = SSHClient()
            let staleClient = SSHClient()
            guard let activeStartToken = manager.beginShellStart(
                for: tab.rootPaneId,
                client: activeClient
            ) else {
                Issue.record("Expected active shell start")
                return
            }

            #expect(!(await manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                startToken: activeStartToken,
                for: tab.rootPaneId,
                serverId: serverId
            )))

            #expect(manager.shellId(for: tab.rootPaneId) == nil)
            #expect(manager.isShellStartInFlight(for: tab.rootPaneId))

            manager.finishShellStart(
                for: tab.rootPaneId,
                client: staleClient,
                startToken: activeStartToken
            )
            #expect(manager.isShellStartInFlight(for: tab.rootPaneId))

            manager.finishShellStart(
                for: tab.rootPaneId,
                client: activeClient,
                startToken: activeStartToken
            )
            #expect(!manager.isShellStartInFlight(for: tab.rootPaneId))
        }
    }

    @Test
    func unregisterWithoutShellClearsPendingStart() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pending")
            installTab(tab, in: manager)

            let firstClient = SSHClient()
            #expect(manager.beginShellStart(for: tab.rootPaneId, client: firstClient) != nil)

            await manager.unregisterSSHClient(for: tab.rootPaneId)

            #expect(!manager.isShellStartInFlight(for: tab.rootPaneId))
            #expect(manager.shellId(for: tab.rootPaneId) == nil)

            let nextClient = SSHClient()
            guard let nextStartToken = manager.beginShellStart(
                for: tab.rootPaneId,
                client: nextClient
            ) else {
                Issue.record("Expected replacement shell start")
                return
            }
            manager.finishShellStart(
                for: tab.rootPaneId,
                client: nextClient,
                startToken: nextStartToken
            )
        }
    }

    @Test
    func unregisterPendingShellStartCancelsItsTmuxPrompt() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pending prompt")
            installTab(tab, in: manager)
            let client = SSHClient()
            guard let startToken = manager.beginShellStart(
                for: tab.rootPaneId,
                client: client
            ) else {
                Issue.record("Expected pending shell start")
                return
            }

            let selection = Task { @MainActor in
                await manager.tmuxResolver.requestSelection(
                    requestId: startToken.id,
                    entityId: tab.rootPaneId,
                    serverId: tab.serverId,
                    availableSessions: [],
                    setPrompt: { manager.tmuxAttachPrompt = $0 }
                )
            }
            guard await waitUntil({
                manager.tmuxResolver.hasPendingPrompt(requestId: startToken.id)
            }) else {
                Issue.record("Pending tmux prompt was not enqueued")
                selection.cancel()
                return
            }

            await manager.unregisterSSHClient(for: tab.rootPaneId)

            let promptWasCancelled = await waitUntil({
                !manager.tmuxResolver.hasPendingPrompt(requestId: startToken.id)
                    && manager.tmuxAttachPrompt == nil
            })
            #expect(promptWasCancelled)
            if !promptWasCancelled {
                selection.cancel()
            }
            #expect(await selection.value == .skipTmux)
        }
    }

    @Test
    func onlyCurrentPaneClientCanContinueConnecting() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pending")
            installTab(tab, in: manager)
            let activeClient = SSHClient()
            let staleClient = SSHClient()

            guard let activeStartToken = manager.beginShellStart(
                for: tab.rootPaneId,
                client: activeClient
            ) else {
                Issue.record("Expected active shell start")
                return
            }
            #expect(manager.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: activeClient,
                startToken: activeStartToken
            ))
            #expect(!manager.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: staleClient,
                startToken: activeStartToken
            ))

            await manager.unregisterSSHClient(for: tab.rootPaneId)

            #expect(!manager.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: activeClient,
                startToken: activeStartToken
            ))
        }
    }

    @Test
    func shellStartFailsWhenPaneIsMissing() async {
        await withCleanManager { manager in
            let missingPaneId = UUID()

            #expect(manager.beginShellStart(for: missingPaneId, client: SSHClient()) == nil)
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
            #expect(await startAndRegisterShell(
                firstClient,
                paneId: firstTab.rootPaneId,
                serverId: firstTab.serverId,
                in: manager
            ))
            #expect(await startAndRegisterShell(
                secondClient,
                paneId: secondTab.rootPaneId,
                serverId: secondTab.serverId,
                in: manager
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
    func staleShellOnSharedClientDoesNotDisconnectSiblingPane() async {
        await withCleanManager { manager in
            let siblingTab = TerminalTab(serverId: UUID(), title: "Sibling")
            let pendingTab = TerminalTab(serverId: UUID(), title: "Pending")
            installTab(siblingTab, in: manager)
            installTab(pendingTab, in: manager)

            let sharedClient = SSHClient()
            #expect(await startAndRegisterShell(
                sharedClient,
                paneId: siblingTab.rootPaneId,
                serverId: siblingTab.serverId,
                in: manager
            ))

            let pendingClient = SSHClient()
            guard let pendingStartToken = manager.beginShellStart(
                for: pendingTab.rootPaneId,
                client: pendingClient
            ) else {
                Issue.record("Expected pending shell start")
                return
            }
            #expect(!(await manager.registerSSHClient(
                sharedClient,
                shellId: UUID(),
                startToken: pendingStartToken,
                for: pendingTab.rootPaneId,
                serverId: pendingTab.serverId
            )))

            #expect(!(await sharedClient.isAborted))
            #expect(manager.getSSHClient(for: siblingTab.rootPaneId) === sharedClient)
            #expect(manager.isCurrentShellOwner(
                for: pendingTab.rootPaneId,
                client: pendingClient,
                startToken: pendingStartToken
            ))
        }
    }

    @Test
    func shellExitLifecycleDisconnectsPaneAndClearsRegistration() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Shell Exit")
            installTab(tab, in: manager)

            let client = SSHClient()
            #expect(await startAndRegisterShell(
                client,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                in: manager
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
    func disconnectedTmuxProbePreservesConfirmedAttachmentInsteadOfReportingMissing() async {
        await withTmuxEnabled {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Long-idle tmux reconnect")
                installTab(tab, in: manager, connectionState: .disconnected)
                manager.tmuxResolver.sessionNames[tab.rootPaneId] = "vvterm_existing"
                manager.tmuxResolver.sessionOwnership[tab.rootPaneId] = .managed
                manager.tmuxResolver.confirmManagedSession(for: tab.rootPaneId)
                manager.updatePaneTmuxStatus(tab.rootPaneId, status: .background)

                let disconnectedClient = SSHClient()
                guard let startToken = manager.beginShellStart(
                    for: tab.rootPaneId,
                    client: disconnectedClient
                ) else {
                    Issue.record("Expected disconnected shell start")
                    return
                }

                do {
                    _ = try await manager.tmuxStartupPlan(
                        for: tab.rootPaneId,
                        serverId: tab.serverId,
                        client: disconnectedClient,
                        startToken: startToken
                    )
                    Issue.record("An indeterminate tmux probe should retry the connection")
                } catch {
                    #expect(error is SSHError)
                }

                #expect(manager.paneStates[tab.rootPaneId]?.tmuxStatus == .background)
                #expect(manager.tmuxResolver.sessionNames[tab.rootPaneId] == "vvterm_existing")
                #expect(manager.tmuxResolver.sessionOwnership[tab.rootPaneId] == .managed)
                #expect(manager.tmuxResolver.hasConfirmedManagedSession(for: tab.rootPaneId))
                #expect(manager.tmuxAttachPrompt == nil)

                manager.finishShellStart(
                    for: tab.rootPaneId,
                    client: disconnectedClient,
                    startToken: startToken
                )
            }
        }
    }

    @Test
    func explicitMissingTmuxProbeClearsAttachmentAndReportsMissing() async {
        await withTmuxEnabled {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Confirmed missing tmux")
                installTab(tab, in: manager, connectionState: .disconnected)
                manager.tmuxResolver.sessionNames[tab.rootPaneId] = "vvterm_existing"
                manager.tmuxResolver.sessionOwnership[tab.rootPaneId] = .managed
                manager.tmuxResolver.confirmManagedSession(for: tab.rootPaneId)
                manager.updatePaneTmuxStatus(tab.rootPaneId, status: .background)

                let client = SSHClient()
                guard let startToken = manager.beginShellStart(
                    for: tab.rootPaneId,
                    client: client
                ) else {
                    Issue.record("Expected shell start")
                    return
                }
                _ = try? await manager.tmuxStartupPlan(
                    for: tab.rootPaneId,
                    serverId: tab.serverId,
                    client: client,
                    startToken: startToken,
                    availabilityResolver: { .confirmedMissing }
                )

                #expect(manager.paneStates[tab.rootPaneId]?.tmuxStatus == .missing)
                #expect(manager.tmuxResolver.sessionNames[tab.rootPaneId] == nil)
                #expect(manager.tmuxResolver.sessionOwnership[tab.rootPaneId] == nil)
                #expect(!manager.tmuxResolver.hasConfirmedManagedSession(for: tab.rootPaneId))

                manager.finishShellStart(
                    for: tab.rootPaneId,
                    client: client,
                    startToken: startToken
                )
            }
        }
    }

    @Test
    func staleMissingTmuxProbeCannotOverwriteReplacementOwner() async {
        await withTmuxEnabled {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Stale tmux probe")
                installTab(tab, in: manager, connectionState: .disconnected)
                manager.tmuxResolver.sessionNames[tab.rootPaneId] = "vvterm_existing"
                manager.tmuxResolver.sessionOwnership[tab.rootPaneId] = .managed
                manager.tmuxResolver.confirmManagedSession(for: tab.rootPaneId)
                manager.updatePaneTmuxStatus(tab.rootPaneId, status: .background)

                let client = SSHClient()
                let gate = TmuxAvailabilityGate()
                guard let staleStartToken = manager.beginShellStart(
                    for: tab.rootPaneId,
                    client: client
                ) else {
                    Issue.record("Expected stale shell start")
                    return
                }

                let stalePlan = Task { @MainActor in
                    do {
                        _ = try await manager.tmuxStartupPlan(
                            for: tab.rootPaneId,
                            serverId: tab.serverId,
                            client: client,
                            startToken: staleStartToken,
                            availabilityResolver: { await gate.waitForResolution() }
                        )
                        return false
                    } catch is CancellationError {
                        return true
                    } catch {
                        Issue.record("Unexpected stale probe error: \(error)")
                        return false
                    }
                }

                #expect(await gate.waitUntilBlocked())
                manager.finishShellStart(
                    for: tab.rootPaneId,
                    client: client,
                    startToken: staleStartToken
                )
                guard let replacementStartToken = manager.beginShellStart(
                    for: tab.rootPaneId,
                    client: client
                ) else {
                    Issue.record("Expected replacement shell start")
                    return
                }
                await gate.resolve(.confirmedMissing)

                #expect(await stalePlan.value)
                #expect(manager.paneStates[tab.rootPaneId]?.tmuxStatus == .background)
                #expect(manager.tmuxResolver.sessionNames[tab.rootPaneId] == "vvterm_existing")
                #expect(manager.tmuxResolver.sessionOwnership[tab.rootPaneId] == .managed)
                #expect(manager.tmuxResolver.hasConfirmedManagedSession(for: tab.rootPaneId))

                manager.finishShellStart(
                    for: tab.rootPaneId,
                    client: client,
                    startToken: replacementStartToken
                )
            }
        }
    }

    @Test
    func cancelledTmuxProbeCannotPublishMissingForCurrentOwner() async {
        await withTmuxEnabled {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Cancelled tmux probe")
                installTab(tab, in: manager, connectionState: .disconnected)
                manager.tmuxResolver.sessionNames[tab.rootPaneId] = "vvterm_existing"
                manager.tmuxResolver.sessionOwnership[tab.rootPaneId] = .managed
                manager.tmuxResolver.confirmManagedSession(for: tab.rootPaneId)
                manager.updatePaneTmuxStatus(tab.rootPaneId, status: .background)

                let client = SSHClient()
                let gate = TmuxAvailabilityGate()
                guard let startToken = manager.beginShellStart(
                    for: tab.rootPaneId,
                    client: client
                ) else {
                    Issue.record("Expected shell start")
                    return
                }

                let cancelledPlan = Task { @MainActor in
                    do {
                        _ = try await manager.tmuxStartupPlan(
                            for: tab.rootPaneId,
                            serverId: tab.serverId,
                            client: client,
                            startToken: startToken,
                            availabilityResolver: { await gate.waitForResolution() }
                        )
                        return false
                    } catch is CancellationError {
                        return true
                    } catch {
                        Issue.record("Unexpected cancelled probe error: \(error)")
                        return false
                    }
                }

                #expect(await gate.waitUntilBlocked())
                cancelledPlan.cancel()
                await gate.resolve(.confirmedMissing)

                #expect(await cancelledPlan.value)
                #expect(manager.paneStates[tab.rootPaneId]?.tmuxStatus == .background)
                #expect(manager.tmuxResolver.sessionNames[tab.rootPaneId] == "vvterm_existing")
                #expect(manager.tmuxResolver.sessionOwnership[tab.rootPaneId] == .managed)
                #expect(manager.tmuxResolver.hasConfirmedManagedSession(for: tab.rootPaneId))

                manager.finishShellStart(
                    for: tab.rootPaneId,
                    client: client,
                    startToken: startToken
                )
            }
        }
    }

    @Test
    func cancelledTmuxPromptCannotResolveReplacementPromptForSamePane() async {
        let resolver = TmuxAttachResolver()
        let paneId = UUID()
        let serverId = UUID()
        let staleRequestId = UUID()
        let replacementRequestId = UUID()

        let staleSelection = Task { @MainActor in
            await resolver.requestSelection(
                requestId: staleRequestId,
                entityId: paneId,
                serverId: serverId,
                availableSessions: [],
                setPrompt: { _ in }
            )
        }
        guard await waitUntil({
            resolver.hasPendingPrompt(requestId: staleRequestId)
        }) else {
            Issue.record("Stale tmux prompt was not enqueued")
            staleSelection.cancel()
            return
        }

        let replacementSelection = Task { @MainActor in
            await resolver.requestSelection(
                requestId: replacementRequestId,
                entityId: paneId,
                serverId: serverId,
                availableSessions: [],
                setPrompt: { _ in }
            )
        }
        guard await waitUntil({
            resolver.hasPendingPrompt(requestId: replacementRequestId)
        }) else {
            Issue.record("Replacement tmux prompt was not enqueued")
            staleSelection.cancel()
            replacementSelection.cancel()
            return
        }

        staleSelection.cancel()
        #expect(await waitUntil({
            resolver.currentPrompt?.id == replacementRequestId
                && !resolver.hasPendingPrompt(requestId: staleRequestId)
        }))

        resolver.resolvePrompt(
            requestId: replacementRequestId,
            selection: .createManaged,
            setPrompt: { _ in }
        )

        #expect(await staleSelection.value == .skipTmux)
        #expect(await replacementSelection.value == .createManaged)
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
    func transientReconnectFailurePreservesAutomaticRetryEligibility() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Transient retry")
            installTab(tab, in: manager, connectionState: .connected)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .transportEnded)
            manager.updatePaneState(
                tab.rootPaneId,
                connectionState: .reconnecting(attempt: 1)
            )
            manager.handleConnectionFailure(for: tab.rootPaneId, error: SSHError.timeout)

            #expect(manager.paneStates[tab.rootPaneId]?.disconnectReason == .transportEnded)
            guard case .failed = manager.paneStates[tab.rootPaneId]?.connectionState else {
                Issue.record("Expected a failed retry state")
                return
            }
        }
    }

    @Test
    func userActionFailureStopsAutomaticRetry() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Manual recovery")
            installTab(tab, in: manager, connectionState: .connected)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .transportEnded)
            manager.handleConnectionFailure(
                for: tab.rootPaneId,
                error: SSHError.authenticationFailed
            )

            #expect(manager.paneStates[tab.rootPaneId]?.disconnectReason == nil)
            guard case .failed = manager.paneStates[tab.rootPaneId]?.connectionState else {
                Issue.record("Expected a failed authentication state")
                return
            }
        }
    }

    @Test
    func staleShellEndCannotDisconnectReplacementShell() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Replacement")
            installTab(tab, in: manager, connectionState: .connected)
            let activeClient = SSHClient()
            let activeShellId = UUID()
            #expect(await startAndRegisterShell(
                activeClient,
                shellId: activeShellId,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                in: manager
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
            #expect(await startAndRegisterShell(
                client,
                paneId: tab.rootPaneId,
                serverId: server.id,
                transport: .mosh,
                in: manager
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

    @Test
    func closeTabUsesLatestManagerStateWhenViewTabIsStale() async {
        await withCleanManager { manager in
            let wasPro = StoreManager.shared.isPro
            StoreManager.shared.isPro = true
            defer { StoreManager.shared.isPro = wasPro }

            let tab = TerminalTab(serverId: UUID(), title: "Close stale tab")
            installTab(tab, in: manager, connectionState: .connected)

            guard let splitPane = manager.splitHorizontal(tab: tab, paneId: tab.rootPaneId) else {
                Issue.record("Split failed unexpectedly")
                return
            }
            manager.updatePaneState(splitPane, connectionState: .connected)

            #expect(
                TerminalLiveActivityPolicy.snapshot(
                    for: manager.paneStates.values.map(\.connectionState)
                )?.activeCount == 2
            )

            manager.closeTab(tab)

            #expect(manager.tabs(for: tab.serverId).isEmpty)
            #expect(manager.paneStates.isEmpty)
            #expect(
                TerminalLiveActivityPolicy.snapshot(
                    for: manager.paneStates.values.map(\.connectionState)
                ) == nil
            )
        }
    }

    #if os(iOS)
    @Test
    func applicationTerminationDisconnectsTabsAndCompletesActivityCleanup() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Termination")
            installTab(tab, in: manager, connectionState: .connected)

            #expect(AppDelegate().handleApplicationWillTerminate())

            #expect(manager.tabs(for: tab.serverId).isEmpty)
            #expect(manager.paneStates.isEmpty)
        }
    }
    #endif
}
