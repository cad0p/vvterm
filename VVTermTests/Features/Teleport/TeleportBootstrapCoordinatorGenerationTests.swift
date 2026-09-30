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
//  Further tests gate the *keyring writes* instead, so `cancel()`/the
//  dismissal latch can interleave between the POST release and the terminal
//  state write — the window the post-`await` re-take guards exist for
//  (B1/S2). Without that interleaving the re-take guards would be
//  unreachable: a generation bump before the handler is entered is caught by
//  the entry guard. They gate the first credential write (the atomic pair
//  write), the last store (cluster TLS state), the foreign-cert fail-closed
//  `clear`, and the D4 helper's `liveCredentialSnapshot` read. The D4
//  section covers the helper's stored-cert user-binding gate (F1), the
//  `privKeyData == nil` branch (unreachable in production; driven through the
//  injected encoder), and the helper's post-read supersession re-take.
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

/// A `TeleportCredentialStore` that gates credential writes (the atomic pair
/// write, the single:
/// writes in the reverted two-call shape, and/or the final cluster-TLS store)
/// on a continuation, so a test can interleave a supersession while the
/// coordinator is suspended *inside* the persistence sequence. Reads and the
/// ungated writes delegate to the underlying mock; writes are counted. The
/// credentialID/userHandle reads, the pinned-name read, the Host-CA refresh
/// and `liveCredentialSnapshot` can also be gated, so a test can supersede the
/// coordinator during a read. Shared with the dismissal tests in
/// `TeleportBootstrapViewWiringTests`.
///
/// The first credential write — the atomic pair write in the new shape, or the
/// first single in the reverted two-call shape — also parks on a shared
/// hold-first gate (before any mutation) so a test can interleave a
/// supersession at the top of the write. Later writes pass through, so a second
/// attempt can complete while the first attempt's write is parked.
@MainActor
final class GatedTeleportCredentialStore: TeleportCredentialStore {
    private let underlying: MockTeleportKeyRing
    private let certGate = BootstrapGate()
    private let tlsGate = BootstrapGate()
    private let loginCertGate = BootstrapGate()
    private let clearGate = BootstrapGate()
    private let snapshotGate = BootstrapGate()
    // The four #298 read/refresh gates park **every** call, unlike the
    // claim-once `firstWriteGate`. That is safe only because every test that
    // enables one is single-attempt: the gated read/refresh is reached by
    // exactly one `begin`, so a gate can never be a second caller's blocker.
    // If a test ever adds a second attempt to a gated call, the gate must
    // become claim-once (see `holdFirstCredentialWriteIfNeeded`).
    private let registeredCredentialIDGate = BootstrapGate()
    private let registeredUserHandleGate = BootstrapGate()
    private let clusterTLSStateGate = BootstrapGate()
    private let updateClusterHostKeysGate = BootstrapGate()
    /// The shared hold-first gate: parks only the *first* credential write
    /// across both shapes, before any mutation. Later credential writes pass
    /// through.
    private let firstWriteGate = BootstrapGate()
    private var firstWriteClaimed = false
    private let gateTheFirstStore: Bool
    private let gateTheLastStore: Bool
    private let gateTheLoginCertStore: Bool
    private let gateTheClear: Bool
    private let gateTheSnapshotRead: Bool
    private let gateTheRegisteredCredentialIDRead: Bool
    private let gateTheRegisteredUserHandleRead: Bool
    private let gateTheClusterTLSStateRead: Bool
    private let gateTheUpdateClusterHostKeys: Bool

    private var certStoreStarted = false
    private var certStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var tlsStoreStarted = false
    private var tlsStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var loginCertStoreStarted = false
    private var loginCertStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var clearStarted = false
    private var clearWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstWriteStarted = false
    private var firstWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotReadStarted = false
    private var snapshotReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var registeredCredentialIDReadStarted = false
    private var registeredCredentialIDReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var registeredUserHandleReadStarted = false
    private var registeredUserHandleReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var clusterTLSStateReadStarted = false
    private var clusterTLSStateReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var updateClusterHostKeysStarted = false
    private var updateClusterHostKeysWaiters: [CheckedContinuation<Void, Never>] = []

    /// Committed write counts: incremented only after the underlying store
    /// accepted the write, so a throwing write (the `.login` no-record case,
    /// or a keychain-status throw) is never counted as stored.
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
    /// The `updateClusterHostKeys` (Host CA refresh) invocation count — the
    /// #298 site-#7 discriminator. The mock mutates its TLS state in place, so
    /// the call itself is the observation point. Incremented at delegate
    /// entry, before the gate.
    private(set) var updateClusterHostKeysCallCount = 0
    /// The atomic pair-write count (T2's positive side).
    private(set) var storedPairCount = 0
    /// Direct single-write invocation counts. The pair write also bumps the
    /// legacy per-half counters above (so every existing probe stays
    /// discriminating), so these are what T2's "0 singles" assertion reads.
    private(set) var singleStoreBootstrapCertCount = 0
    private(set) var singleStoreLoginCertCount = 0
    private(set) var singleStoreEd25519PrivateKeyCount = 0
    /// The write-invocation ordinal of the last *committed* cert / key half.
    /// The pair write installs both halves in one invocation, so a torn pair
    /// (halves from two invocations) is detectable without value comparison;
    /// the two-call counterfactual always leaves these different.
    private(set) var committedCertWriteOrdinal = 0
    private(set) var committedKeyWriteOrdinal = 0
    private var writeOrdinal = 0

    init(
        underlying: MockTeleportKeyRing,
        gateTheFirstStore: Bool = true,
        gateTheLastStore: Bool = false,
        gateTheLoginCertStore: Bool = false,
        gateTheClear: Bool = false,
        gateTheSnapshotRead: Bool = false,
        gateTheRegisteredCredentialIDRead: Bool = false,
        gateTheRegisteredUserHandleRead: Bool = false,
        gateTheClusterTLSStateRead: Bool = false,
        gateTheUpdateClusterHostKeys: Bool = false
    ) {
        self.underlying = underlying
        self.gateTheFirstStore = gateTheFirstStore
        self.gateTheLastStore = gateTheLastStore
        self.gateTheLoginCertStore = gateTheLoginCertStore
        self.gateTheClear = gateTheClear
        self.gateTheSnapshotRead = gateTheSnapshotRead
        self.gateTheRegisteredCredentialIDRead = gateTheRegisteredCredentialIDRead
        self.gateTheRegisteredUserHandleRead = gateTheRegisteredUserHandleRead
        self.gateTheClusterTLSStateRead = gateTheClusterTLSStateRead
        self.gateTheUpdateClusterHostKeys = gateTheUpdateClusterHostKeys
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

    /// Suspends until the gated `storeLoginCert` has been entered.
    func waitUntilLoginCertStoreStarted() async {
        guard !loginCertStoreStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loginCertStoreWaiters.append(continuation)
        }
    }

    /// Suspends until the gated `liveCredentialSnapshot` has been entered.
    func waitUntilSnapshotReadStarted() async {
        guard !snapshotReadStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            snapshotReadWaiters.append(continuation)
        }
    }

    func releaseSnapshotRead() async {
        await snapshotGate.release()
    }

    /// Suspends until the gated `registeredCredentialID` read has been entered.
    func waitUntilRegisteredCredentialIDReadStarted() async {
        guard !registeredCredentialIDReadStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registeredCredentialIDReadWaiters.append(continuation)
        }
    }

    func releaseRegisteredCredentialIDRead() async {
        await registeredCredentialIDGate.release()
    }

    /// Suspends until the gated `registeredUserHandle` read has been entered.
    func waitUntilRegisteredUserHandleReadStarted() async {
        guard !registeredUserHandleReadStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registeredUserHandleReadWaiters.append(continuation)
        }
    }

    func releaseRegisteredUserHandleRead() async {
        await registeredUserHandleGate.release()
    }

    /// Suspends until the gated `clusterTLSState` read has been entered.
    func waitUntilClusterTLSStateReadStarted() async {
        guard !clusterTLSStateReadStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            clusterTLSStateReadWaiters.append(continuation)
        }
    }

    func releaseClusterTLSStateRead() async {
        await clusterTLSStateGate.release()
    }

    /// Suspends until the gated `updateClusterHostKeys` has been entered.
    func waitUntilUpdateClusterHostKeysStarted() async {
        guard !updateClusterHostKeysStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            updateClusterHostKeysWaiters.append(continuation)
        }
    }

    func releaseUpdateClusterHostKeys() async {
        await updateClusterHostKeysGate.release()
    }

    /// Suspends until the gated `clear` has been entered.
    func waitUntilClearStarted() async {
        guard !clearStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            clearWaiters.append(continuation)
        }
    }

    private func signalClearStarted() {
        clearStarted = true
        let waiters = clearWaiters
        clearWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until the first credential write (the atomic pair write, or
    /// the first single in the reverted two-call shape) is entered.
    func waitUntilFirstCredentialWriteStarted() async {
        guard !firstWriteStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            firstWriteWaiters.append(continuation)
        }
    }

    func releaseCertStore() async {
        await certGate.release()
        // The atomic pair write parks on the shared gate instead of the
        // per-single cert gate; releasing either name must unpark it.
        await firstWriteGate.release()
    }

    func releaseTLSStore() async {
        await tlsGate.release()
    }

    func releaseLoginCertStore() async {
        await loginCertGate.release()
        await firstWriteGate.release()
    }

    func releaseClear() async {
        await clearGate.release()
    }

    /// Releases the parked first credential write in either shape.
    func releaseFirstCredentialWrite() async {
        await firstWriteGate.release()
        await certGate.release()
        await loginCertGate.release()
    }

    // MARK: - Reads (delegate)

    func clusterTLSState(for clusterId: UUID) async -> TeleportClusterTLSState? {
        if gateTheClusterTLSStateRead {
            clusterTLSStateReadStarted = true
            let waiters = clusterTLSStateReadWaiters
            clusterTLSStateReadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await clusterTLSStateGate.wait()
        }
        return underlying.clusterTLSState(for: clusterId)
    }

    func liveCertPEM(for clusterId: UUID) async -> String? {
        underlying.liveCertPEM(for: clusterId)
    }

    func liveEd25519PrivateKey(for clusterId: UUID) async -> Data? {
        underlying.liveEd25519PrivateKey(for: clusterId)
    }

    func liveCredentialSnapshot(for clusterId: UUID) async -> (certPEM: String, privateKeyPEM: Data)? {
        if gateTheSnapshotRead {
            snapshotReadStarted = true
            let waiters = snapshotReadWaiters
            snapshotReadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await snapshotGate.wait()
        }
        return await underlying.liveCredentialSnapshot(for: clusterId)
    }

    func registeredCredentialID(for clusterId: UUID) async -> Data? {
        if gateTheRegisteredCredentialIDRead {
            registeredCredentialIDReadStarted = true
            let waiters = registeredCredentialIDReadWaiters
            registeredCredentialIDReadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await registeredCredentialIDGate.wait()
        }
        return underlying.registeredCredentialID(for: clusterId)
    }

    func registeredUserHandle(for clusterId: UUID) async -> Data? {
        if gateTheRegisteredUserHandleRead {
            registeredUserHandleReadStarted = true
            let waiters = registeredUserHandleReadWaiters
            registeredUserHandleReadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await registeredUserHandleGate.wait()
        }
        return underlying.registeredUserHandle(for: clusterId)
    }

    // MARK: - Writes

    /// Parks the first credential write across both shapes: the pair write
    /// parks on the shared `firstWriteGate`, the first single (the two-call
    /// counterfactual) on its per-single gate. Later writes pass through. The
    /// wait sits before any mutation, never between a write's own mutations.
    private func holdFirstCredentialWriteIfNeeded(gate: BootstrapGate) async {
        guard !firstWriteClaimed else { return }
        firstWriteClaimed = true
        firstWriteStarted = true
        let waiters = firstWriteWaiters
        firstWriteWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await gate.wait()
    }

    private func signalCertStoreStarted() {
        certStoreStarted = true
        let waiters = certStoreWaiters
        certStoreWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func signalLoginCertStoreStarted() {
        loginCertStoreStarted = true
        let waiters = loginCertStoreWaiters
        loginCertStoreWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func storeBootstrapCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async {
        if gateTheFirstStore {
            signalCertStoreStarted()
            await holdFirstCredentialWriteIfNeeded(gate: certGate)
        }
        writeOrdinal += 1
        let ordinal = writeOrdinal
        singleStoreBootstrapCertCount += 1
        storedCertCount += 1
        underlying.storeBootstrapCert(certPEM, validBefore: validBefore, for: clusterId)
        committedCertWriteOrdinal = ordinal
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
            signalLoginCertStoreStarted()
            await holdFirstCredentialWriteIfNeeded(gate: loginCertGate)
        }
        writeOrdinal += 1
        let ordinal = writeOrdinal
        singleStoreLoginCertCount += 1
        storedLoginCertCount += 1
        underlying.storeLoginCert(certPEM, validBefore: validBefore, for: clusterId)
        committedCertWriteOrdinal = ordinal
    }

    func storeCredentialPair(
        _ certPEM: String,
        validBefore: Date,
        privateKeyPEM: Data,
        policy: TeleportCredentialWritePolicy,
        for clusterId: UUID
    ) async throws {
        switch policy {
        case .bootstrap:
            if gateTheFirstStore {
                signalCertStoreStarted()
                await holdFirstCredentialWriteIfNeeded(gate: firstWriteGate)
            }
        case .login:
            if gateTheLoginCertStore {
                signalLoginCertStoreStarted()
                await holdFirstCredentialWriteIfNeeded(gate: firstWriteGate)
            }
        }
        // The counting block runs only after the underlying store accepted the
        // write, so a throw (the `.login` no-record case, or a keychain-status
        // throw) counts as attempted-but-not-committed. Both halves of the
        // committed pair share this invocation's ordinal.
        try underlying.storeCredentialPair(
            certPEM,
            validBefore: validBefore,
            privateKeyPEM: privateKeyPEM,
            policy: policy,
            for: clusterId
        )
        writeOrdinal += 1
        let ordinal = writeOrdinal
        storedPairCount += 1
        storedCertCount += 1
        storedLoginCertCount += 1
        storedPrivateKeyCount += 1
        committedCertWriteOrdinal = ordinal
        committedKeyWriteOrdinal = ordinal
    }

    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) async throws {
        try underlying.storeEd25519PrivateKey(pemData, for: clusterId)
        writeOrdinal += 1
        let ordinal = writeOrdinal
        singleStoreEd25519PrivateKeyCount += 1
        storedPrivateKeyCount += 1
        committedKeyWriteOrdinal = ordinal
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
        updateClusterHostKeysCallCount += 1
        if gateTheUpdateClusterHostKeys {
            updateClusterHostKeysStarted = true
            let waiters = updateClusterHostKeysWaiters
            updateClusterHostKeysWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await updateClusterHostKeysGate.wait()
        }
        return underlying.updateClusterHostKeys(checkingKeys, for: clusterId)
    }

    func clear(for clusterId: UUID) async {
        if gateTheClear {
            signalClearStarted()
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
        presenter: (any WebAuthenticationSessionPresenting)? = nil,
        sshKeyPairGenerator: (any TeleportSSHKeyPairGenerating)? = nil,
        privateKeyDataEncoder: ((String) -> Data?)? = nil
    ) -> TeleportBootstrapCoordinator {
        TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: keyRing,
            safariPresenter: presenter ?? MockWebAuthenticationSessionPresenter(),
            logging: DefaultTeleportLogging(),
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: sshKeyPairGenerator ?? TeleportFixtureSupport.makeFixedSSHGenerator(),
            tlsKeyPairGenerator: try! TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock },
            privateKeyDataEncoder: privateKeyDataEncoder ?? { $0.data(using: .utf8) }
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
    /// atomic pair write. The pair write was already in flight when the cancel
    /// landed, so it is allowed to land **complete** (§1.4) — the credential
    /// can never be torn. The later cluster-TLS write, the in-memory result
    /// and the terminal state must all be withheld.
    func testCancelledRequestDuringFirstKeyringStoreLetsTheInFlightPairLand() async {
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
        await store.waitUntilFirstCredentialWriteStarted()

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await store.releaseFirstCredentialWrite()
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertEqual(store.storedPairCount, 1, "the in-flight pair write is allowed to land complete")
        XCTAssertEqual(store.storedPrivateKeyCount, 1)
        XCTAssertNotNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
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

    // MARK: - T1: a superseded atomic pair write cannot tear the credential

    /// T1 (bootstrap half): a supersession landing while attempt 1's atomic pair
    /// write is parked cannot tear the credential. Attempt 2 runs to `.success`
    /// (pair 2 + TLS state) while attempt 1 is parked; releasing attempt 1 then
    /// lands **pair 1 complete** over pair 2. The final snapshot is one
    /// attempt's complete pair, and the committed cert and key halves come from
    /// the same write invocation.
    ///
    /// This is a coordinator-shape test with a suspension-capable conformer;
    /// the production atomicity is pinned structurally by
    /// `TeleportCredentialPairPinsTests` (the keyring pair body suspends
    /// nowhere).
    ///
    /// The measured counterfactual (coordinator-only revert to the two singles)
    /// fails this test with `(cert_1, key_2)` — see the PR report.
    func testSupersededPairWriteCannotTearTheBootstrapCredential() async {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing)
        let http = GatedTeleportHTTPClient()
        let generator = AttemptTaggedSSHKeyPairGenerator(attemptCount: 2)
        let coordinator = makeCoordinator(http: http, keyRing: store, sshKeyPairGenerator: generator)

        // Distinct per-attempt validity so a stale attempt-1 terminal write is
        // distinguishable from attempt 2's (G1: with identical payloads the
        // final-state assertion below would be vacuous).
        let attempt1ValidBefore = TeleportFixtureSupport.attemptCertValidBefore.addingTimeInterval(60)
        let attempt2ValidBefore = TeleportFixtureSupport.attemptCertValidBefore.addingTimeInterval(120)

        let attempt1Cert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: generator.attempts[0].rawKey,
            keyID: cluster.username,
            validBefore: attempt1ValidBefore
        )
        let attempt2Cert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: generator.attempts[1].rawKey,
            keyID: cluster.username,
            validBefore: attempt2ValidBefore
        )

        // Attempt 1: release its POST so it reaches the pair write and parks.
        let first = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)
        await http.release(
            index: 0,
            with: .success(TeleportFixtureSupport.makeAttemptHeadlessResponse(
                attempt: 0,
                generator: generator,
                cluster: cluster,
                validBefore: attempt1ValidBefore
            ))
        )
        await store.waitUntilFirstCredentialWriteStarted()
        XCTAssertEqual(store.storedPairCount, 0, "attempt 1's pair write is parked, not committed")

        // Attempt 2: supersedes attempt 1 and runs to `.success`, landing its
        // complete pair + TLS state while attempt 1 is still parked.
        let second = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(2)
        await http.release(
            index: 1,
            with: .success(TeleportFixtureSupport.makeAttemptHeadlessResponse(
                attempt: 1,
                generator: generator,
                cluster: cluster,
                validBefore: attempt2ValidBefore
            ))
        )
        await second.value

        XCTAssertEqual(coordinator.state, .success)
        XCTAssertEqual(
            coordinator.lastBootstrapResult?.certValidBefore,
            attempt2ValidBefore,
            "attempt 2's result is the current hand-off"
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
        XCTAssertEqual(coordinator.state, .success, "attempt 1's stale pair write must not write the terminal state")
        XCTAssertEqual(
            coordinator.lastBootstrapResult?.certValidBefore,
            attempt2ValidBefore,
            "attempt 1's stale pair write must not overwrite attempt 2's hand-off result"
        )
    }

    /// T1 sub-case (C): the dismissal latch while the pair write is parked has
    /// the same in-flight-lands rule as `cancel()`: the released pair lands
    /// complete, and the terminal state is withheld (the latch itself writes
    /// nothing; the view's scheduled teardown owns it).
    func testLatchDuringParkedPairWriteLandsACompletePair() async {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing)
        let http = GatedTeleportHTTPClient()
        let generator = AttemptTaggedSSHKeyPairGenerator(attemptCount: 1)
        let coordinator = makeCoordinator(http: http, keyRing: store, sshKeyPairGenerator: generator)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)
        await http.release(
            index: 0,
            with: .success(TeleportFixtureSupport.makeAttemptHeadlessResponse(attempt: 0, generator: generator, cluster: cluster))
        )
        await store.waitUntilFirstCredentialWriteStarted()

        coordinator.latchDismissal()
        XCTAssertTrue(coordinator.isDismissalLatched)

        await store.releaseFirstCredentialWrite()
        await beginTask.value

        XCTAssertEqual(store.storedPairCount, 1)
        let final = await keyRing.liveCredentialSnapshot(for: cluster.id)
        XCTAssertEqual(
            final?.certPEM,
            TeleportFixtureSupport.makeSynthUserCert(rawKey: generator.attempts[0].rawKey, keyID: cluster.username)
        )
        XCTAssertEqual(final?.privateKeyPEM, Data(generator.attempts[0].privateKeyPEM.utf8))
        XCTAssertEqual(store.committedCertWriteOrdinal, store.committedKeyWriteOrdinal)
        XCTAssertEqual(coordinator.state, .awaitingApproval, "the latch withholds the terminal state")
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertEqual(store.storedTLSStateCount, 0)
    }

    // MARK: - T2: exactly one pair write, zero single writes

    /// T2 (bootstrap): exactly one atomic pair write and zero single writes,
    /// with the terminal `.success` as the positive control (a flow that bails
    /// before the store cannot satisfy it).
    func testBootstrapStoresTheCredentialAsExactlyOnePairWrite() async {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()
        let coordinator = makeCoordinator(http: http, keyRing: store)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .success)
        XCTAssertEqual(store.storedPairCount, 1)
        XCTAssertEqual(store.singleStoreBootstrapCertCount, 0)
        XCTAssertEqual(store.singleStoreEd25519PrivateKeyCount, 0)
    }

    // MARK: - T6 / D4: the post-throw states

    /// T6 (bootstrap): `cancel()` while the pair write is parked, then a
    /// throwing key seam on release — nothing is committed, no TLS state is
    /// written, and the cancel's `.failed(.userCancelled)` wins over the D4
    /// store-failure outcome (the generation re-take withholds it).
    func testCancelledRequestDuringPairStoreFailureCommitsNothing() async {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)
        let store = GatedTeleportCredentialStore(underlying: keyRing)
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)
        await http.release(
            index: 0,
            with: .success(MockTeleportHTTPClient.makeFixtureSuccessResponse())
        )
        await store.waitUntilFirstCredentialWriteStarted()

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await store.releaseFirstCredentialWrite()
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
        XCTAssertEqual(store.storedPairCount, 0, "the throwing write was attempted but committed nothing")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertNil(keyRing.clusterTLSState(for: cluster.id))
    }

    /// D4 (bootstrap) non-nil branch: a failed pair write with a usable prior
    /// stored pair keeps the hand-off working — `.success` with the STORED
    /// cert's fields, and no TLS state written on this path.
    func testBootstrapPairStoreFailureWithAPriorPairSucceedsWithTheStoredPair() async throws {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let priorCert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: Data(repeating: 0x77, count: 32),
            keyID: cluster.username
        )
        let priorKey = Data("prior-ed25519-private-key".utf8)
        keyRing.seed(
            clusterId: cluster.id,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: Data([1, 2, 3]),
                userHandle: Data("handle".utf8),
                deviceName: "test-device"
            )
        )
        keyRing.storeBootstrapCert(priorCert, validBefore: TeleportFixtureSupport.attemptCertValidBefore, for: cluster.id)
        try keyRing.storeEd25519PrivateKey(priorKey, for: cluster.id)
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)

        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()
        let coordinator = makeCoordinator(http: http, keyRing: store)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .success)
        XCTAssertEqual(coordinator.lastBootstrapResult?.sshCertPEM, priorCert)
        XCTAssertEqual(coordinator.lastBootstrapResult?.certValidBefore, TeleportFixtureSupport.attemptCertValidBefore)
        XCTAssertEqual(keyRing.liveCredentialSnapshot(for: cluster.id)?.certPEM, priorCert)
        XCTAssertEqual(keyRing.liveCredentialSnapshot(for: cluster.id)?.privateKeyPEM, priorKey)
        XCTAssertNil(keyRing.clusterTLSState(for: cluster.id), "the throw path does not write TLS state")
    }

    /// F1 (bootstrap): the D4 helper must re-apply the stored cert's
    /// user-binding gate. A prior stored pair whose cert belongs to a foreign
    /// Teleport user (the row's username was edited after storage) must not be
    /// handed off as `.success` when this attempt's pair write throws: the
    /// helper clears the credential and fails closed, exactly like the main
    /// path (:537).
    func testBootstrapPairStoreFailureWithAForeignStoredCertClearsAndFails() async throws {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let priorCert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: Data(repeating: 0x88, count: 32),
            keyID: "someone-else"  // not cluster.username — the stored cert is foreign
        )
        let priorKey = Data("foreign-prior-ed25519-key".utf8)
        keyRing.seed(
            clusterId: cluster.id,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: Data([1, 2, 3]),
                userHandle: Data("handle".utf8),
                deviceName: "test-device"
            )
        )
        keyRing.storeBootstrapCert(priorCert, validBefore: TeleportFixtureSupport.attemptCertValidBefore, for: cluster.id)
        try keyRing.storeEd25519PrivateKey(priorKey, for: cluster.id)
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)

        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()
        let coordinator = makeCoordinator(http: http, keyRing: store)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(
            coordinator.state,
            .failed(.unknown("Certificate user binding check failed: the certificate does not belong to this Teleport user")),
            "the stored foreign cert must not be handed off as .success"
        )
        XCTAssertNil(keyRing.credentials[cluster.id], "the foreign stored credential was cleared")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertNil(keyRing.clusterTLSState(for: cluster.id))
    }

    /// G5 (bootstrap): the `privKeyData == nil` branch is unreachable in
    /// production (a Swift `String` always UTF-8-encodes), so it is driven
    /// through the injected encoder. It must fail closed through the D4
    /// outcome instead of committing half a credential.
    func testBootstrapNilPrivateKeyDataFailsClosedWithoutAWrite() async {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()
        let coordinator = makeCoordinator(http: http, keyRing: store, privateKeyDataEncoder: { _ in nil })

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .failed(.unknown("credentials could not be stored")))
        XCTAssertEqual(store.storedPairCount, 0, "the nil branch must not attempt a pair write")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertNil(keyRing.clusterTLSState(for: cluster.id))
    }

    /// G5 (bootstrap): the D4 helper's post-read re-take. A `cancel()` landing
    /// while the helper is suspended in `liveCredentialSnapshot` must keep the
    /// helper from writing the store-failure state over `.failed(.userCancelled)`.
    func testSupersessionDuringTheD4SnapshotReadWithholdsTheStoreFailure() async {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheSnapshotRead: true
        )
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()
        let coordinator = makeCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await store.waitUntilSnapshotReadStarted()

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await store.releaseSnapshotRead()
        await beginTask.value

        XCTAssertEqual(
            coordinator.state,
            .failed(.userCancelled),
            "the stale store-failure must not overwrite the cancel's terminal state"
        )
    }
}

#endif
