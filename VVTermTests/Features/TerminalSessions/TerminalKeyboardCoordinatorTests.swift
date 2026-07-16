#if os(iOS)
import CoreGraphics
import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class TerminalKeyboardInputSessionSpy: TerminalKeyboardInputSession {
    var snapshot = TerminalKeyboardCoordinatorDiagnosticSnapshot(
        windowAttached: true,
        windowIsKey: true,
        sceneActivationState: "foregroundActive",
        isFirstResponder: true,
        isSoftwareInputActive: true
    )
    private(set) var acquireCount = 0
    private(set) var forceSoftwareKeyboardCount = 0
    private(set) var focusWithoutSoftwareKeyboardCount = 0
    private(set) var releaseCount = 0
    private(set) var rebuildCount = 0
    private(set) var accessorySuppressionRequests: [Bool] = []
    var acquireResults: [Bool] = []
    var acquireObservedStates: [Bool] = []
    var forceSoftwareKeyboardResults: [Bool] = []
    var forceSoftwareKeyboardObservedStates: [Bool] = []
    var completesRebuildImmediately = true
    private var pendingRebuildCompletions: [() -> Void] = []

    func keyboardCoordinatorDiagnosticSnapshot() -> TerminalKeyboardCoordinatorDiagnosticSnapshot {
        snapshot
    }

    func acquireTerminalInput() -> Bool {
        acquireCount += 1
        let result = acquireResults.isEmpty ? true : acquireResults.removeFirst()
        let observed = acquireObservedStates.isEmpty ? result : acquireObservedStates.removeFirst()
        snapshot.isFirstResponder = observed
        snapshot.isSoftwareInputActive = observed
        return result
    }

    func forceSoftwareKeyboardInput() -> Bool {
        forceSoftwareKeyboardCount += 1
        let result = forceSoftwareKeyboardResults.isEmpty
            ? true
            : forceSoftwareKeyboardResults.removeFirst()
        let observed = forceSoftwareKeyboardObservedStates.isEmpty
            ? result
            : forceSoftwareKeyboardObservedStates.removeFirst()
        snapshot.isFirstResponder = observed
        snapshot.isSoftwareInputActive = observed
        return result
    }

    func focusTerminalInputWithoutShowingSoftwareKeyboard() -> Bool {
        focusWithoutSoftwareKeyboardCount += 1
        snapshot.isFirstResponder = true
        snapshot.isSoftwareInputActive = true
        return true
    }

    func releaseTerminalInput() {
        releaseCount += 1
        snapshot.isFirstResponder = false
        snapshot.isSoftwareInputActive = false
    }

    func releaseTerminalInputForReacquisition(completion: @escaping () -> Void) {
        rebuildCount += 1
        releaseTerminalInput()
        if completesRebuildImmediately {
            completion()
        } else {
            pendingRebuildCompletions.append(completion)
        }
    }

    func setTerminalInputAccessorySuppressed(_ suppressed: Bool) {
        accessorySuppressionRequests.append(suppressed)
    }

    func resetCommands() {
        acquireCount = 0
        forceSoftwareKeyboardCount = 0
        focusWithoutSoftwareKeyboardCount = 0
        releaseCount = 0
        rebuildCount = 0
        accessorySuppressionRequests.removeAll()
    }

    func completeNextRebuild() {
        guard !pendingRebuildCompletions.isEmpty else { return }
        pendingRebuildCompletions.removeFirst()()
    }
}

struct TerminalKeyboardCoordinatorTests {
    @Test
    func reconnectInputEligibilityRequiresPriorTypingIntent() {
        #expect(TerminalKeyboardCoordinator.paneInputEligible(
            connectionState: .connected,
            shouldRestoreOnReconnect: false
        ))
        #expect(!TerminalKeyboardCoordinator.paneInputEligible(
            connectionState: .connecting,
            shouldRestoreOnReconnect: false
        ))
        #expect(TerminalKeyboardCoordinator.paneInputEligible(
            connectionState: .reconnecting(attempt: 1),
            shouldRestoreOnReconnect: true
        ))
        #expect(!TerminalKeyboardCoordinator.paneInputEligible(
            connectionState: .disconnected,
            shouldRestoreOnReconnect: true
        ))
    }

    @Test
    func desiredInputSessionAndKeyboardPresentationContract() {
        struct Case {
            let name: String
            let inputs: TerminalKeyboardCoordinator.StateInputs
            let expectedInputSessionActive: Bool
            let expectedKeyboardVisible: Bool
        }

        let visible = TerminalKeyboardCoordinator.StateInputs(
            viewActive: true,
            activePaneInputEligible: true,
            activePaneWindowAttached: true,
            userHidKeyboard: false,
            findNavigatorActive: false
        )

        let cases = [
            Case(
                name: "connected active attached",
                inputs: visible,
                expectedInputSessionActive: true,
                expectedKeyboardVisible: true
            ),
            Case(
                name: "user hidden",
                inputs: .init(
                    viewActive: true,
                    activePaneInputEligible: true,
                    activePaneWindowAttached: true,
                    userHidKeyboard: true,
                    findNavigatorActive: false
                ),
                expectedInputSessionActive: true,
                expectedKeyboardVisible: false
            ),
            Case(
                name: "user shown again",
                inputs: visible,
                expectedInputSessionActive: true,
                expectedKeyboardVisible: true
            ),
            Case(
                name: "left terminal view",
                inputs: .init(
                    viewActive: false,
                    activePaneInputEligible: true,
                    activePaneWindowAttached: true,
                    userHidKeyboard: false,
                    findNavigatorActive: false
                ),
                expectedInputSessionActive: false,
                expectedKeyboardVisible: false
            ),
            Case(
                name: "window not attached",
                inputs: .init(
                    viewActive: true,
                    activePaneInputEligible: true,
                    activePaneWindowAttached: false,
                    userHidKeyboard: false,
                    findNavigatorActive: false
                ),
                expectedInputSessionActive: false,
                expectedKeyboardVisible: false
            ),
            Case(
                name: "window attached after mount",
                inputs: visible,
                expectedInputSessionActive: true,
                expectedKeyboardVisible: true
            ),
            Case(
                name: "find navigator active",
                inputs: .init(
                    viewActive: true,
                    activePaneInputEligible: true,
                    activePaneWindowAttached: true,
                    userHidKeyboard: false,
                    findNavigatorActive: true
                ),
                expectedInputSessionActive: false,
                expectedKeyboardVisible: false
            ),
            Case(
                name: "reconnect restores when visible before",
                inputs: visible,
                expectedInputSessionActive: true,
                expectedKeyboardVisible: true
            ),
            Case(
                name: "reconnect stays hidden when hidden before",
                inputs: .init(
                    viewActive: true,
                    activePaneInputEligible: true,
                    activePaneWindowAttached: true,
                    userHidKeyboard: true,
                    findNavigatorActive: false
                ),
                expectedInputSessionActive: true,
                expectedKeyboardVisible: false
            ),
        ]

        for testCase in cases {
            #expect(
                TerminalKeyboardCoordinator.desiredInputSessionActive(inputs: testCase.inputs) == testCase.expectedInputSessionActive,
                "\(testCase.name) input session"
            )
            #expect(
                TerminalKeyboardCoordinator.desiredKeyboardVisible(inputs: testCase.inputs) == testCase.expectedKeyboardVisible,
                "\(testCase.name) keyboard presentation"
            )
        }
    }

    @Test
    @MainActor
    func directTouchDoesNotRestoreKeyboardAfterUserHide() {
        let coordinator = TerminalKeyboardCoordinator()

        coordinator.userRequestedHide()
        #expect(coordinator.isUserHidden)

        coordinator.directTouchOnTerminal(isFocusTap: false)
        #expect(coordinator.isUserHidden)

        coordinator.directTouchOnTerminal(isFocusTap: true)
        #expect(coordinator.isUserHidden)
    }

    @Test
    @MainActor
    func explicitShowRestoresKeyboardAfterUserHide() {
        let coordinator = TerminalKeyboardCoordinator()

        coordinator.userRequestedHide()
        #expect(coordinator.isUserHidden)

        coordinator.userRequestedShow()
        #expect(!coordinator.isUserHidden)
    }

    @Test
    @MainActor
    func reconnectWithTypingIntentKeepsOneInputSessionOwner() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.setPaneInputEligible(
            TerminalKeyboardCoordinator.paneInputEligible(
                connectionState: .reconnecting(attempt: 1),
                shouldRestoreOnReconnect: true
            ),
            for: paneId
        )
        await drainMainQueue()

        #expect(session.releaseCount == 0)
        #expect(session.acquireCount == 0)
        #expect(session.forceSoftwareKeyboardCount == 0)

        coordinator.setPaneInputEligible(
            TerminalKeyboardCoordinator.paneInputEligible(
                connectionState: .connected,
                shouldRestoreOnReconnect: true
            ),
            for: paneId
        )
        await drainMainQueue()

        #expect(session.releaseCount == 0)
        #expect(session.acquireCount == 0)
        #expect(session.forceSoftwareKeyboardCount == 0)
    }

    @Test
    @MainActor
    func onlyActiveTerminalSceneActivationRequestsPresentationRepair() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
        session.resetCommands()

        coordinator.activeTerminalSceneDidActivate(for: UUID())
        await drainMainQueue()

        #expect(session.rebuildCount == 0)
        #expect(session.acquireCount == 0)

        coordinator.activeTerminalSceneDidActivate(for: paneId)
        await drainMainQueue()

        #expect(session.rebuildCount == 1)
        #expect(session.acquireCount == 1)
    }

    @Test
    @MainActor
    func sceneActivationRepairsAcquiredSessionOnceWhenKeyboardNeverPresents() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
        session.snapshot.isFirstResponder = false
        session.snapshot.isSoftwareInputActive = false
        session.resetCommands()

        coordinator.activeTerminalSceneDidActivate(for: paneId)
        await drainMainQueue()

        #expect(session.acquireCount == 1)
        #expect(session.rebuildCount == 0)
        #expect(coordinator.keyboardUITestPresentationVerificationPending)

        try? await Task.sleep(nanoseconds: 1_100_000_000)
        await drainMainQueue()

        #expect(session.acquireCount == 2)
        #expect(session.rebuildCount == 1)
        #expect(coordinator.keyboardUITestPresentationVerificationPending)

        try? await Task.sleep(nanoseconds: 1_100_000_000)
        await drainMainQueue()

        #expect(session.acquireCount == 2)
        #expect(session.rebuildCount == 1)
        #expect(!coordinator.keyboardUITestPresentationVerificationPending)
        #expect(session.accessorySuppressionRequests == [true])
    }

    @Test
    @MainActor
    func terminalReplacementReconcilesNewOwnerAndCancelsOldVerification() async {
        let paneId = UUID()
        let originalSession = TerminalKeyboardInputSessionSpy()
        let replacementSession = TerminalKeyboardInputSessionSpy()
        replacementSession.snapshot.windowAttached = false
        replacementSession.snapshot.windowIsKey = false
        replacementSession.snapshot.isFirstResponder = false
        replacementSession.snapshot.isSoftwareInputActive = false
        var providedSession = originalSession
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? providedSession : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        coordinator.userRequestedHide()
        await drainMainQueue()
        originalSession.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()

        #expect(originalSession.forceSoftwareKeyboardCount == 1)
        #expect(coordinator.keyboardUITestPresentationVerificationPending)

        providedSession = replacementSession
        coordinator.setWindowAttached(false, for: paneId)
        coordinator.terminalProviderIdentityDidChange(for: paneId)
        await drainMainQueue()

        #expect(replacementSession.acquireCount == 0)
        #expect(replacementSession.forceSoftwareKeyboardCount == 0)
        #expect(replacementSession.rebuildCount == 0)
        #expect(!coordinator.keyboardUITestPresentationVerificationPending)

        replacementSession.snapshot.windowAttached = true
        replacementSession.snapshot.windowIsKey = true
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        #expect(replacementSession.acquireCount == 1)
        #expect(replacementSession.forceSoftwareKeyboardCount == 0)
        #expect(replacementSession.rebuildCount == 0)
        #expect(coordinator.keyboardUITestPresentationVerificationPending)

        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        await drainMainQueue()
        await drainMainQueue()

        #expect(!coordinator.keyboardUITestPresentationVerificationPending)
        #expect(originalSession.forceSoftwareKeyboardCount == 1)
        #expect(originalSession.rebuildCount == 0)
        #expect(originalSession.accessorySuppressionRequests.isEmpty)
        #expect(replacementSession.acquireCount == 1)
        #expect(replacementSession.forceSoftwareKeyboardCount == 0)
        #expect(replacementSession.rebuildCount == 0)
        #expect(replacementSession.accessorySuppressionRequests == [false])
    }

    @Test
    @MainActor
    func explicitShowBeginsOnePresentationWithoutRebuildingActiveInput() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        coordinator.userRequestedHide()
        await drainMainQueue()
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()

        #expect(session.acquireCount == 0)
        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(coordinator.keyboardUITestPresentationVerificationPending)
        #expect(session.rebuildCount == 0)
    }

    @Test
    @MainActor
    func explicitShowRepairsUnexpectedlyMissingKeyboardImmediately() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()

        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(session.rebuildCount == 1)
        #expect(coordinator.keyboardUITestPresentationVerificationPending)
        #expect(session.accessorySuppressionRequests.isEmpty)

        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )

        #expect(!coordinator.keyboardUITestPresentationVerificationPending)
        #expect(session.rebuildCount == 1)
        #expect(session.accessorySuppressionRequests == [false])
    }

    @Test
    @MainActor
    func explicitRepairRetriesWhenResponderReacquisitionFails() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
        session.resetCommands()
        session.forceSoftwareKeyboardResults = [false, true]

        coordinator.userRequestedShow()
        await drainMainQueue()
        await drainMainQueue()

        #expect(session.rebuildCount == 1)
        #expect(session.forceSoftwareKeyboardCount == 2)
        #expect(session.snapshot.isSoftwareInputActive)
        #expect(coordinator.keyboardUITestPresentationVerificationPending)
    }

    @Test
    @MainActor
    func explicitReacquisitionFailuresStopAtAttemptLimit() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.forceSoftwareKeyboardResults = [false, false, true]
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        session.resetCommands()
        coordinator.userRequestedShow()
        await drainMainQueue()
        await drainMainQueue()
        await drainMainQueue()

        #expect(session.rebuildCount == 1)
        #expect(session.forceSoftwareKeyboardCount == 2)
        #expect(!session.snapshot.isSoftwareInputActive)
        #expect(!coordinator.keyboardUITestPresentationVerificationPending)
        #expect(session.accessorySuppressionRequests == [true])
    }

    @Test
    @MainActor
    func automaticReacquisitionFailuresStopAtAttemptLimit() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.acquireResults = [false, false, true]
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.directTouchOnTerminal()
        await drainMainQueue()
        await drainMainQueue()
        await drainMainQueue()

        #expect(session.rebuildCount == 1)
        #expect(session.acquireCount == 2)
        #expect(!session.snapshot.isSoftwareInputActive)
        #expect(!coordinator.keyboardUITestPresentationVerificationPending)
        #expect(session.accessorySuppressionRequests == [true])
    }

    @Test
    @MainActor
    func findRelinquishingOwnershipStartsFreshAfterRepairBudgetIsExhausted() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.acquireResults = [false, false]
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.directTouchOnTerminal()
        await drainMainQueue()
        await drainMainQueue()
        await drainMainQueue()

        #expect(session.acquireCount == 2)
        #expect(!session.snapshot.isSoftwareInputActive)

        // UIFindInteraction may resign the terminal before its visibility
        // callback reaches the coordinator. That leaves input already absent
        // when Find takes ownership, so the normal release branch cannot be
        // relied on to reset a stale presentation-repair budget.
        coordinator.setFindNavigatorActive(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()
        session.acquireResults = [true]

        coordinator.setFindNavigatorActive(false, for: paneId)
        await drainMainQueue()

        #expect(session.acquireCount == 1)
        #expect(session.snapshot.isSoftwareInputActive)
    }

    @Test
    @MainActor
    func rebuildCompletionDoesNotReacquireReplacedTerminal() async {
        let paneId = UUID()
        let originalSession = TerminalKeyboardInputSessionSpy()
        originalSession.completesRebuildImmediately = false
        let replacementSession = TerminalKeyboardInputSessionSpy()
        var providedSession = originalSession
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? providedSession : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        originalSession.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()
        #expect(originalSession.rebuildCount == 1)

        providedSession = replacementSession
        originalSession.completeNextRebuild()
        await drainMainQueue()

        #expect(originalSession.forceSoftwareKeyboardCount == 0)
        #expect(!originalSession.snapshot.isSoftwareInputActive)
        #expect(replacementSession.acquireCount == 0)
    }

    @Test
    @MainActor
    func rebuildCompletionDoesNotReacquireAfterInputOwnershipEnds() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.completesRebuildImmediately = false
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()
        #expect(session.rebuildCount == 1)

        coordinator.deactivateInputImmediately()
        session.completeNextRebuild()
        await drainMainQueue()

        #expect(session.forceSoftwareKeyboardCount == 0)
        #expect(!session.snapshot.isSoftwareInputActive)
    }

    @Test
    @MainActor
    func newerExplicitRequestSupersedesDelayedAutomaticReacquisition() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.completesRebuildImmediately = false
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.directTouchOnTerminal()
        await drainMainQueue()
        #expect(session.rebuildCount == 1)

        coordinator.userRequestedShow()
        session.completeNextRebuild()
        await drainMainQueue()
        await drainMainQueue()

        #expect(session.acquireCount == 0)
        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(session.rebuildCount == 1)
        #expect(session.snapshot.isSoftwareInputActive)
        #expect(coordinator.keyboardUITestPresentationVerificationPending)
    }

    @Test
    @MainActor
    func paneSwitchDoesNotTransferDeferredExplicitRequest() async {
        let originalPaneId = UUID()
        let nextPaneId = UUID()
        let originalSession = TerminalKeyboardInputSessionSpy()
        let nextSession = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            switch requestedPaneId {
            case originalPaneId: originalSession
            case nextPaneId: nextSession
            default: nil
            }
        }
        coordinator.setActivePane(originalPaneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: originalPaneId)
        coordinator.setWindowAttached(true, for: originalPaneId)
        coordinator.setPaneInputEligible(true, for: nextPaneId)
        coordinator.setWindowAttached(true, for: nextPaneId)
        await drainMainQueue()

        coordinator.setFindNavigatorActive(true, for: originalPaneId)
        await drainMainQueue()
        coordinator.userRequestedShow()
        await drainMainQueue()

        coordinator.setActivePane(nextPaneId)
        coordinator.setFindNavigatorActive(false, for: nextPaneId)
        await drainMainQueue()

        #expect(nextSession.forceSoftwareKeyboardCount == 0)
    }

    @Test
    @MainActor
    func findUpdateFromInactivePaneDoesNotReleaseActiveTerminal() async {
        let activePaneId = UUID()
        let backgroundPaneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == activePaneId ? session : nil
        }
        coordinator.setActivePane(activePaneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: activePaneId)
        coordinator.setWindowAttached(true, for: activePaneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.setFindNavigatorActive(true, for: backgroundPaneId)
        await drainMainQueue()

        #expect(session.releaseCount == 0)
        #expect(session.snapshot.isSoftwareInputActive)
    }

    @Test
    @MainActor
    func obsoleteCompletionDoesNotReacquireOldTerminalOrExceedNewPaneBudget() async {
        let originalPaneId = UUID()
        let nextPaneId = UUID()
        let originalSession = TerminalKeyboardInputSessionSpy()
        originalSession.completesRebuildImmediately = false
        let nextSession = TerminalKeyboardInputSessionSpy()
        nextSession.snapshot.isFirstResponder = false
        nextSession.snapshot.isSoftwareInputActive = false
        nextSession.acquireResults = [false, false, true]
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            switch requestedPaneId {
            case originalPaneId: originalSession
            case nextPaneId: nextSession
            default: nil
            }
        }
        coordinator.setActivePane(originalPaneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: originalPaneId)
        coordinator.setWindowAttached(true, for: originalPaneId)
        coordinator.setPaneInputEligible(true, for: nextPaneId)
        coordinator.setWindowAttached(true, for: nextPaneId)
        await drainMainQueue()

        coordinator.directTouchOnTerminal()
        await drainMainQueue()
        #expect(originalSession.rebuildCount == 1)

        coordinator.setActivePane(nextPaneId)
        originalSession.completeNextRebuild()
        await drainMainQueue()
        await drainMainQueue()
        await drainMainQueue()

        #expect(originalSession.acquireCount == 0)
        // The new ownership session gets one ordinary acquisition plus two
        // capped repair attempts. The obsolete completion must not add a
        // fourth attempt or reacquire the old terminal.
        #expect(nextSession.acquireCount == 3)
        #expect(nextSession.snapshot.isSoftwareInputActive)
        #expect(coordinator.keyboardUITestPresentationVerificationPending)
    }

    @Test
    @MainActor
    func observedResponderStateOverridesUIKitReturnValue() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.forceSoftwareKeyboardResults = [false]
        session.forceSoftwareKeyboardObservedStates = [true]
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()

        #expect(session.rebuildCount == 1)
        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(session.snapshot.isSoftwareInputActive)
        #expect(coordinator.keyboardUITestPresentationVerificationPending)
    }

    @Test
    @MainActor
    func explicitShowDuringReconnectForcesSoftwareKeyboardWhenSessionReturns() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        coordinator.userRequestedHide()
        await drainMainQueue()
        coordinator.setPaneInputEligible(false, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()

        #expect(session.forceSoftwareKeyboardCount == 0)

        coordinator.setPaneInputEligible(true, for: paneId)
        await drainMainQueue()

        #expect(session.acquireCount == 0)
        #expect(session.forceSoftwareKeyboardCount == 1)
    }

    @Test
    @MainActor
    func explicitShowWaitsForFindToRelinquishInputOwnership() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )

        coordinator.setFindNavigatorActive(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()

        #expect(session.forceSoftwareKeyboardCount == 0)

        coordinator.setFindNavigatorActive(false, for: paneId)
        await drainMainQueue()

        #expect(session.acquireCount == 0)
        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(session.rebuildCount == 0)
    }

    @Test
    @MainActor
    func explicitShowAfterFindRebuildsSessionWhenFindKeyboardMasksTerminalLoss() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        // UIFindInteraction can take the responder before its visibility
        // callback reaches the coordinator. The terminal's broken software
        // input presentation survives that ordinary ownership handoff and is
        // cleared only by a real input-session rebuild.
        session.snapshot.isFirstResponder = false
        session.snapshot.isSoftwareInputActive = false
        coordinator.setFindNavigatorActive(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        // The Find field's keyboard is still globally visible when the user
        // chooses Keyboard and the terminal retakes input. It must not count
        // as proof that the terminal's own software-input session recovered.
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )
        coordinator.userRequestedShow()
        await drainMainQueue()
        coordinator.setFindNavigatorActive(false, for: paneId)
        await drainMainQueue()

        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(session.snapshot.isSoftwareInputActive)
        #expect(session.rebuildCount == 1)
    }

    @Test
    @MainActor
    func explicitShowRepairsTerminalAfterFindDismissalMaskedItsMissingKeyboard() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        session.snapshot.isFirstResponder = false
        session.snapshot.isSoftwareInputActive = false
        coordinator.setFindNavigatorActive(true, for: paneId)
        await drainMainQueue()

        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )
        coordinator.setFindNavigatorActive(false, for: paneId)
        await drainMainQueue()

        // Returning from Find can reacquire the proxy while its still-visible
        // keyboard frame masks the broken terminal input view.
        #expect(session.snapshot.isSoftwareInputActive)
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()

        #expect(session.rebuildCount == 1)
        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(session.snapshot.isSoftwareInputActive)
    }

    @Test
    @MainActor
    func explicitShowPreservesKnownFindRepairAfterUserHide() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        session.snapshot.isFirstResponder = false
        session.snapshot.isSoftwareInputActive = false
        coordinator.setFindNavigatorActive(true, for: paneId)
        await drainMainQueue()
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )
        coordinator.setFindNavigatorActive(false, for: paneId)
        await drainMainQueue()

        coordinator.userRequestedHide()
        await drainMainQueue()
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()

        #expect(session.rebuildCount == 1)
        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(session.snapshot.isSoftwareInputActive)
    }

    @Test
    @MainActor
    func rebuildCompletionWaitsUntilTerminalWindowBecomesKey() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.completesRebuildImmediately = false
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()
        #expect(session.rebuildCount == 1)

        session.snapshot.windowIsKey = false
        session.completeNextRebuild()
        await drainMainQueue()

        #expect(session.acquireCount == 0)
        #expect(session.forceSoftwareKeyboardCount == 0)

        session.snapshot.windowIsKey = true
        coordinator.activeTerminalWindowDidBecomeKey(for: paneId)
        await drainMainQueue()

        #expect(session.acquireCount == 0)
        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(session.rebuildCount == 1)
        #expect(session.snapshot.isSoftwareInputActive)
    }

    @Test(arguments: [false, true])
    @MainActor
    func explicitRebuildSurvivesRouteKeyTransition(
        keyReturnsBeforeCompletion: Bool
    ) async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.completesRebuildImmediately = false
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()
        #expect(session.rebuildCount == 1)

        session.snapshot.windowIsKey = false
        coordinator.setActivePane(nil)
        coordinator.setViewActive(false)
        await drainMainQueue()

        if keyReturnsBeforeCompletion {
            session.snapshot.windowIsKey = true
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.activeTerminalWindowDidBecomeKey(for: paneId)
            await drainMainQueue()
            #expect(session.forceSoftwareKeyboardCount == 0)
        }

        session.completeNextRebuild()
        await drainMainQueue()

        if !keyReturnsBeforeCompletion {
            #expect(session.forceSoftwareKeyboardCount == 0)
            session.snapshot.windowIsKey = true
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.activeTerminalWindowDidBecomeKey(for: paneId)
            await drainMainQueue()
        }

        #expect(session.acquireCount == 0)
        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(session.rebuildCount == 1)
        #expect(session.snapshot.isSoftwareInputActive)
    }

    @Test
    @MainActor
    func explicitRebuildResumesWhenPaneInputBecomesEligible() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.completesRebuildImmediately = false
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()
        #expect(session.rebuildCount == 1)

        coordinator.setPaneInputEligible(false, for: paneId)
        session.completeNextRebuild()
        await drainMainQueue()
        #expect(session.forceSoftwareKeyboardCount == 0)

        // Focus can return through a direct-touch or hardware-key path while
        // the explicit software-keyboard request waits on SSH eligibility.
        session.snapshot.isFirstResponder = true
        session.snapshot.isSoftwareInputActive = true
        coordinator.setPaneInputEligible(true, for: paneId)
        await drainMainQueue()

        #expect(session.acquireCount == 0)
        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(session.rebuildCount == 1)
        #expect(session.snapshot.isSoftwareInputActive)
    }

    @Test
    @MainActor
    func explicitRebuildForcesAfterIndependentReacquisitionBeforeCompletion() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.completesRebuildImmediately = false
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()
        #expect(session.rebuildCount == 1)

        session.snapshot.isFirstResponder = true
        session.snapshot.isSoftwareInputActive = true
        session.completeNextRebuild()
        await drainMainQueue()

        #expect(session.acquireCount == 0)
        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(session.rebuildCount == 1)
        #expect(session.snapshot.isSoftwareInputActive)
    }

    @Test
    @MainActor
    func observedKeyboardHidePreservesAccessoryPairing() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        coordinator.userRequestedShow()
        await drainMainQueue()
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )
        #expect(session.accessorySuppressionRequests == [false])

        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
        #expect(session.accessorySuppressionRequests == [false, true])

        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )
        #expect(session.accessorySuppressionRequests == [false, true, false])
    }

    @Test
    @MainActor
    func missingInitialKeyboardSuppressesAccessoryImmediately() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        coordinator.userRequestedShow()
        await drainMainQueue()
        session.resetCommands()

        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)

        #expect(session.accessorySuppressionRequests == [true])
    }

    @Test
    @MainActor
    func automaticSessionAcquisitionDoesNotForceSoftwareKeyboard() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.snapshot.isFirstResponder = false
        session.snapshot.isSoftwareInputActive = false
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }

        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        #expect(session.acquireCount == 1)
        #expect(session.forceSoftwareKeyboardCount == 0)
    }

    @Test
    @MainActor
    func losingViewOwnershipClearsObservedKeyboardGeometry() {
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.setViewActive(true)
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(x: 0, y: 700, width: 1_024, height: 300)
        )

        #expect(coordinator.softwareKeyboardEndFrame != nil)

        coordinator.setViewActive(false)

        #expect(coordinator.softwareKeyboardEndFrame == nil)
        #expect(!coordinator.isSoftwareKeyboardVisible)
    }

    @Test
    func presentationAlreadyInProgressIsNotRebuilt() {
        #expect(
            TerminalKeyboardCoordinator.presentationRefreshAction(
                keyboardPresentationDesired: true,
                refreshRequested: true,
                softwareInputActive: true,
                softwareKeyboardVisible: false,
                presentationVerificationPending: true,
                refreshAttemptCount: 0,
                refreshAttemptLimit: 2
            ) == .deferUntilVerification
        )
    }

    @Test
    func settledMissingPresentationCanBeRebuiltWithinAttemptLimit() {
        #expect(
            TerminalKeyboardCoordinator.presentationRefreshAction(
                keyboardPresentationDesired: true,
                refreshRequested: true,
                softwareInputActive: true,
                softwareKeyboardVisible: false,
                presentationVerificationPending: false,
                refreshAttemptCount: 0,
                refreshAttemptLimit: 2
            ) == .rebuild
        )
        #expect(
            TerminalKeyboardCoordinator.presentationRefreshAction(
                keyboardPresentationDesired: true,
                refreshRequested: true,
                softwareInputActive: true,
                softwareKeyboardVisible: false,
                presentationVerificationPending: false,
                refreshAttemptCount: 2,
                refreshAttemptLimit: 2
            ) == .none
        )
    }

    @Test
    func visibleKeyboardSupersedesPendingRefresh() {
        #expect(
            TerminalKeyboardCoordinator.presentationRefreshAction(
                keyboardPresentationDesired: true,
                refreshRequested: true,
                softwareInputActive: true,
                softwareKeyboardVisible: true,
                presentationVerificationPending: true,
                refreshAttemptCount: 0,
                refreshAttemptLimit: 2
            ) == .none
        )
    }
}

@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}
#endif
