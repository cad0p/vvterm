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
@testable import VVTerm

@MainActor
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
        var channelBuffer = banner
        let channelRead: @Sendable (UnsafeMutablePointer<UInt8>, Int) -> Int = { buf, maxLen in
            guard !channelBuffer.isEmpty else { return 0 }  // EOF
            let n = min(maxLen, channelBuffer.count)
            for i in 0..<n { buf[i] = channelBuffer.removeFirst() }
            return n
        }
        let channelWrite: @Sendable (UnsafePointer<UInt8>, Int) -> Int = { _, _ in 0 }

        let transport = SSHProxySubsystemTransport(
            channelRead: channelRead,
            channelWrite: channelWrite
        )
        let fd = try await transport.start()
        defer { Task { await transport.close() } }

        // The pump is async; give it a moment to drain the channel into the
        // socketpair, then read the banner back from the libssh2FD.
        let received = try await readBytesAsync(fd: fd, count: banner.count, timeoutSeconds: 2)
        #expect(received == banner)
    }

    @Test
    func pumpForwardsLibssh2FDBytesToChannel() async throws {
        // The inner libssh2 session writes its own banner to the libssh2FD;
        // the pump's second job is to read that and forward it to the channel
        // (which sends it to the target node via the proxy tunnel).
        let clientBanner: [UInt8] = Array("SSH-2.0-libssh2_1.11.1\r\n".utf8)
        var receivedByChannel: [UInt8] = []
        let channelRead: @Sendable (UnsafeMutablePointer<UInt8>, Int) -> Int = { _, _ in 0 }
        let channelWrite: @Sendable (UnsafePointer<UInt8>, Int) -> Int = { buf, len in
            for i in 0..<len { receivedByChannel.append(buf[i]) }
            return len
        }

        let transport = SSHProxySubsystemTransport(
            channelRead: channelRead,
            channelWrite: channelWrite
        )
        let fd = try await transport.start()
        defer { Task { await transport.close() } }

        // Write the client banner to the libssh2FD (as the inner libssh2
        // session would). The pump should forward it to the channel.
        _ = try writeAll(fd: fd, bytes: clientBanner)

        // Wait for the pump to forward the bytes.
        try await waitForCondition(timeoutSeconds: 2) {
            receivedByChannel.count >= clientBanner.count
        }
        #expect(Array(receivedByChannel.prefix(clientBanner.count)) == clientBanner)
    }

    @Test
    func pumpHandlesChannelEOFByClosingPumpFD() async throws {
        // When the channel read returns 0 (EOF — the proxy closed the tunnel),
        // the pump must close the pumpFD so the inner libssh2 session's reads
        // also see EOF (otherwise `libssh2_session_handshake` would hang
        // forever waiting for a banner that will never arrive).
        let channelRead: @Sendable (UnsafeMutablePointer<UInt8>, Int) -> Int = { _, _ in 0 }  // immediate EOF
        let channelWrite: @Sendable (UnsafePointer<UInt8>, Int) -> Int = { _, _ in 0 }

        let transport = SSHProxySubsystemTransport(
            channelRead: channelRead,
            channelWrite: channelWrite
        )
        let fd = try await transport.start()
        defer { Task { await transport.close() } }

        // After EOF, a read on the libssh2FD should return 0 (EOF) rather than
        // blocking indefinitely. Give the pump a moment to close the pump end.
        let result = try await readWithTimeout(fd: fd, count: 1, timeoutSeconds: 2)
        #expect(result == 0, "expected EOF (0) on libssh2FD after channel EOF")
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
    /// of bytes read (0 = EOF, or timeout with no data).
    private func readWithTimeout(fd: Int32, count: Int, timeoutSeconds: TimeInterval) async throws -> Int {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
            // Use a poll-based approach with a small sleep loop to avoid blocking.
            DispatchQueue.global().async {
                var waited: TimeInterval = 0
                let step: useconds_t = 5_000  // 5ms
                while true {
                    let n = Darwin.read(fd, buf, count)
                    if n >= 0 {
                        buf.deallocate()
                        cont.resume(returning: n)
                        return
                    }
                    // EAGAIN / EWOULDBLOCK — keep waiting.
                    usleep(step)
                    waited += Double(step) / 1_000_000.0
                    if waited >= timeoutSeconds {
                        buf.deallocate()
                        cont.resume(returning: -1)
                        return
                    }
                }
            }
        }
    }

    /// Read exactly `count` bytes from a fd, waiting up to `timeoutSeconds`
    /// for them to arrive (the pump is async, so the bytes may not be
    /// available immediately).
    private func readBytesAsync(fd: Int32, count: Int, timeoutSeconds: TimeInterval) async throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var read = 0
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { buf.deallocate() }

        var waited: TimeInterval = 0
        let step: useconds_t = 5_000  // 5ms
        while read < count {
            let n = Darwin.read(fd, buf.advanced(by: read), count - read)
            if n > 0 {
                read += n
            } else if n == 0 {
                // EOF before count bytes — the pump closed early.
                break
            } else {
                usleep(step)
                waited += Double(step) / 1_000_000.0
                if waited >= timeoutSeconds {
                    for i in 0..<read { buffer[i] = buf[i] }
                    throw SSHError.socketError("readBytesAsync: timed out after \(waited)s, read \(read)/\(count)")
                }
            }
        }
        for i in 0..<read { buffer[i] = buf[i] }
        return Array(buffer.prefix(read))
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
