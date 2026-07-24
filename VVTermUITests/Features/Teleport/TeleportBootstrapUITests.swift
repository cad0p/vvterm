// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportBootstrapUITests.swift
//  VVTermUITests
//
//  Layer 2 UI tests for the Phase-1 bootstrap error-recovery matrix
//  (mockup C in the 2.2 UI design doc).
//
//  Each test injects a `MockTeleportBootstrapCoordinator` with a specific
//  `Scenario`, drives the state machine, and asserts the recovery UX state
//  transition. An `XCTAttachment` screenshot is captured at key states
//  (initial, error, success) with `.keepAlways` lifetime — the visual
//  regression artifact pattern from the design doc's CI strategy.
//
//  These tests target the coordinator protocol (not the SwiftUI views,
//  which the parallel agent is building) — they verify the state-machine
//  coverage + the mock injection mechanism. Once the views land, they'll
//  observe the same `@Published var state` these tests drive, so the
//  assertions carry over unchanged.
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup C —
//      the 7-row bootstrap matrix; CI strategy Layer 2)
//    - VVTermUITests/Features/Teleport/MockTeleportBootstrapCoordinator.swift
//

import XCTest
@testable import VVTerm

@MainActor
final class TeleportBootstrapUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Drive a bootstrap coordinator to a terminal state and assert it.
    /// Captures a screenshot at the terminal state for visual regression.
    private func assertBootstrapReaches(
        _ expected: TeleportBootstrapState,
        scenario: MockTeleportBootstrapCoordinator.Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let coordinator = MockTeleportBootstrapCoordinator(scenario: scenario, delay: 0.01)
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")

        // Initial state — screenshot for the "idle" baseline.
        XCTAssertEqual(coordinator.state, .idle, "initial state should be .idle", file: file, line: line)
        attachScreenshot(named: "bootstrap-\(scenario)-initial")

        await coordinator.begin(cluster: cluster)

        // Wait for the state to settle (the mock's delay is 10ms × ~4 steps).

        XCTAssertEqual(coordinator.state, expected, file: file, line: line)

        // Terminal-state screenshot — .keepAlways for CI visual diff.
        attachScreenshot(named: "bootstrap-\(scenario)-terminal")
    }

    /// Attach a screenshot of the current test state. In a protocol-level test
    /// there's no app window to screenshot, so we attach a placeholder that
    /// records the test name + state — when the SwiftUI views land, this
    /// helper will capture `app.screenshot()` instead (the pattern from
    /// VVTermUITestsLaunchTests).
    private func attachScreenshot(named name: String) {
        // The design doc's CI strategy calls for XCTAttachment screenshots at
        // key states. In the protocol-level tests (no app window), we attach
        // a text marker so the CI artifact records which state was reached.
        // When the views land, replace this with:
        //   let attachment = XCTAttachment(screenshot: app.screenshot())
        let attachment = XCTAttachment(string: "state-marker: \(name)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - The 7-row bootstrap matrix (mockup C)

    func testBootstrap_happyPath_reachesSuccess() async {
        // Happy path: the user approves in Safari → POST returns with a cert →
        // success. Advances to the registration sheet.
        await assertBootstrapReaches(.success, scenario: .happyPath)
    }

    func testBootstrap_alreadyLoggedIn_reachesSuccess() async {
        // The user was already logged in elsewhere → POST returns immediately
        // with a cert → silent success (same UX as happyPath).
        await assertBootstrapReaches(.success, scenario: .alreadyLoggedIn)
    }

    func testBootstrap_userCancelsInSafari_reachesFailedUserCancelled() async {
        // The user cancelled in Safari (ASWebAuthenticationSessionError).
        // → .failed(.userCancelled) → "Setup cancelled. Tap retry to start again."
        await assertBootstrapReaches(
            .failed(.userCancelled),
            scenario: .userCancelsInSafari
        )
    }

    func testBootstrap_timeout_reachesFailedTimeout() async {
        // The 180s server-side timeout fired (POST returned with no cert).
        // → .failed(.timeout) → "Safari approval timed out. Tap retry."
        await assertBootstrapReaches(
            .failed(.timeout),
            scenario: .timeout
        )
    }

    func testBootstrap_networkLost_reachesFailedNetworkLost() async {
        // The URLSession failed (no connection / timeout / DNS).
        // → .failed(.networkLost) → "Network connection lost. Tap retry."
        await assertBootstrapReaches(
            .failed(.networkLost),
            scenario: .networkLost
        )
    }

    func testBootstrap_suspended_reachesFailedSuspended_thenSuccessOnRetry() async {
        // The app was backgrounded mid-POST → suspended. On retry → success.
        // This is a two-step assertion: first call → .failed(.suspended),
        // second call (after retry) → .success.
        let coordinator = MockTeleportBootstrapCoordinator(scenario: .suspended, delay: 0.01)
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")

        await coordinator.begin(cluster: cluster)
        XCTAssertEqual(coordinator.state, .failed(.suspended))
        attachScreenshot(named: "bootstrap-suspended-suspended")

        // Retry: the sheet calls retry() then begin() again.
        await coordinator.retry()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.retryCallCount, 1)

        await coordinator.begin(cluster: cluster)
        XCTAssertEqual(coordinator.state, .success)
        XCTAssertEqual(coordinator.beginCallCount, 2, "begin should have been called twice (initial + retry)")
        attachScreenshot(named: "bootstrap-suspended-success-after-retry")
    }

    func testBootstrap_safariUnavailable_reachesFailedSafariUnavailable() async {
        // ASWebAuthenticationSession.start() returned false (Safari disabled).
        // → .failed(.safariUnavailable) → "Open Safari manually:" + URL.
        await assertBootstrapReaches(
            .failed(.safariUnavailable),
            scenario: .safariUnavailable
        )
    }

    func testBootstrap_serverError_reachesFailedServerWithMessageVerbatim() async {
        // The Teleport server returned a non-2xx status. The message is
        // surfaced verbatim.
        let serverMessage = "cluster not found"
        await assertBootstrapReaches(
            .failed(.server(serverMessage)),
            scenario: .serverError(serverMessage)
        )
    }

    // MARK: - Retry behavior (recovery UX)

    func testBootstrap_retry_afterUserCancel_resetsToIdleThenReachesSuccess() async {
        // After a failure, the retry button resets state to .idle and the
        // sheet re-invokes begin(). This test asserts the retry path works
        // for the user-cancel scenario (the most common recovery).
        let coordinator = MockTeleportBootstrapCoordinator(scenario: .userCancelsInSafari, delay: 0.01)
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")

        await coordinator.begin(cluster: cluster)
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        // User taps Retry.
        await coordinator.retry()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.retryCallCount, 1)
        attachScreenshot(named: "bootstrap-retry-after-cancel-idle")

        // The sheet re-invokes begin() — this time the mock still produces
        // userCancelsInSafari (the scenario doesn't change), so we reach
        // .failed(.userCancelled) again. The point is the retry mechanism
        // works, not that the scenario flips.
        await coordinator.begin(cluster: cluster)
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
        XCTAssertEqual(coordinator.beginCallCount, 2)
    }

    func testBootstrap_cancel_setsFailedUserCancelled() async {
        // The Cancel button cancels an in-flight bootstrap. The real
        // coordinator cancels the POST + dismisses Safari → .failed(.userCancelled).
        let coordinator = MockTeleportBootstrapCoordinator(scenario: .happyPath, delay: 0.01)
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")

        // Start begin() in a detached task so we can cancel mid-flight.
        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        // Yield to let the detached task start (the mock's first Task.sleep
        // is 10ms; we yield a few times to let it enter .preparing).
        for _ in 0..<10 { await Task.yield() }

        await coordinator.cancel()
        XCTAssertEqual(coordinator.cancelCallCount, 1)
        // The state is .failed(.userCancelled) after cancel.
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
        attachScreenshot(named: "bootstrap-cancel-failed")

        // Clean up the detached task.
        await beginTask.value
    }

    // MARK: - State isolation

    func testBootstrap_eachScenarioProducesCorrectTerminalState() async {
        // A single test that runs through every scenario and asserts the
        // terminal state — a regression guard against future refactors that
        // might swap two error cases.
        let expectations: [(MockTeleportBootstrapCoordinator.Scenario, TeleportBootstrapState)] = [
            (.happyPath, .success),
            (.alreadyLoggedIn, .success),
            (.userCancelsInSafari, .failed(.userCancelled)),
            (.timeout, .failed(.timeout)),
            (.networkLost, .failed(.networkLost)),
            (.safariUnavailable, .failed(.safariUnavailable)),
            (.serverError("err"), .failed(.server("err"))),
        ]

        for (scenario, expected) in expectations {
            let coordinator = MockTeleportBootstrapCoordinator(scenario: scenario, delay: 0.01)
            await coordinator.begin(cluster: TeleportCluster(host: "h", username: "u"))
            XCTAssertEqual(
                coordinator.state, expected,
                "scenario \(scenario) produced wrong terminal state: got \(coordinator.state)"
            )
        }
    }
}
