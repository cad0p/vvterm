#if os(iOS)
import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TerminalScreenAwakeCoordinatorTests {
    @Test
    func requestRequiresEnabledVisibleForegroundTerminalRoute() {
        #expect(
            TerminalScreenAwakeCoordinator.shouldRequest(
                preferenceEnabled: true,
                routeVisible: true,
                terminalSelected: true,
                sceneIsInBackground: false
            )
        )
        #expect(
            !TerminalScreenAwakeCoordinator.shouldRequest(
                preferenceEnabled: false,
                routeVisible: true,
                terminalSelected: true,
                sceneIsInBackground: false
            )
        )
        #expect(
            !TerminalScreenAwakeCoordinator.shouldRequest(
                preferenceEnabled: true,
                routeVisible: false,
                terminalSelected: true,
                sceneIsInBackground: false
            )
        )
        #expect(
            !TerminalScreenAwakeCoordinator.shouldRequest(
                preferenceEnabled: true,
                routeVisible: true,
                terminalSelected: false,
                sceneIsInBackground: false
            )
        )
        #expect(
            !TerminalScreenAwakeCoordinator.shouldRequest(
                preferenceEnabled: true,
                routeVisible: true,
                terminalSelected: true,
                sceneIsInBackground: true
            )
        )
    }

    @Test
    func activeRequestsAreAggregatedAcrossTerminalScenes() {
        var idleTimerValues: [Bool] = []
        let coordinator = TerminalScreenAwakeCoordinator { isDisabled in
            idleTimerValues.append(isDisabled)
        }
        let firstScene = UUID()
        let secondScene = UUID()

        coordinator.update(isRequested: true, for: firstScene)
        coordinator.update(isRequested: true, for: firstScene)
        coordinator.update(isRequested: true, for: secondScene)
        #expect(idleTimerValues == [true])

        coordinator.update(isRequested: false, for: firstScene)
        #expect(idleTimerValues == [true])

        coordinator.update(isRequested: true, for: secondScene)
        coordinator.update(isRequested: false, for: secondScene)
        coordinator.update(isRequested: false, for: secondScene)
        #expect(idleTimerValues == [true, false])
    }
}
#endif
