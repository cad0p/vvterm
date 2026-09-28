// SPDX-License-Identifier: MIT
//
//  StartupDeadlineTests.swift
//  VVTermTests
//
//  #276/D2b: `SSHClient.withStartupDeadline` bounds the *caller* of the
//  terminal-type stage without cancelling the abandoned worker.
//
//  The helper is the only wall-clock bound for the pre-install and the
//  post-install park (D1 removes the cancellation-*delivery* hop; a task
//  parked inside a hard-wedged actor still cannot complete — see the E2
//  characterization in ExecRequestCancellationTests). These tests pin:
//    - a never-returning operation throws `StartupDeadlineExceeded` promptly;
//    - the abandoned operation is never cancelled (it completes normally
//      when released);
//    - the deadline detail is emitted exactly once when the deadline wins,
//      and not at all on the fast path or an operation error;
//    - caller cancellation resumes early with `CancellationError` (V10)
//      instead of blocking the full deadline, and still does not cancel the
//      operation;
//    - the terminal-type stage's trace token is begun before the race and
//      ended by the caller, never by the worker.
//
//  Counterfactual: `withStartupDeadline` is new API, so reverting the
//  production change fails this target to compile rather than failing
//  behaviourally. The source pin below fails against the pre-fix source
//  (verified via `VVTERM_PINS_SOURCE_ROOT`).

import Foundation
import Testing
@testable import VVTerm

struct StartupDeadlineTests {

    /// Records the deadline details emitted by the helper.
    private final class DetailRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var details: [String] = []

        func record(_ detail: String) {
            lock.lock()
            details.append(detail)
            lock.unlock()
        }

        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return details
        }
    }

    /// A parked operation that records whether its task was cancelled when it
    /// finally resumes.
    private final class ParkedOperation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var parked = false
        private var finished = false
        private var observedCancellation = false

        func park() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    parked = true
                    lock.unlock()
                }
            }
            lock.lock()
            observedCancellation = Task.isCancelled
            finished = true
            lock.unlock()
        }

        func release() {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }

        var isParked: Bool {
            lock.lock()
            defer { lock.unlock() }
            return parked
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        var didObserveCancellation: Bool {
            lock.lock()
            defer { lock.unlock() }
            return observedCancellation
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func deadlineAbandonsANeverReturningOperationWithoutCancellingIt() async {
        let recorder = DetailRecorder()
        let parked = ParkedOperation()
        let start = ContinuousClock.now

        do {
            _ = try await SSHClient.withStartupDeadline(
                deadline: .milliseconds(100),
                emitter: { recorder.record($0) }
            ) { () -> Int in
                await parked.park()
                return 1
            }
            Issue.record("expected the deadline to win")
        } catch is SSHClient.StartupDeadlineExceeded {
            // Expected: the caller degrades within the deadline.
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let elapsed = start.duration(to: ContinuousClock.now)
        #expect(elapsed >= .milliseconds(80), "the deadline must actually be awaited")
        #expect(elapsed < .seconds(5), "the deadline must bound the caller")
        #expect(recorder.recorded == ["deadline after 0.10s"])

        // The abandoned worker must still complete — never cancelled.
        parked.release()
        while !parked.isFinished {
            await Task.yield()
        }
        #expect(
            !parked.didObserveCancellation,
            "the abandoned operation must not be cancelled (cancelling can tear down the live session)"
        )
    }

    @Test
    func fastOperationReturnsItsValueAndEmitsNothing() async throws {
        let recorder = DetailRecorder()
        let value = try await SSHClient.withStartupDeadline(
            deadline: .seconds(30),
            emitter: { recorder.record($0) }
        ) { 42 }
        #expect(value == 42)
        #expect(recorder.recorded.isEmpty, "the fast path must emit nothing")
    }

    @Test
    func operationErrorPropagatesWithoutADeadlineDetail() async {
        struct Boom: Error {}
        let recorder = DetailRecorder()
        do {
            _ = try await SSHClient.withStartupDeadline(
                deadline: .seconds(30),
                emitter: { recorder.record($0) }
            ) { () -> Int in throw Boom() }
            Issue.record("expected the operation error")
        } catch is Boom {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(recorder.recorded.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func callerCancellationResumesEarlyWithoutWaitingForTheDeadline() async {
        let parked = ParkedOperation()
        let start = ContinuousClock.now
        let caller = Task<Bool, Never> {
            do {
                _ = try await SSHClient.withStartupDeadline(
                    deadline: .seconds(60),
                    emitter: { _ in }
                ) { () -> Int in
                    await parked.park()
                    return 1
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        while !parked.isParked {
            await Task.yield()
        }

        caller.cancel()
        let wasCancelled = await caller.value

        #expect(wasCancelled, "caller cancellation must surface as CancellationError")
        #expect(
            start.duration(to: ContinuousClock.now) < .seconds(5),
            "a dismissal must not block the full stage deadline"
        )

        // Still not cancelled: resume the caller does not cancel the worker.
        parked.release()
        while !parked.isFinished {
            await Task.yield()
        }
        #expect(!parked.didObserveCancellation)
    }

    // MARK: - Source pin: the stage token is owned by the race caller

    @Test
    func terminalTypeStageTokenIsStartedBeforeTheRaceAndEndedByTheCaller() throws {
        // `SSHStartupTrace.end` is not idempotent, so an abandoned worker that
        // ended the `.terminalType` token late would emit a second event with
        // a huge `stageMs`. Pin: the token is begun before the deadline race,
        // the worker body contains no `end`, and the caller ends it for both
        // the value win and the deadline fallback.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // StartupDeadlineTests.swift
                .deletingLastPathComponent()  // SSH/
                .deletingLastPathComponent()  // VVTermTests/
                .appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift"),
            encoding: .utf8
        )

        let stageStart = try #require(source.range(of: "func remoteTerminalType(forceRefresh: Bool = false)"))
        let stageEnd = try #require(
            source.range(of: "private func resolveRemoteTerminalTypeForStage", range: stageStart.upperBound..<source.endIndex)
        )
        let stageBody = source[stageStart.lowerBound..<stageEnd.lowerBound]
        let beginIndex = try #require(stageBody.range(of: "startupTrace?.begin(.terminalType)"))
        let raceIndex = try #require(stageBody.range(of: "withStartupDeadline"))
        #expect(
            beginIndex.lowerBound < raceIndex.lowerBound,
            "the token must be begun before the deadline race"
        )
        #expect(
            stageBody.contains("startupTrace?.end(token, detail: terminalType.rawValue)"),
            "the caller must end the token on the value win"
        )
        #expect(
            stageBody.contains("outcome: \"fallback\""),
            "the caller must end the token with the fallback outcome on a deadline win"
        )

        let workerStart = stageEnd
        let workerEnd = try #require(
            source.range(of: "func remotePlatform(forceRefresh: Bool = false)", range: workerStart.upperBound..<source.endIndex)
        )
        let workerBody = source[workerStart.lowerBound..<workerEnd.lowerBound]
        #expect(
            !workerBody.contains("startupTrace?.end("),
            "the abandoned worker must never end the stage token"
        )
        #expect(
            workerBody.contains("isCurrentSession(capturedSession, current: session)"),
            "the worker's cache fill must be epoch-guarded"
        )
    }

    // MARK: - Epoch guard

    private func makeTeleportSession() -> SSHSession {
        SSHSession(
            config: SSHSessionConfig(
                host: "example.invalid",
                port: 22,
                username: "user",
                connectionMode: .standard,
                authMethod: .faceIDTeleport,
                credentials: ServerCredentials(serverId: UUID())
            )
        )
    }

    @Test
    func epochGuardOnlyAllowsTheCapturedSession() {
        // A late worker may only fill the cache while the session it resolved
        // against is still current (N7). `SSHSession` is recreated per
        // connect, so identity is the connection generation.
        let captured = makeTeleportSession()
        let reconnected = makeTeleportSession()

        #expect(SSHClient.isCurrentSession(captured, current: captured))
        #expect(
            !SSHClient.isCurrentSession(captured, current: reconnected),
            "a completion from an older session must not overwrite the new session's cache"
        )
        #expect(!SSHClient.isCurrentSession(captured, current: nil), "a disconnect must discard the write")
        #expect(SSHClient.isCurrentSession(nil, current: nil))
        #expect(!SSHClient.isCurrentSession(nil, current: captured))
    }
}
