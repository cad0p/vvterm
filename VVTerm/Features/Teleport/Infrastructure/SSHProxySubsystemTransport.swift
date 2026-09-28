// SPDX-License-Identifier: MIT
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
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    private let lock = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        lock.withLock { $0 = true }
    }

    var isCancelled: Bool {
        lock.withLock { $0 }
    }
}

/// A `Sendable` mutex guarding all libssh2 calls on the outer (proxy) session.
///
/// libssh2 is NOT thread-safe per-session — the session's transport read
/// buffer (`session->packet.writeidx/readidx`, shared across all channels)
/// and crypto sequence-number state are corrupted when two threads call into
/// the same `LIBSSH2_SESSION*` concurrently. The symptom is
/// `assert(remainbuf >= 0)` in `ssh2_transport_read` (transport.c) —
/// `remainbuf = writeidx - readidx` goes negative when a concurrent reader
/// advances `readidx` past another reader's `writeidx`.
///
/// The Teleport proxy-subsystem path is uniquely exposed: its pump runs two
/// concurrent loops in a task group (`pumpChannelToFD` -> `channelRead` ->
/// `libssh2_channel_read_ex`, and `pumpFDToChannel` -> `channelWrite` ->
/// `libssh2_channel_write_ex`). Both touch the outer session. Without
/// serialization, they race on every bidirectional byte and crash after
/// enough data flows. `sendKeepAlive` (every 30s) races the pump too.
///
/// This mutex is shared between the pump closures (which run off-actor in
/// detached tasks) and the `SSHSession` actor methods that touch the outer
/// session (`sendKeepAlive`, and any exec/SFTP/ioLoop call). Acquiring it
/// around every outer-session libssh2 call serializes them. `NSLock` is
/// non-reentrant by design — the lock is held only around the synchronous
/// libssh2 C call (never across an `await` or an EAGAIN `usleep` retry), so
/// reentrancy would indicate a bug.
final class SessionMutex: @unchecked Sendable {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    private let lock = NSLock()

    nonisolated init() {}

    /// Acquire the mutex, run `body`, release. Returns `body`'s result.
    nonisolated func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Host-side conformance: the bridge pump + `SSHSession` share this mutex
/// through the package-movable `TeleportSessionMutex` seam.
extension SessionMutex: TeleportSessionMutex {}

/// The pump end of the socketpair, with waking it and releasing it split into
/// one lock-serialized `open → shutDown → closed` state machine (the
/// `AtomicSocket` shape, `SSHClient.swift`).
///
/// Four paths can race to wake the fd — the `pumpNWToFD` exits (receive error,
/// EOF, write failure), `close()`, and `cancelPumpSync()` — and two can reach
/// the release (the TLS-handshake-failure path and `runPump`, both only after
/// joining their loops). `shutdownOnce` wakes a reader/writer with `0`/`EPIPE`
/// **without** freeing the number; `closeOnce` frees it exactly once, and
/// `.closed` is terminal for both, so a delayed wake can never touch a
/// descriptor the process has since reused. Two independent flags would let a
/// stale `shutdown(2)` shut down an unrelated connection; a single once-flag
/// would leak the descriptor on every clean teardown. `shutdown(SHUT_RDWR)` is
/// also what actually wakes a blocked reader: `close` alone does NOT wake a
/// thread blocked in `read()` on the same fd — the in-flight syscall holds a
/// file reference, so the socket stays half-alive and the peer never sees EOF
/// (this deadlocked the `pumpHandlesChannelEOFByClosingPumpFD` test:
/// `pumpFDToChannel` stayed blocked in `read(pumpFD)` and `read(libssh2FD)`
/// never returned 0).
///
/// The recorded incident behind single ownership: a repeated `close(2)` is not
/// harmless — under the extracted package's parallel test execution it
/// surfaced as a spurious fixture-read failure in an unrelated suite while
/// four handshake-failure tests were tearing their pumps down (2026-09-24).
///
/// The `shutdown(2)`/`close(2)` return values are deliberately ignored: single
/// ownership means `EBADF`/`EINTR` cannot leave recoverable state, `.closed`
/// is terminal, and a retry would risk touching a number a concurrent release
/// has already freed.
final class PumpFDCloser: @unchecked Sendable {
    /// Test seam: the closer's state, so a teardown test can assert the
    /// number was released without naming the (private) fd.
    enum State: Sendable {
        case open
        case shutDown
        case closed
    }

    private let state = OSAllocatedUnfairLock(initialState: State.open)

    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change. #216's
    // class list missed this one; the #234 regression test constructs and
    // releases it from a synchronous test method, which is exactly the path
    // that traps.
    nonisolated deinit {}

    nonisolated init() {}

    /// The closer's state (test seam).
    nonisolated var stateForTesting: State { state.withLock { $0 } }

    /// Wake any reader/writer without freeing the descriptor number. No-op
    /// once shut down or closed, so a stale wake can never reach a reused
    /// number.
    nonisolated func shutdownOnce(_ fd: Int32) {
        guard fd >= 0 else { return }
        state.withLock { s in
            guard case .open = s else { return }
            s = .shutDown
            // Inside the lock: with the check outside, a preempted wake could
            // resume after a concurrent release freed (and the process
            // reused) the number, and shut down an unrelated descriptor.
            Darwin.shutdown(fd, SHUT_RDWR)
        }
    }

    /// Release the number exactly once, and only from a path that can prove no
    /// loop can start another syscall (after the join). `.closed` is terminal
    /// for both methods.
    nonisolated func closeOnce(_ fd: Int32) {
        guard fd >= 0 else { return }
        state.withLock { s in
            switch s {
            case .closed:
                return
            case .open, .shutDown:
                s = .closed
                // Both syscalls are inside the lock for the same reason as
                // `shutdownOnce`: no window between the state decision and
                // the release.
                Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
        }
    }
}

/// A socketpair bridge that lets a second libssh2 session read/write through
/// an SSH channel opened on the outer (proxy) session.
///
/// Created with `channelRead` / `channelWrite` closures that wrap the outer
/// session's SSH channel (`libssh2_channel_read_ex` / `libssh2_channel_write_ex`).
/// `start()` creates the socketpair, starts the bidirectional pump, and returns
/// the libssh2-facing FD. `close()` stops the pump and wakes the pump-end FD;
/// the pump releases that descriptor once both of its loops have joined (issue
/// #237), so `close()` does not free the descriptor number.
///
/// The returned FD is owned by the inner SSHSession (its `AtomicSocket` closes
/// it after `libssh2_session_free`). The caller must NOT `close()` it directly
/// (libssh2 reads/writes it directly during the inner handshake + I/O) — see
/// `SSHTLSTransport.close` for the same pattern.
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
        var closer: PumpFDCloser?
    }

    private let logger = Logger.forCategory("SSH-Proxy-Subsystem-Transport")

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
    /// the libssh2 end and must `close()` it; the pump end is owned by the
    /// pump and released by it through `PumpFDCloser` once both pump loops
    /// have joined (issue #237).
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
        // Non-blocking ends: the inner libssh2 session runs in non-blocking
        // mode (EAGAIN-loop handshake + non-blocking I/O) and the pump loops
        // handle EAGAIN with cooperative yields. A blocking fd would let
        // read()/write() pin a cooperative-pool thread (pool exhaustion
        // stalls the pumps — the teleport-e2e socketpair-KEX stall).
        for fd in fds {
            let flags = Darwin.fcntl(fd, F_GETFL, 0)
            if flags >= 0 {
                _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            }
        }
        // Suppress SIGPIPE on **both** ends. `PumpFDCloser` shuts an end down
        // (`shutdown(SHUT_RDWR)`) before it closes, so a `write` racing that
        // release — the pump's write on the pump end, libssh2's write on the
        // peer — gets `EPIPE` and the kernel raises `SIGPIPE`, whose default
        // disposition terminates the process. With the option set the same
        // write returns `-1`/`EPIPE` and the pump's error path handles it.
        // Same idiom as the TCP path in `SSHClient`.
        for fd in fds {
            var noSigPipe: Int32 = 1
            _ = setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
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
    /// The returned FD is owned by the inner SSHSession; the caller must NOT
    /// `close()` it directly (libssh2 reads/writes it during the inner
    /// handshake + I/O).
    func start() async throws -> Int32 {
        let pair = try Self.makeSocketPair()
        self.socketPair = pair

        logger.info(
            "proxy_subsystem_transport_start libssh2FD=\(pair.libssh2FD) pumpFD=\(pair.pumpFD)"
        )

        // Start the pump before returning the FD. Both loops run concurrently
        // in a detached task; either loop exiting cancels the other + wakes
        // the pump end (so the libssh2 session sees EOF on its reads), and
        // `runPump` releases it only after both loops have joined. The closer
        // is shared between the pump loops, `runPump`, and `cancelPumpSync`
        // (see `PumpFDCloser`).
        //
        // The detached body must not capture `self`: if the actor dies after
        // `close()` returns (which no longer releases the fd) but before the
        // body runs, a `guard let self` would return without ever releasing
        // the descriptor. Read the closures + token here and pass them by
        // value (issue #237).
        let closer = PumpFDCloser()
        let channelRead = self.channelRead
        let channelWrite = self.channelWrite
        let cancelToken = self.cancelToken
        let task = Task.detached(priority: .userInitiated) {
            await SSHProxySubsystemTransport.runPump(
                pair: pair,
                closer: closer,
                channelRead: channelRead,
                channelWrite: channelWrite,
                cancelToken: cancelToken
            )
        }
        pumpTask = task
        pumpState.withLock { state in
            state.task = task
            state.pumpFD = pair.pumpFD
            state.closer = closer
        }

        return pair.libssh2FD
    }

    // MARK: - Close

    /// Tear down the transport: stop the pump and wake the pump end of the
    /// socketpair. `runPump` releases that descriptor after both of its loops
    /// have joined, so this returns without freeing the descriptor number
    /// (issue #237: a loop that started a syscall after `close(2)` could land
    /// on a reused descriptor). The libssh2-facing FD is NOT closed here — it
    /// is owned by the inner SSHSession (which closes it after
    /// `libssh2_session_free`), because libssh2 reads/writes that FD directly.
    /// Closing it here would double-close.
    ///
    /// Safe to call multiple times.
    func close() {
        cancelPumpSync()
        pumpTask = nil
        socketPair = nil
        logger.info("proxy_subsystem_transport_close")
    }

    /// Synchronously cancel the pump task and wake the pump end of the
    /// socketpair (shutdown, not close — `runPump` releases it after its join,
    /// issue #237), without awaiting the actor. Used by
    /// `SSHSession.cleanupLibssh2()` which is synchronous and must stop the
    /// pump BEFORE freeing the outer libssh2 session (the pump reads/writes a
    /// channel on the outer session; freeing the session underneath a live
    /// pump would be a use-after-free).
    ///
    /// Idempotent. Does NOT close the libssh2-facing FD (owned by the inner
    /// session's `AtomicSocket`).
    nonisolated func cancelPumpSync() {
        let (task, fd, closer) = pumpState.withLock {
            state -> (Task<Void, Never>?, Int32, PumpFDCloser?) in
            let t = state.task
            let f = state.pumpFD
            let c = state.closer
            state.task = nil
            state.pumpFD = -1
            state.closer = nil
            return (t, f, c)
        }
        // Flip the cancellation token so the channel I/O closures bail out
        // of their EAGAIN retry loops before the outer libssh2 session is
        // freed (avoids a use-after-free on the outer session/channel).
        cancelToken?.cancel()
        task?.cancel()
        // Wake only: `shutdown(2)` unblocks an in-flight read/write (`0`/
        // `EPIPE`) without freeing the number, so no loop can fall through to
        // a reused descriptor. `runPump` closes after its join (issue #237).
        closer?.shutdownOnce(fd)
    }

    // MARK: - Pump internals

    /// The bidirectional pump. Two loops run concurrently:
    ///   - channel -> pumpFD: read from the channel, write to pumpFD.
    ///   - pumpFD -> channel: read from pumpFD, write to the channel.
    ///
    /// Both loops exit when either side hits EOF or errors. The cleanup then
    /// (1) cancels the group and flips the channel cancellation token — the
    /// loops park inside the synchronous `channelRead`/`channelWrite`
    /// closures, which only observe the token, so `group.cancelAll()` alone
    /// cannot end them — (2) shuts the pump end down, waking the sibling's
    /// `read` with `0` and its `write` with `EPIPE` **without** freeing the
    /// descriptor number, (3) joins both loops, and only then (4) releases the
    /// pump end so the inner libssh2 session's reads on the libssh2FD return
    /// EOF. The libssh2FD itself is closed by the inner session (it owns that
    /// end); the pump never closes libssh2FD. The join is what makes the
    /// release safe: no syscall on `pumpFD` can start after `close(2)` freed
    /// the number (issue #237).
    ///
    /// `nonisolated` static, not an instance method: the detached body must
    /// capture no `self` (a `guard let self` could otherwise skip the release
    /// when the actor dies first), and the static shape keeps the pump's
    /// `read()`/`write()` syscalls on the pump FD (both ends are `O_NONBLOCK`;
    /// EAGAIN yields) on the detached task's thread without hopping onto the
    /// actor.
    nonisolated private static func runPump(
        pair: SocketPair,
        closer: PumpFDCloser,
        channelRead: @escaping ChannelRead,
        channelWrite: @escaping ChannelWrite,
        cancelToken: PumpCancelToken?
    ) async {
        let pumpLog = Logger.forCategory("SSH-Proxy-Subsystem-Pump")
        pumpLog.info("pump_start libssh2FD=\(pair.libssh2FD) pumpFD=\(pair.pumpFD)")
        await withTaskGroup(of: Void.self) { group in
            // channel -> pumpFD
            group.addTask {
                await SSHProxySubsystemTransport.pumpChannelToFD(
                    pair: pair,
                    closer: closer,
                    channelRead: channelRead,
                    log: pumpLog
                )
            }
            // pumpFD -> channel
            group.addTask {
                await SSHProxySubsystemTransport.pumpFDToChannel(
                    pair: pair,
                    channelWrite: channelWrite,
                    log: pumpLog
                )
            }
            // When either loop exits: cancel the group, flip the token the
            // channel closures observe, wake the sibling's descriptor, then
            // JOIN both loops before releasing the number. A `read`/`write`
            // that starts after `close(2)` would land on whatever reused the
            // number — read forwards unrelated bytes, write corrupts an
            // unrelated file (issue #237).
            await group.next()
            group.cancelAll()
            cancelToken?.cancel()
            closer.shutdownOnce(pair.pumpFD)
            await group.waitForAll()
            closer.closeOnce(pair.pumpFD)
        }
    }

    /// channel -> pumpFD: read bytes from the outer SSH channel (via the
    /// injected `channelRead` closure), write them to the pump FD for the
    /// inner libssh2 session to read. Loops until the channel returns 0 (EOF)
    /// or the task is cancelled.
    nonisolated private static func pumpChannelToFD(
        pair: SocketPair,
        closer: PumpFDCloser,
        channelRead: ChannelRead,
        log: Logger
    ) async {
        var channelToFDBytes: Int = 0
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buffer.deallocate() }
        while !Task.isCancelled {
            let n = channelRead(buffer, 64 * 1024)
            if n <= 0 {
                // Channel EOF or error — wake the pump FD so the inner
                // libssh2 session's reads return EOF (otherwise
                // `libssh2_session_handshake` would hang forever waiting for
                // a banner that will never arrive). `shutdown`, not `close`:
                // it wakes the FD->channel loop blocked in `read(pumpFD)`
                // without freeing the number (the release belongs to `runPump`
                // after the join, issue #237).
                log.diagInfo("SSH-Proxy-Subsystem-Pump", "pump_channel_to_fd_eof_or_err ret=\(n) bytes=\(channelToFDBytes)")
                closer.shutdownOnce(pair.pumpFD)
                return
            }
            channelToFDBytes += n
            // Write all bytes to the pump FD (may need multiple writes),
            // yielding on EAGAIN so a full socketpair buffer never pins a
            // cooperative-pool thread.
            if !(await SSHProxySubsystemTransport.writeAllToPumpFD(fd: pair.pumpFD, buffer: buffer, count: n)) {
                log.error("pump_channel_to_fd_write_fail errno=\(Darwin.errno) written=\(n)")
                closer.shutdownOnce(pair.pumpFD)
                return
            }
        }
        log.info("pump_channel_to_fd_cancelled bytes=\(channelToFDBytes)")
    }

    /// pumpFD -> channel: read bytes from the pump FD (written by the inner
    /// libssh2 session), write them to the outer SSH channel (via the injected
    /// `channelWrite` closure). Loops until read returns EOF or the task is
    /// cancelled. Reads never hard-block: the fd is O_NONBLOCK and EAGAIN
    /// yields via `Task.sleep`, so the cooperative pool thread stays
    /// available to the other pump loop + the inner handshake loop.
    nonisolated private static func pumpFDToChannel(
        pair: SocketPair,
        channelWrite: ChannelWrite,
        log: Logger
    ) async {
        log.info("pump_fd_to_channel_start pumpFD=\(pair.pumpFD)")
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buffer.deallocate() }
        var fdToChannelBytes: Int = 0
        while !Task.isCancelled {
            let n = Darwin.read(pair.pumpFD, buffer, 64 * 1024)
            if n > 0 {
                if fdToChannelBytes == 0 {
                    log.info("pump_fd_to_channel_read_first bytes=\(n)")
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
            } else if n == 0 {
                // EOF — stop sending.
                log.diagInfo("SSH-Proxy-Subsystem-Pump", "pump_fd_to_channel_eof_or_err ret=0 bytes=\(fdToChannelBytes)")
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                // No bytes yet — yield so the pool thread serves the other
                // pump loop + the inner handshake loop.
                try? await Task.sleep(nanoseconds: 5_000_000)
            } else {
                // Hard error — stop sending.
                log.diagInfo("SSH-Proxy-Subsystem-Pump", "pump_fd_to_channel_eof_or_err ret=\(n) errno=\(Darwin.errno) bytes=\(fdToChannelBytes)")
                return
            }
        }
        log.info("pump_fd_to_channel_cancelled bytes=\(fdToChannelBytes)")
    }

    /// Write all bytes to the pump FD, yielding on EAGAIN (O_NONBLOCK
    /// socketpair) so a full buffer never pins a cooperative-pool thread.
    /// Returns false on EOF/error.
    ///
    /// The `Task.isCancelled` check at the top of the loop is load-bearing:
    /// with the only reader gone, the socketpair buffer stays full and the
    /// EAGAIN retry would otherwise never observe `group.cancelAll()` (the
    /// `Task.sleep` swallows its cancellation error).
    nonisolated private static func writeAllToPumpFD(
        fd: Int32,
        buffer: UnsafePointer<UInt8>,
        count: Int
    ) async -> Bool {
        var written = 0
        while written < count {
            if Task.isCancelled { return false }
            let n = Darwin.write(fd, buffer.advanced(by: written), count - written)
            if n > 0 {
                written += n
                continue
            }
            if n == 0 { return false }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try? await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            return false
        }
        return true
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
    /// All libssh2 calls are serialized through `outerSessionMutex`. The
    /// pump's two loops (`pumpChannelToFD` -> `channelRead`, and
    /// `pumpFDToChannel` -> `channelWrite`) run concurrently in a task group
    /// but both touch the same outer `LIBSSH2_SESSION*`. libssh2 is not
    /// thread-safe per-session — concurrent `ssh2_transport_read` /
    /// `ssh2_transport_send` corrupt the session's transport buffer
    /// accounting and trip `assert(remainbuf >= 0)` in transport.c. The
    /// mutex is the same one `SSHSession.sendKeepAlive` (and other
    /// outer-session callers) acquire, so the pump also serializes against
    /// keepalives. The lock is held only around the synchronous libssh2 C
    /// call; the EAGAIN `usleep` retry happens outside the lock so a
    /// backpressured channel doesn't stall keepalives.
    ///
    /// The cancel token is re-checked *inside* the mutex, immediately before
    /// each libssh2 call, so the synchronous teardown (which flips the token,
    /// then frees the outer session under the same mutex) cannot race a call
    /// into the freed outer session.
    ///
    /// - Parameters:
    ///   - channel: The outer session channel (already has the `proxy:...`
    ///     subsystem requested). The transport does NOT take ownership — the
    ///     caller frees the channel after the inner session is done.
    ///   - outerSession: The outer libssh2 session (used only for
    ///     `libssh2_session_last_errno` diagnostics; may be nil in tests).
    ///   - outerSessionMutex: The mutex shared with `SSHSession` to serialize
    ///     all outer-session libssh2 access. Required for the production path;
    ///     pass `SessionMutex()` in tests that don't touch a real session.
    static func makeForChannel(
        channel: OpaquePointer,
        outerSession: OpaquePointer?,
        outerSessionMutex: any TeleportSessionMutex
    ) -> SSHProxySubsystemTransport {
        // A standalone cancellation token (NOT the transport) captured by the
        // channel I/O closures. This avoids a retain cycle: the closures are
        // stored on the transport, so capturing the transport itself would
        // pin it forever. The token is a small Sendable class that the
        // transport flips via cancelPumpSync().
        let cancelToken = PumpCancelToken()
        // Sentinel returned from inside `withLock` when the token is already
        // cancelled. libssh2 never returns this from a read/write (it collides
        // with neither EOF (0) nor an error), and both closures map it back to
        // 0 so the pump loops exit via their EOF/closed-channel paths instead
        // of touching a freed session.
        let cancelledReturn = Int.min
        let transportLog = Logger.forCategory("SSH-Proxy-Subsystem-Pump")
        let transport = SSHProxySubsystemTransport(
            channelRead: { buf, maxLen in
                // Retry on EAGAIN until data arrives, EOF, a hard error, or
                // cancellation. A small usleep prevents a busy-spin while the
                // channel has no data. The libssh2 call is guarded by the
                // outer-session mutex (see class doc) — the EAGAIN sleep is
                // outside the lock so a backpressured channel doesn't stall
                // keepalives or the FD->channel loop.
                //
                // The cancel token is re-checked *inside* the mutex (same
                // discipline as the agent service's closures): the teardown
                // flips the token and then frees the outer session under this
                // mutex, so a call that just passed the token check cannot
                // race the free. Cancellation surfaces to the pump loop as
                // EOF (0), which wakes the pump FD and exits the loop.
                var eagainSpins = 0
                while true {
                    if Task.isCancelled { return 0 }
                    let n = outerSessionMutex.withLock { () -> Int in
                        guard !cancelToken.isCancelled else { return cancelledReturn }
                        return libssh2_channel_read_ex(channel, 0, buf, maxLen)
                    }
                    if n == cancelledReturn { return 0 }  // EOF — pump loop exits
                    if n == LIBSSH2_ERROR_EAGAIN {
                        eagainSpins += 1
                        if eagainSpins == 1_000 {
                            transportLog.info("proxy_subsystem_channel_read_eagain_spin spins=\(eagainSpins)")
                        }
                        usleep(1_000)  // 1ms — non-blocking retry
                        continue
                    }
                    if n > 0 {
                        transportLog.info("proxy_subsystem_channel_read_first_bytes count=\(n) spins=\(eagainSpins)")
                    }
                    // n > 0: bytes read. n == 0: EOF. n < 0 (other): hard error
                    // (map to EOF so the pump closes the pumpFD and the inner
                    // session sees EOF rather than hanging).
                    return n < 0 ? 0 : n
                }
            },
            channelWrite: { buf, len in
                // Same guard-inside-the-mutex discipline as `channelRead`:
                // re-check the token under the outer-session mutex before the
                // libssh2 call, then surface cancellation to the pump loop as
                // a closed channel (0), which makes it exit.
                var eagainSpins = 0
                while true {
                    if Task.isCancelled { return 0 }
                    let n = outerSessionMutex.withLock { () -> Int in
                        guard !cancelToken.isCancelled else { return cancelledReturn }
                        return libssh2_channel_write_ex(channel, 0, buf, len)
                    }
                    if n == cancelledReturn { return 0 }  // closed — loop exits
                    if n == LIBSSH2_ERROR_EAGAIN {
                        eagainSpins += 1
                        if eagainSpins == 1_000 {
                            transportLog.info("proxy_subsystem_channel_write_eagain_spin spins=\(eagainSpins)")
                        }
                        usleep(1_000)  // 1ms — non-blocking retry
                        continue
                    }
                    if n > 0 {
                        transportLog.info("proxy_subsystem_channel_write_first_bytes count=\(n) spins=\(eagainSpins)")
                    }
                    return n < 0 ? 0 : n
                }
            },
            cancelToken: cancelToken
        )
        return transport
    }
}

/// Host-side conformance: `SSHSession` stores the bridge through the
/// package-movable `TeleportChannelTransport` seam.
extension SSHProxySubsystemTransport: TeleportChannelTransport {}

/// The live `TeleportChannelTransportFactory` over the libssh2 channel
/// bridge. Stateless; the defaulted `SSHClient.teleportTransportFactory`
/// value, so the seam is genuinely exercised on the production path.
struct SSHProxySubsystemTransportFactory: TeleportChannelTransportFactory {
    func makeChannelTransport(
        channel: OpaquePointer,
        outerSession: OpaquePointer?,
        mutex: any TeleportSessionMutex
    ) -> any TeleportChannelTransport {
        SSHProxySubsystemTransport.makeForChannel(
            channel: channel,
            outerSession: outerSession,
            outerSessionMutex: mutex
        )
    }
}

#endif // canImport(Darwin)
