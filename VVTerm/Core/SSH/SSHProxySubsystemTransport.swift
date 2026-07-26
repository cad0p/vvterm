// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  SSHProxySubsystemTransport.swift
//  VVTerm
//
//  Socketpair bridge that lets a second libssh2 session read/write through an
//  SSH channel opened on the *outer* (proxy) session.
//
//  Why this exists
//  ---------------
//  Teleport's proxy SSH listener runs in `proxyMode`: it rejects `pty` /
//  `shell` / `exec` channel requests and only accepts `subsystem` requests
//  named `proxy:<node>:<port>[@<cluster>]` (see `TeleportProxySubsystem`).
//  The proxy then forwards the channel as a raw TCP tunnel to the target
//  node's SSH service. VVTerm runs a *second* full SSH handshake (KEX +
//  cert auth) over that tunnel to reach the node itself.
//
//  libssh2's session handshake + I/O API takes a raw file descriptor (it
//  calls `read()`/`write()` on it). An SSH channel is not an FD — bytes move
//  through `libssh2_channel_read_ex` / `libssh2_channel_write_ex`. This
//  transport bridges the two with a socketpair + a bidirectional pump,
//  exactly mirroring `SSHTLSTransport` (which bridges
//  NWConnection <-> socketpair):
//
//      inner libssh2  ──read/write──  libssh2FD  ──┐
//                                                   │ socketpair (AF_UNIX, SOCK_STREAM)
//      outer channel  ──channel read/write──  pumpFD └┘
//                                                   ▲
//                                                   └── pump forwards bytes both ways
//
//  Ordering (same lesson as SSHTLSTransport)
//  -----------------------------------------
//  The target node sends its SSH banner (`SSH-2.0-...`) immediately after the
//  proxy subsystem channel is established. The pump's channel->FD loop MUST be
//  started before `libssh2_session_handshake(innerSession, fd)` is called, or
//  libssh2's blocking read for the banner races the pump's first channel read
//  and KEX fails with `-5` (no banner seen). `start()` guarantees this: the
//  pump is running when the libssh2FD is returned.
//
//  Testability
//  -----------
//  The channel side is injected as two `@Sendable` closures
//  (`channelRead` / `channelWrite`) so the pump, the socketpair lifecycle,
//  and the EOF/error handling can be unit-tested without a live libssh2
//  channel (the live Teleport proxy test needs a real device — see the live
//  verification note below).
//
//  Live verification note
//  ----------------------
//  The end-to-end second handshake (real Teleport proxy → real target node)
//  cannot be exercised in the simulator — it needs a real device with Face
//  ID + a live Teleport cluster. The unit tests here cover the transport's
//  mechanics (socketpair creation, bidirectional byte forwarding, EOF
//  propagation). The device smoke test is the final confidence check.
//

#if canImport(Darwin)
import Darwin
import Foundation
import os.log
import os

/// Standalone cancellation token captured by the channel I/O closures so they
/// can observe cancellation without retaining the transport (which would be a
/// retain cycle: the closures are stored on the transport). A small Sendable
/// class wrapping a lock-protected bool.
final class PumpCancelToken: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        lock.withLock { $0 = true }
    }

    var isCancelled: Bool {
        lock.withLock { $0 }
    }
}

/// A socketpair bridge that lets a second libssh2 session read/write through
/// an SSH channel opened on the outer (proxy) session.
///
/// Created with `channelRead` / `channelWrite` closures that wrap the outer
/// session's SSH channel (`libssh2_channel_read_ex` / `libssh2_channel_write_ex`).
/// `start()` creates the socketpair, starts the bidirectional pump, and returns
/// the libssh2-facing FD. `close()` tears down the pump + the pump-end FD.
///
/// The returned FD is owned by the transport — `close()` closes it. The caller
/// must NOT `close()` the FD directly (libssh2 reads/writes it directly during
/// the inner handshake + I/O; closing it here after the inner session is freed
/// is the transport's responsibility — see `SSHTLSTransport.close` for the same
/// pattern).
actor SSHProxySubsystemTransport {

    /// The result of creating the socketpair bridge.
    struct SocketPair: Sendable {
        let libssh2FD: Int32
        let pumpFD: Int32
    }

    /// Reads up to `maxLen` bytes from the outer SSH channel into `buffer`.
    ///
    /// - Returns: The number of bytes read. `0` means EOF (the proxy closed
    ///   the tunnel). A negative value would indicate an error (libssh2
    ///   returns `LIBSSH2_ERROR_EAGAIN` for non-blocking channels, which the
    ///   production closure maps to a short retry loop internally).
    typealias ChannelRead = @Sendable (_ buffer: UnsafeMutablePointer<UInt8>, _ maxLen: Int) -> Int

    /// Writes `len` bytes from `buffer` to the outer SSH channel.
    ///
    /// - Returns: The number of bytes written. The production closure maps
    ///   `LIBSSH2_ERROR_EAGAIN` to a retry loop, so callers always see a
    ///   non-negative byte count or `0` (channel closed).
    typealias ChannelWrite = @Sendable (_ buffer: UnsafePointer<UInt8>, _ len: Int) -> Int

    private let channelRead: ChannelRead
    private let channelWrite: ChannelWrite
    /// Cancellation token captured by the channel I/O closures (via
    /// `makeForChannel`). A standalone `Sendable` class so the closures can
    /// observe cancellation without retaining the transport (which would be a
    /// retain cycle: the closures are stored on the transport). `nil` for the
    /// test-only init (test closures don't need cancellation).
    private let cancelToken: PumpCancelToken?

    private var socketPair: SocketPair?
    private var pumpTask: Task<Void, Never>?
    /// Lock-protected pump state so a nonisolated caller (`cancelPumpSync`)
    /// can stop the pump without awaiting the actor. This is needed by
    /// `SSHSession.cleanupLibssh2()`, which is synchronous and must stop the
    /// pump BEFORE freeing the outer libssh2 session (the pump reads/writes a
    /// channel on the outer session — freeing the session underneath a live
    /// pump would be a use-after-free).
    private let pumpState = OSAllocatedUnfairLock(initialState: PumpState())

    private struct PumpState {
        var task: Task<Void, Never>?
        var pumpFD: Int32 = -1
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "it.pcad.vvterm",
        category: "SSH-Proxy-Subsystem-Transport"
    )

    init(channelRead: @escaping ChannelRead, channelWrite: @escaping ChannelWrite) {
        self.channelRead = channelRead
        self.channelWrite = channelWrite
        self.cancelToken = nil
    }

    /// Test/production split: the production `makeForChannel` factory passes a
    /// `cancelToken` so the closures can observe cancellation. The test-only
    /// init (above) doesn't need one.
    init(
        channelRead: @escaping ChannelRead,
        channelWrite: @escaping ChannelWrite,
        cancelToken: PumpCancelToken
    ) {
        self.channelRead = channelRead
        self.channelWrite = channelWrite
        self.cancelToken = cancelToken
    }

    /// Create a connected socketpair for the channel <-> libssh2 bridge.
    ///
    /// Both ends are full-duplex `AF_UNIX` `SOCK_STREAM` sockets. The
    /// libssh2 end is handed to `libssh2_session_handshake(session, fd)`;
    /// the pump end is read/written by the pump coroutine. The caller owns
    /// both FDs and must `close()` them.
    ///
    /// - Returns: a `SocketPair` with two valid (>= 0) FDs.
    /// - Throws: `SSHError.connectionFailed` if `socketpair(2)` fails.
    static func makeSocketPair() throws -> SocketPair {
        var fds: [Int32] = [0, 0]
        let result = Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        guard result == 0, fds[0] >= 0, fds[1] >= 0 else {
            throw SSHError.connectionFailed(
                "SSHProxySubsystemTransport: socketpair failed (errno \(errno))"
            )
        }
        return SocketPair(libssh2FD: fds[0], pumpFD: fds[1])
    }

    // MARK: - Start

    /// Create the socketpair, start the bidirectional pump, and return the
    /// libssh2-facing FD.
    ///
    /// The pump is started BEFORE this returns, so the channel's first bytes
    /// (the target node's SSH banner) are forwarded to the libssh2FD as soon
    /// as they arrive — the caller can immediately hand the FD to
    /// `libssh2_session_handshake` without a race.
    ///
    /// The returned FD is owned by the transport — `close()` closes it.
    func start() async throws -> Int32 {
        let pair = try Self.makeSocketPair()
        self.socketPair = pair

        logger.info(
            "proxy_subsystem_transport_start libssh2FD=\(pair.libssh2FD) pumpFD=\(pair.pumpFD)"
        )

        // Start the pump before returning the FD. Both loops run concurrently
        // in a detached task; either loop exiting cancels the other + closes
        // the pump end (so the libssh2 session sees EOF on its reads).
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runPump(pair: pair)
        }
        pumpTask = task
        pumpState.withLock { state in
            state.task = task
            state.pumpFD = pair.pumpFD
        }

        return pair.libssh2FD
    }

    // MARK: - Close

    /// Tear down the transport: stop the pump and close the pump end of the
    /// socketpair. The libssh2-facing FD is NOT closed here — it is owned by
    /// the inner SSHSession (which closes it after `libssh2_session_free`),
    /// because libssh2 reads/writes that FD directly. Closing it here would
    /// double-close.
    ///
    /// Safe to call multiple times.
    func close() {
        cancelPumpSync()
        pumpTask = nil
        socketPair = nil
        logger.info("proxy_subsystem_transport_close")
    }

    /// Synchronously cancel the pump task + close the pump end of the
    /// socketpair, without awaiting the actor. Used by `SSHSession.cleanupLibssh2()`
    /// which is synchronous and must stop the pump BEFORE freeing the outer
    /// libssh2 session (the pump reads/writes a channel on the outer session;
    /// freeing the session underneath a live pump would be a use-after-free).
    ///
    /// Idempotent. Does NOT close the libssh2-facing FD (owned by the inner
    /// session's `AtomicSocket`).
    nonisolated func cancelPumpSync() {
        let (task, fd) = pumpState.withLock { state -> (Task<Void, Never>?, Int32) in
            let t = state.task
            let f = state.pumpFD
            state.task = nil
            state.pumpFD = -1
            return (t, f)
        }
        // Flip the cancellation token so the channel I/O closures bail out
        // of their EAGAIN retry loops before the outer libssh2 session is
        // freed (avoids a use-after-free on the outer session/channel).
        cancelToken?.cancel()
        task?.cancel()
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    // MARK: - Pump internals

    /// The bidirectional pump. Two loops run concurrently:
    ///   - channel -> pumpFD: read from the channel, write to pumpFD.
    ///   - pumpFD -> channel: read from pumpFD, write to the channel.
    ///
    /// Both loops exit when either side hits EOF or errors, then close the
    /// pump end so the inner libssh2 session's reads on the libssh2FD return
    /// EOF. The libssh2FD itself is closed by the inner session (it owns that
    /// end); the pump never closes libssh2FD to avoid racing FD reuse.
    ///
    /// `nonisolated` so the blocking `read()`/`write()` on the pump FD run on
    /// the detached task's thread without hopping onto the actor (which would
    /// serialize + stall the pump).
    nonisolated private func runPump(pair: SocketPair) async {
        let pumpLog = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "it.pcad.vvterm",
            category: "SSH-Proxy-Subsystem-Pump"
        )
        pumpLog.info("pump_start libssh2FD=\(pair.libssh2FD) pumpFD=\(pair.pumpFD)")
        await withTaskGroup(of: Void.self) { group in
            // channel -> pumpFD
            group.addTask {
                await self.pumpChannelToFD(pair: pair, log: pumpLog)
            }
            // pumpFD -> channel
            group.addTask {
                await self.pumpFDToChannel(pair: pair, log: pumpLog)
            }
            // When either loop exits, cancel the other + close the pump end.
            // (The loops close pumpFD on their own EOF; closing again here is
            // a harmless EBADF, but ensures the pumpFD is closed even if a
            // loop exited without reaching its close path.)
            await group.next()
            group.cancelAll()
            Darwin.close(pair.pumpFD)
        }
    }

    /// channel -> pumpFD: read bytes from the outer SSH channel (via the
    /// injected `channelRead` closure), write them to the pump FD for the
    /// inner libssh2 session to read. Loops until the channel returns 0 (EOF)
    /// or the task is cancelled.
    nonisolated private func pumpChannelToFD(pair: SocketPair, log: Logger) async {
        var channelToFDBytes: Int = 0
        var loggedFirst = false
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buffer.deallocate() }
        while !Task.isCancelled {
            let n = channelRead(buffer, 64 * 1024)
            if n <= 0 {
                // Channel EOF or error — close the pump FD so the inner
                // libssh2 session's reads return EOF (otherwise
                // `libssh2_session_handshake` would hang forever waiting for
                // a banner that will never arrive).
                log.info("pump_channel_to_fd_eof_or_err ret=\(n) bytes=\(channelToFDBytes)")
                Darwin.close(pair.pumpFD)
                return
            }
            if !loggedFirst {
                loggedFirst = true
                // The first channel->FD chunk carries the target node's SSH
                // banner (`SSH-2.0-...`). Dump the first 512 bytes as hex so
                // the banner (and any KEX_INIT bytes that did arrive) are
                // visible in the live device log.
                let first = min(n, 512)
                var hex = ""
                hex.reserveCapacity(first * 2)
                for i in 0..<first { hex += String(format: "%02x", buffer[i]) }
                log.info("pump_channel_to_fd_first len=\(n) hex=\(hex, privacy: .public)")
            }
            channelToFDBytes += n
            // Write all bytes to the pump FD (may need multiple writes).
            var written = 0
            while written < n {
                let w = Darwin.write(pair.pumpFD, buffer.advanced(by: written), n - written)
                if w <= 0 {
                    log.error("pump_channel_to_fd_write_fail errno=\(Darwin.errno) written=\(written)/\(n)")
                    return
                }
                written += w
            }
        }
        log.info("pump_channel_to_fd_cancelled bytes=\(channelToFDBytes)")
    }

    /// pumpFD -> channel: read bytes from the pump FD (written by the inner
    /// libssh2 session), write them to the outer SSH channel (via the injected
    /// `channelWrite` closure). Loops until read returns EOF or the task is
    /// cancelled.
    nonisolated private func pumpFDToChannel(pair: SocketPair, log: Logger) async {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buffer.deallocate() }
        var fdToChannelBytes: Int = 0
        var loggedFirst = false
        while !Task.isCancelled {
            let n = Darwin.read(pair.pumpFD, buffer, 64 * 1024)
            if n <= 0 {
                // EOF or error — stop sending.
                log.info("pump_fd_to_channel_eof_or_err ret=\(n) errno=\(Darwin.errno) bytes=\(fdToChannelBytes)")
                return
            }
            if !loggedFirst {
                loggedFirst = true
                let first = min(n, 32)
                var hex = ""
                hex.reserveCapacity(first * 2)
                for i in 0..<first { hex += String(format: "%02x", buffer[i]) }
                log.info("pump_fd_to_channel_first len=\(n) hex=\(hex, privacy: .public)")
            }
            fdToChannelBytes += n
            // Write all bytes to the channel (the closure handles
            // EAGAIN retries internally and always returns the byte count
            // or 0 on a closed channel).
            var written = 0
            while written < n {
                let w = channelWrite(buffer.advanced(by: written), n - written)
                if w <= 0 {
                    log.error("pump_fd_to_channel_write_fail ret=\(w) written=\(written)/\(n)")
                    return
                }
                written += w
            }
        }
        log.info("pump_fd_to_channel_cancelled bytes=\(fdToChannelBytes)")
    }
}

// MARK: - libssh2 channel adapter

extension SSHProxySubsystemTransport {

    /// Create a transport backed by a real libssh2 channel from the outer
    /// (proxy) session.
    ///
    /// The closures wrap `libssh2_channel_read_ex` (stream 0 = stdout) and
    /// `libssh2_channel_write_ex` (stream 0 = stdin) with a non-blocking
    /// retry loop that yields on `LIBSSH2_ERROR_EAGAIN`. The outer session
    /// MUST be in non-blocking mode (the default after `SSHSession.connect`
    /// sets it) so EAGAIN is returned rather than blocking the pump's thread.
    ///
    /// - Parameters:
    ///   - channel: The outer session channel (already has the `proxy:...`
    ///     subsystem requested). The transport does NOT take ownership — the
    ///     caller frees the channel after the inner session is done.
    ///   - outerSession: The outer libssh2 session (used only for
    ///     `libssh2_session_last_errno` diagnostics; may be nil in tests).
    static func makeForChannel(
        channel: OpaquePointer,
        outerSession: OpaquePointer?
    ) -> SSHProxySubsystemTransport {
        // A standalone cancellation token (NOT the transport) captured by the
        // channel I/O closures. This avoids a retain cycle: the closures are
        // stored on the transport, so capturing the transport itself would
        // pin it forever. The token is a small Sendable class that the
        // transport flips via cancelPumpSync().
        let cancelToken = PumpCancelToken()
        let transport = SSHProxySubsystemTransport(
            channelRead: { buf, maxLen in
                // Retry on EAGAIN until data arrives, EOF, a hard error, or
                // cancellation. A small usleep prevents a busy-spin while the
                // channel has no data.
                while true {
                    if cancelToken.isCancelled { return 0 }  // EOF
                    let n = libssh2_channel_read_ex(channel, 0, buf, maxLen)
                    if n == LIBSSH2_ERROR_EAGAIN {
                        usleep(1_000)  // 1ms — non-blocking retry
                        continue
                    }
                    // n > 0: bytes read. n == 0: EOF. n < 0 (other): hard error
                    // (map to EOF so the pump closes the pumpFD and the inner
                    // session sees EOF rather than hanging).
                    return n < 0 ? 0 : n
                }
            },
            channelWrite: { buf, len in
                while true {
                    if cancelToken.isCancelled { return 0 }
                    let n = libssh2_channel_write_ex(channel, 0, buf, len)
                    if n == LIBSSH2_ERROR_EAGAIN {
                        usleep(1_000)  // 1ms — non-blocking retry
                        continue
                    }
                    return n < 0 ? 0 : n
                }
            },
            cancelToken: cancelToken
        )
        return transport
    }
}

#endif // canImport(Darwin)
