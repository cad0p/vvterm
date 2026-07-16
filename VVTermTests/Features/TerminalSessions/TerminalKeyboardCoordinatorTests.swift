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
        snapshot.isFirstResponder = true
        snapshot.isSoftwareInputActive = true
        return true
    }

    func releaseTerminalInput() {
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
    func desiredInputSessionAndKeyboardPresentationContract() {
        struct Case {
            let name: String
            let inputs: TerminalKeyboardCoordinator.StateInputs
            let expectedInputSessionActive: Bool
            let expectedKeyboardVisible: Bool
        }

        let visible = TerminalKeyboardCoordinator.StateInputs(
            viewActive: true,
            activePaneConnected: true,
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
                    activePaneConnected: true,
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
                    activePaneConnected: true,
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
                    activePaneConnected: true,
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
                    activePaneConnected: true,
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
                    activePaneConnected: true,
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
    func explicitShowBeginsOnePresentationWithoutRebuildingActiveInput() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        let coordinator = TerminalKeyboardCoordinator()
        coordinator.terminalProvider = { requestedPaneId in
            requestedPaneId == paneId ? session : nil
        }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setFindNavigatorActive(true)
        await drainMainQueue()
        session.resetCommands()
        session.acquireResults = [true]

        coordinator.setFindNavigatorActive(false)
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
        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setPaneConnected(true, for: originalPaneId)
        coordinator.setWindowAttached(true, for: originalPaneId)
        coordinator.setPaneConnected(true, for: nextPaneId)
        coordinator.setWindowAttached(true, for: nextPaneId)
        await drainMainQueue()

        coordinator.setFindNavigatorActive(true)
        await drainMainQueue()
        coordinator.userRequestedShow()
        await drainMainQueue()

        coordinator.setActivePane(nextPaneId)
        coordinator.setFindNavigatorActive(false)
        await drainMainQueue()

        #expect(nextSession.forceSoftwareKeyboardCount == 0)
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
        coordinator.setPaneConnected(true, for: originalPaneId)
        coordinator.setWindowAttached(true, for: originalPaneId)
        coordinator.setPaneConnected(true, for: nextPaneId)
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
        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setPaneConnected(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        coordinator.userRequestedHide()
        await drainMainQueue()
        coordinator.setPaneConnected(false, for: paneId)
        await drainMainQueue()
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()

        #expect(session.forceSoftwareKeyboardCount == 0)

        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setPaneConnected(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()

        coordinator.setFindNavigatorActive(true)
        await drainMainQueue()
        session.resetCommands()

        coordinator.userRequestedShow()
        await drainMainQueue()

        #expect(session.forceSoftwareKeyboardCount == 0)

        coordinator.setFindNavigatorActive(false)
        await drainMainQueue()

        #expect(session.acquireCount == 0)
        #expect(session.forceSoftwareKeyboardCount == 1)
        #expect(session.rebuildCount == 0)
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
        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setPaneConnected(true, for: paneId)
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
        coordinator.setPaneConnected(true, for: paneId)
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
