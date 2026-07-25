// SPDX-License-Identifier: AGPL-3.0-or-later
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
//  this because they hold the coordinator in `@StateObject` (see
//  `PhaseChainBootstrapSheet`), which preserves identity across body re-evals.
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

    private func makeCluster() -> TeleportCluster {
        TeleportCluster(host: "teleport.pcad.it", username: "pier")
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
            // MockSEPKeySigner conforms to TeleportSEPSigning; the bootstrap
            // coordinator keeps a signer for symmetry but doesn't use it in
            // Phase 1, so a default mock is fine.
            signer: MockSEPKeySigner(outcome: .success)
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
            .onReceive(Timer.publish(every: 0.01, on: .main, in: .common).autoconnect()) { _ in
                tick &+= 1
            }
        }

        @MainActor
        private func makeCoordinator() -> TeleportBootstrapCoordinator {
            TeleportBootstrapCoordinator(
                httpClient: http,
                keyRing: keyRing,
                safariPresenter: safari,
                signer: MockSEPKeySigner(outcome: .success)
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
            .onReceive(Timer.publish(every: 0.01, on: .main, in: .common).autoconnect()) { _ in
                tick &+= 1
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
                signer: MockSEPKeySigner(outcome: .success)
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

    // MARK: - Failing test (proves the bug with current production wiring)

    /// With the current production wiring (inline `makeBootstrapCoordinator()`),
    /// the bootstrap coordinator is orphaned by parent body re-evaluations
    /// during the blocking POST. The view's `onChange` never observes
    /// `.success` on a coordinator it still holds, so `onSuccess` is never
    /// invoked. This test FAILS until the production wiring switches to
    /// `@StateObject`.
    func testBootstrapSuccess_firesOnSuccess_whenParentReEvaluatesDuringPost() {
        let cluster = makeCluster()
        let http = MockTeleportHTTPClient()
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
        // Force the hosted view into a window so `.task` + `.onReceive` fire.
        installInWindow(host)

        let expectation = expectation(description: "onSuccess fired with bootstrap result")

        // Poll for up to 5s — the mock POST returns in ~150ms, so 5s is ample
        // even with parent re-evals racing.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            Task { @MainActor in
                if onSuccessResult.value != nil {
                    expectation.fulfill()
                    timer.invalidate()
                }
            }
        }

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

        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            Task { @MainActor in
                if onSuccessResult.value != nil {
                    expectation.fulfill()
                    timer.invalidate()
                }
            }
        }

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

    // MARK: - Hosting helpers

    /// Install a `UIHostingController`'s view in a live window so SwiftUI's
    /// `.task` / `.onReceive` modifiers actually run (a hosted view with no
    /// window never starts its `.task`).
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
