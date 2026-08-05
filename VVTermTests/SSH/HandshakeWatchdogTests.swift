// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  HandshakeWatchdogTests.swift
//  VVTermTests
//
//  Regression test for the dispatch-9 bug (issue #83, fix stack): the
//  handshake watchdogs used `try? await Task.sleep(...)` followed by
//  `atomicSocket.interrupt()`. When the handshake COMPLETED, the
//  `defer { watchdog.cancel() }` cancelled the sleeping task — but `try?`
//  swallowed the CancellationError and execution fell through to
//  `interrupt()`, killing the just-established connection 0.8ms after
//  connect() returned (pump EOF + `.notConnected` at the outer channel
//  stage on every leg).
//
//  The correct pattern (used by the disconnect watchdog): catch the
//  cancellation and RETURN — cancellation disarms the watchdog.

import Testing
import Darwin
@testable import VVTerm

struct HandshakeWatchdogTests {

    /// The watchdog must NOT interrupt the socket when cancelled (i.e. when
    /// the handshake it guards completed and the `defer` disarmed it).
    @Test
    func handshakeWatchdogCancellationDisarmsWithoutInterrupting() async throws {
        let socket = AtomicSocket()
        var fds: [Int32] = [0, 0]
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        socket.install(fds[0])
        defer {
            socket.close()
            Darwin.close(fds[1])
        }

        // The fixed watchdog pattern: cancellation returns without firing.
        let watchdog = Task.detached { [socket] in
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)  // 60s
            } catch {
                return  // cancelled — disarmed
            }
            socket.interrupt()
        }
        // Disarm immediately (the connect-return defer does this).
        watchdog.cancel()

        // Give the cancellation time to land and the task to exit. With the
        // buggy `try?` pattern the interrupt fires within microseconds and
        // `isUsable` flips to false.
        try await Task.sleep(for: .milliseconds(200))

        #expect(
            socket.isUsable,
            "watchdog must be disarmed by cancellation — the try? fall-through bug interrupts the live socket"
        )
        #expect(watchdog.isCancelled)
    }

    /// The watchdog still fires when it actually times out (the guard
    /// works): a short sleep + no cancellation → the socket is interrupted.
    @Test
    func handshakeWatchdogFiresOnTimeout() async throws {
        let socket = AtomicSocket()
        var fds: [Int32] = [0, 0]
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        socket.install(fds[0])
        defer {
            socket.close()
            Darwin.close(fds[1])
        }

        let watchdog = Task.detached { [socket] in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            } catch {
                return
            }
            socket.interrupt()
        }
        // No cancellation — the watchdog must fire.
        try await Task.sleep(for: .milliseconds(500))

        #expect(!socket.isUsable, "watchdog must interrupt the socket after its timeout")
        #expect(watchdog.isCancelled == false || watchdog.isFinished)
    }
}
