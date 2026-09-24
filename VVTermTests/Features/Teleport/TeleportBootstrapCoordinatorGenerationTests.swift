// SPDX-License-Identifier: MIT
//
//  TeleportBootstrapCoordinatorGenerationTests.swift
//  VVTermTests
//
//  Pins `TeleportBootstrapCoordinator`'s request-generation guard (issue
//  #222): a stale POST continuation (the request was cancelled, or superseded
//  by a newer `begin()`) must not overwrite the state a newer attempt owns.
//
//  The HTTP gate is a continuation-gated `TeleportHTTPClienting` stub, so the
//  tests are deterministic and use no sleeps: the POST is held at the gate,
//  the coordinator state is changed out from under it, and the gate is then
//  released.
//
//  Two further tests gate the *keyring store* instead, so `cancel()` can
//  interleave between the POST release and the terminal state write — the
//  window the post-`await` re-take guards exist for (B1/S2). Without that
//  interleaving the re-take guards would be unreachable: a generation bump
//  before the handler is entered is caught by the entry guard.
//

#if DEBUG
import Combine
import Foundation
import XCTest
@testable import VVTerm

/// A per-call gate: `wait()` suspends until `release()` is called (or returns
/// immediately if it was already released). An actor so it is safe to hold a
/// `CheckedContinuation` across the HTTP client's isolation boundary.
private actor BootstrapGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A `TeleportHTTPClienting` stub whose `headlessLogin` blocks on a per-call
/// gate until the test releases it with a scripted result.
@MainActor
private final class GatedTeleportHTTPClient: TeleportHTTPClienting {
    /// The number of `headlessLogin` calls that have started.
    private(set) var startedCount = 0
    private var gates: [BootstrapGate] = []
    private var scriptedResults: [Int: Result<HeadlessLoginResponse, Error>] = [:]
    private var startWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Suspends until at least `count` `headlessLogin` calls have started.
    /// Signalled from `headlessLogin` entry — no polling, no deadline. A test
    /// that awaits a count that never arrives is killed by the suite's
    /// execution allowance rather than trapping.
    func waitUntilStarted(_ count: Int) async {
        guard startedCount < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startWaiters.append((count, continuation))
        }
    }

    /// Release the gate for the `index`-th `headlessLogin` call with `result`.
    func release(index: Int, with result: Result<HeadlessLoginResponse, Error>) async {
        guard gates.indices.contains(index) else {
            XCTFail("release(index: \(index)) but only \(gates.count) headlessLogin call(s) started")
            return
        }
        scriptedResults[index] = result
        await gates[index].release()
    }

    func headlessLogin(
        baseURL: URL,
        user: String,
        headlessAuthenticationID: String,
        sshPubKeyB64: String,
        tlsPubKeyB64: String?,
        ttl: Int64
    ) async throws -> HeadlessLoginResponse {
        let index = startedCount
        let gate = BootstrapGate()
        gates.append(gate)
        startedCount += 1
        resumeStartWaiters()

        await gate.wait()
        guard let result = scriptedResults.removeValue(forKey: index) else {
            throw HeadlessError.transport("headlessLogin not scripted", code: nil)
        }
        return try result.get()
    }

    private func resumeStartWaiters() {
        guard !startWaiters.isEmpty else { return }
        let ready = startWaiters.filter { $0.target <= startedCount }
        startWaiters.removeAll { $0.target <= startedCount }
        for waiter in ready { waiter.continuation.resume() }
    }

    // Not exercised by the bootstrap coordinator.

    func loginBegin(baseURL: URL) async throws -> LoginBeginResponse {
        throw HeadlessError.transport("loginBegin not scripted", code: nil)
    }

    func loginFinish(
        baseURL: URL,
        assertion: CredentialAssertionResponse,
        sshPubKey: Data,
        ttl: Int64
    ) async throws -> LoginFinishResponse {
        throw HeadlessError.transport("loginFinish not scripted", code: nil)
    }
}

/// A `TeleportCredentialStore` that gates the bootstrap-cert store (and,
/// optionally, the final cluster-TLS store) on a continuation, so a test can
/// interleave `cancel()` while the coordinator is suspended *inside* the
/// persistence sequence. Reads and the ungated writes delegate to the
/// underlying mock; writes are counted.
@MainActor
private final class GatedTeleportCredentialStore: TeleportCredentialStore {
    private let underlying: MockTeleportKeyRing
    private let certGate = BootstrapGate()
    private let tlsGate = BootstrapGate()
    private let gateTheFirstStore: Bool
    private let gateTheLastStore: Bool

    private var certStoreStarted = false
    private var certStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var tlsStoreStarted = false
    private var tlsStoreWaiters: [CheckedContinuation<Void, Never>] = []

    /// Committed write counts (incremented only after the gate is released).
    private(set) var storedCertCount = 0
    private(set) var storedPrivateKeyCount = 0
    private(set) var storedTLSStateCount = 0

    init(underlying: MockTeleportKeyRing, gateTheFirstStore: Bool = true, gateTheLastStore: Bool = false) {
        self.underlying = underlying
        self.gateTheFirstStore = gateTheFirstStore
        self.gateTheLastStore = gateTheLastStore
    }

    /// Suspends until the gated `storeBootstrapCert` has been entered.
    func waitUntilCertStoreStarted() async {
        guard !certStoreStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            certStoreWaiters.append(continuation)
        }
    }

    /// Suspends until the gated `storeClusterTLSState` has been entered.
    func waitUntilTLSStoreStarted() async {
        guard !tlsStoreStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            tlsStoreWaiters.append(continuation)
        }
    }

    func releaseCertStore() async {
        await certGate.release()
    }

    func releaseTLSStore() async {
        await tlsGate.release()
    }

    // MARK: - Reads (delegate)

    func clusterTLSState(for clusterId: UUID) async -> TeleportClusterTLSState? {
        underlying.clusterTLSState(for: clusterId)
    }

    func liveCertPEM(for clusterId: UUID) async -> String? {
        underlying.liveCertPEM(for: clusterId)
    }

    func liveEd25519PrivateKey(for clusterId: UUID) async -> Data? {
        underlying.liveEd25519PrivateKey(for: clusterId)
    }

    func registeredCredentialID(for clusterId: UUID) async -> Data? {
        underlying.registeredCredentialID(for: clusterId)
    }

    func registeredUserHandle(for clusterId: UUID) async -> Data? {
        underlying.registeredUserHandle(for: clusterId)
    }

    // MARK: - Writes

    func storeBootstrapCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async {
        if gateTheFirstStore {
            certStoreStarted = true
            let waiters = certStoreWaiters
            certStoreWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await certGate.wait()
        }
        storedCertCount += 1
        underlying.storeBootstrapCert(certPEM, validBefore: validBefore, for: clusterId)
    }

    func storeRegisteredSEPKey(
        credentialID: Data,
        userHandle: Data,
        publicKeyRaw: Data,
        deviceName: String,
        for clusterId: UUID
    ) async {
        underlying.storeRegisteredSEPKey(
            credentialID: credentialID,
            userHandle: userHandle,
            publicKeyRaw: publicKeyRaw,
            deviceName: deviceName,
            for: clusterId
        )
    }

    func storeLoginCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async {
        underlying.storeLoginCert(certPEM, validBefore: validBefore, for: clusterId)
    }

    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) async throws {
        storedPrivateKeyCount += 1
        try underlying.storeEd25519PrivateKey(pemData, for: clusterId)
    }

    func storeClusterTLSState(_ state: TeleportClusterTLSState, for clusterId: UUID) async {
        if gateTheLastStore {
            tlsStoreStarted = true
            let waiters = tlsStoreWaiters
            tlsStoreWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await tlsGate.wait()
        }
        storedTLSStateCount += 1
        underlying.storeClusterTLSState(state, for: clusterId)
    }

    func updateClusterHostKeys(_ checkingKeys: [String], for clusterId: UUID) async -> TeleportHostKeyUpdateResult {
        underlying.updateClusterHostKeys(checkingKeys, for: clusterId)
    }

    func clear(for clusterId: UUID) async {
        underlying.clear(for: clusterId)
    }
}

/// A `WebAuthenticationSessionPresenting` stub whose `open(url:)` blocks on a
/// per-call gate, so a test can interleave a `cancel()`/newer `begin()` while
/// the coordinator is suspended in the presenter await (S1).
@MainActor
private final class GatedWebAuthenticationSessionPresenter: WebAuthenticationSessionPresenting {
    private(set) var openCount = 0
    private var openGates: [BootstrapGate] = []
    private var openResults: [Int: Bool] = [:]
    private var openWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func waitUntilOpenStarted(_ count: Int) async {
        guard openCount < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            openWaiters.append((count, continuation))
        }
    }

    func releaseOpen(index: Int, result: Bool) async {
        guard openGates.indices.contains(index) else {
            XCTFail("releaseOpen(index: \(index)) but only \(openGates.count) open call(s) started")
            return
        }
        openResults[index] = result
        await openGates[index].release()
    }

    func open(url: URL) async -> Bool {
        let index = openCount
        let gate = BootstrapGate()
        openGates.append(gate)
        openCount += 1
        let ready = openWaiters.filter { $0.target <= openCount }
        openWaiters.removeAll { $0.target <= openCount }
        for waiter in ready { waiter.continuation.resume() }

        await gate.wait()
        return openResults[index] ?? true
    }

    func cancel() {}
}

@MainActor
final class TeleportBootstrapCoordinatorGenerationTests: XCTestCase {

    private func makeCluster() -> TeleportCluster {
        TeleportCluster(host: "teleport.pcad.it", username: "pier")
    }

    private func makeCoordinator(
        http: any TeleportHTTPClienting,
        keyRing: any TeleportCredentialStore,
        presenter: (any WebAuthenticationSessionPresenting)? = nil
    ) -> TeleportBootstrapCoordinator {
        TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: keyRing,
            safariPresenter: presenter ?? MockWebAuthenticationSessionPresenter(),
            logging: DefaultTeleportLogging(),
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            tlsKeyPairGenerator: try! TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
    }

    /// Suspends until `coordinator.state` becomes `expected`. Driven by the
    /// `@Published` state, so it is signal-based (no polling).
    private func awaitState(
        _ expected: TeleportBootstrapState,
        on coordinator: TeleportBootstrapCoordinator
    ) async {
        if coordinator.state == expected { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            var cancellable: AnyCancellable?
            cancellable = coordinator.$state.sink { state in
                guard !resumed, state == expected else { return }
                resumed = true
                continuation.resume()
                cancellable?.cancel()
            }
        }
    }

    /// A superseded `begin()` that resumes from the presenter await with a
    /// failed open must not write `.failed(.safariUnavailable)` over the newer
    /// attempt's `.awaitingApproval` (S1). The post-`open` re-take is the only
    /// thing that prevents it: the state-case check alone lets the stale write
    /// through because the newer attempt is in `.awaitingApproval`.
    func testSupersededBeginDoesNotClobberTheNewerAttemptsAwaitingApproval() async {
        let http = GatedTeleportHTTPClient()
        let presenter = GatedWebAuthenticationSessionPresenter()
        let coordinator = makeCoordinator(
            http: http,
            keyRing: MockTeleportKeyRing(),
            presenter: presenter
        )
        let cluster = makeCluster()

        let first = Task { await coordinator.begin(cluster: cluster) }
        await presenter.waitUntilOpenStarted(1)

        let second = Task { await coordinator.begin(cluster: cluster) }
        await presenter.waitUntilOpenStarted(2)

        // The newer attempt opens Safari and reaches `.awaitingApproval`.
        await presenter.releaseOpen(index: 1, result: true)
        await awaitState(.awaitingApproval, on: coordinator)

        // The superseded first attempt now resumes with a failed open.
        await presenter.releaseOpen(index: 0, result: false)
        // Drain the first attempt's POST (cancelled by the newer begin) so it
        // cannot outlive the test.
        await http.release(index: 0, with: .failure(HeadlessError.http(status: 403, body: "denied")))
        await first.value

        XCTAssertEqual(coordinator.state, .awaitingApproval)

        // Drain the second attempt so its POST task does not outlive the test.
        await http.release(index: 1, with: .failure(HeadlessError.http(status: 403, body: "denied")))
        await second.value
    }

    /// `cancel()` bumps the generation, so a failure continuation that
    /// resumes afterwards must not overwrite `.userCancelled`.
    func testCancelledRequestDiscardsAStaleFailureContinuation() async {
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: MockTeleportKeyRing())

        let beginTask = Task { await coordinator.begin(cluster: makeCluster()) }
        await http.waitUntilStarted(1)

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await http.release(index: 0, with: .failure(HeadlessError.http(status: 403, body: "denied")))
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
    }

    /// Even a *successful* stale continuation must not land: it would flip the
    /// state to `.success` after the user cancelled.
    func testCancelledRequestDiscardsAStaleSuccessContinuation() async {
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: MockTeleportKeyRing())

        let beginTask = Task { await coordinator.begin(cluster: makeCluster()) }
        await http.waitUntilStarted(1)

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await http.release(
            index: 0,
            with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse())
        )
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
    }

    /// A stale success from the first attempt must not land after a newer
    /// `begin()` took over; the newer attempt's own success still lands.
    func testStaleSuccessCannotOverwriteANewerBegin() async {
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: MockTeleportKeyRing())
        let cluster = makeCluster()

        let first = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)

        let second = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(2)

        await http.release(
            index: 0,
            with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse())
        )
        await first.value

        // The second attempt is still in flight; the stale success must not
        // have produced the terminal state.
        XCTAssertNotEqual(coordinator.state, .success)

        await http.release(
            index: 1,
            with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse())
        )
        await second.value

        XCTAssertEqual(coordinator.state, .success)
    }

    /// Interleave `cancel()` while the coordinator is suspended *inside* the
    /// final keyring store. The re-take after the last `await` must keep the
    /// stale success from committing the terminal state or the in-memory
    /// result — this is the window the `:510` guard exists for, and the three
    /// entry-guard tests above never reach it.
    ///
    /// Counterfactual (measured): deleting the re-take immediately before
    /// `lastBootstrapResult = result` / `state = .success` makes this test
    /// fail with `state == .success`.
    func testCancelledRequestDuringFinalKeyringStoreDiscardsStaleSuccess() async {
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false, gateTheLastStore: true)
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: store)
        let cluster = makeCluster()

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)

        await http.release(
            index: 0,
            with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse())
        )
        await store.waitUntilTLSStoreStarted()

        // The coordinator is now suspended between the POST release and the
        // terminal state write.
        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await store.releaseTLSStore()
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
        XCTAssertNil(coordinator.lastBootstrapResult)
    }

    /// Interleave `cancel()` while the coordinator is suspended *inside* the
    /// first keyring store. The re-take after that store must stop the later
    /// credential writes (the ed25519 private key and the pinned cluster TLS
    /// state) so a superseded success persists no secret material, and the
    /// terminal state/result must not be committed.
    func testCancelledRequestDuringFirstKeyringStoreStopsLaterCredentialWrites() async {
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing)
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: store)
        let cluster = makeCluster()

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)

        await http.release(
            index: 0,
            with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse())
        )
        await store.waitUntilCertStoreStarted()

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await store.releaseCertStore()
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertEqual(store.storedPrivateKeyCount, 0)
        XCTAssertEqual(store.storedTLSStateCount, 0)
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
        XCTAssertNil(keyRing.clusterTLSState(for: cluster.id))
    }
}

#endif
