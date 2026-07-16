#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

struct AppSceneLifecyclePolicyTests {
    @Test
    func fullyBackgroundedScenesSuspendTerminals() {
        #expect(AppSceneLifecyclePolicy.shouldSuspendTerminals(
            connectedSceneStates: [.background, .unattached]
        ))
    }

    @Test
    func activeSceneKeepsTerminalsConnected() {
        #expect(!AppSceneLifecyclePolicy.shouldSuspendTerminals(
            connectedSceneStates: [.background, .foregroundActive]
        ))
    }

    @Test
    func inactiveSceneKeepsTerminalsConnectedForSystemOverlays() {
        #expect(!AppSceneLifecyclePolicy.shouldSuspendTerminals(
            connectedSceneStates: [.foregroundInactive]
        ))
    }

    @Test
    @MainActor
    func lastBackgroundedSceneLocksAndSuspendsTerminals() {
        let delegate = AppDelegate()
        var actions: [String] = []

        delegate.handleSceneDidEnterBackground(
            connectedSceneStates: [.background, .unattached],
            lock: { actions.append("lock") },
            suspendTerminals: { actions.append("suspend") }
        )

        #expect(actions == ["lock", "suspend"])
    }

    @Test
    @MainActor
    func anotherForegroundScenePreventsGlobalLockAndSuspension() {
        let delegate = AppDelegate()
        var actions: [String] = []

        delegate.handleSceneDidEnterBackground(
            connectedSceneStates: [.background, .foregroundInactive],
            lock: { actions.append("lock") },
            suspendTerminals: { actions.append("suspend") }
        )

        #expect(actions.isEmpty)
    }

    @Test
    func pausedTerminalResumesFromCurrentSceneFactsWithoutPhaseEdge() {
        #expect(TerminalRenderingPolicy.transition(
            terminalIsActive: true,
            sceneIsActive: true,
            renderingIsPaused: true
        ) == .resume)
    }

    @Test
    func backgroundTerminalPausesFromCurrentSceneFacts() {
        #expect(TerminalRenderingPolicy.transition(
            terminalIsActive: true,
            sceneIsActive: false,
            renderingIsPaused: false
        ) == .pause)
    }

    @Test
    func renderingAlreadyMatchesSceneNeedsNoTransition() {
        #expect(TerminalRenderingPolicy.transition(
            terminalIsActive: true,
            sceneIsActive: true,
            renderingIsPaused: false
        ) == .none)
    }
}
#endif
