// SPDX-License-Identifier: MIT
//
//  TeleportLoginDismissalWiringTests.swift
//  VVTermTests
//
//  Pins the login sheet's dismissal path (#240, commit 2): the shared
//  `TeleportLoginView` must latch the dismissal synchronously — on the toolbar
//  Cancel and on `.onDisappear` (swipe-down / close) — before the async
//  teardown is scheduled, so a continuation that has not yet passed its next
//  re-take cannot start a keyring write or a terminal `.success`.
//
//  The behavioural test hosts the production view, removes it mid-flow, awaits
//  `isDismissalLatched` (set synchronously inside the production `.onDisappear`
//  closure, so it is the correct ordering point), then releases the parked
//  `loginFinish` and asserts nothing landed. The source pins are the tripwire
//  for the call sites themselves: a behavioural test cannot see a missing
//  `latchDismissal()` call when the scheduled `cancel()` happens to win the
//  race anyway.
//

#if DEBUG
import SwiftUI
import Combine
import XCTest
@testable import VVTerm

@MainActor
final class TeleportLoginDismissalWiringTests: XCTestCase {

    // MARK: - Fixtures

    /// The keyID of the committed fixture user certificate
    /// (`Fixtures/OpenSSH/user-cert-ed25519.pub`); the login coordinator binds
    /// the issued cert's keyID to the configured Teleport user.
    private static let fixtureCertKeyID = "user-cert-ed25519"

    private static let credentialID = Data([1, 2, 3, 4])

    private func makeCluster() -> TeleportCluster {
        TeleportCluster(host: "teleport.pcad.it", username: Self.fixtureCertKeyID)
    }

    /// A seeded keyring: the reads resolve, so `storeLoginCert` is a real
    /// write (an unseeded keyring would make the absence assertions vacuous).
    private func makeRegisteredKeyRing(clusterId: UUID) -> MockTeleportKeyRing {
        let keyRing = MockTeleportKeyRing()
        keyRing.seed(
            clusterId: clusterId,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: Self.credentialID,
                userHandle: Data("user-handle".utf8),
                deviceName: "test-device"
            )
        )
        return keyRing
    }

    /// The verified login fixture chain (see
    /// `TeleportLoginCoordinatorGenerationTests`, which carries the same
    /// helper): a fixed SSH keypair bound to the fixture cert, a mock SEP
    /// signer with a created key, the fixture clock, and a gated HTTP client.
    private func makeLoginCoordinator(
        http: any TeleportHTTPClienting,
        keyRing: any TeleportCredentialStore
    ) throws -> TeleportLoginCoordinator {
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: Self.credentialID)
        return TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: signer,
            keyPairGenerator: FixedTeleportSSHKeyPairGenerator(publicKey: TeleportFixtureSupport.fixedSSHPublicKey),
            now: { TeleportFixtureSupport.fixtureClock }
        )
    }

    // MARK: - The dismissal gate is exhaustive

    /// The login `.onDisappear` gate is an exhaustive switch (no `default`), so
    /// a future state case is a compile error rather than a silent mis-map.
    /// Mirrors the bootstrap's `testDismissalRequiresTeardownIsExhaustive`.
    func testLoginDismissalRequiresTeardownIsExhaustive() {
        XCTAssertTrue(TeleportLoginState.idle.dismissalRequiresTeardown)
        XCTAssertTrue(TeleportLoginState.awaitingFaceID.dismissalRequiresTeardown)
        XCTAssertTrue(TeleportLoginState.fetchingCert.dismissalRequiresTeardown)
        XCTAssertFalse(
            TeleportLoginState.success(certValidUntil: Date(), logins: ["alice"]).dismissalRequiresTeardown,
            ".success is the host-login hand-off and must survive a dismissal"
        )
        XCTAssertFalse(TeleportLoginState.failed(.faceIDCancelled).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportLoginState.failed(.faceIDUnavailable("locked")).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportLoginState.failed(.server("HTTP 500: boom")).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportLoginState.failed(.networkLost).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportLoginState.failed(.noRegisteredKey).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportLoginState.failed(.unknown("boom")).dismissalRequiresTeardown)
    }

    // MARK: - The swipe-down dismissal latches and drops the parked work

    /// The issue's scenario for the login sheet: remove the production view
    /// mid-flow, await the latch (`isDismissalLatched` is set synchronously in
    /// the production `.onDisappear`), release the parked `loginFinish` with a
    /// valid success *without* awaiting `.failed(.faceIDCancelled)`, and assert
    /// no keyring write and no terminal state landed. The scheduled `cancel()`
    /// then still runs.
    func testLoginSheetDismissalLatchesAndDropsAParkedSuccess() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = GatedTeleportHTTPClient()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let model = LoginDismissalModel()
        let disappeared = LoginDisappearFlag()
        let host = UIHostingController(rootView: RemovableLoginHost(
            model: model,
            coordinator: coordinator,
            cluster: cluster,
            onDisappear: { disappeared.value = true }
        ))
        installLoginHostInWindow(host)

        // `TeleportLoginView` has no `.task`/`.onAppear`, so the harness (like
        // the sign-in button) starts the flow itself.
        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilLoginBeginStarted(1)
        await http.releaseLoginBegin(index: 0)
        await http.waitUntilLoginFinishStarted(1)

        // Remove the production view: the deterministic `.onDisappear` a sheet
        // dismissal runs, while the flow is parked in `loginFinish`.
        model.showsLogin = false
        XCTAssertTrue(waitUntil { disappeared.value }, "the production view should leave the hierarchy and fire .onDisappear")
        XCTAssertTrue(
            waitUntil { coordinator.isDismissalLatched },
            "the production .onDisappear must latch the dismissal synchronously"
        )

        // Release the parked success without waiting for the scheduled cancel:
        // the latch's generation bump must drop it. Absence needs a bound that
        // lets the MainActor run the resumed continuation, so poll with real
        // suspension (a run-loop pump does not).
        await http.releaseLoginFinish(index: 0, with: .success(MockTeleportHTTPClient.makeFixtureLoginFinishResponse()))
        let staleWriteLanded = await waitForLoginStaleWrite(timeout: 0.5) { store.storedLoginCertCount > 0 }
        XCTAssertFalse(
            staleWriteLanded,
            "a stale success must not store the login cert (storedLoginCertCount=\(store.storedLoginCertCount))"
        )
        XCTAssertEqual(store.storedLoginCertCount, 0)
        XCTAssertEqual(store.storedPrivateKeyCount, 0)
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))

        // The scheduled teardown still runs.
        await awaitLoginState(.failed(.faceIDCancelled), on: coordinator)
        await beginTask.value
    }

    // MARK: - Source pins (the call sites a behavioural test cannot see)

    /// The repository root, derived from this file's location
    /// (`VVTermTests/Features/Teleport/TeleportLoginDismissalWiringTests.swift`).
    /// The `VVTERM_PINS_SOURCE_ROOT` override points the scan at a mutated tree
    /// to prove the pins fail there (`TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT`
    /// reaches the test process; never set in CI).
    private func repositoryRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportLoginDismissalWiringTests.swift
            .deletingLastPathComponent()  // Teleport/
            .deletingLastPathComponent()  // Features/
            .deletingLastPathComponent()  // VVTermTests/
    }

    private func loginViewSource() throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "VVTerm/Features/Teleport/UI/TeleportLoginView.swift"
            ),
            encoding: .utf8
        )
    }

    /// Collapse all whitespace runs to a single space so the pin matches across
    /// line breaks and indentation.
    private static func whitespaceNormalized(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The login Cancel button must latch *before* scheduling `cancel()`; the
    /// `onCancel()` tail makes the sequence unique to that call site.
    func testLoginViewCancelButtonLatchesBeforeTheScheduledTeardown() throws {
        let source = Self.whitespaceNormalized(try loginViewSource())
        XCTAssertTrue(
            source.contains("coordinator.latchDismissal() Task { await coordinator.cancel() } onCancel()"),
            "the login Cancel button must latch synchronously before scheduling cancel()"
        )
    }

    /// The login `.onDisappear` must keep the `dismissalRequiresTeardown` gate,
    /// latch, and then schedule `cancel()` — in that order — and the view must
    /// latch at exactly those two call sites.
    func testLoginViewOnDisappearLatchesBeforeTheScheduledTeardown() throws {
        let source = Self.whitespaceNormalized(try loginViewSource())
        XCTAssertTrue(
            source.contains(
                "guard coordinator.state.dismissalRequiresTeardown else { return } coordinator.latchDismissal() Task { await coordinator.cancel() }"
            ),
            "the login .onDisappear must gate on dismissalRequiresTeardown, latch, then schedule cancel()"
        )
        XCTAssertEqual(
            source.components(separatedBy: "coordinator.latchDismissal()").count - 1,
            2,
            "the login view must latch at exactly the toolbar Cancel and .onDisappear"
        )
    }

    // MARK: - Hosting helpers

    /// Bounded state wait: suspends until `coordinator.state == expected`, and
    /// fails the test (rather than hanging to the suite's execution allowance)
    /// if it never arrives. Signal-driven via the `@Published` state.
    private func awaitLoginState(
        _ expected: TeleportLoginState,
        on coordinator: TeleportLoginCoordinator,
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

    /// Bounded poll that suspends (rather than pumping the run loop) so the
    /// MainActor can run a resumed continuation. Used for the stale-write
    /// signal: the release → re-take → return path has no I/O suspension, so a
    /// surviving stale write lands within a few turns.
    private func waitForLoginStaleWrite(
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
    /// lifecycle modifiers actually run. The host/window pair is retained for
    /// the process lifetime (see `TeleportBootstrapViewWiringTests` for why the
    /// tree is not force-deallocated here).
    private func installLoginHostInWindow(_ host: UIHostingController<some View>) {
        #if canImport(UIKit)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        objc_setAssociatedObject(
            host,
            &TeleportLoginDismissalWiringTests.windowKey,
            window,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        #endif
    }

    nonisolated(unsafe) private static var windowKey: UInt8 = 0

    // MARK: - Harness views

    /// Drives the conditional inclusion of the production login view so a test
    /// can remove it from the hierarchy deterministically (the `.onDisappear` a
    /// real swipe-down dismissal runs).
    @MainActor
    private final class LoginDismissalModel: ObservableObject {
        @Published var showsLogin = true
    }

    /// A MainActor reference flag so a SwiftUI lifecycle closure can record
    /// that it ran without capture-by-value surprises.
    @MainActor
    private final class LoginDisappearFlag {
        var value = false
    }

    private struct RemovableLoginHost<Coordinator: TeleportLoginCoordinating>: View {
        @ObservedObject var model: LoginDismissalModel
        let coordinator: Coordinator
        let cluster: TeleportCluster
        let onDisappear: () -> Void

        var body: some View {
            if model.showsLogin {
                TeleportLoginView(
                    coordinator: coordinator,
                    cluster: cluster,
                    storedHostLogin: nil,
                    onSuccess: { _ in },
                    onCancel: {}
                )
                .onDisappear(perform: onDisappear)
            } else {
                Color.clear
            }
        }
    }
}

#endif

#if canImport(UIKit)
import UIKit
import ObjectiveC
#endif
