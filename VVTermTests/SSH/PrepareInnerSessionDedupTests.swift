// SPDX-License-Identifier: MIT
//
//  PrepareInnerSessionDedupTests.swift
//  VVTermTests
//
//  #276/V1: `SSHSession.prepareTeleportInnerSession()` must run a single body
//  for concurrent callers. Without the in-flight dedup a second caller starts
//  a second prepare while the first is still handshaking, and both clobber
//  `proxySubsystemChannel` / `agentForwardingService`.
//
//  The body is parked with a DEBUG-only hook so the dedup is observable
//  without a live libssh2 session (the body itself throws `.notConnected` at
//  its first guard).
//
//  Counterfactual: removing the dedup control flow (keeping the hook) makes
//  the second concurrent caller enter the body — `entryCount` becomes 2 and
//  this test fails. Reverting the whole production file is a compile failure
//  for this target because the hook is part of the same commit.

import Foundation
import Testing
@testable import VVTerm

/// Parks every prepare-body entry until `release()` is called.
private final class PrepareBodyHook: @unchecked Sendable {
    private let lock = NSLock()
    private var entries = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func enter() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            entries += 1
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

struct PrepareInnerSessionDedupTests {

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
    func twoConcurrentPreparesRunOneBody() async {
        let session = makeTeleportSession()
        let hook = PrepareBodyHook()
        await session.setPrepareTeleportInnerSessionBodyTestHook { await hook.enter() }

        let first = Task { try await session.prepareTeleportInnerSession() }
        while hook.entryCount == 0 {
            await Task.yield()
        }

        let second = Task { try await session.prepareTeleportInnerSession() }
        // Give the second call time to reach the actor; without the dedup it
        // enters the body again. This is the counterfactual: with the join
        // removed, `entryCount` reaches 2 inside this window.
        //
        // A *delayed* second caller only makes this observation later than the
        // budget, which leaves `entryCount == 1` (a false green for this
        // assertion) rather than a false red — so the budget is safe to keep
        // short. The number is captured here, while the body is still parked,
        // and asserted after both tasks complete; asserting `entryCount`
        // *after* `release()` would be racy: a caller that arrives after the
        // body finished legally starts a fresh body (T6).
        try? await Task.sleep(for: .milliseconds(150))
        let entriesWhileParked = hook.entryCount
        #expect(
            entriesWhileParked == 1,
            "two concurrent prepares must share one body (found \(entriesWhileParked))"
        )

        hook.release()
        for task in [first, second] {
            do {
                try await task.value
                Issue.record("expected notConnected (the session never connected)")
            } catch SSHError.notConnected {
                // Expected: the parked body's first guard throws.
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
        // The parked-window observation is the load-bearing one; the final
        // count may legally be 1 (the second caller joined) or 2 (it arrived
        // after the body completed and started a fresh attempt).
        #expect(
            hook.entryCount >= entriesWhileParked,
            "the body count must never decrease"
        )
    }

    @Test
    func aLaterPrepareStartsAFreshBodyAfterCompletion() async {
        // The dedup must not become a permanent sticky failure: after the
        // body completes the slot clears, so a later caller retries (the
        // pre-fix retry behavior).
        let session = makeTeleportSession()
        let hook = PrepareBodyHook()
        await session.setPrepareTeleportInnerSessionBodyTestHook { await hook.enter() }
        hook.release()

        for _ in 0..<2 {
            do {
                try await session.prepareTeleportInnerSession()
                Issue.record("expected notConnected")
            } catch SSHError.notConnected {
                // Expected.
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
        #expect(hook.entryCount == 2, "each non-concurrent prepare must run its own body")
    }
}
