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
//  and test 6 covers `loginBegin`'s catch-path guard. The D4 section covers
//  the helper's stored-cert user-binding gate (F1), the typed no-record
//  mapping (D3) and its post-read re-take, plus the `privKeyData == nil`
//  branch (unreachable in production; driven through the injected encoder).
//  The `#298` section pins the guards after `registeredCredentialID`,
//  `registeredUserHandle`, `keyRing.clear`, `clusterTLSState` and
//  `updateClusterHostKeys` (each one red under its own single guard deletion);
//  the production `TeleportKeyRing` witness cannot suspend today, so they
//  stay as future-proofing against a suspension-capable store.
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

    /// The fixture cluster's `domain_name` — the pinned TLS state's
    /// `clusterName` must equal it for `matchesPinnedCluster` to hold.
    private static let fixtureDomainName = "teleport.pcad.it"

    /// The pinned Host CA checking key (authorized_keys line), from the
    /// committed fixture; the refresh payload adds `rotatedHostCA` on top so
    /// the update policy accepts an additions-only refresh.
    private static let pinnedHostCA = TeleportFixtureSupport
        .fixtureString("OpenSSH/ca_ed25519.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private static let rotatedHostCA = TeleportFixtureSupport
        .fixtureString("OpenSSH/ca_foreign.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    private func makeCluster() -> TeleportCluster {
        TeleportCluster(host: "teleport.pcad.it", username: Self.fixtureCertKeyID)
    }

    /// A seeded keyring: the reads resolve, so `storeLoginCert` is a real write
    /// (an unseeded keyring would make the absence assertions vacuous).
    private func makeRegisteredKeyRing(
        clusterId: UUID,
        credentialID: Data = TeleportLoginCoordinatorGenerationTests.credentialID,
        userHandle: Data = Data("user-handle".utf8)
    ) -> MockTeleportKeyRing {
        let keyRing = MockTeleportKeyRing()
        keyRing.seed(
            clusterId: clusterId,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: credentialID,
                userHandle: userHandle,
                deviceName: "test-device"
            )
        )
        return keyRing
    }

    /// Seeds the pinned TLS state the Host-CA refresh needs on the underlying
    /// mock, *before* it is wrapped: the wrapper's `clusterTLSState` read gate
    /// would otherwise park the seed's read. `clusterName` matches the fixture
    /// `domain_name` so `matchesPinnedCluster` is true and the refresh call is
    /// reachable (sites #6/#7).
    private func seedPinnedTLSState(on keyRing: MockTeleportKeyRing, clusterId: UUID) {
        keyRing.storeClusterTLSState(
            TeleportClusterTLSState(
                clusterName: Self.fixtureDomainName,
                clusterCAPEMs: ["pinned-pem"],
                hostCACheckingKeys: [Self.pinnedHostCA]
            ),
            for: clusterId
        )
    }

    /// The verified login fixture chain (copied from
    /// `TeleportCertBindingCoordinatorTests`, whose helper is file-private): a
    /// fixed SSH keypair bound to the fixture cert, a mock SEP signer with a
    /// created key, the fixture clock, and the fixture login responses.
    private func makeLoginCoordinator(
        http: any TeleportHTTPClienting,
        keyRing: any TeleportCredentialStore,
        credentialID: Data = TeleportLoginCoordinatorGenerationTests.credentialID,
        keyPairGenerator: (any TeleportSSHKeyPairGenerating)? = nil,
        privateKeyDataEncoder: ((String) -> Data?)? = nil
    ) throws -> TeleportLoginCoordinator {
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        return TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: signer,
            keyPairGenerator: keyPairGenerator ?? FixedTeleportSSHKeyPairGenerator(publicKey: TeleportFixtureSupport.fixedSSHPublicKey),
            now: { TeleportFixtureSupport.fixtureClock },
            privateKeyDataEncoder: privateKeyDataEncoder ?? { $0.data(using: .utf8) }
        )
    }

    private func fixtureLoginFinishResponse() -> LoginFinishResponse {
        MockTeleportHTTPClient.makeFixtureLoginFinishResponse()
    }

    /// The `hostSigners` login-finish fixture: the `domain_name` the refresh
    /// policy matches against the pinned cluster name plus the `checking_keys`
    /// it accepts. The app-target mock deliberately carries
    /// `hostSigners: nil` (and empty checking keys), so the refresh block is
    /// only reachable with this test-target builder — copied from
    /// `TeleportCertBindingCoordinatorTests.makeLoginFinishResponse`.
    private func makeLoginFinishResponse(
        domainName: String,
        checkingKeys: [String]
    ) -> LoginFinishResponse {
        LoginFinishResponse(
            cert: Data(TeleportFixtureSupport.fixedIssuedUserCert.utf8).base64EncodedString(),
            hostSigners: [
                LoginFinishResponse.HostSigner(domainName: domainName, checkingKeys: checkingKeys)
            ]
        )
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
        XCTAssertEqual(store.storedPairCount, 0, "the throwing write was attempted but committed nothing")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
    }

    // MARK: - T1: a superseded atomic pair write cannot tear the credential

    /// T1 (login half): a supersession landing while attempt 1's atomic pair
    /// write is parked cannot tear the credential. Attempt 2 runs to `.success`
    /// (pair 2) while attempt 1 is parked; releasing attempt 1 then lands
    /// **pair 1 complete** over pair 2. The final snapshot is one attempt's
    /// complete pair, and the committed cert and key halves come from the same
    /// write invocation.
    ///
    /// This is a coordinator-shape test with a suspension-capable conformer;
    /// the production atomicity is pinned structurally by
    /// `TeleportCredentialPairPinsTests` (the keyring pair body suspends
    /// nowhere).
    ///
    /// The measured counterfactual (coordinator-only revert to the two singles)
    /// fails this test with `(cert_1, key_2)` — see the PR report.
    func testSupersededPairWriteCannotTearTheLoginCredential() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheLoginCertStore: true
        )
        let http = GatedTeleportHTTPClient()
        let generator = AttemptTaggedSSHKeyPairGenerator(attemptCount: 2)
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store, keyPairGenerator: generator)

        // Distinct per-attempt validity/principal payloads so a stale
        // attempt-1 terminal write is distinguishable from attempt 2's (G1:
        // with identical payloads the final-state assertion below would be
        // vacuous).
        let attempt1ValidBefore = TeleportFixtureSupport.attemptCertValidBefore.addingTimeInterval(60)
        let attempt1Principals = ["alice-attempt-1"]
        let attempt2ValidBefore = TeleportFixtureSupport.attemptCertValidBefore.addingTimeInterval(120)
        let attempt2Principals = ["alice-attempt-2"]

        let attempt1Cert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: generator.attempts[0].rawKey,
            keyID: cluster.username,
            principals: attempt1Principals,
            validBefore: attempt1ValidBefore
        )
        let attempt2Cert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: generator.attempts[1].rawKey,
            keyID: cluster.username,
            principals: attempt2Principals,
            validBefore: attempt2ValidBefore
        )

        // Attempt 1: run to the parked pair write.
        let first = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilLoginBeginStarted(1)
        await http.releaseLoginBegin(index: 0)
        await http.waitUntilLoginFinishStarted(1)
        await http.releaseLoginFinish(
            index: 0,
            with: .success(TeleportFixtureSupport.makeAttemptLoginFinishResponse(
                attempt: 0,
                generator: generator,
                cluster: cluster,
                validBefore: attempt1ValidBefore,
                principals: attempt1Principals
            ))
        )
        await store.waitUntilFirstCredentialWriteStarted()
        XCTAssertEqual(store.storedPairCount, 0, "attempt 1's pair write is parked, not committed")

        // Attempt 2: supersedes attempt 1 and completes while attempt 1 is
        // still parked.
        let second = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilLoginBeginStarted(2)
        await http.releaseLoginBegin(index: 1)
        await http.waitUntilLoginFinishStarted(2)
        await http.releaseLoginFinish(
            index: 1,
            with: .success(TeleportFixtureSupport.makeAttemptLoginFinishResponse(
                attempt: 1,
                generator: generator,
                cluster: cluster,
                validBefore: attempt2ValidBefore,
                principals: attempt2Principals
            ))
        )
        await second.value

        XCTAssertEqual(
            coordinator.state,
            .success(certValidUntil: attempt2ValidBefore, logins: attempt2Principals),
            "attempt 2's terminal state names its own payload"
        )
        let afterSecond = await keyRing.liveCredentialSnapshot(for: cluster.id)
        XCTAssertEqual(afterSecond?.certPEM, attempt2Cert)
        XCTAssertEqual(afterSecond?.privateKeyPEM, Data(generator.attempts[1].privateKeyPEM.utf8))

        // Release attempt 1's parked pair write: it must land attempt 1's
        // complete pair (cert_1 + key_1), never mixing halves.
        await store.releaseFirstCredentialWrite()
        await first.value

        XCTAssertEqual(store.storedPairCount, 2)
        let final = await keyRing.liveCredentialSnapshot(for: cluster.id)
        XCTAssertEqual(final?.certPEM, attempt1Cert, "the released pair write lands attempt 1's cert last")
        let finalKeyText = (final?.privateKeyPEM).flatMap { String(data: $0, encoding: .utf8) } ?? "<no key committed>"
        XCTAssertEqual(
            finalKeyText,
            generator.attempts[0].privateKeyPEM,
            "the final key must be attempt 1's — a mismatch means the pair tore (cert_1 + key_2); actual=\(finalKeyText)"
        )
        XCTAssertEqual(
            store.committedCertWriteOrdinal, store.committedKeyWriteOrdinal,
            "the final cert and key halves must come from the same (atomic pair) write invocation"
        )
        XCTAssertEqual(
            coordinator.state,
            .success(certValidUntil: attempt2ValidBefore, logins: attempt2Principals),
            "attempt 1's stale pair write must not write the terminal state"
        )
    }

    // MARK: - T2: exactly one pair write, zero single writes

    /// T2 (login): exactly one atomic pair write and zero single writes, with
    /// the terminal `.success` as the positive control (a flow that bails
    /// before the store cannot satisfy it).
    func testLoginStoresTheCredentialAsExactlyOnePairWrite() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = fixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, fixtureSuccessState())
        XCTAssertEqual(store.storedPairCount, 1)
        XCTAssertEqual(store.singleStoreLoginCertCount, 0)
        XCTAssertEqual(store.singleStoreEd25519PrivateKeyCount, 0)
    }

    // MARK: - T6 / D4: the post-throw states

    /// T6 (login): a pair-write throw without a supersession and with no prior
    /// usable pair routes through the D4 nil branch: the flow fails and the
    /// user can retry, and neither half is committed.
    func testLoginPairStoreFailureWithoutAPriorCredentialFailsTheFlow() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = fixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .failed(.unknown("credentials could not be stored")))
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
    }

    /// D4 (login) non-nil branch: a failed pair write with a usable prior
    /// stored pair reports `.success` with the STORED cert's validity and
    /// principals, not the response's.
    func testLoginPairStoreFailureWithAPriorPairSucceedsWithTheStoredCert() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let priorCert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: Data(repeating: 0x66, count: 32),
            keyID: cluster.username
        )
        let priorKey = Data("prior-login-ed25519-key".utf8)
        keyRing.storeLoginCert(priorCert, validBefore: TeleportFixtureSupport.attemptCertValidBefore, for: cluster.id)
        try keyRing.storeEd25519PrivateKey(priorKey, for: cluster.id)
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)

        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = fixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(
            coordinator.state,
            .success(certValidUntil: TeleportFixtureSupport.attemptCertValidBefore, logins: ["alice"])
        )
        XCTAssertEqual(keyRing.liveCredentialSnapshot(for: cluster.id)?.certPEM, priorCert)
        XCTAssertEqual(keyRing.liveCredentialSnapshot(for: cluster.id)?.privateKeyPEM, priorKey)
    }

    // MARK: - F1/D3/G5: the D4 helper's gates and branches

    /// F1 (login): the D4 helper must re-apply the stored cert's user-binding
    /// gate. A prior stored pair whose cert belongs to a foreign Teleport user
    /// (the row's username was edited after storage) must not be handed off as
    /// a false `.success` when this attempt's pair write throws: the helper
    /// clears the credential and fails closed, exactly like the main path
    /// (:416).
    func testLoginPairStoreFailureWithAForeignStoredCertClearsAndFails() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let priorCert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: Data(repeating: 0x99, count: 32),
            keyID: "someone-else"  // not cluster.username — the stored cert is foreign
        )
        let priorKey = Data("foreign-prior-login-key".utf8)
        keyRing.storeLoginCert(priorCert, validBefore: TeleportFixtureSupport.attemptCertValidBefore, for: cluster.id)
        try keyRing.storeEd25519PrivateKey(priorKey, for: cluster.id)
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)

        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = fixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(
            coordinator.state,
            .failed(.server("Certificate user binding check failed: the certificate does not belong to this Teleport user")),
            "the stored foreign cert must not be handed off as .success"
        )
        XCTAssertNil(keyRing.credentials[cluster.id], "the foreign stored credential was cleared")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
    }

    /// D3 (login): a `clear(for:)` landing while the login's pair write is
    /// parked (the connect path clearing under a parked login) makes the write
    /// throw `noRegisteredCredential`; the terminal state must be the
    /// dedicated no-record failure, never a silent success or the generic
    /// store-failure text. The gated double forwards to the mock's `.login`
    /// policy check after the gate, so the clear is observed by the write.
    func testConcurrentClearDuringThePairWriteFailsWithTheNoRecordState() async throws {
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
        XCTAssertEqual(store.storedPairCount, 0, "the pair write is parked, not committed")

        // The connect-path clear lands while the login is parked (D3).
        await store.clear(for: cluster.id)

        await store.releaseFirstCredentialWrite()
        await beginTask.value

        XCTAssertEqual(
            coordinator.state,
            .failed(.unknown("the registered credential was cleared while the flow was in progress")),
            "the typed no-record error maps to the dedicated message"
        )
        XCTAssertEqual(store.storedPairCount, 0, "the thrown write committed nothing")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
    }

    /// G5 (login): the `privKeyData == nil` branch is unreachable in production
    /// (a Swift `String` always UTF-8-encodes), so it is driven through the
    /// injected encoder. It must fail closed through the D4 outcome instead of
    /// committing half a credential.
    func testLoginNilPrivateKeyDataFailsClosedWithoutAWrite() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = fixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: store,
            privateKeyDataEncoder: { _ in nil }
        )

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .failed(.unknown("credentials could not be stored")))
        XCTAssertEqual(store.storedPairCount, 0, "the nil branch must not attempt a pair write")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
    }

    /// G5 (login): the D4 helper's post-read re-take. A `cancel()` landing
    /// while the helper is suspended in `liveCredentialSnapshot` must keep the
    /// helper from writing the store-failure state over
    /// `.failed(.faceIDCancelled)`.
    func testSupersessionDuringTheD4SnapshotReadWithholdsTheStoreFailure() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheSnapshotRead: true
        )
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = fixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await store.waitUntilSnapshotReadStarted()

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled))

        await store.releaseSnapshotRead()
        await beginTask.value

        XCTAssertEqual(
            coordinator.state,
            .failed(.faceIDCancelled),
            "the stale store-failure must not overwrite the cancel's terminal state"
        )
    }

    // MARK: - #298: the remaining login continuation guards

    /// Site #1 — the re-take after the `registeredCredentialID` read.
    ///
    /// Fixture: an **unseeded** keyring, so the read returns nil and the
    /// deleted guard falls into the `.failed(.noRegisteredKey)` branch.
    /// Supersession: `cancel()` (single attempt — no second `begin`).
    ///
    /// Discriminator: the state stays `.failed(.faceIDCancelled)`; with the
    /// `:232` guard deleted it becomes `.failed(.noRegisteredKey)`.
    /// Positive control: the read really returned nil (the guard-deleted run
    /// observed `.noRegisteredKey`).
    ///
    /// Counterfactual (measured): deleting only the `:232` guard fails this
    /// test in 1.338 s with
    /// `("failed(VVTerm.TeleportLoginError.noRegisteredKey)") is not equal to ("failed(VVTerm.TeleportLoginError.faceIDCancelled)")`
    /// — an assertion, not an allowance kill.
    func testCancelDuringTheRegisteredCredentialIDReadIsNotClobberedByTheNilBranch() async throws {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheRegisteredCredentialIDRead: true
        )
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = fixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await store.waitUntilRegisteredCredentialIDReadStarted()
        XCTAssertEqual(
            coordinator.state, .idle,
            "the flow is parked in the credentialID read, before any terminal write"
        )

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled))

        await store.releaseRegisteredCredentialIDRead()
        await beginTask.value

        XCTAssertEqual(
            coordinator.state,
            .failed(.faceIDCancelled),
            "the guard-deleted nil branch would write .failed(.noRegisteredKey) over the cancel"
        )
    }

    /// Site #2 — the re-take after the `registeredUserHandle` read.
    ///
    /// Fixture: a seeded record with a non-empty credentialID and an **empty
    /// userHandle**, so site #1 passes and the userHandle read returns nil.
    /// Supersession: `cancel()`.
    ///
    /// Discriminator: `.failed(.faceIDCancelled)` survives; with the `:239`
    /// guard deleted the nil branch becomes `.failed(.noRegisteredKey)`.
    /// Positive control: the flow reached the #2 read (`state == .idle` at the
    /// park), so site #1 did not take its nil branch.
    ///
    /// Counterfactual (measured): deleting only the `:239` guard fails this
    /// test in 0.431 s with
    /// `("failed(VVTerm.TeleportLoginError.noRegisteredKey)") is not equal to ("failed(VVTerm.TeleportLoginError.faceIDCancelled)")`
    /// — an assertion, not an allowance kill.
    func testCancelDuringTheRegisteredUserHandleReadIsNotClobberedByTheNilBranch() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, userHandle: Data())
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheRegisteredUserHandleRead: true
        )
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = fixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await store.waitUntilRegisteredUserHandleReadStarted()
        XCTAssertEqual(
            coordinator.state, .idle,
            "site #1 read a credentialID, so the flow reached the userHandle read"
        )

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled))

        await store.releaseRegisteredUserHandleRead()
        await beginTask.value

        XCTAssertEqual(
            coordinator.state,
            .failed(.faceIDCancelled),
            "the guard-deleted nil branch would write .failed(.noRegisteredKey) over the cancel"
        )
    }

    /// Site #5 — the post-`clear` re-take in the foreign-cert branch.
    ///
    /// Fixture: the standard seeded keyring + a mismatch cluster username
    /// (≠ `user-cert-ed25519`), so the fixture cert fails the user-binding
    /// check and the coordinator parks in the fail-closed `clear` (the clear
    /// gate already existed). Supersession: `cancel()`.
    ///
    /// Discriminator: `.failed(.faceIDCancelled)` survives; with the `:435`
    /// guard deleted the binding-failure `.failed(.server(…))` overwrites it.
    /// Positive control: `clearedCount == 1` — the in-flight clear is allowed
    /// to commit (§1.4).
    ///
    /// Counterfactual (measured): deleting only the `:435` guard fails this
    /// test in 0.956 s with
    /// `("failed(VVTerm.TeleportLoginError.server("Certificate user binding check failed: the certificate does not belong to this Teleport user"))") is not equal to ("failed(VVTerm.TeleportLoginError.faceIDCancelled)")`
    /// — an assertion, not an allowance kill.
    func testCancelDuringTheMismatchClearIsNotClobberedByTheBindingFailure() async throws {
        let cluster = TeleportCluster(host: Self.fixtureDomainName, username: "not-the-fixture-user")
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheClear: true
        )
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = fixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await store.waitUntilClearStarted()
        XCTAssertEqual(store.clearedCount, 0, "the clear is parked, not committed")

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled))

        await store.releaseClear()
        await beginTask.value

        XCTAssertEqual(
            coordinator.state,
            .failed(.faceIDCancelled),
            "the guard-deleted binding failure would overwrite the cancel with .failed(.server(…))"
        )
        XCTAssertEqual(store.clearedCount, 1, "the in-flight clear is allowed to land (§1.4)")
    }

    /// Site #6 — the re-take after the pinned `clusterTLSState` name read.
    ///
    /// Fixture: the standard seeded keyring + the `hostSigners` login-finish
    /// fixture + a pinned TLS state whose `clusterName` matches the fixture
    /// `domain_name` (seeded on the underlying mock before wrapping).
    /// Supersession: `cancel()`.
    ///
    /// Discriminator: `updateClusterHostKeysCallCount == 0`; with the `:460`
    /// guard deleted the stale flow sees the matching name and calls the
    /// refresh (the counter becomes 1). **The update gate stays off** so the
    /// guard-deleted run cannot park at `:465`.
    /// Positive control: before `begin`, the underlying mock still holds the
    /// seeded state with `clusterName == fixtureDomainName` — the
    /// matching-name read is otherwise proven only by the counterfactual.
    ///
    /// Counterfactual (measured): deleting only the `:460` guard fails this
    /// test in 0.457 s with `("1") is not equal to ("0")` on the
    /// `updateClusterHostKeysCallCount` assertion — an assertion, not an
    /// allowance kill.
    func testCancelDuringThePinnedNameReadSkipsTheHostKeyRefresh() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        seedPinnedTLSState(on: keyRing, clusterId: cluster.id)
        XCTAssertEqual(
            keyRing.clusterTLSState(for: cluster.id)?.clusterName,
            Self.fixtureDomainName,
            "the pinned TLS state is seeded on the underlying mock before the flow starts"
        )
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheLoginCertStore: false,
            gateTheClusterTLSStateRead: true
        )
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = makeLoginFinishResponse(
            domainName: Self.fixtureDomainName,
            checkingKeys: [Self.pinnedHostCA, Self.rotatedHostCA]
        )
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await store.waitUntilClusterTLSStateReadStarted()
        XCTAssertEqual(coordinator.state, .fetchingCert, "the flow is parked in the pinned-name read")

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled))

        await store.releaseClusterTLSStateRead()
        await beginTask.value

        XCTAssertEqual(
            store.updateClusterHostKeysCallCount,
            0,
            "the guard-deleted stale flow would call updateClusterHostKeys once"
        )
        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled), "the cancel state still holds")
    }

    /// Site #7 — the re-take after `updateClusterHostKeys`.
    ///
    /// Fixture: the same seeded pinned TLS state and `hostSigners` response as
    /// site #6, but gating the refresh call itself and leaving the pinned-name
    /// read gate off. Supersession: `cancel()`.
    ///
    /// Discriminator: `storedPairCount == 0`; with the `:466` guard deleted the
    /// stale flow falls through to the pair write and commits it (the count
    /// becomes 1). The terminal state is **not** the discriminator — it is
    /// masked by the post-pair re-take at `:523` (which stays present), so it
    /// is asserted only as a positive control. `gateTheLoginCertStore: false`
    /// is the load-bearing pin for the guard-deleted pair write (the `.login`
    /// policy consults only that gate).
    /// Positive control: the state is still `.failed(.faceIDCancelled)`.
    ///
    /// Counterfactual (measured): deleting only the `:466` guard fails this
    /// test in 0.452 s with `("1") is not equal to ("0")` on the
    /// `storedPairCount` assertion — an assertion, not an allowance kill.
    func testCancelDuringTheHostKeyRefreshIsNotClobberedByThePairWrite() async throws {
        let cluster = makeCluster()
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id)
        seedPinnedTLSState(on: keyRing, clusterId: cluster.id)
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheLoginCertStore: false,
            gateTheUpdateClusterHostKeys: true
        )
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = makeLoginFinishResponse(
            domainName: Self.fixtureDomainName,
            checkingKeys: [Self.pinnedHostCA, Self.rotatedHostCA]
        )
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await store.waitUntilUpdateClusterHostKeysStarted()
        XCTAssertEqual(store.updateClusterHostKeysCallCount, 1, "the refresh call was entered, then parked")

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled))

        await store.releaseUpdateClusterHostKeys()
        await beginTask.value

        XCTAssertEqual(
            store.storedPairCount,
            0,
            "the guard-deleted stale flow would fall through to and commit the pair write"
        )
        XCTAssertEqual(coordinator.state, .failed(.faceIDCancelled), "the cancel state still holds")
    }
}

#endif
