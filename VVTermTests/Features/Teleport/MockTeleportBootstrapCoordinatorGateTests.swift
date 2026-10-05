// SPDX-License-Identifier: MIT
//
//  MockTeleportBootstrapCoordinatorGateTests.swift
//  VVTermTests
//
//  Unit coverage for the `holdsForApproval` gate seam in
//  `MockTeleportBootstrapCoordinator` (issue #277). The phase-chain UI
//  harness constructs the mock with `holdsForApproval: true` and parks it
//  in `.awaitingApproval` until the test taps the release control, so the
//  UI test observes a stable state instead of the ~150 ms happyPath
//  window. The default-off contract keeps the other three harnesses
//  behaviour-identical.
//
//  Assertions:
//    (a) default-off `begin` reaches `.success`;
//    (b) a held `begin` stays non-terminal until `releaseApproval()` and
//        then reaches `.success`;
//    (c) `cancel()` while held leaves `.failed(.userCancelled)` with no
//        `lastBootstrapResult`, and a later `begin` still reaches
//        `.success` (the per-invocation reset);
//    (d) a release before/during `begin` is harmless (idempotent).
//
//  The suite runs on the mock's 50 ms poll cadence plus one deliberate
//  two-cadence (100 ms) stability sleep in case (b); it completes in well
//  under a second.
//

#if DEBUG
import Foundation
import Testing
@testable import VVTerm

@MainActor
struct MockTeleportBootstrapCoordinatorGateTests {

    private func makeCluster() -> TeleportCluster {
        TeleportCluster(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            host: "teleport.example.com",
            port: 22,
            username: "tester"
        )
    }

    /// Polls `predicate` at the mock's own 50 ms cadence until it is true or
    /// the timeout expires. A timeout leaves the following `#expect` to
    /// report the real state.
    private func waitUntil(
        _ predicate: @MainActor () -> Bool,
        timeout: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test
    func defaultOffBeginReachesSuccess() async {
        let mock = MockTeleportBootstrapCoordinator(scenario: .happyPath)
        await mock.begin(cluster: makeCluster())
        #expect(mock.state == .success)
        #expect(mock.lastBootstrapResult != nil)
        // A non-gated instance never engaged a hold.
        #expect(mock.releaseApproval() == false)
    }

    @Test
    func heldBeginStaysNonTerminalUntilRelease() async {
        let mock = MockTeleportBootstrapCoordinator(scenario: .happyPath, holdsForApproval: true)
        let begin = Task { await mock.begin(cluster: makeCluster()) }
        await waitUntil { mock.state == .awaitingApproval }
        #expect(mock.state == .awaitingApproval)
        #expect(mock.lastBootstrapResult == nil)

        // Stay held across two poll cadences: the state must not advance on
        // its own.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(mock.state == .awaitingApproval)

        #expect(mock.releaseApproval() == true)
        await begin.value
        #expect(mock.state == .success)
        #expect(mock.lastBootstrapResult != nil)
    }

    @Test
    func cancelWhileHeldIsTerminalAndALaterBeginSucceeds() async {
        let mock = MockTeleportBootstrapCoordinator(scenario: .happyPath, holdsForApproval: true)
        let firstBegin = Task { await mock.begin(cluster: makeCluster()) }
        await waitUntil { mock.state == .awaitingApproval }

        await mock.cancel()
        #expect(mock.state == .failed(.userCancelled))
        await firstBegin.value
        #expect(mock.state == .failed(.userCancelled))
        #expect(mock.lastBootstrapResult == nil)

        // The per-invocation reset: the sticky cancelled-while-held flag must
        // not swallow the next begin.
        await mock.begin(cluster: makeCluster())
        #expect(mock.state == .success)
        #expect(mock.lastBootstrapResult != nil)
    }

    @Test
    func releaseBeforeBeginIsHarmless() async {
        let mock = MockTeleportBootstrapCoordinator(scenario: .happyPath, holdsForApproval: true)
        #expect(mock.releaseApproval() == true)
        #expect(mock.releaseApproval() == false)

        let begin = Task { await mock.begin(cluster: makeCluster()) }
        // Time-bounded: if the pre-release did NOT disarm the hold, this wait
        // expires at 2 s (well below the mock's 30 s self-release) and the
        // `#expect` below reds instead of passing via the self-release.
        await waitUntil({ mock.state == .success }, timeout: 2)
        #expect(mock.state == .success)
        #expect(mock.lastBootstrapResult != nil)
        await begin.value
    }
}
#endif
