// SPDX-License-Identifier: MIT
//
//  TeleportLoginCoordinatorGenerationTests.swift
//  VVTermTests
//
//  Pins `TeleportLoginCoordinator`'s request-generation guard (issue #240,
//  the #222/#239 shape applied to the login coordinator): a stale
//  continuation — from a superseded `begin()` or from a cancelled attempt —
//  must not write state or start a keyring write over the state the newer
//  attempt (or the cancel) owns.
//
//  The tests are gate-driven and use no sleeps: the login HTTP calls and the
//  keyring stores block on continuation gates, the coordinator state is
//  changed out from under the parked continuation, and the gate is then
//  released.
//
//  Guard coverage (so a mutation run is not misread): tests 1/2/3 cover the
//  re-take after `loginFinish` (test 2 additionally covers that site's
//  catch-path guard), test 4 covers the re-take after the atomic pair store,
//  and test 6 covers `loginBegin`'s catch-path guard. The guards after
//  `registeredCredentialID`, `registeredUserHandle`, `keyRing.clear`,
//  `clusterTLSState` and `updateClusterHostKeys` are untested-by-design: the
//  production `TeleportKeyRing` witness cannot suspend, and the fixture login
//  response sets `hostSigners: nil` so the refresh block is skipped. They stay
//  as future-proofing against a suspension-capable store.
//

#if DEBUG
import Combine
import Foundation
import Security
import XCTest
@testable import VVTerm

@MainActor
final class TeleportLoginCoordinatorGenerationTests: XCTestCase {

    // MARK: - Fixtures

    /// The keyID of the committed fixture user certificate
    /// (`Fixtures/OpenSSH/user-cert-ed25519.pub`). The login coordinator binds
    /// the issued cert's keyID to the configured Teleport user, so the success
    /// path needs the cluster to name that user.
    private static let fixtureCertKeyID = "user-cert-ed25519"

    /// The fixture cert's `validBefore` (read from the committed cert), which
    /// drives the `.success` copy.
    private static let fixtureCertValidUntil = Date(timeIntervalSince1970: 2_082_758_400)

    private static let credentialID = Data([1, 2, 3, 4])

    private func makeCluster() -> TeleportCluster {
        TeleportCluster(host: "teleport.pcad.it", username: Self.fixtureCertKeyID)
    }

    /// A seeded keyring: the reads resolve, so `storeLoginCert` is a real write
    /// (an unseeded keyring would make the absence assertions vacuous).
    private func makeRegisteredKeyRing(
        clusterId: UUID,
        credentialID: Data = TeleportLoginCoordinatorGenerationTests.credentialID
    ) -> MockTeleportKeyRing {
        let keyRing = MockTeleportKeyRing()
        keyRing.seed(
            clusterId: clusterId,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: credentialID,
                userHandle: Data("user-handle".utf8),
                deviceName: "test-device"
            )
        )
        return keyRing
    }

    /// The verified login fixture chain (copied from
    /// `TeleportCertBindingCoordinatorTests`, whose helper is file-private): a
    /// fixed SSH keypair bound to the fixture cert, a mock SEP signer with a
    /// created key, the fixture clock, and the fixture login responses.
    private func makeLoginCoordinator(
        http: any TeleportHTTPClienting,
        keyRing: any TeleportCredentialStore,
        credentialID: Data = TeleportLoginCoordinatorGenerationTests.credentialID
    ) throws -> TeleportLoginCoordinator {
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        return TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: signer,
            keyPairGenerator: FixedTeleportSSHKeyPairGenerator(publicKey: TeleportFixtureSupport.fixedSSHPublicKey),
            now: { TeleportFixtureSupport.fixtureClock }
        )
    }

    private func fixtureLoginFinishResponse() -> LoginFinishResponse {
        MockTeleportHTTPClient.makeFixtureLoginFinishResponse()
    }

    private func fixtureSuccessState() -> TeleportLoginState {
        .success(certValidUntil: Self.fixtureCertValidUntil, logins: ["alice"])
    }

    // MARK: - #240: a stale continuation must not land

    /// A stale success from the first attempt must not land after a newer
    /// `begin()` took over; the newer attempt's own success still lands.
    ///
    /// Counterfactual (measured): deleting only the re-take after `loginFinish`
    /// leaves the state at `.fetchingCert` (the later re-takes still return)
    /// and reddens this test on the write assertions: `storedLoginCertCount ==
    /// 1`, `liveCertPEM != nil` and the final count mismatch (`2 != 1`). The
    /// `.success`-state failure text belongs to the all-guards-removed run.
    func testStaleSuccessCannotOverwriteANewerBegin() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = GatedTeleportHTTPClient()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let first = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilLoginBeginStarted(1)
        await http.releaseLoginBegin(index: 0)
        await http.waitUntilLoginFinishStarted(1)

        let second = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilLoginBeginStarted(2)
        await http.releaseLoginBegin(index: 1)
        await http.waitUntilLoginFinishStarted(2)

        // Attempt 1 resumes with a *valid* success while attempt 2 is parked
        // inside its own `loginFinish`.
        await http.releaseLoginFinish(index: 0, with: .success(fixtureLoginFinishResponse()))
        await first.value

        XCTAssertEqual(
            coordinator.state, .fetchingCert,
            "the stale success must not overwrite attempt 2's in-flight state"
        )
        XCTAssertEqual(store.storedLoginCertCount, 0, "the stale success must not store the login cert")
        XCTAssertEqual(store.storedPrivateKeyCount, 0, "the stale success must not store the private key")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))

        // Attempt 2's own success still lands.
        await http.releaseLoginFinish(index: 1, with: .success(fixtureLoginFinishResponse()))
        await second.value

        XCTAssertEqual(coordinator.state, fixtureSuccessState())
        XCTAssertEqual(store.storedLoginCertCount, 1)
        XCTAssertEqual(store.storedPrivateKeyCount, 1)
        XCTAssertEqual(keyRing.liveCertPEM(for: cluster.id), TeleportFixtureSupport.fixedIssuedUserCert)
    }

    /// A stale *failure* from the first attempt must not overwrite the newer
    /// attempt's state (`loginFinish`'s catch-path guard).
    func testStaleFailureCannotOverwriteANewerBegin() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = GatedTeleportHTTPClient()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let first = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilLoginBeginStarted(1)
        await http.releaseLoginBegin(index: 0)
        await http.waitUntilLoginFinishStarted(1)

        let second = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilLoginBeginStarted(2)
        await http.releaseLoginBegin(index: 1)
        await http.waitUntilLoginFinishStarted(2)

        await http.releaseLoginFinish(index: 0, with: .failure(HeadlessError.http(status: 403, body: "denied")))
        await first.value

        XCTAssertEqual(
            coordinator.state, .fetchingCert,
            "the stale failure must not overwrite attempt 2's in-flight state"
        )

        await http.releaseLoginFinish(index: 1, with: .success(fixtureLoginFinishResponse()))
        await second.value

        XCTAssertEqual(coordinator.state, fixtureSuccessState())
        XCTAssertEqual(store.storedLoginCertCount, 1)
    }

    /// `cancel()` bumps the generation, so a continuation that resumes
    /// afterwards must not overwrite `.failed(.faceIDCancelled)`, store the
    /// cert, or store the private key.
    func testCancelIsNotClobberedByAStaleContinuation() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = GatedTeleportHTTPClient()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilLoginBeginStarted(1)
        await http.releaseLoginBegin(index: 0)
        await http.waitUntilLoginFinishStarted(1)

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled))

        await http.releaseLoginFinish(index: 0, with: .success(fixtureLoginFinishResponse()))
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled))
        XCTAssertEqual(store.storedLoginCertCount, 0)
        XCTAssertEqual(store.storedPrivateKeyCount, 0)
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
    }

    /// Interleave `cancel()` while the coordinator is suspended *inside* the
    /// atomic pair write. The pair write was already in flight when the cancel
    /// landed, so it is allowed to land **complete** (§1.4) — the credential
    /// can never be torn. Only the terminal `.success` is withheld.
    ///
    /// This is the in-flight-lands acceptance evidence for the login path.
    func testCancelledRequestDuringLoginCertStoreLetsTheInFlightPairLand() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheLoginCertStore: true
        )
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = fixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await store.waitUntilFirstCredentialWriteStarted()

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled))

        await store.releaseFirstCredentialWrite()
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled))
        XCTAssertEqual(store.storedPairCount, 1, "the in-flight pair write is allowed to land complete")
        XCTAssertEqual(store.storedPrivateKeyCount, 1)
        XCTAssertNotNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
    }

    /// The dismissal latch drops a parked continuation and is terminal: after
    /// `latchDismissal()` a stray `begin()` must not re-arm the flow.
    ///
    /// This is a coordinator-level test: the view call sites are pinned
    /// separately (`TeleportLoginDismissalWiringTests`).
    ///
    /// Counterfactual (measured): a `latchDismissal()` that sets
    /// `isDismissalLatched` without bumping the generation makes this test
    /// fail with `storedLoginCertCount == 1` / `.success`.
    func testLatchDismissalDropsAParkedSuccessAndIsTerminal() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = GatedTeleportHTTPClient()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilLoginBeginStarted(1)
        await http.releaseLoginBegin(index: 0)
        await http.waitUntilLoginFinishStarted(1)

        coordinator.latchDismissal()
        XCTAssertTrue(coordinator.isDismissalLatched)
        coordinator.latchDismissal()  // idempotent

        await http.releaseLoginFinish(index: 0, with: .success(fixtureLoginFinishResponse()))
        await beginTask.value

        XCTAssertEqual(
            coordinator.state, .fetchingCert,
            "the latch withholds the terminal state; cancel() (the call site's second half) owns it"
        )
        XCTAssertEqual(store.storedLoginCertCount, 0)
        XCTAssertEqual(store.storedPrivateKeyCount, 0)
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))

        // Terminal: a stray begin after the latch is a no-op (no re-arm, no
        // new request). The stray runs as a bounded task and the request count
        // is asserted before it is awaited, so a missing latch guard fails as
        // an assertion instead of parking the call on a gate no test releases
        // (the closure lens measured that mutation as an execution-allowance
        // kill). The post-call assertions are kept: if the guard is missing and
        // the stray is drained below, the re-armed flow is still caught.
        XCTAssertTrue(coordinator.isDismissalLatched)
        XCTAssertEqual(http.loginBeginStartedCount, 1)
        XCTAssertEqual(http.loginFinishStartedCount, 1)
        XCTAssertEqual(store.storedLoginCertCount, 0)

        let strayBegin = Task { await coordinator.begin(cluster: cluster) }
        let strayStartedARequest = await http.waitForLoginBeginStarted(2, timeout: 0.5)
        XCTAssertFalse(
            strayStartedARequest,
            "a latched coordinator must not start another login/begin"
        )
        if strayStartedARequest {
            // Guard missing: drain the stray's two requests so it cannot park —
            // release its begin, wait for its finish to start, release that,
            // then let it run to its terminal write (caught below).
            await http.releaseLoginBeginIfStarted(index: 1)
            await http.waitUntilLoginFinishStarted(2)
            await http.releaseLoginFinishIfStarted(index: 1)
        }
        await strayBegin.value

        XCTAssertEqual(http.loginBeginStartedCount, 1)
        XCTAssertEqual(http.loginFinishStartedCount, 1)
        XCTAssertEqual(store.storedLoginCertCount, 0)
    }

    /// A stale `loginBegin` *failure* must not overwrite the newer attempt's
    /// state: the `catch` writes `.failed(...)` before any post-await guard, so
    /// the guard must be the catch's first statement.
    ///
    /// Counterfactual (measured): deleting the guard at the top of the
    /// `loginBegin` catch makes this test fail with
    /// `.failed(.server("HTTP 403: denied"))`.
    func testStaleLoginBeginFailureCannotOverwriteANewerBegin() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = GatedTeleportHTTPClient()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let first = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilLoginBeginStarted(1)

        let second = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilLoginBeginStarted(2)

        await http.releaseLoginBegin(
            index: 0,
            with: .failure(HeadlessError.http(status: 403, body: "denied"))
        )
        await first.value

        XCTAssertEqual(
            coordinator.state, .idle,
            "the stale login/begin failure must not overwrite attempt 2's state"
        )

        // Attempt 2's own outcome wins: release its begin, then its finish.
        await http.releaseLoginBegin(index: 1, with: .success(MockTeleportHTTPClient.makeFixtureLoginBeginResponse()))
        await http.waitUntilLoginFinishStarted(1)
        await http.releaseLoginFinish(index: 0, with: .success(fixtureLoginFinishResponse()))
        await second.value

        XCTAssertEqual(coordinator.state, fixtureSuccessState())
        XCTAssertEqual(store.storedLoginCertCount, 1)
    }

    /// A throwing atomic pair write after a cancel must not fall through to
    /// `.success`, and nothing may be committed. The pair write parks on the
    /// shared hold-first gate (before any mutation); releasing it makes the
    /// mock's key seam throw, and the cancel's generation bump withholds the
    /// terminal state.
    func testThrowingPairStoreAfterCancelDoesNotWriteSuccess() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheLoginCertStore: true
        )
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = fixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await store.waitUntilFirstCredentialWriteStarted()
        XCTAssertEqual(store.storedPairCount, 0, "the pair write is parked, not committed")

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled))

        // Release the parked pair write; the underlying mock's key seam throws
        // before any mutation, so neither half is committed.
        await store.releaseFirstCredentialWrite()
        await beginTask.value

        XCTAssertEqual(
            coordinator.state, .failed(.faceIDCancelled),
            "a superseded throwing pair store must not fall through to .success"
        )
        XCTAssertEqual(store.storedPairCount, 1, "the write was attempted")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
    }
}

#endif
