// SPDX-License-Identifier: MIT
//
//  StartupWatchdogTests.swift
//  VVTermTests
//
//  #276/D4: the remaining unbounded startup awaits are *named* by short,
//  non-interrupting watchdogs — the `isInnerSessionReady` hop inside
//  `remoteEnvironment` and `session.startShell`. A watchdog emits one labelled
//  diag line when the watched await is still parked after 3 s; it does not
//  bound or cancel the await (`withStartupDeadline` owns bounding, D2b).
//
//  These tests pin the helper semantics (fires once while parked, silent on
//  the fast path, error forwarding, cancellation disarm) and the labels.
//  `catch { return }` on the sleep is the HandshakeWatchdogTests pattern: a
//  cancelled watchdog must not fall through to the emit.
//
//  Counterfactual: `withStartupWatchdog` is new API, so reverting the whole
//  production file fails this target to compile; the label pin fails against
//  the pre-fix source (no watchdog call sites).

import Foundation
import Testing
@testable import VVTerm

struct StartupWatchdogTests {

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

    /// A one-shot gate the watched operation parks on.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            opened = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    @Test
    func watchdogFiresOnceWhileParkedAndStillReturnsTheValue() async throws {
        let recorder = DetailRecorder()
        let gate = Gate()
        let watched = Task<Int, Error> {
            try await SSHClient.withStartupWatchdog(
                deadline: .milliseconds(100),
                emitter: { recorder.record($0) }
            ) {
                await gate.wait()
                return 7
            }
        }

        let limit = ContinuousClock.now + .seconds(10)
        while recorder.recorded.isEmpty, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.recorded == ["still parked after 0.10s"])

        gate.open()
        let value = try await watched.value
        #expect(value == 7, "the watchdog must not interrupt the watched await")

        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.recorded.count == 1, "the watchdog must fire once")
    }

    @Test
    func watchdogIsSilentOnTheFastPath() async throws {
        let recorder = DetailRecorder()
        let value = try await SSHClient.withStartupWatchdog(
            deadline: .seconds(30),
            emitter: { recorder.record($0) }
        ) { 11 }
        #expect(value == 11)
        #expect(recorder.recorded.isEmpty)
    }

    @Test
    func watchdogForwardsOperationErrorsWithoutEmitting() async {
        struct Boom: Error {}
        let recorder = DetailRecorder()
        do {
            _ = try await SSHClient.withStartupWatchdog(
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

    @Test
    func watchdogIsDisarmedByCancellation() async {
        let recorder = DetailRecorder()
        let task = Task<Bool, Never> {
            do {
                _ = try await SSHClient.withStartupWatchdog(
                    deadline: .milliseconds(100),
                    emitter: { recorder.record($0) }
                ) {
                    try await Task.sleep(for: .seconds(60))
                    return 1
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        let wasCancelled = await task.value
        #expect(wasCancelled)

        try? await Task.sleep(for: .milliseconds(250))
        #expect(recorder.recorded.isEmpty, "a cancelled watchdog must not emit")
    }

    // MARK: - Labels

    @Test
    func watchdogLabelsNameTheHops() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // StartupWatchdogTests.swift
                .deletingLastPathComponent()  // SSH/
                .deletingLastPathComponent()  // VVTermTests/
                .appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift"),
            encoding: .utf8
        )

        #expect(source.contains("nonisolated static let startupHopWatchdogDeadline: Duration = .seconds(3)"))
        #expect(source.contains("watchdogOrigin: \"startShell\""), "the :690 remoteEnvironment call must be labelled")
        #expect(
            source.contains("watchdogOrigin: \"terminalTypeStage\""),
            "the terminal-type stage's env re-entry must be labelled"
        )
        #expect(source.contains("remoteEnvironment(from:"), "the hop line must name the caller")
        #expect(source.contains("startup watchdog: session.startShell"), "the shell-start await must be labelled")

        // T5/C1: the strings above survive a mutation that keeps the label but
        // stops *watching* the await. The check must therefore be structural:
        // inside `startValidatedSSHShell`, the watchdog call's trailing closure
        // must contain the `expectedSession.startShell` await, and no
        // `startShell` call may exist outside that closure.
        let shellStart = try #require(source.range(of: "func startValidatedSSHShell"))
        let shellEnd = try #require(
            source.range(of: "// MARK: - Mosh", range: shellStart.upperBound..<source.endIndex)
        )
        let shellBody = source[shellStart.lowerBound..<shellEnd.lowerBound]
        let watchdog = try #require(
            shellBody.range(of: "withStartupWatchdog("),
            "the shell-start await must be wrapped in a watchdog"
        )

        // The trailing closure is the block after the call's closing `) {`.
        // Find the argument list's end by matching the `emitter:` closure, then
        // take the remainder as the watched operation.
        let afterWatchdog = shellBody[watchdog.upperBound...]
        let operationStart = try #require(
            afterWatchdog.range(of: "\n        ) {"),
            "the watchdog must be called with a trailing operation closure"
        )
        let watchedOperation = afterWatchdog[operationStart.upperBound...]
        #expect(
            watchedOperation.contains("try await expectedSession.startShell("),
            "the watchdog's trailing closure must contain the startShell await"
        )

        // Any `startShell` call in this function must live inside that trailing
        // closure: a mutation that wrapped a no-op and left the real await
        // outside would be caught here.
        let callSites = shellBody.components(separatedBy: "expectedSession.startShell(").count - 1
        let watchedSites = watchedOperation.components(separatedBy: "expectedSession.startShell(").count - 1
        #expect(
            callSites == 1 && watchedSites == 1,
            "the only startShell call must be the one inside the watchdog (found \(callSites) call(s), \(watchedSites) watched)"
        )
    }
}
