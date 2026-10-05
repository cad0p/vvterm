// SPDX-License-Identifier: MIT
//
//  TeleportBootstrapViewWiringTests.swift
//  VVTermTests
//
//  Regression test for the live-device bug where the Teleport bootstrap sheet
//  stays stuck on "Waiting for Safari approval…" even though the coordinator's
//  logs confirm it reached `state = .success` and stored the cert + ed25519 key.
//
//  Root cause (verified):
//    `ServerSidebarView.teleportSetupSheet` and `ServerFormSheet` construct the
//    `TeleportBootstrapCoordinator` INLINE via `makeBootstrapCoordinator()`
//    inside the sheet content closure — NOT via `@StateObject`. Every parent
//    body re-evaluation therefore constructs a FRESH coordinator whose `state`
//    is `.idle`. During the real (10–60s+) blocking POST, unrelated parent
//    state changes (`ServerManager`/`StoreManager`/`TerminalTabManager`
//    publishing, or the `onSuccess` callback itself mutating
//    `teleportSetupReadiness`) re-evaluate the parent, swap the view's
//    `@ObservedObject` to a fresh `.idle` coordinator, and orphan the one
//    that actually reached `.success`. The view's `onChange` never observes
//    `.success` (or fires it on a coordinator nobody holds), so `onSuccess`
//    is never invoked and the sheet shows `waitingBlock` forever.
//
//  The UI-test harnesses (`TeleportPhaseChainUITestHarness`) do NOT reproduce
//  this because they hold the coordinator in `@StateObject` (see the shared
//  `TeleportBootstrapSheet`), which preserves identity across body re-evals.
//
//  These unit tests host a parent view that mirrors the production inline
//  construction pattern, drive the REAL `TeleportBootstrapCoordinator` (with a
//  mock HTTP client that returns success) to `.success`, and assert that
//  `onSuccess` is invoked. The "inline construction" variant FAILS with the
//  current production wiring (coordinator orphaned); the `@StateObject` variant
//  PASSES.
//
//  See:
//    - VVTerm/Features/Teleport/UI/TeleportBootstrapView.swift (the view's
//      `.onChange(of: coordinator.state)` — correct in isolation)
//    - VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift (the buggy
//      inline `makeBootstrapCoordinator()` wiring — fixed in the follow-up
//      production commit)
//

import SwiftUI
import Combine
import XCTest
@testable import VVTerm

@MainActor
final class TeleportBootstrapViewWiringTests: XCTestCase {

    // MARK: - Shared fixtures

    /// The keyID of the committed fixture user certificate
    /// (`Fixtures/OpenSSH/user-cert-ed25519.pub`). The bootstrap coordinator
    /// requires the issued cert's keyID to equal the configured Teleport user
    /// (the keyID binding check), so the success-path fixtures use the cert's
    /// own keyID — same rule as `TeleportCertBindingCoordinatorTests`.
    private static let fixtureCertKeyID = "user-cert-ed25519"

    private func makeCluster() -> TeleportCluster {
        TeleportCluster(host: "teleport.pcad.it", username: Self.fixtureCertKeyID)
    }

    /// Build the real bootstrap coordinator with mocked infrastructure so the
    /// state machine runs end-to-end without a real Teleport server or Safari.
    private func makeCoordinator(
        http: MockTeleportHTTPClient,
        safari: MockWebAuthenticationSessionPresenter,
        keyRing: MockTeleportKeyRing
    ) -> TeleportBootstrapCoordinator {
        TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: keyRing,
            safariPresenter: safari,
            logging: DefaultTeleportLogging(),
            // MockSEPKeySigner conforms to TeleportSEPSigning; the bootstrap
            // coordinator keeps a signer for symmetry but doesn't use it in
            // Phase 1, so a default mock is fine.
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            tlsKeyPairGenerator: try! TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
    }

    /// Build the real coordinator with protocol-typed seams so the gated
    /// stubs (promoted from `TeleportBootstrapCoordinatorGenerationTests`)
    /// can hold the POST open while the hosted view is removed for #272.
    private func makeGatedCoordinator(
        http: any TeleportHTTPClienting,
        keyRing: any TeleportCredentialStore,
        safari: any WebAuthenticationSessionPresenting
    ) -> TeleportBootstrapCoordinator {
        TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: keyRing,
            safariPresenter: safari,
            logging: DefaultTeleportLogging(),
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            tlsKeyPairGenerator: try! TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
    }

    // MARK: - The bug: inline coordinator construction orphans success

    /// A parent view that mirrors the PRODUCTION wiring: the coordinator is
    /// constructed inline in `body` (like `makeBootstrapCoordinator()`),
    /// NOT held in `@StateObject`. A `tick` `@State` forces periodic body
    /// re-evaluations (mirroring `ServerManager`/`TerminalTabManager`
    /// publishing during the real blocking POST), which recreates the
    /// coordinator and orphans the one running the POST.
    ///
    /// `onSuccess` is recorded so the test can assert whether it fired.
    private struct InlineCoordinatorParent: View {
        let cluster: TeleportCluster
        let http: MockTeleportHTTPClient
        let safari: MockWebAuthenticationSessionPresenter
        let keyRing: MockTeleportKeyRing
        let onSuccessResult: Box<ResultBox>

        /// Toggled on a timer to force body re-evaluations during the POST,
        /// recreating the inline coordinator each time (the production race).
        @State private var tick: Int = 0

        var body: some View {
            // MIRRORS ServerSidebarView.makeBootstrapCoordinator() — a fresh
            // coordinator every body eval.
            let coordinator = makeCoordinator()
            return TeleportBootstrapView(
                coordinator: coordinator,
                cluster: cluster,
                onSuccess: { result in
                    self.onSuccessResult.value = result
                },
                onCancel: {}
            )
            .id(tick)  // force view recreation on tick to amplify the race
            .task {
                // Bounded re-evaluation driver: enough ticks (~0.5s) to race
                // the 0.15s mock POST. A repeating Timer publisher here would
                // outlive the test and keep starting bootstraps after the
                // suite finishes (the CI diagnostics-hang class).
                for _ in 0..<50 {
                    try? await Task.sleep(for: .milliseconds(10))
                    guard !Task.isCancelled else { return }
                    tick &+= 1
                }
            }
        }

        @MainActor
        private func makeCoordinator() -> TeleportBootstrapCoordinator {
            TeleportBootstrapCoordinator(
                httpClient: http,
                keyRing: keyRing,
                safariPresenter: safari,
                logging: DefaultTeleportLogging(),
                signer: MockSEPKeySigner(outcome: .success),
                sshKeyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
                tlsKeyPairGenerator: try! TeleportFixtureSupport.makeFixedTLSGenerator(),
                now: { TeleportFixtureSupport.fixtureClock }
            )
        }
    }

    /// A parent view that mirrors the FIXED wiring: the coordinator is held in
    /// `@StateObject`, preserving identity across body re-evaluations.
    private struct StateObjectCoordinatorParent: View {
        let cluster: TeleportCluster
        let http: MockTeleportHTTPClient
        let safari: MockWebAuthenticationSessionPresenter
        let keyRing: MockTeleportKeyRing
        let onSuccessResult: Box<ResultBox>

        @StateObject private var coordinatorHolder: CoordinatorHolder
        @State private var tick: Int = 0

        @MainActor
        init(
            cluster: TeleportCluster,
            http: MockTeleportHTTPClient,
            safari: MockWebAuthenticationSessionPresenter,
            keyRing: MockTeleportKeyRing,
            onSuccessResult: Box<ResultBox>
        ) {
            self.cluster = cluster
            self.http = http
            self.safari = safari
            self.keyRing = keyRing
            self.onSuccessResult = onSuccessResult
            _coordinatorHolder = StateObject(wrappedValue: CoordinatorHolder(
                http: http,
                safari: safari,
                keyRing: keyRing
            ))
        }

        var body: some View {
            TeleportBootstrapView(
                coordinator: coordinatorHolder.coordinator,
                cluster: cluster,
                onSuccess: { result in
                    self.onSuccessResult.value = result
                },
                onCancel: {}
            )
            .task {
                // See InlineCoordinatorParent: bounded, cancellable ticks.
                for _ in 0..<50 {
                    try? await Task.sleep(for: .milliseconds(10))
                    guard !Task.isCancelled else { return }
                    tick &+= 1
                }
            }
        }
    }

    /// Holds the coordinator so `@StateObject` preserves it across body evals.
    @MainActor
    private final class CoordinatorHolder: ObservableObject {
        let coordinator: TeleportBootstrapCoordinator
        init(
            http: MockTeleportHTTPClient,
            safari: MockWebAuthenticationSessionPresenter,
            keyRing: MockTeleportKeyRing
        ) {
            self.coordinator = TeleportBootstrapCoordinator(
                httpClient: http,
                keyRing: keyRing,
                safariPresenter: safari,
                logging: DefaultTeleportLogging(),
                signer: MockSEPKeySigner(outcome: .success),
                sshKeyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
                tlsKeyPairGenerator: try! TeleportFixtureSupport.makeFixedTLSGenerator(),
                now: { TeleportFixtureSupport.fixtureClock }
            )
        }
    }

    /// A reference type so a value-type View can record the success result.
    @MainActor
    private final class Box<T>: ObservableObject {
        var value: T?
        init() {}
    }
    private typealias ResultBox = TeleportBootstrapCoordinator.BootstrapResult

    /// Drives the conditional inclusion of the production bootstrap view so a
    /// test can remove it from the hierarchy deterministically. This is the
    /// `.onDisappear` a real swipe-down dismissal runs, without relying on
    /// `installInWindow`'s process-lifetime retention.
    @MainActor
    private final class DismissalModel: ObservableObject {
        @Published var showsBootstrap = true
    }

    /// A MainActor reference flag so a SwiftUI lifecycle closure can record
    /// that it ran without capture-by-value surprises.
    @MainActor
    private final class Flag {
        var value = false
    }

    /// Hosts the production view behind a `showsBootstrap` switch; toggling the
    /// model off removes the view (the dismissal path) while an outer
    /// `.onDisappear` records that the removal happened.
    private struct RemovableBootstrapHost<Coordinator: TeleportBootstrapCoordinating>: View {
        @ObservedObject var model: DismissalModel
        let coordinator: Coordinator
        let cluster: TeleportCluster
        let onSuccess: (TeleportBootstrapCoordinator.BootstrapResult) -> Void
        let onDisappear: () -> Void

        var body: some View {
            if model.showsBootstrap {
                TeleportBootstrapView(
                    coordinator: coordinator,
                    cluster: cluster,
                    onSuccess: onSuccess,
                    onCancel: {}
                )
                .onDisappear(perform: onDisappear)
            } else {
                Color.clear
            }
        }
    }

    // MARK: - Failing test (proves the bug with the inline pattern)

    /// With the INLINE `makeBootstrapCoordinator()` pattern (constructing the
    /// coordinator fresh in every `body` evaluation, like the test's
    /// `InlineCoordinatorParent`), the bootstrap coordinator is orphaned by
    /// parent body re-evaluations during the blocking POST. The view's
    /// `onChange` never observes `.success` on a coordinator it still holds,
    /// so `onSuccess` is never invoked.
    ///
    /// This test intentionally exercises the BUGGY inline pattern as a
    /// permanent regression marker. Production wiring NO LONGER uses inline
    /// construction — `ServerSidebarView.teleportSetupSheet` now wraps the
    /// coordinator in `@StateObject` through the shared `TeleportSetupSheet`
    /// (its `TeleportBootstrapSheet`), and `ServerFormSheet` uses the same
    /// shared wrapper directly (see b530ed9, #369). The companion test
    /// `testBootstrapSuccess_firesOnSuccess_whenCoordinatorHeldInStateObject`
    /// proves the `@StateObject` wiring fires `onSuccess` correctly.
    ///
    /// `XCTExpectFailure` documents that this test is EXPECTED to fail with
    /// the inline pattern and prevents it from red CI noise; if someone ever
    /// reverts production back to inline construction, this test's expectation
    /// will need to be re-evaluated. The expectation is NON-STRICT (see issue
    /// #130): reproducing the inline bug requires a timing race (the parent's
    /// periodic re-eval must land during the POST), so when the race misses,
    /// strict mode reports a spurious "but none recorded" failure. Non-strict
    /// records the expected failure when the bug reproduces and never fails CI
    /// when the race misses.
    func testBootstrapSuccess_firesOnSuccess_whenParentReEvaluatesDuringPost() {
        // The inline pattern (fresh coordinator per body eval) is known-buggy:
        // a parent re-eval during the POST recreates the coordinator and
        // orphans the one that reaches `.success`. Production no longer uses
        // this pattern; this test keeps it as a documented regression marker.
        // Non-strict: the inline bug's reproduction is a timing race (the
        // parent's periodic re-eval must land during the POST). When the race
        // misses, strict XCTExpectFailure reports a spurious "but none
        // recorded" failure and turns the marker red (issue #130). Non-strict
        // records the expected failure when the bug reproduces and passes
        // silently when it does not — the marker documents behavior and never
        // gates CI. The companion @StateObject test is the real guard.
        let markerOptions = XCTExpectedFailure.Options()
        markerOptions.isStrict = false
        XCTExpectFailure(
            "Inline coordinator construction orphans the coordinator that reached .success (production uses @StateObject wrapper instead)",
            options: markerOptions
        )

        let cluster = makeCluster()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()
        // Small delay so the parent's periodic re-eval lands during the POST,
        // recreating the inline coordinator (the production race).
        http.scriptedDelay = 0.15
        let safari = MockWebAuthenticationSessionPresenter()
        let keyRing = MockTeleportKeyRing()
        let onSuccessResult = Box<ResultBox>()

        let host = UIHostingController(
            rootView: InlineCoordinatorParent(
                cluster: cluster,
                http: http,
                safari: safari,
                keyRing: keyRing,
                onSuccessResult: onSuccessResult
            )
        )
        // Force the hosted view into a window so `.task` fires.
        installInWindow(host)

        let expectation = expectation(description: "onSuccess fired with bootstrap result")

        // Poll for up to 5s — the mock POST returns in ~150ms, so 5s is ample
        // even with parent re-evals racing. Capture the timer so it is
        // invalidated when `wait` returns (on timeout the repeating timer
        // would otherwise keep firing forever, pinning the host process and
        // tripping the simulator's 600s diagnostic-collection timeout →
        // spurious `TEST FAILED`).
        let pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            Task { @MainActor in
                if onSuccessResult.value != nil {
                    expectation.fulfill()
                    timer.invalidate()
                }
            }
        }
        defer { pollTimer.invalidate() }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertNotNil(
            onSuccessResult.value,
            "onSuccess should fire when the bootstrap coordinator reaches .success — " +
            "with inline coordinator construction the coordinator is orphaned by parent " +
            "body re-evaluations and onSuccess never fires (the live-device bug)"
        )
    }

    // MARK: - Passing test (proves the fix: @StateObject preserves the coordinator)

    /// With the coordinator held in `@StateObject`, parent body re-evaluations
    /// preserve the coordinator's identity, so the view's `onChange` observes
    /// `.success` and `onSuccess` fires.
    func testBootstrapSuccess_firesOnSuccess_whenCoordinatorHeldInStateObject() {
        let cluster = makeCluster()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()
        http.scriptedDelay = 0.15
        let safari = MockWebAuthenticationSessionPresenter()
        let keyRing = MockTeleportKeyRing()
        let onSuccessResult = Box<ResultBox>()

        let host = UIHostingController(
            rootView: StateObjectCoordinatorParent(
                cluster: cluster,
                http: http,
                safari: safari,
                keyRing: keyRing,
                onSuccessResult: onSuccessResult
            )
        )
        installInWindow(host)

        let expectation = expectation(description: "onSuccess fired with bootstrap result")

        // See testBootstrapSuccess_firesOnSuccess_whenParentReEvaluatesDuringPost
        // for why the timer is captured + invalidated in a defer.
        let pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            Task { @MainActor in
                if onSuccessResult.value != nil {
                    expectation.fulfill()
                    timer.invalidate()
                }
            }
        }
        defer { pollTimer.invalidate() }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertNotNil(
            onSuccessResult.value,
            "onSuccess should fire when the bootstrap coordinator (held in @StateObject) reaches .success"
        )
    }

    // MARK: - Coordinator state-machine baseline (always passes)

    /// Baseline: the REAL coordinator, driven directly (no SwiftUI), reaches
    /// `.success` and sets `lastBootstrapResult` when the mock HTTP client
    /// returns a cert. This proves the coordinator itself is correct — the
    /// bug is in the view wiring, not the coordinator.
    func testCoordinator_reachesSuccessAndSetsResult_whenHttpReturnsCert() async {
        let cluster = makeCluster()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()
        let safari = MockWebAuthenticationSessionPresenter()
        let keyRing = MockTeleportKeyRing()
        let coordinator = makeCoordinator(http: http, safari: safari, keyRing: keyRing)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .success, "coordinator should reach .success")
        XCTAssertNotNil(
            coordinator.lastBootstrapResult,
            "lastBootstrapResult should be set on .success"
        )
    }

    // MARK: - #267: retry() restarts the POST + Safari (required-check pin)

    /// The bug: the bootstrap sheet's "Reopen Safari" button called
    /// `retry()` only, and `retry()` cancelled the POST + dismissed Safari
    /// and reset to `.idle` without re-invoking `begin` — so the sheet went
    /// back to the waiting spinner with no Safari and no POST. This pin drives
    /// the REAL coordinator: first attempt fails (1 POST), `retry()` must run
    /// a fresh POST (count 2) and land back on `.failed`, not `.idle`.
    ///
    /// Fails pre-fix: `retry()` starts no POST, so the count stays 1.
    func testRetry_startsFreshPostAndReopensSafari() async {
        let cluster = makeCluster()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessError = URLError(.notConnectedToInternet)
        let safari = MockWebAuthenticationSessionPresenter()
        let keyRing = MockTeleportKeyRing()
        let coordinator = makeCoordinator(http: http, safari: safari, keyRing: keyRing)

        await coordinator.begin(cluster: cluster)
        XCTAssertEqual(coordinator.state, .failed(.networkLost))
        XCTAssertEqual(http.headlessLoginCallCount, 1)
        XCTAssertEqual(safari.openedURLs.count, 1)

        // The script still fails, so the retry must land on `.failed` again
        // (not stay on `.idle` with the spinner) after a fresh POST.
        await coordinator.retry()

        XCTAssertEqual(
            http.headlessLoginCallCount, 2,
            "retry() must start a fresh POST (#267)"
        )
        XCTAssertEqual(
            safari.openedURLs.count, 2,
            "retry() must reopen Safari (#267)"
        )
        XCTAssertEqual(coordinator.state, .failed(.networkLost))
    }

    /// The success half of the same contract: the retry's fresh POST can
    /// succeed, so the sheet advances out of the failure state instead of
    /// waiting forever. Fails pre-fix (no second POST → `.idle`, no result).
    func testRetry_reachesSuccessOnASecondSuccessfulPost() async {
        let cluster = makeCluster()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessError = URLError(.notConnectedToInternet)
        let safari = MockWebAuthenticationSessionPresenter()
        let keyRing = MockTeleportKeyRing()
        let coordinator = makeCoordinator(http: http, safari: safari, keyRing: keyRing)

        await coordinator.begin(cluster: cluster)
        XCTAssertEqual(coordinator.state, .failed(.networkLost))
        XCTAssertEqual(http.headlessLoginCallCount, 1)

        // The second POST returns the fixture cert (bound to the fixed
        // keypair the coordinator is driven with).
        http.scriptedHeadlessError = nil
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()

        await coordinator.retry()

        XCTAssertEqual(http.headlessLoginCallCount, 2)
        XCTAssertEqual(coordinator.state, .success)
        XCTAssertNotNil(coordinator.lastBootstrapResult)
    }

    /// #267 review (L1-2): a retry while the previous attempt is still in
    /// flight must not leave the old Safari session live. The counting
    /// presenter starts a session per `open` and closes it per `cancel`
    /// (it does NOT cancel-before-replace, so a caller-side leak shows as
    /// `liveSessionCount == 2`).
    func testRetry_cancelsLiveSafariSessionBeforeReopening() async {
        let cluster = makeCluster()
        let http = MockTeleportHTTPClient()
        // Keep attempt 1's POST in flight so its Safari session is still
        // live when the retry starts (the rapid-double-attempt window).
        http.scriptedDelay = 0.3
        http.scriptedHeadlessError = URLError(.notConnectedToInternet)
        let safari = MockWebAuthenticationSessionPresenter()
        let keyRing = MockTeleportKeyRing()
        let coordinator = makeCoordinator(http: http, safari: safari, keyRing: keyRing)

        let first = Task { await coordinator.begin(cluster: cluster) }
        await safari.waitUntilOpenStarted(1)
        XCTAssertEqual(safari.liveSessionCount, 1, "attempt 1's Safari session is live")

        let retry = Task { await coordinator.retry() }
        let secondOpenStarted = await safari.waitUntilOpenStarted(2)
        XCTAssertTrue(secondOpenStarted, "retry() must start a second Safari session (#267)")
        XCTAssertEqual(
            safari.liveSessionCount, 1,
            "retry() must cancel the live Safari session before opening the new one — "
                + "a count of 2 means the previous session leaked (L1-2)"
        )

        await first.value
        await retry.value
        XCTAssertEqual(http.headlessLoginCallCount, 2)
        XCTAssertEqual(safari.liveSessionCount, 0, "each failed attempt dismisses its Safari session")
    }

    // MARK: - #272: dismissal tears the flow down (swipe-down path)

    /// `.onDisappear` teardown is state-guarded. The exhaustive switch makes a
    /// future `TeleportBootstrapState` case a compile error; this test pins the
    /// decisions the guard makes, including the two non-obvious ones.
    func testDismissalRequiresTeardownIsExhaustive() {
        XCTAssertTrue(TeleportBootstrapState.idle.dismissalRequiresTeardown)
        XCTAssertTrue(TeleportBootstrapState.preparing.dismissalRequiresTeardown)
        XCTAssertTrue(TeleportBootstrapState.openingSafari.dismissalRequiresTeardown)
        XCTAssertTrue(TeleportBootstrapState.awaitingApproval.dismissalRequiresTeardown)
        XCTAssertFalse(TeleportBootstrapState.success.dismissalRequiresTeardown)
        XCTAssertTrue(
            TeleportBootstrapState.failed(.safariUnavailable).dismissalRequiresTeardown,
            ".failed(.safariUnavailable) keeps the POST running in begin(), so a late success must still be torn down"
        )
        XCTAssertFalse(TeleportBootstrapState.failed(.userCancelled).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportBootstrapState.failed(.timeout).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportBootstrapState.failed(.networkLost).dismissalRequiresTeardown)
        XCTAssertFalse(
            TeleportBootstrapState.failed(.suspended).dismissalRequiresTeardown,
            ".failed(.suspended) is mock-only; the real coordinator never sets it"
        )
        XCTAssertFalse(TeleportBootstrapState.failed(.server("HTTP 500: boom")).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportBootstrapState.failed(.unknown("boom")).dismissalRequiresTeardown)
    }

    /// #272: dismissing while the POST is in flight must tear the flow down
    /// (generation bump + POST cancel + Safari cancel) and must drop the stale
    /// success the released POST then delivers: no keyring write, no `.success`.
    func testDismissalWhileInFlightTearsDownAndDropsStaleWork() async {
        let cluster = makeCluster()
        let http = GatedTeleportHTTPClient()
        let safari = MockWebAuthenticationSessionPresenter()
        let keyRing = MockTeleportKeyRing()
        // Gate nothing on the store: any write is visible as a committed count.
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let coordinator = makeGatedCoordinator(http: http, keyRing: store, safari: safari)

        let model = DismissalModel()
        let disappeared = Flag()
        let host = UIHostingController(rootView: RemovableBootstrapHost(
            model: model,
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: { _ in },
            onDisappear: { disappeared.value = true }
        ))
        installInWindow(host)

        // The hosted view's `.task` starts the bootstrap; the gate holds the
        // POST so the test can dismiss while it is in flight.
        await http.waitUntilStarted(1)
        await awaitState(.awaitingApproval, on: coordinator)
        XCTAssertEqual(safari.liveSessionCount, 1)

        // Remove the production view: the deterministic `.onDisappear` a
        // sheet dismissal runs.
        model.showsBootstrap = false
        XCTAssertTrue(waitUntil { disappeared.value }, "the production view should leave the hierarchy and fire .onDisappear")
        await awaitState(.failed(.userCancelled), on: coordinator)

        XCTAssertGreaterThanOrEqual(safari.cancelCallCount, 1)
        XCTAssertEqual(safari.liveSessionCount, 0, "dismissal must close the live Safari session")
        XCTAssertEqual(http.startedCount, 1, "dismissal must not start another POST")

        // Release the gated POST with a success: the dismissal's generation
        // bump must drop the continuation before any persistence. Absence needs
        // a bound, and the bound must let the MainActor run the resumed
        // continuation: a synchronous run-loop pump (`waitUntil`/`settle`) does
        // NOT — measured in the reverted counterfactual, where the released
        // continuation stayed `.awaitingApproval` through the pump. Poll with
        // real suspension instead, so a stale write that survives the drop is
        // observable and this assertion can fail.
        await http.release(index: 0, with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse()))
        let staleWriteLanded = await waitForStaleWrite(timeout: 0.5) { store.storedCertCount > 0 }
        XCTAssertFalse(
            staleWriteLanded,
            "a stale success must not store the bootstrap cert (storedCertCount=\(store.storedCertCount))"
        )

        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertEqual(store.storedCertCount, 0, "a stale success must not store the bootstrap cert")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
    }

    /// #272 (the issue's exact scenario): a retry already inside `retry()` when
    /// the sheet is dismissed must not restart the flow. The dismissal's
    /// generation bump drops the retry's POST continuation, so the flow cannot
    /// reach `.success` after the sheet is gone.
    func testDismissalDuringRetryDoesNotRestartTheFlow() async {
        let cluster = makeCluster()
        let http = GatedTeleportHTTPClient()
        let safari = MockWebAuthenticationSessionPresenter()
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let coordinator = makeGatedCoordinator(http: http, keyRing: store, safari: safari)

        let model = DismissalModel()
        let disappeared = Flag()
        let host = UIHostingController(rootView: RemovableBootstrapHost(
            model: model,
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: { _ in },
            onDisappear: { disappeared.value = true }
        ))
        installInWindow(host)

        // Attempt 1 (started by the hosted view's `.task`) fails at the gate.
        await http.waitUntilStarted(1)
        await http.release(index: 0, with: .failure(URLError(.notConnectedToInternet)))
        await awaitState(.failed(.networkLost), on: coordinator)

        // Start the retry exactly as the Reopen Safari button does: a tracked
        // task around `retry()`. The view's `.onDisappear` can only cancel this
        // task cooperatively, which is why the coordinator teardown matters.
        let retryTask = Task {
            guard !Task.isCancelled else { return }
            await coordinator.retry()
        }
        await http.waitUntilStarted(2)

        // The failed attempt already called `safari.cancel()` once; the
        // dismissal must add another cancel on top of that baseline.
        let cancelsBeforeDismissal = safari.cancelCallCount

        // Dismiss mid-retry.
        model.showsBootstrap = false
        XCTAssertTrue(waitUntil { disappeared.value }, "the production view should leave the hierarchy and fire .onDisappear")
        await awaitState(.failed(.userCancelled), on: coordinator)
        retryTask.cancel()

        // Release the retry's POST with a success. The dismissal's generation
        // bump must drop it: the flow is over.
        await http.release(index: 1, with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse()))
        await retryTask.value

        XCTAssertEqual(http.startedCount, 2, "a dismissed retry must never start a third POST")
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertEqual(store.storedCertCount, 0)
        XCTAssertGreaterThan(
            safari.cancelCallCount,
            cancelsBeforeDismissal,
            "the dismissal must cancel the coordinator's Safari session on top of the failure-path cancel"
        )
    }

    /// #279 (the issue's exact scenario, latched): the harness removes the
    /// production view while the POST is parked, awaits the *latch*
    /// (`isDismissalLatched` is set synchronously inside the production
    /// `.onDisappear` closure, so it is the correct ordering point), and then
    /// releases the POST with a success **without** awaiting
    /// `.failed(.userCancelled)`. The latch's generation bump must drop the
    /// continuation: no cert store, no result, no `.success`. The scheduled
    /// teardown then still runs.
    func testDismissalWhileInFlightLatchesAndDropsTheStaleSuccess() async {
        let cluster = makeCluster()
        let http = GatedTeleportHTTPClient()
        let safari = MockWebAuthenticationSessionPresenter()
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let coordinator = makeGatedCoordinator(http: http, keyRing: store, safari: safari)

        let model = DismissalModel()
        let disappeared = Flag()
        let host = UIHostingController(rootView: RemovableBootstrapHost(
            model: model,
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: { _ in },
            onDisappear: { disappeared.value = true }
        ))
        installInWindow(host)

        await http.waitUntilStarted(1)
        await awaitState(.awaitingApproval, on: coordinator)

        model.showsBootstrap = false
        XCTAssertTrue(waitUntil { disappeared.value }, "the production view should leave the hierarchy and fire .onDisappear")
        XCTAssertTrue(
            waitUntil { coordinator.isDismissalLatched },
            "the production .onDisappear must latch the dismissal synchronously"
        )

        // Release the parked POST *without* awaiting the scheduled cancel: the
        // latch's synchronous bump is what must drop this continuation.
        await http.release(index: 0, with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse()))
        let staleWriteLanded = await waitForStaleWrite(timeout: 0.5) { store.storedCertCount > 0 }
        XCTAssertFalse(
            staleWriteLanded,
            "a latched dismissal must not store the bootstrap cert (storedCertCount=\(store.storedCertCount))"
        )
        XCTAssertEqual(store.storedCertCount, 0)
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNotEqual(coordinator.state, .success)

        // The scheduled teardown still runs.
        await awaitState(.failed(.userCancelled), on: coordinator)
    }

    /// #272: `.success` is the Phase-1 → Phase-2 hand-off. Dismissing then must
    /// NOT cancel the coordinator: the result stays available to the parent and
    /// `onSuccess` has already fired.
    func testDismissalAfterSuccessKeepsTheHandoff() async {
        let cluster = makeCluster()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()
        let safari = MockWebAuthenticationSessionPresenter()
        let keyRing = MockTeleportKeyRing()
        let coordinator = makeCoordinator(http: http, safari: safari, keyRing: keyRing)

        let model = DismissalModel()
        let disappeared = Flag()
        let success = Box<ResultBox>()
        let host = UIHostingController(rootView: RemovableBootstrapHost(
            model: model,
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: { success.value = $0 },
            onDisappear: { disappeared.value = true }
        ))
        installInWindow(host)

        // The hosted view's `.task` starts the bootstrap and drives `.success`.
        await awaitState(.success, on: coordinator)
        XCTAssertTrue(waitUntil { success.value != nil }, "onSuccess should fire with the bootstrap result")

        // The success path already dismissed Safari once; capture that
        // baseline so the post-dismissal assertion is about the dismissal.
        let cancelsBeforeDismissal = safari.cancelCallCount

        model.showsBootstrap = false
        XCTAssertTrue(waitUntil { disappeared.value }, "the production view should leave the hierarchy and fire .onDisappear")
        settle()

        XCTAssertEqual(coordinator.state, .success, ".success is the hand-off state and must survive dismissal")
        XCTAssertEqual(
            safari.cancelCallCount,
            cancelsBeforeDismissal,
            "dismissing after .success must not cancel the bootstrap"
        )
        XCTAssertNotNil(coordinator.lastBootstrapResult)
        XCTAssertNotNil(success.value)
    }

    // MARK: - Source pins (the call sites a behavioural test cannot see)

    /// The repository root, derived from this file's location
    /// (`VVTermTests/Features/Teleport/TeleportBootstrapViewWiringTests.swift`).
    /// The `VVTERM_PINS_SOURCE_ROOT` override points the scan at a mutated tree
    /// to prove the pin fails there (`TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT`
    /// reaches the test process; never set in CI).
    private func repositoryRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportBootstrapViewWiringTests.swift
            .deletingLastPathComponent()  // Teleport/
            .deletingLastPathComponent()  // Features/
            .deletingLastPathComponent()  // VVTermTests/
    }

    private func bootstrapViewSource() throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "VVTerm/Features/Teleport/UI/TeleportBootstrapView.swift"
            ),
            encoding: .utf8
        )
    }

    /// Collapse all whitespace runs to a single space so the pin matches across
    /// line breaks and indentation.
    private static func whitespaceNormalized(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The bootstrap Cancel button must latch *before* scheduling `cancel()`;
    /// the `onCancel()` tail makes the sequence unique to that call site (the
    /// `.onDisappear` site ends with the scheduled task, with no `onCancel()`).
    func testBootstrapViewCancelButtonLatchesBeforeTheScheduledTeardown() throws {
        let source = Self.whitespaceNormalized(try bootstrapViewSource())
        XCTAssertTrue(
            source.contains("coordinator.latchDismissal() Task { await coordinator.cancel() } onCancel()"),
            "the bootstrap Cancel button must latch synchronously before scheduling cancel()"
        )
    }

    /// The bootstrap `.onDisappear` must keep the `dismissalRequiresTeardown`
    /// gate, latch, and then schedule `cancel()` — in that order — and the
    /// view must latch at exactly those two call sites.
    func testBootstrapViewOnDisappearLatchesBeforeTheScheduledTeardown() throws {
        let source = Self.whitespaceNormalized(try bootstrapViewSource())
        XCTAssertTrue(
            source.contains(
                "guard coordinator.state.dismissalRequiresTeardown else { return } coordinator.latchDismissal() Task { await coordinator.cancel() }"
            ),
            "the bootstrap .onDisappear must gate on dismissalRequiresTeardown, latch, then schedule cancel()"
        )
        XCTAssertEqual(
            source.components(separatedBy: "coordinator.latchDismissal()").count - 1,
            2,
            "the bootstrap view must latch at exactly the toolbar Cancel and .onDisappear"
        )
    }

    // MARK: - Hosting helpers

    /// Bounded state wait: suspends until `coordinator.state == expected`, and
    /// fails the test (rather than hanging to the suite's execution allowance)
    /// if it never arrives. Signal-driven via the `@Published` state, so it is
    /// deterministic; the timeout exists only to keep the counterfactual
    /// (teardown removed) fast.
    private func awaitState(
        _ expected: TeleportBootstrapState,
        on coordinator: TeleportBootstrapCoordinator,
        timeout: TimeInterval = 5
    ) async {
        if coordinator.state == expected { return }
        let reached = expectation(description: "coordinator state reaches \(expected)")
        var cancellable: AnyCancellable?
        cancellable = coordinator.$state.sink { state in
            guard state == expected else { return }
            reached.fulfill()
            cancellable?.cancel()
        }
        await fulfillment(of: [reached], timeout: timeout)
    }

    /// Bounded run-loop pump for post-gate assertions that have no completion
    /// signal (e.g. "this stale continuation was dropped, not committed").
    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Bounded poll that suspends (rather than pumping the run loop) so the
    /// MainActor can run a resumed continuation. Used for the stale-write
    /// signal: the release → `handlePostSuccess` → store path has no I/O
    /// suspension, so a surviving stale write lands within a few turns.
    private func waitForStaleWrite(
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Pump the main run loop in bounded steps until `condition` holds. Used
    /// only for SwiftUI lifecycle signals (`.onDisappear`); the network gates
    /// stay continuation-based, so nothing here waits on I/O or sleeps.
    /// Returns the final condition value so the caller asserts (bounded).
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Install a `UIHostingController`'s view in a live window so SwiftUI's
    /// `.task` modifiers actually run (a hosted view with no window never
    /// starts its `.task`).
    ///
    /// The host/window pair is intentionally retained for the process
    /// lifetime (the associated object retains the window and the window
    /// retains the host). Forcing the view tree to deallocate here hits a
    /// pre-existing local simulator-runtime bug in the MainActor deinit
    /// back-deployment path (`libmalloc: pointer being freed was not
    /// allocated`), which is environment-specific. The re-evaluation work the
    /// views drive is bounded and cancellable instead (see the `.task` loops),
    /// so a retained view cannot keep the test process busy after the suite
    /// finishes.
    private func installInWindow(_ host: UIHostingController<some View>) {
        #if canImport(UIKit)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        // Retain the window for the test's lifetime.
        objc_setAssociatedObject(host, &TeleportBootstrapViewWiringTests.windowKey, window, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        #endif
    }

    nonisolated(unsafe) private static var windowKey: UInt8 = 0
}

#if canImport(UIKit)
import UIKit
import ObjectiveC
#endif
