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
//  Four further tests gate the *keyring writes* instead, so `cancel()`/the
//  dismissal latch can interleave between the POST release and the terminal
//  state write — the window the post-`await` re-take guards exist for
//  (B1/S2). Without that interleaving the re-take guards would be
//  unreachable: a generation bump before the handler is entered is caught by
//  the entry guard. They gate the first store (cert), the middle store
//  (ed25519 private key), the last store (cluster TLS state) and the
//  foreign-cert fail-closed `clear`, one per re-take guard.
//

#if DEBUG
import Combine
import Foundation
import XCTest
@testable import VVTerm

/// A per-call gate: `wait()` suspends until `release()` is called (or returns
/// immediately if it was already released). An actor so it is safe to hold a
/// `CheckedContinuation` across the HTTP client's isolation boundary. Internal
/// (not private) so the dismissal tests in `TeleportBootstrapViewWiringTests`
/// share it.
actor BootstrapGate {
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
/// gate until the test releases it with a scripted result. Shared with the
/// dismissal tests in `TeleportBootstrapViewWiringTests`.
@MainActor
final class GatedTeleportHTTPClient: TeleportHTTPClienting {
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

    /// A bounded variant of `waitUntilStarted`: `true` when at least `count`
    /// `headlessLogin` calls started within `timeout`, `false` otherwise. The
    /// latch tests use it so a missing latch guard fails as an assertion
    /// instead of parking the stray `begin` on a gate no test releases (the
    /// closure lens measured that mutation as an execution-allowance kill).
    func waitForStarted(_ count: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if startedCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return startedCount >= count
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

    /// Release the `index`-th `headlessLogin` gate only when that call has
    /// started. Unlike `release(index:with:)` this never `XCTFail`s, so a drain
    /// path can call it unconditionally.
    func releaseIfStarted(index: Int, with result: Result<HeadlessLoginResponse, Error>) async {
        guard gates.indices.contains(index) else { return }
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

    // MARK: - Phase-3 login (the login coordinator's per-method gates)

    /// The number of `loginBegin` calls that have started.
    private(set) var loginBeginStartedCount = 0
    /// The number of `loginFinish` calls that have started.
    private(set) var loginFinishStartedCount = 0

    /// Scripted Phase-3 responses, used by the no-result release forms
    /// (`releaseLoginBegin(index:)` / `releaseLoginFinish(index:)`). Seeded
    /// from the committed fixtures so a released call returns a cert the login
    /// coordinator can actually validate.
    var scriptedLoginBeginResponse: LoginBeginResponse? = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
    var scriptedLoginFinishResponse: LoginFinishResponse? = MockTeleportHTTPClient.makeFixtureLoginFinishResponse()

    private var loginBeginGates: [BootstrapGate] = []
    private var loginBeginResults: [Int: Result<LoginBeginResponse, Error>] = [:]
    private var loginBeginStartWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var loginFinishGates: [BootstrapGate] = []
    private var loginFinishResults: [Int: Result<LoginFinishResponse, Error>] = [:]
    private var loginFinishStartWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Suspends until at least `count` `loginBegin` calls have started.
    func waitUntilLoginBeginStarted(_ count: Int) async {
        guard loginBeginStartedCount < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loginBeginStartWaiters.append((count, continuation))
        }
    }

    /// Suspends until at least `count` `loginFinish` calls have started.
    func waitUntilLoginFinishStarted(_ count: Int) async {
        guard loginFinishStartedCount < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loginFinishStartWaiters.append((count, continuation))
        }
    }

    /// A bounded variant of `waitUntilLoginBeginStarted`: `true` when at least
    /// `count` `loginBegin` calls started within `timeout` (see
    /// `waitForStarted` for why the latch tests need the bound).
    func waitForLoginBeginStarted(_ count: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loginBeginStartedCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return loginBeginStartedCount >= count
    }

    /// Release the gate for the `index`-th `loginBegin` call with `result`.
    func releaseLoginBegin(index: Int, with result: Result<LoginBeginResponse, Error>) async {
        guard loginBeginGates.indices.contains(index) else {
            XCTFail("releaseLoginBegin(index: \(index)) but only \(loginBeginGates.count) loginBegin call(s) started")
            return
        }
        loginBeginResults[index] = result
        await loginBeginGates[index].release()
    }

    /// Release the gate for the `index`-th `loginBegin` call with the scripted
    /// response (or the committed fixture when none is scripted).
    func releaseLoginBegin(index: Int) async {
        await releaseLoginBegin(
            index: index,
            with: .success(scriptedLoginBeginResponse ?? MockTeleportHTTPClient.makeFixtureLoginBeginResponse())
        )
    }

    /// Release the gate for the `index`-th `loginFinish` call with `result`.
    func releaseLoginFinish(index: Int, with result: Result<LoginFinishResponse, Error>) async {
        guard loginFinishGates.indices.contains(index) else {
            XCTFail("releaseLoginFinish(index: \(index)) but only \(loginFinishGates.count) loginFinish call(s) started")
            return
        }
        loginFinishResults[index] = result
        await loginFinishGates[index].release()
    }

    /// Release the gate for the `index`-th `loginFinish` call with the scripted
    /// response (or the committed fixture when none is scripted).
    func releaseLoginFinish(index: Int) async {
        await releaseLoginFinish(
            index: index,
            with: .success(scriptedLoginFinishResponse ?? MockTeleportHTTPClient.makeFixtureLoginFinishResponse())
        )
    }

    /// Release the `index`-th `loginBegin` gate only when that call has
    /// started, with the scripted response (or the committed fixture). Unlike
    /// `releaseLoginBegin(index:)` this never `XCTFail`s, so a drain path can
    /// call it unconditionally.
    func releaseLoginBeginIfStarted(index: Int) async {
        await releaseLoginBeginIfStarted(
            index: index,
            with: .success(scriptedLoginBeginResponse ?? MockTeleportHTTPClient.makeFixtureLoginBeginResponse())
        )
    }

    /// Release the `index`-th `loginBegin` gate only when that call has started.
    func releaseLoginBeginIfStarted(index: Int, with result: Result<LoginBeginResponse, Error>) async {
        guard loginBeginGates.indices.contains(index) else { return }
        loginBeginResults[index] = result
        await loginBeginGates[index].release()
    }

    /// Release the `index`-th `loginFinish` gate only when that call has
    /// started, with the scripted response (or the committed fixture).
    func releaseLoginFinishIfStarted(index: Int) async {
        await releaseLoginFinishIfStarted(
            index: index,
            with: .success(scriptedLoginFinishResponse ?? MockTeleportHTTPClient.makeFixtureLoginFinishResponse())
        )
    }

    /// Release the `index`-th `loginFinish` gate only when that call has started.
    func releaseLoginFinishIfStarted(index: Int, with result: Result<LoginFinishResponse, Error>) async {
        guard loginFinishGates.indices.contains(index) else { return }
        loginFinishResults[index] = result
        await loginFinishGates[index].release()
    }

    func loginBegin(baseURL: URL) async throws -> LoginBeginResponse {
        let index = loginBeginStartedCount
        let gate = BootstrapGate()
        loginBeginGates.append(gate)
        loginBeginStartedCount += 1
        resumeLoginBeginStartWaiters()

        await gate.wait()
        guard let result = loginBeginResults.removeValue(forKey: index) else {
            throw HeadlessError.transport("loginBegin not scripted", code: nil)
        }
        return try result.get()
    }

    func loginFinish(
        baseURL: URL,
        assertion: CredentialAssertionResponse,
        sshPubKey: Data,
        ttl: Int64
    ) async throws -> LoginFinishResponse {
        let index = loginFinishStartedCount
        let gate = BootstrapGate()
        loginFinishGates.append(gate)
        loginFinishStartedCount += 1
        resumeLoginFinishStartWaiters()

        await gate.wait()
        guard let result = loginFinishResults.removeValue(forKey: index) else {
            throw HeadlessError.transport("loginFinish not scripted", code: nil)
        }
        return try result.get()
    }

    private func resumeLoginBeginStartWaiters() {
        guard !loginBeginStartWaiters.isEmpty else { return }
        let ready = loginBeginStartWaiters.filter { $0.target <= loginBeginStartedCount }
        loginBeginStartWaiters.removeAll { $0.target <= loginBeginStartedCount }
        for waiter in ready { waiter.continuation.resume() }
    }

    private func resumeLoginFinishStartWaiters() {
        guard !loginFinishStartWaiters.isEmpty else { return }
        let ready = loginFinishStartWaiters.filter { $0.target <= loginFinishStartedCount }
        loginFinishStartWaiters.removeAll { $0.target <= loginFinishStartedCount }
        for waiter in ready { waiter.continuation.resume() }
    }
}

/// A `TeleportCredentialStore` that gates the bootstrap-cert store (and,
/// optionally, the final cluster-TLS store) on a continuation, so a test can
/// interleave `cancel()` while the coordinator is suspended *inside* the
/// persistence sequence. Reads and the ungated writes delegate to the
/// underlying mock; writes are counted. Shared with the dismissal tests in
/// `TeleportBootstrapViewWiringTests`.
@MainActor
final class GatedTeleportCredentialStore: TeleportCredentialStore {
    private let underlying: MockTeleportKeyRing
    private let certGate = BootstrapGate()
    private let keyGate = BootstrapGate()
    private let tlsGate = BootstrapGate()
    private let loginCertGate = BootstrapGate()
    private let clearGate = BootstrapGate()
    private let gateTheFirstStore: Bool
    private let gateTheMiddleStore: Bool
    private let gateTheLastStore: Bool
    private let gateTheLoginCertStore: Bool
    private let gateTheClear: Bool

    private var certStoreStarted = false
    private var certStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var keyStoreStarted = false
    private var keyStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var tlsStoreStarted = false
    private var tlsStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var loginCertStoreStarted = false
    private var loginCertStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var clearStarted = false
    private var clearWaiters: [CheckedContinuation<Void, Never>] = []

    /// Committed write counts (incremented only after the gate is released).
    private(set) var storedCertCount = 0
    private(set) var storedPrivateKeyCount = 0
    private(set) var storedTLSStateCount = 0
    /// The Phase-3 login-cert write count (the login coordinator's first
    /// store). A write already in flight when the generation changes is
    /// allowed to land (§1.4), so tests assert on the *later* writes for the
    /// supersession evidence.
    private(set) var storedLoginCertCount = 0
    /// The fail-closed `clear` count (the login/bootstrap foreign-cert
    /// branch). A clear already in flight when the generation changes is
    /// allowed to land (§1.4), so the discriminating assertion for the
    /// post-`clear` re-take is the withheld terminal state.
    private(set) var clearedCount = 0

    init(
        underlying: MockTeleportKeyRing,
        gateTheFirstStore: Bool = true,
        gateTheMiddleStore: Bool = false,
        gateTheLastStore: Bool = false,
        gateTheLoginCertStore: Bool = false,
        gateTheClear: Bool = false
    ) {
        self.underlying = underlying
        self.gateTheFirstStore = gateTheFirstStore
        self.gateTheMiddleStore = gateTheMiddleStore
        self.gateTheLastStore = gateTheLastStore
        self.gateTheLoginCertStore = gateTheLoginCertStore
        self.gateTheClear = gateTheClear
    }

    /// Suspends until the gated `storeBootstrapCert` has been entered.
    func waitUntilCertStoreStarted() async {
        guard !certStoreStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            certStoreWaiters.append(continuation)
        }
    }

    /// Suspends until the gated `storeEd25519PrivateKey` has been entered.
    func waitUntilPrivKeyStoreStarted() async {
        guard !keyStoreStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            keyStoreWaiters.append(continuation)
        }
    }

    /// Suspends until the gated `storeClusterTLSState` has been entered.
    func waitUntilTLSStoreStarted() async {
        guard !tlsStoreStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            tlsStoreWaiters.append(continuation)
        }
    }

    /// Suspends until the gated `storeLoginCert` has been entered.
    func waitUntilLoginCertStoreStarted() async {
        guard !loginCertStoreStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loginCertStoreWaiters.append(continuation)
        }
    }

    /// Suspends until the gated `clear` has been entered.
    func waitUntilClearStarted() async {
        guard !clearStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            clearWaiters.append(continuation)
        }
    }

    func releaseCertStore() async {
        await certGate.release()
    }

    func releasePrivKeyStore() async {
        await keyGate.release()
    }

    func releaseTLSStore() async {
        await tlsGate.release()
    }

    func releaseLoginCertStore() async {
        await loginCertGate.release()
    }

    func releaseClear() async {
        await clearGate.release()
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

    func liveCredentialSnapshot(for clusterId: UUID) async -> (certPEM: String, privateKeyPEM: Data)? {
        await underlying.liveCredentialSnapshot(for: clusterId)
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
        if gateTheLoginCertStore {
            loginCertStoreStarted = true
            let waiters = loginCertStoreWaiters
            loginCertStoreWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await loginCertGate.wait()
        }
        storedLoginCertCount += 1
        underlying.storeLoginCert(certPEM, validBefore: validBefore, for: clusterId)
    }

    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) async throws {
        if gateTheMiddleStore {
            keyStoreStarted = true
            let waiters = keyStoreWaiters
            keyStoreWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await keyGate.wait()
        }
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
        if gateTheClear {
            clearStarted = true
            let waiters = clearWaiters
            clearWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await clearGate.wait()
        }
        clearedCount += 1
        underlying.clear(for: clusterId)
    }
}

/// A `WebAuthenticationSessionPresenting` stub whose `open(url:)` blocks on a
/// per-call gate, so a test can interleave a `cancel()`/newer `begin()` while
/// the coordinator is suspended in the presenter await (S1). Shared with the
/// dismissal tests in `TeleportBootstrapViewWiringTests`.
@MainActor
final class GatedWebAuthenticationSessionPresenter: WebAuthenticationSessionPresenting {
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
        // The fixture user cert's keyID is `user-cert-ed25519`; the bootstrap
        // coordinator binds `cert.keyID` to the cluster's Teleport user, so
        // the test cluster must name that user (see #262).
        TeleportCluster(host: "teleport.pcad.it", username: "user-cert-ed25519")
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

    /// The coordinator-level twin of the #279 view test (TQ-4): latch the
    /// dismissal directly while the POST is parked, release it with a success,
    /// and assert the absence set without the view's scheduled `cancel()`
    /// having run. The view test proves the call site fires; this proves the
    /// latch semantics.
    ///
    /// Counterfactual (measured): a `latchDismissal()` that sets
    /// `isDismissalLatched` without bumping the generation makes this test fail
    /// on the write assertion (`storedCertCount == 1`, `state == .success`).
    func testDismissalLatchDropsAStalePostSuccess() async {
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: store)
        let cluster = makeCluster()

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)

        coordinator.latchDismissal()
        XCTAssertTrue(coordinator.isDismissalLatched)
        coordinator.latchDismissal()  // idempotent

        await http.release(index: 0, with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse()))
        await beginTask.value

        XCTAssertEqual(coordinator.state, .awaitingApproval, "the latch withholds the terminal state; cancel() owns it")
        XCTAssertEqual(store.storedCertCount, 0, "a latched dismissal must drop the stale success before any store")
        XCTAssertEqual(store.storedPrivateKeyCount, 0)
        XCTAssertEqual(store.storedTLSStateCount, 0)
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))

        // Terminal: a stray retry/begin after the latch is a no-op.
        //
        // `retry()` is awaited directly: it has no gate to park on, so a
        // missing latch guard there fails as the assertion below (measured).
        // `begin()` does have one, so it runs as a bounded task and the request
        // count is asserted before it is awaited — a missing latch guard must
        // fail as an assertion rather than park on a gate no test releases
        // (the closure lens measured that mutation as an execution-allowance
        // kill). The stray's own request is drained when it starts, so the
        // re-armed flow is still caught by the assertions after the await.
        XCTAssertTrue(coordinator.isDismissalLatched)
        XCTAssertEqual(http.startedCount, 1)

        await coordinator.retry()
        XCTAssertEqual(
            coordinator.state, .awaitingApproval,
            "an unguarded retry resets to .idle before begin()'s guard early-returns"
        )

        let strayBegin = Task { await coordinator.begin(cluster: cluster) }
        let strayStartedARequest = await http.waitForStarted(2, timeout: 0.5)
        XCTAssertFalse(
            strayStartedARequest,
            "a latched coordinator must not start another POST"
        )
        if strayStartedARequest {
            await http.releaseIfStarted(
                index: 1,
                with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse())
            )
        }
        await strayBegin.value

        XCTAssertEqual(http.startedCount, 1)
        XCTAssertEqual(store.storedCertCount, 0)
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

    /// Interleave `cancel()` while the coordinator is suspended *inside* the
    /// middle keyring store (the ed25519 private key). This is the one re-take
    /// guard the first/last store tests cannot reach: the cert store has
    /// already committed, and the re-take after the key store (the `:515`
    /// guard) is the only thing that stops the later cluster-TLS write. The
    /// cert and the key are authentic and already in flight when the cancel
    /// lands, so they are allowed to commit; the TLS state, the terminal state
    /// and the in-memory result must all be withheld.
    ///
    /// Counterfactual (measured): deleting the re-take immediately after
    /// `storeEd25519PrivateKey` makes this test fail with
    /// `storedTLSStateCount == 1` and a non-nil `clusterTLSState`.
    func testCancelledRequestDuringPrivateKeyStoreStopsLaterCredentialWrites() async {
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheMiddleStore: true
        )
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: store)
        let cluster = makeCluster()

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)

        await http.release(
            index: 0,
            with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse())
        )
        await store.waitUntilPrivKeyStoreStarted()

        // The cert store has already committed by the time the key store is
        // entered; the coordinator is now suspended inside the key store.
        XCTAssertEqual(store.storedCertCount, 1)
        XCTAssertNotNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await store.releasePrivKeyStore()
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertEqual(store.storedTLSStateCount, 0)
        XCTAssertNil(keyRing.clusterTLSState(for: cluster.id))
    }

    /// Interleave the dismissal latch while the coordinator is suspended
    /// *inside* the foreign-cert fail-closed `clear` (the mismatched-keyID
    /// branch). The clear started while the generation was current, so it is
    /// allowed to land (§1.4); the post-`clear` re-take must withhold the
    /// terminal `.failed(.unknown("Certificate user binding check failed: …"))`
    /// so the stale rejection does not overwrite the newer state.
    ///
    /// Counterfactual (measured): deleting the re-take after `keyRing.clear`
    /// makes this test fail on the state assertion (the terminal `.failed`
    /// overwrites `.awaitingApproval`).
    func testDismissalLatchDuringMismatchClearDoesNotOverwriteTheNewerState() async {
        // Any user other than the fixture cert's keyID (`user-cert-ed25519`)
        // drives `handlePostSuccess` into the foreign-cert fail-closed branch.
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "not-the-fixture-user")
        let keyRing = MockTeleportKeyRing()
        // Seed the credential the fail-closed branch clears, so the
        // post-clear `liveCertPEM` assertion is non-vacuous.
        keyRing.seed(
            clusterId: cluster.id,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: true,
                hasSEPKey: false,
                certValidBefore: TeleportFixtureSupport.fixtureClock,
                credentialID: Data(),
                userHandle: Data(),
                deviceName: "test-device"
            )
        )
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheClear: true
        )
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)
        await awaitState(.awaitingApproval, on: coordinator)
        XCTAssertNotNil(keyRing.liveCertPEM(for: cluster.id))

        // The POST returns a cert that validates against the fixture keypair
        // but carries the fixture keyID, not this cluster's user — the
        // coordinator parks in the fail-closed `clear`.
        await http.release(index: 0, with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse()))
        await store.waitUntilClearStarted()
        XCTAssertEqual(store.clearedCount, 0, "the clear is parked, not committed")

        // Supersede while the clear is in flight.
        coordinator.latchDismissal()
        XCTAssertTrue(coordinator.isDismissalLatched)

        await store.releaseClear()
        await beginTask.value

        XCTAssertEqual(store.clearedCount, 1, "the in-flight clear is allowed to land (§1.4)")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id), "the clear removed the row's credential")
        XCTAssertEqual(
            coordinator.state, .awaitingApproval,
            "the stale mismatch rejection must not overwrite the newer state"
        )
    }
}

#endif
