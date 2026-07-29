// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  SSHProxySubsystemTransportTests.swift
//  VVTerm
//
//  Unit coverage for `SSHProxySubsystemTransport`, the socketpair bridge
//  that lets a second libssh2 session read/write through an SSH channel
//  opened on the *outer* (proxy) session.
//
//  Why a socketpair bridge
//  -----------------------
//  libssh2's session handshake + I/O API takes a raw file descriptor (it
//  calls `read()`/`write()` on it). An SSH channel is not an FD — bytes
//  move through `libssh2_channel_read_ex` / `libssh2_channel_write_ex`.
//  `SSHProxySubsystemTransport` bridges the two with a socketpair + a
//  bidirectional pump, exactly mirroring `SSHTLSTransport` (which bridges
//  NWConnection <-> socketpair):
//
//      inner libssh2  ──read/write──  libssh2FD  ──┐
//                                                   │ socketpair (AF_UNIX, SOCK_STREAM)
//      outer channel  ──channel read/write──  pumpFD └┘
//                                                   ▲
//                                                   └── pump forwards bytes both ways
//
//  Testing without a live libssh2 channel
//  --------------------------------------
//  The transport's channel side is injected as two closures
//  (`channelRead` / `channelWrite`) so the test can stand in for a real
//  libssh2 channel with an in-memory byte buffer. This exercises the pump,
//  the socketpair lifecycle, and the EOF/error handling without a live SSH
//  connection (which needs a real device + Teleport proxy — see the live
//  verification note in the class doc).
//

import Testing
import Foundation
import os
@testable import VVTerm

/// Thread-safe byte buffer for the fake channel closures. `@Sendable`
/// closures can't capture mutable `var` arrays, so the fake channel's
/// buffered bytes + the bytes received from the pump live behind a lock.
final class LockedByteQueue: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [UInt8]())
    private let isOpen = OSAllocatedUnfairLock(initialState: true)

    /// Enqueue bytes to be read by the fake `channelRead`.
    func enqueue(_ bytes: [UInt8]) {
        lock.withLock { queue in queue.append(contentsOf: bytes) }
    }

    /// Dequeue up to `maxLen` bytes for `channelRead`, blocking (spinning
    /// with usleep) until data is available or the channel is closed.
    /// Returns the dequeued bytes, or an empty array when the queue is empty
    /// AND the channel is closed (EOF). Mirrors a blocking
    /// `libssh2_channel_read_ex` that returns EAGAIN internally and retries
    /// until data or EOF.
    func blockingDequeue(maxLen: Int) -> [UInt8] {
        while true {
            let chunk = lock.withLock { queue -> [UInt8] in
                if !queue.isEmpty {
                    let n = min(maxLen, queue.count)
                    let dequeued = Array(queue.prefix(n))
                    queue.removeFirst(n)
                    return dequeued
                }
                return []
            }
            if !chunk.isEmpty { return chunk }
            // Queue empty — is the channel closed?
            if !isOpen.withLock({ $0 }) { return [] }  // EOF
            // Open + empty — spin (the real libssh2 path returns EAGAIN and
            // the makeForChannel adapter sleeps 1ms before retrying).
            usleep(1_000)
        }
    }

    func hasBytes(_ count: Int) -> Bool {
        lock.withLock { $0.count >= count }
    }

    func snapshot() -> [UInt8] {
        lock.withLock { $0 }
    }

    func close() {
        isOpen.withLock { $0 = false }
    }
}

/// Detects concurrent access to a shared resource (e.g. the outer libssh2
/// session). `enter()`/`exit()` bracket a critical section; `maxDepth` records
/// the maximum number of concurrent entrants. Used to regression-test the
/// pump's outer-session mutex: if `maxDepth > 1`, two closures ran
/// concurrently — the race that trips `assert(remainbuf >= 0)` in libssh2's
/// transport.c.
final class ConcurrentAccessDetector: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var current: Int = 0
        var max: Int = 0
    }

    func enter() {
        lock.withLock { state in
            state.current += 1
            if state.current > state.max { state.max = state.current }
        }
    }

    func exit() {
        lock.withLock { state in
            state.current -= 1
        }
    }

    var maxDepth: Int {
        lock.withLock { $0.max }
    }
}

struct SSHProxySubsystemTransportTests {

    // MARK: - Socketpair creation

    @Test
    func makeSocketPairReturnsTwoValidFDs() throws {
        let pair = try SSHProxySubsystemTransport.makeSocketPair()
        #expect(pair.libssh2FD >= 0)
        #expect(pair.pumpFD >= 0)
        #expect(pair.libssh2FD != pair.pumpFD)
        // Clean up — the FDs are owned by the caller here.
        Darwin.close(pair.libssh2FD)
        Darwin.close(pair.pumpFD)
    }

    @Test
    func makeSocketPairFDsAreBidirectionallyConnected() throws {
        // The socketpair must be full-duplex: writing to one end must be
        // readable from the other, in both directions. If the pair were
        // unidirectional (e.g. created with SOCK_DGRAM or a pipe), the
        // second handshake would deadlock.
        let pair = try SSHProxySubsystemTransport.makeSocketPair()
        defer {
            Darwin.close(pair.libssh2FD)
            Darwin.close(pair.pumpFD)
        }

        // libssh2FD -> pumpFD
        let w1: [UInt8] = [0x53, 0x53, 0x48, 0x2D]  // "SSH-"
        let written1 = try writeAll(fd: pair.libssh2FD, bytes: w1)
        #expect(written1 == w1.count)
        let read1 = try readBytes(fd: pair.pumpFD, count: w1.count)
        #expect(read1 == w1)

        // pumpFD -> libssh2FD
        let w2: [UInt8] = [0x32, 0x2E, 0x30, 0x2D]  // "2.0-"
        let written2 = try writeAll(fd: pair.pumpFD, bytes: w2)
        #expect(written2 == w2.count)
        let read2 = try readBytes(fd: pair.libssh2FD, count: w2.count)
        #expect(read2 == w2)
    }

    // MARK: - Pump: channel -> libssh2FD

    @Test
    func pumpForwardsChannelBytesToLibssh2FD() async throws {
        // The server (target node) sends its SSH banner immediately after the
        // proxy subsystem channel is opened. The pump's first job is to drain
        // the channel and write those bytes to the libssh2FD so the inner
        // libssh2 session's blocking read sees the banner.
        let banner: [UInt8] = Array("SSH-2.0-OpenSSH_8.9\r\n".utf8)
        let queue = LockedByteQueue()
        queue.enqueue(banner)
        queue.close()  // EOF after the banner

        let transport = SSHProxySubsystemTransport(
            channelRead: { buf, maxLen in
                let chunk = queue.blockingDequeue(maxLen: maxLen)
                if chunk.isEmpty { return 0 }  // EOF
                for (i, b) in chunk.enumerated() { buf[i] = b }
                return chunk.count
            },
            channelWrite: { _, _ in 0 }
        )
        let fd = try await transport.start()
        defer { Task { await transport.close() } }

        // The pump is async; give it a moment to drain the channel into the
        // socketpair, then read the banner back from the libssh2FD.
        let received = try await readBytesAsync(fd: fd, count: banner.count, timeoutSeconds: 3)
        #expect(received == banner)
    }

    @Test
    func pumpForwardsLibssh2FDBytesToChannel() async throws {
        // The inner libssh2 session writes its own banner to the libssh2FD;
        // the pump's second job is to read that and forward it to the channel
        // (which sends it to the target node via the proxy tunnel).
        let clientBanner: [UInt8] = Array("SSH-2.0-libssh2_1.11.1\r\n".utf8)
        let received = LockedByteQueue()
        // Keep the channel open (no EOF) so the pump stays alive long enough
        // to forward the client banner. The channelRead blocks (spins) on an
        // empty-but-open queue, mirroring a real channel with no inbound
        // data yet.
        let inbound = LockedByteQueue()  // stays open + empty -> channelRead blocks

        let transport = SSHProxySubsystemTransport(
            channelRead: { buf, maxLen in
                let chunk = inbound.blockingDequeue(maxLen: maxLen)
                if chunk.isEmpty { return 0 }  // EOF
                for (i, b) in chunk.enumerated() { buf[i] = b }
                return chunk.count
            },
            channelWrite: { buf, len in
                var bytes = [UInt8]()
                for i in 0..<len { bytes.append(buf[i]) }
                received.enqueue(bytes)
                return len
            }
        )
        let fd = try await transport.start()
        defer { Task { await transport.close() } }

        // Write the client banner to the libssh2FD (as the inner libssh2
        // session would). The pump should forward it to the channel.
        _ = try writeAll(fd: fd, bytes: clientBanner)

        // Wait for the pump to forward the bytes.
        try await waitForCondition(timeoutSeconds: 3) {
            received.hasBytes(clientBanner.count)
        }
        #expect(Array(received.snapshot().prefix(clientBanner.count)) == clientBanner)

        // Close the inbound queue so the pump's channel->FD loop exits and
        // the detached pump task can terminate (avoids leaking the task).
        inbound.close()
    }

    @Test
    func pumpHandlesChannelEOFByClosingPumpFD() async throws {
        // When the channel read returns 0 (EOF — the proxy closed the tunnel),
        // the pump must close the pumpFD so the inner libssh2 session's reads
        // also see EOF (otherwise `libssh2_session_handshake` would hang
        // forever waiting for a banner that will never arrive).
        let transport = SSHProxySubsystemTransport(
            channelRead: { _, _ in 0 },  // immediate EOF
            channelWrite: { _, _ in 0 }
        )
        let fd = try await transport.start()
        defer { Task { await transport.close() } }

        // After EOF, a read on the libssh2FD should return 0 (EOF) rather than
        // blocking indefinitely. Give the pump a moment to close the pump end.
        let result = try await readWithTimeout(fd: fd, count: 1, timeoutSeconds: 3)
        #expect(result == 0, "expected EOF (0) on libssh2FD after channel EOF")
    }

    // MARK: - Outer-session mutex (remainbuf crash regression)

    /// The pump's two loops (channel->FD and FD->channel) run concurrently in
    /// a task group. Both call into the *outer* libssh2 session — `channelRead`
    /// via `libssh2_channel_read_ex` -> `ssh2_transport_read`, `channelWrite` via
    /// `libssh2_channel_write_ex` -> `ssh2_transport_send`. libssh2 is NOT
    /// thread-safe per-session (the session's transport read buffer
    /// `session->packet.writeidx/readidx` is shared across all channels). Two
    /// concurrent `ssh2_transport_read`/`ssh2_transport_send` calls corrupt that
    /// buffer's accounting and trip `assert(remainbuf >= 0)` in transport.c.
    ///
    /// `makeForChannel` accepts a `SessionMutex` (the outer session's lock) so
    /// the closures serialize their libssh2 calls. This test verifies the
    /// pump's concurrent loops never execute their libssh2-calling critical
    /// sections simultaneously when the closures share a mutex.
    @Test
    func pumpSerializesChannelReadAndWriteThroughSharedMutex() async throws {
        // A detector that tracks whether the read and write critical sections
        // overlap. `enter()` returns the depth; if it ever exceeds 1, two
        // closures ran concurrently — the race that crashes libssh2.
        let detector = ConcurrentAccessDetector()
        let outerSessionMutex = SessionMutex()

        // Bidirectional data: inbound bytes for channelRead to drain, outbound
        // bytes written to libssh2FD for the pump to forward to channelWrite.
        // The inbound queue stays open (empty after the banner) so channelRead
        // blocks rather than returning EOF — this keeps the channel->FD loop
        // alive while the FD->channel loop drains the outbound banner. Closing
        // inbound at the end lets the pump exit.
        let inbound = LockedByteQueue()
        let inboundBanner: [UInt8] = Array("SSH-2.0-OpenSSH_8.9\r\n".utf8)
        inbound.enqueue(inboundBanner)  // not closed — channelRead blocks after

        let outboundBanner: [UInt8] = Array("SSH-2.0-libssh2_1.11.1\r\n".utf8)
        let writtenToChannel = LockedByteQueue()

        // Closures mirror `makeForChannel`: the (simulated) libssh2 call is
        // bracketed by the outer-session mutex + the detector. The blocking
        // dequeue happens OUTSIDE the lock (production holds the lock only
        // around `libssh2_channel_read_ex`, not the EAGAIN retry sleep) so a
        // backpressured read doesn't stall the write loop.
        let transport = SSHProxySubsystemTransport(
            channelRead: { buf, maxLen in
                let chunk = inbound.blockingDequeue(maxLen: maxLen)
                if chunk.isEmpty { return 0 }
                // Simulated `libssh2_channel_read_ex` — guarded by the mutex.
                return outerSessionMutex.withLock {
                    detector.enter()
                    defer { detector.exit() }
                    for (i, b) in chunk.enumerated() { buf[i] = b }
                    return chunk.count
                }
            },
            channelWrite: { buf, len in
                // Simulated `libssh2_channel_write_ex` — guarded by the mutex.
                return outerSessionMutex.withLock {
                    detector.enter()
                    defer { detector.exit() }
                    var bytes = [UInt8]()
                    for i in 0..<len { bytes.append(buf[i]) }
                    writtenToChannel.enqueue(bytes)
                    return len
                }
            }
        )
        let fd = try await transport.start()
        defer { Task { await transport.close() } }

        // Write the client banner to the libssh2FD (as the inner libssh2
        // session would). The FD->channel loop forwards it to channelWrite.
        _ = try writeAll(fd: fd, bytes: outboundBanner)

        // Wait for the banner to flow both ways. The inbound banner should
        // arrive on the libssh2FD (channel->FD), and the outbound banner
        // should arrive on the channel (FD->channel).
        let receivedInbound = try await readBytesAsync(
            fd: fd, count: inboundBanner.count, timeoutSeconds: 3
        )
        #expect(receivedInbound == inboundBanner)
        try await waitForCondition(timeoutSeconds: 3) {
            writtenToChannel.hasBytes(outboundBanner.count)
        }
        #expect(
            Array(writtenToChannel.snapshot().prefix(outboundBanner.count)) == outboundBanner
        )

        // The detector must never have seen concurrent access (depth > 1).
        // If it did, the pump's read+write loops raced on the outer session —
        // the exact condition that trips `assert(remainbuf >= 0)` in libssh2's
        // transport.c.
        #expect(detector.maxDepth <= 1, "channelRead and channelWrite overlapped — outer-session race")

        // Close the inbound queue so the pump's channel->FD loop exits (it
        // blocks on the empty-but-open queue) and the detached pump task can
        // terminate (avoids leaking the task).
        inbound.close()
    }

    /// Verify `SessionMutex` provides mutual exclusion: two threads calling
    /// `withLock` concurrently never run their bodies at the same time.
    @Test
    func sessionMutexProvidesMutualExclusion() async throws {
        let mutex = SessionMutex()
        let detector = ConcurrentAccessDetector()
        let iterations = 500
        let half = iterations / 2

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<half {
                    mutex.withLock {
                        detector.enter()
                        _ = usleep(10)  // hold briefly to force overlap if non-exclusive
                        detector.exit()
                    }
                }
            }
            group.addTask {
                for _ in 0..<half {
                    mutex.withLock {
                        detector.enter()
                        _ = usleep(10)
                        detector.exit()
                    }
                }
            }
        }

        #expect(detector.maxDepth <= 1, "SessionMutex allowed concurrent critical sections")
    }

    // MARK: - Helpers

    /// Write all bytes to a fd (retrying on partial writes).
    private func writeAll(fd: Int32, bytes: [UInt8]) throws -> Int {
        var written = 0
        try bytes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            while written < bytes.count {
                let n = Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                if n <= 0 {
                    throw SSHError.socketError("writeAll: write returned \(n) errno=\(Darwin.errno)")
                }
                written += n
            }
        }
        return written
    }

    /// Read exactly `count` bytes from a fd (retrying on partial reads).
    private func readBytes(fd: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var read = 0
        try buffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            while read < count {
                let n = Darwin.read(fd, base.advanced(by: read), count - read)
                if n <= 0 {
                    throw SSHError.socketError("readBytes: read returned \(n) errno=\(Darwin.errno)")
                }
                read += n
            }
        }
        return buffer
    }

    /// Read up to `count` bytes from a fd with a timeout. Returns the number
    /// of bytes read (0 = EOF). Uses a non-blocking poll to avoid blocking
    /// the test forever if the pump never closes the FD.
    private func readWithTimeout(fd: Int32, count: Int, timeoutSeconds: TimeInterval) async throws -> Int {
        // Set the fd non-blocking so a read with no data returns EAGAIN
        // instead of blocking.
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = Darwin.fcntl(fd, F_SETFL, flags) }  // restore

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { buf.deallocate() }
        var waited: TimeInterval = 0
        let step: useconds_t = 5_000  // 5ms
        while true {
            let n = Darwin.read(fd, buf, count)
            if n >= 0 {
                return n  // bytes read or EOF (0)
            }
            // n < 0 — check for EAGAIN/EWOULDBLOCK
            if errno != EAGAIN && errno != EWOULDBLOCK {
                return -1  // hard error
            }
            usleep(step)
            waited += Double(step) / 1_000_000.0
            if waited >= timeoutSeconds {
                return -1  // timed out
            }
        }
    }

    /// Read exactly `count` bytes from a fd, waiting up to `timeoutSeconds`
    /// for them to arrive (the pump is async, so the bytes may not be
    /// available immediately).
    private func readBytesAsync(fd: Int32, count: Int, timeoutSeconds: TimeInterval) async throws -> [UInt8] {
        // Set the fd non-blocking so we can poll without blocking forever.
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = Darwin.fcntl(fd, F_SETFL, flags) }  // restore

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { buf.deallocate() }
        var read = 0
        var waited: TimeInterval = 0
        let step: useconds_t = 5_000  // 5ms
        while read < count {
            let n = Darwin.read(fd, buf.advanced(by: read), count - read)
            if n > 0 {
                read += n
            } else if n == 0 {
                // EOF before count bytes — the pump closed early.
                break
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(step)
                waited += Double(step) / 1_000_000.0
                if waited >= timeoutSeconds {
                    throw SSHError.socketError("readBytesAsync: timed out after \(waited)s, read \(read)/\(count)")
                }
            } else {
                throw SSHError.socketError("readBytesAsync: read returned \(n) errno=\(errno)")
            }
        }
        var buffer = [UInt8](repeating: 0, count: read)
        for i in 0..<read { buffer[i] = buf[i] }
        return buffer
    }

    /// Poll a condition until it returns true or the timeout elapses.
    private func waitForCondition(
        timeoutSeconds: TimeInterval,
        condition: () -> Bool
    ) async throws {
        var waited: TimeInterval = 0
        let step: useconds_t = 5_000  // 5ms
        while !condition() {
            usleep(step)
            waited += Double(step) / 1_000_000.0
            if waited >= timeoutSeconds {
                throw SSHError.socketError("waitForCondition: timed out after \(waited)s")
            }
        }
    }
}
