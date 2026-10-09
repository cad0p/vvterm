// SPDX-License-Identifier: MIT
//
//  GatedTeleportTestDoubles.swift
//  VVTermTests
//
//  Host-side gated test doubles for the Teleport seams. These lived in the
//  deleted `TeleportBootstrapCoordinatorGenerationTests.swift` (the coordinator
//  suites moved into `swift-teleport`); the kept host dismissal/wiring tests
//  still drive them, so they live host-side now.
//
//  See:
//    - VVTermTests/Features/Teleport/TeleportBootstrapViewWiringTests.swift
//    - VVTermTests/Features/Teleport/TeleportLoginDismissalWiringTests.swift
//

#if DEBUG
import Combine
import Foundation
import XCTest
import TeleportCore
import TeleportTesting
@testable import VVTerm

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
    var scriptedLoginFinishResponse: LoginFinishResponse? = TeleportFixtureSupport.makeFixtureLoginFinishResponse()

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
            with: .success(scriptedLoginFinishResponse ?? TeleportFixtureSupport.makeFixtureLoginFinishResponse())
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
            with: .success(scriptedLoginFinishResponse ?? TeleportFixtureSupport.makeFixtureLoginFinishResponse())
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
    /// #298 site-#6 discriminator (site #7's is `storedPairCount`: its
    /// terminal state is masked by the post-pair re-take). The mock mutates
    /// its TLS state in place, so the call itself is the observation point.
    /// Incremented at delegate entry, before the gate.
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
#endif
