// SPDX-License-Identifier: AGPL-3.0-or-later
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
//  - Off-loop cancellation (`cancelExecRequest`): marks the request
//    cancelled and resumes its continuation with the error. Never touches
//    the libssh2 channel.
//  - Loop-side teardown (`finishExecRequest` / the loops' cancelled-request
//    branch): closes + frees the channel exactly once, then removes the
//    request from the table.
//
//  The libssh2 channel teardown itself cannot be unit-tested here — the
//  harness has no live libssh2 session — so those paths are verified in CI
//  against real SSH/Teleport endpoints. What IS tested is the pure-Swift
//  part of the fix: the single-resume invariant that prevents double-resume
//  crashes when cancellation, loop-side completion and session teardown
//  race to complete the same request, and the loop-keep-alive decision
//  that guarantees the deferred teardown runs.

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
        let request = SSHSession.ExecRequest(
            id: UUID(),
            command: command,
            continuation: box.continuation!
        )
        return (request, outcome)
    }

    // MARK: - Off-loop cancellation (cancelExecRequest-equivalent)

    /// The off-loop cancellation path marks the request cancelled and
    /// resumes its continuation with the cancellation error. The mark is
    /// what tells the I/O loop to tear the channel down WITHOUT resuming
    /// the continuation again.
    func testCancellationMarksRequestAndResumesContinuation() async {
        let (request, outcome) = await makeRequest()

        request.isCancelled = true
        request.resume(throwing: CancellationError())

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

        request.resume(throwing: CancellationError())
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

        request.isCancelled = true
        request.resume(throwing: CancellationError())
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
        request.resume(throwing: CancellationError()) // ignored

        let value = try? await outcome.value
        XCTAssertEqual(value, "output")
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
