// SPDX-License-Identifier: MIT
//
//  ExecRequestCancellationTests.swift
//  VVTermTests
//
//  Unit tests for the exec-request cancellation lifecycle (issue #121:
//  probe timeouts called `cancelExecRequest` -> `finishExecRequest`, which
//  closed/freed the libssh2 channel off-loop while the I/O loop was
//  suspended between reads on that same channel, corrupting the session
//  and cascading into `Exec read failed: -43` + `channelOpenFailed` +
//  reconnect loops).
//
//  The fix splits completion into two roles:
//  - Off-loop cancellation (`ExecRequest.cancel()`, invoked from the
//    off-actor `withTaskCancellationHandler(onCancel:)`): marks the request
//    cancelled and resumes its continuation directly — no session-actor hop
//    (#276; the old `cancelExecRequest` hop never arrived while the actor
//    was parked). Never touches the libssh2 channel.
//  - Loop-side teardown (`finishExecRequest` / the loops' cancelled-request
//    branch): closes + frees the channel exactly once, then removes the
//    request from the table.
//
//  The libssh2 channel teardown itself cannot be unit-tested here — the
//  harness has no live libssh2 session — so those paths are verified in CI
//  against real SSH/Teleport endpoints. What IS tested here is the pure-Swift
//  part of the fix: the single-resume invariant that prevents double-resume
//  crashes when cancellation, loop-side completion and session teardown
//  race to complete the same request, the cancel-before-install windows
//  (#276), and the loop-keep-alive decision that guarantees the deferred
//  teardown runs.

import XCTest
@testable import VVTerm

final class ExecRequestCancellationTests: XCTestCase {

    // MARK: - Helpers

    /// Captures a real `CheckedContinuation` from a suspended task so a
    /// request under test can be resumed exactly like the production
    /// cancellation/completion paths do.
    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CheckedContinuation<String, Error>?

        func store(_ continuation: CheckedContinuation<String, Error>) {
            lock.lock()
            stored = continuation
            lock.unlock()
        }

        var continuation: CheckedContinuation<String, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private func makeRequest(
        command: String = "probe"
    ) async -> (request: SSHSession.ExecRequest, outcome: Task<String, Error>) {
        let box = ContinuationBox()
        let outcome = Task<String, Error> {
            try await withCheckedThrowingContinuation { box.store($0) }
        }
        while box.continuation == nil {
            await Task.yield()
        }
        let request = SSHSession.ExecRequest(id: UUID(), command: command, isInner: false)
        request.install(box.continuation!)
        return (request, outcome)
    }

    // MARK: - Off-loop cancellation (holder `cancel()`)

    /// The off-loop cancellation path marks the request cancelled and
    /// resumes its continuation with the cancellation error. The mark is
    /// what tells the I/O loop to tear the channel down WITHOUT resuming
    /// the continuation again.
    ///
    /// Counterfactual: cannot fail against the pre-#276 code — `cancel()` and
    /// `install(_:)` are new API, so reverting production leaves this target
    /// failing to compile rather than failing behaviourally. It is a holder
    /// state-semantics test; the hop removal itself is not unit-observable
    /// without a live `SSHSession`.
    func testCancellationMarksRequestAndResumesContinuation() async {
        let (request, outcome) = await makeRequest()

        request.cancel()

        XCTAssertTrue(request.isCancelled)
        XCTAssertTrue(request.continuationResumed)
        do {
            _ = try await outcome.value
            XCTFail("Expected the cancellation error")
        } catch is CancellationError {
            // Expected: the first resume wins.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// A second cancellation (double timeout, timeout + user cancel) must
    /// be a no-op: the continuation is resumed exactly once.
    func testDoubleCancellationResumesExactlyOnce() async {
        let (request, outcome) = await makeRequest()

        request.cancel()
        request.cancel()
        request.resume(throwing: SSHError.timeout) // ignored

        XCTAssertTrue(request.continuationResumed)
        do {
            _ = try await outcome.value
            XCTFail("Expected the cancellation error")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Session teardown (`failAllExecRequests`, transport invalidation)
    /// must not double-resume a request that the cancellation path already
    /// completed.
    func testSessionTeardownDoesNotDoubleResumeCancelledRequest() async {
        let (request, outcome) = await makeRequest()

        request.cancel()
        // failAllExecRequests-equivalent for a cancelled request that is
        // still in the table when the transport is invalidated:
        request.channel = nil
        request.resume(throwing: SSHError.notConnected) // ignored

        XCTAssertTrue(request.continuationResumed)
        do {
            _ = try await outcome.value
            XCTFail("Expected the cancellation error")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Loop-side completion before cancellation (the loop won the race):
    /// the success resume wins and the later cancellation resume is
    /// ignored.
    func testLoopSideCompletionWinsOverLateCancellation() async {
        let (request, outcome) = await makeRequest()

        request.resume(returning: "output")
        request.cancel() // ignored

        let value = try? await outcome.value
        XCTAssertEqual(value, "output")
    }

    // MARK: - Cancel-before-install

    /// `onCancel` can run before the continuation is installed (it is invoked
    /// immediately when the task is already cancelled at handler
    /// installation, and the handler races the continuation body). The holder
    /// must record the cancel and `install` must apply it exactly once.
    ///
    /// Counterfactual: cannot fail against the pre-#276 code (`install` is new
    /// API; reverting production is a compile failure for this target).
    func testCancelBeforeInstallResumesOnceAtInstall() async {
        let box = ContinuationBox()
        let outcome = Task<String, Error> {
            try await withCheckedThrowingContinuation { box.store($0) }
        }
        while box.continuation == nil {
            await Task.yield()
        }
        let request = SSHSession.ExecRequest(id: UUID(), command: "probe", isInner: false)

        request.cancel() // before install: no continuation to resume yet
        XCTAssertTrue(request.isCancelled)
        XCTAssertFalse(request.continuationResumed)

        let installed = request.install(box.continuation!)

        XCTAssertFalse(installed, "install must report the applied pending cancel")
        XCTAssertTrue(request.continuationResumed)
        do {
            _ = try await outcome.value
            XCTFail("Expected the cancellation error")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// No cancellation: install keeps the request live for the I/O loop.
    func testInstallWithoutCancellationKeepsRequestLive() async {
        let (request, _) = await makeRequest()

        XCTAssertFalse(request.isCancelled)
        XCTAssertFalse(request.continuationResumed)
    }

    // MARK: - runWithTimeout harness (D1 negative control + E2 characterization)

    /// An off-actor-resumable operation times out promptly. This is a harness
    /// negative control, NOT coverage of the production hop removal
    /// (#276/N9): the operation abandons itself at its own cancellation
    /// suspension point, so it passes identically before and after D1. The
    /// behaviour coverage of D1 is the holder state-semantics tests above.
    func testRunWithTimeoutTimesOutAPromptlyAbandonableOperation() async {
        let start = ContinuousClock.now
        do {
            _ = try await SSHClient.runWithTimeout(.milliseconds(200)) {
                try await Task.sleep(for: .seconds(60))
                return "late"
            }
            XCTFail("Expected the timeout")
        } catch SSHError.timeout {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertLessThan(
            start.duration(to: ContinuousClock.now),
            .seconds(5),
            "a promptly-abandonable operation must time out promptly"
        )
    }

    /// E2 characterization (plan v3; measured in `/tmp/exp276/expA.swift`):
    /// a child parked inside a hard-wedged actor still defeats
    /// `runWithTimeout`. The deadline fires at ~0.2 s, but the task-group
    /// scope awaits the still-parked child, so this call only returns once
    /// the wedge ends. This pins D1's honest claim: removing the
    /// cancellation-*delivery* hop does not make the timeout bounded by the
    /// deadline.
    ///
    /// Characterization test — it passes against the pre-#276 code too (it
    /// pins existing behaviour so the claim stays documented; it is not
    /// coverage of a fix).
    func testRunWithTimeoutCharacterizesAHardActorWedge() async {
        let session = WedgedExecSession()
        let start = ContinuousClock.now
        let operation = Task<String, Error> {
            try await SSHClient.runWithTimeout(.milliseconds(200)) {
                try await session.park()
            }
        }
        while !session.isParked {
            await Task.yield()
        }
        let wedge = Task { await session.wedge(seconds: 2.0) }

        do {
            _ = try await operation.value
            XCTFail("Expected the timeout")
        } catch SSHError.timeout {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        XCTAssertGreaterThanOrEqual(
            elapsed,
            .milliseconds(1500),
            "a hard-wedged actor keeps the parked child (and the timeout call) alive past the deadline"
        )
        XCTAssertLessThan(elapsed, .seconds(15), "the wedge must self-terminate")
        _ = await wedge.value
    }

    // MARK: - Loop keep-alive decision (shouldOuterIOLoopContinue)

    /// A request cancelled off-loop stays in `execRequests` until the loop
    /// tears its channel down, so it must keep the loop alive — this is
    /// what guarantees the deferred teardown runs (issue #121).
    func testOuterLoopContinuesWhileCancelledRequestPending() {
        XCTAssertTrue(
            SSHSession.shouldOuterIOLoopContinue(hasOuterShell: false, hasOuterExec: true)
        )
    }

    func testOuterLoopContinuesWithShellChannel() {
        XCTAssertTrue(
            SSHSession.shouldOuterIOLoopContinue(hasOuterShell: true, hasOuterExec: false)
        )
    }

    func testOuterLoopContinuesWithBothWorkKinds() {
        XCTAssertTrue(
            SSHSession.shouldOuterIOLoopContinue(hasOuterShell: true, hasOuterExec: true)
        )
    }

    func testOuterLoopExitsWhenIdle() {
        XCTAssertFalse(
            SSHSession.shouldOuterIOLoopContinue(hasOuterShell: false, hasOuterExec: false)
        )
    }

    // MARK: - Shell close reason diagnostics (issue #120 evidence)

    /// The `ssh_diag shell_closed reason=...` strings are the CI evidence
    /// contract — lock them down so greps in the runner logs keep working.
    func testShellCloseReasonDiagDescriptions() {
        XCTAssertEqual(SSHSession.ShellCloseReason.eof.diagDescription, "eof")
        XCTAssertEqual(
            SSHSession.ShellCloseReason.readError(-43).diagDescription,
            "read_error:-43"
        )
        XCTAssertEqual(
            SSHSession.ShellCloseReason.appInitiated.diagDescription,
            "app_initiated"
        )
        XCTAssertEqual(
            SSHSession.ShellCloseReason.loopExit.diagDescription,
            "loop_exit"
        )
        XCTAssertEqual(
            SSHSession.ShellCloseReason.transportInvalidated.diagDescription,
            "transport_invalidated"
        )
    }
}

// MARK: - E2 characterization helpers

/// Lock-protected parked continuation mirroring D1's `ExecRequest` holder:
/// the onCancel handler resumes the continuation **off-actor**, exactly the
/// shape whose limits E2 pins (the resumed child still needs the wedged
/// actor to return from the parked method).
private final class ParkState: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<String, Error>?
        var resumed = false
    }

    private let lock = NSLock()
    private var state = State()

    var isParked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.continuation != nil
    }

    func install(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        state.continuation = continuation
        lock.unlock()
    }

    /// Off-actor resume — no actor hop (the D1 shape).
    func cancelOffActor() {
        lock.lock()
        let continuation: CheckedContinuation<String, Error>?
        if !state.resumed, let stored = state.continuation {
            state.resumed = true
            state.continuation = nil
            continuation = stored
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

/// A session-shaped actor whose `park()` is cancelled off-actor and whose
/// `wedge()` synchronously blocks the actor's executor.
private actor WedgedExecSession {
    nonisolated let parkState = ParkState()

    nonisolated var isParked: Bool {
        parkState.isParked
    }

    func park() async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                parkState.install(continuation)
            }
        }, onCancel: {
            parkState.cancelOffActor()
        })
    }

    /// Synchronously blocks the actor's executor (the "hard wedge").
    func wedge(seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = 0 }
    }
}
