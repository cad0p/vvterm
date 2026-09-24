// SPDX-License-Identifier: MIT
//
//  SSHTLSTransport.swift
//  VVTerm
//
//  TLS+ALPN transport for Teleport SSH on port 443 (TLS Routing, RFD 39).
//
//  Teleport proxies (default since Teleport 13) multiplex all client
//  protocols on port 443 behind a single TLS listener. SSH is reached via
//  the ALPN protocol `teleport-proxy-ssh` *inside* a TLS tunnel:
//
//      VVTerm ──TLS(ALPN=teleport-proxy-ssh)──▶ Teleport proxy :443
//                                              └─▶ SSH service
//
//  libssh2 expects a raw file descriptor it can read()/write() on. Network
//  framework's `NWConnection` is stream-based and exposes no FD, so this
//  transport bridges the two with a socketpair + a bidirectional pump:
//
//      libssh2  ──read/write──  libssh2FD  ──┐
//                                            │  socketpair (AF_UNIX, SOCK_STREAM)
//      NWConnection  ──send/receive──  pumpFD ─┘
//                                            ▲
//                                            └── pump task forwards bytes both ways
//
//  TLS verification: the proxy presents a *host identity* certificate
//  signed by the cluster's Host CA — the TLS-routing model from RFD 39 /
//  RFD 123, matching tsh's `configureTLS` and the ALPN listener serving the
//  proxy host identity. The Host CA x509 certs captured at Phase 1 bootstrap
//  (`host_signers[].tls_certs`) are the only trust anchors: the leaf must
//  chain to them, carry a SAN matching the dial host (or
//  `teleport.cluster.local`), and negotiate the `teleport-proxy-ssh` ALPN.
//  User authentication *inside* the tunnel is the SSH certificate (this leg
//  carries no client cert).
//
//  This chain validates against the real cluster: `SecTrustEvaluateWithError`
//  succeeds with the Host CA anchored (verified against teleport.pcad.it,
//  2026-09-21), and `TeleportTLSTrust` evaluates an explicit SSL policy per
//  candidate name. Earlier revisions did not evaluate the certificate chain
//  on this leg; that gap is closed — a self-signed or foreign-CA leaf now
//  fails the handshake.
//

#if canImport(Network)
import Darwin
import Foundation
import Network
import Security
import os.log
import os

/// A TLS+ALPN transport that exposes a raw FD for libssh2.
///
/// Created with a host/port + the cluster name + cluster CA PEMs (captured
/// at Phase 1 bootstrap and persisted in `TeleportKeyRing`). `connect()`
/// dials the TLS connection, starts the socketpair pump, and returns the
/// libssh2-facing FD. `close()` tears down the pump + NWConnection + FDs.
///
/// Scoped to `.faceIDTeleport`: the non-Teleport SSH path keeps using
/// `SSHAddressConnector` (raw TCP).
actor SSHTLSTransport {

    /// The ALPN protocol Teleport's proxy routes SSH over on port 443.
    /// See Teleport RFD 39 (TLS Routing).
    static let alpnProtocol = "teleport-proxy-ssh"

    /// The ALPN protocols offered to the TLS listener. Only the SSH route is
    /// offered: the verify block requires `teleport-proxy-ssh`, so an `h2`
    /// fallback could only ever negotiate into a rejection.
    static let offeredALPNProtocols: [String] = [alpnProtocol]

    /// The result of creating the socketpair bridge.
    struct SocketPair: Sendable {
        let libssh2FD: Int32
        let pumpFD: Int32
    }

    private let host: String
    private let port: Int
    private let clusterName: String
    private let clusterCAPEMs: [String]

    private var connection: NWConnection?
    private var socketPair: SocketPair?
    private var pumpTask: Task<Void, Never>?
    /// Single owner of the pump end's fd. Six paths can race to close it (the
    /// three `pumpNWToFD` exits, `runPump`'s cleanup, `close()`, and the
    /// handshake-failure path); routing them all through one guard is what
    /// keeps the fd from being closed twice. See `PumpFDCloser`.
    private var pumpFDCloser: PumpFDCloser?

    private let logger: Logger
    private nonisolated let logging: any TeleportLogging

    init(host: String,
         port: Int,
         clusterName: String,
         clusterCAPEMs: [String],
         logging: any TeleportLogging) {
        self.host = host
        self.port = port
        self.clusterName = clusterName
        self.clusterCAPEMs = clusterCAPEMs
        self.logging = logging
        self.logger = logging.logger(category: "SSH-TLS-Transport")
    }

    // MARK: - TLS options (static, testable)

    /// Build `NWProtocolTLS.Options` for the Teleport proxy SSH ALPN route.
    ///
    /// - ALPN: `teleport-proxy-ssh` only
    /// - SNI: the dial host
    /// - Server verification: the cluster Host CA certs as the only trust
    ///   anchors, the cert evaluated against the dial host /
    ///   `teleport.cluster.local`, and the negotiated ALPN required to be
    ///   `teleport-proxy-ssh`.
    ///
    /// - Throws: if the cluster name / dial host is empty, or no usable
    ///   trust anchor can be built from the supplied PEMs (fail closed —
    ///   never fall back to the system roots).
    static func makeTLSOptions(
        clusterName: String,
        clusterCAPEMs: [String],
        dialHost: String,
        logger: Logger
    ) throws -> NWProtocolTLS.Options {
        guard !clusterName.isEmpty else {
            throw TeleportPackageError.connectionFailed("SSHTLSTransport: empty cluster name")
        }
        guard !dialHost.isEmpty else {
            throw TeleportPackageError.connectionFailed("SSHTLSTransport: empty dial host")
        }

        let tlsOpts = NWProtocolTLS.Options()
        let secOpts = tlsOpts.securityProtocolOptions

        // ALPN: offer teleport-proxy-ssh (the verify block accepts this or
        // no negotiated ALPN — see TeleportTLSTrust).
        for proto in offeredALPNProtocols {
            proto.withCString { cStr in
                sec_protocol_options_add_tls_application_protocol(secOpts, cStr)
            }
        }

        // SNI: the dial host (e.g. teleport.pcad.it). The gRPC path encodes
        // the cluster name hex into the SNI (teleport-auth@<hex>.teleport-
        // cluster.local) because the auth service is an ALPN SNI route. The
        // SSH proxy ALPN route uses the dial host directly (matching `tsh`'s
        // SSH dial — Network.framework also derives SNI from NWEndpoint.host,
        // but setting it explicitly on the TLS options is belt-and-suspenders).
        dialHost.withCString { cStr in
            sec_protocol_options_set_tls_server_name(secOpts, cStr)
        }

        // Server verification: the cluster Host CA certs are the only
        // anchors; the trust is evaluated against explicit SSL policies for
        // the expected names and accepted only when the negotiated ALPN is
        // the SSH route (or absent — Teleport ≤ v16 does not echo it).
        let anchors = TeleportTLSTrust.anchors(fromPEMs: clusterCAPEMs)
        guard !anchors.isEmpty else {
            throw TeleportPackageError.connectionFailed(
                "SSHTLSTransport: no usable cluster CA trust anchors (input \(clusterCAPEMs.count) PEMs)"
            )
        }
        let serverNames = TeleportTLSTrust.sshServerNames(dialHost: dialHost)
        sec_protocol_options_set_verify_block(
            secOpts,
            TeleportTLSTrust.makeVerifyBlock(
                anchors: anchors,
                serverNames: serverNames,
                allowedALPNs: [alpnProtocol],
                logger: logger
            ),
            .global()
        )

        return tlsOpts
    }

    /// Create a connected socketpair for the NWConnection <-> libssh2 bridge.
    ///
    /// Both ends are full-duplex `AF_UNIX` `SOCK_STREAM` sockets. The
    /// libssh2 end is handed to `libssh2_session_handshake(session, fd)`;
    /// the pump end is read/written by the pump coroutine. The caller owns
    /// both FDs and must `close()` them.
    ///
    /// - Returns: a `SocketPair` with two valid (>= 0) FDs.
    /// - Throws: `TeleportPackageError.connectionFailed` if `socketpair(2)` fails.
    static func makeSocketPair() throws -> SocketPair {
        var fds: [Int32] = [0, 0]
        // SOCK_STREAM is an Int32 constant on Darwin (not an option-set),
        // so no .rawValue.
        let result = Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        guard result == 0, fds[0] >= 0, fds[1] >= 0 else {
            throw TeleportPackageError.connectionFailed("SSHTLSTransport: socketpair failed (errno \(errno))")
        }
        // Non-blocking ends: the libssh2 session runs in non-blocking mode
        // (EAGAIN-loop handshake + non-blocking I/O) and the pump loops
        // handle EAGAIN with cooperative yields. A blocking fd would let
        // recv()/write() pin a cooperative-pool thread (pool exhaustion
        // stalls the pumps — the teleport-e2e socketpair-KEX stall).
        for fd in fds {
            let flags = Darwin.fcntl(fd, F_GETFL, 0)
            if flags >= 0 {
                _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            }
        }
        return SocketPair(libssh2FD: fds[0], pumpFD: fds[1])
    }

    // MARK: - Connect

    /// Dial the TLS connection, start the pump, and return the libssh2 FD.
    ///
    /// The returned FD is owned by the transport — `close()` closes it.
    /// The caller must NOT `close()` the FD directly.
    func connect() async throws -> Int32 {
        let tlsOpts = try Self.makeTLSOptions(
            clusterName: clusterName,
            clusterCAPEMs: clusterCAPEMs,
            dialHost: host,
            logger: logger
        )

        let params = NWParameters(tls: tlsOpts)

        let hostPort = NWEndpoint.Port(rawValue: UInt16(port))
        guard let hostPort else {
            throw TeleportPackageError.connectionFailed("SSHTLSTransport: invalid port \(port)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: hostPort)
        let connection = NWConnection(to: endpoint, using: params)
        self.connection = connection

        // Create the socketpair + start the pump before connecting, so the
        // libssh2 FD is valid as soon as connect() returns (or fails, in
        // which case close() cleans it up).
        let pair = try Self.makeSocketPair()
        self.socketPair = pair

        logger.info(
            "tls_transport_connect host=\(self.host, privacy: .public) port=\(self.port) alpn=\(Self.alpnProtocol, privacy: .public) libssh2FD=\(pair.libssh2FD) pumpFD=\(pair.pumpFD) ca_certs=\(self.clusterCAPEMs.count)"
        )

        // Start the NWConnection (state machine + queue).
        connection.start(queue: .global(qos: .userInitiated))

        // Start the bidirectional pump BEFORE waiting for `.ready`.
        //
        // The Teleport proxy sends its SSH banner (`SSH-2.0-Teleport-...`)
        // immediately after the TLS handshake completes. If the pump's first
        // `NWConnection.receive` is not already posted when that banner
        // arrives, the bytes sit in NWConnection's internal buffer and — in
        // the prior ordering (pump started after `.ready`) — libssh2's
        // `read()` on the libssh2FD (the session is non-blocking) could race
        // the pump's first receive, causing an immediate KEX_FAILURE (`-5:
        // Unable to exchange encryption keys`) because libssh2 saw no server
        // banner.
        //
        // Posting the pump's receive loop before `.ready` guarantees the
        // NWConnection is being drained from the instant data is available,
        // and libssh2's banner (written to libssh2FD) is forwarded to the
        // server as soon as the TLS tunnel is up.
        let pumpFDCloser = PumpFDCloser()
        self.pumpFDCloser = pumpFDCloser
        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runPump(
                connection: connection,
                pair: pair,
                pumpFDCloser: pumpFDCloser,
                logger: self.logging.logger(category: "SSH-TLS-Pump")
            )
        }

        // Wait for the connection to be ready (TLS handshake complete).
        do {
            try await waitForReady(connection: connection)
        } catch {
            // TLS handshake failed — clean up the socketpair + NWConnection
            // so no FDs leak.
            logger.error("tls_transport_connect_failed host=\(self.host, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            pumpTask?.cancel()
            pumpTask = nil
            connection.cancel()
            self.connection = nil
            Darwin.close(pair.libssh2FD)
            pumpFDCloser.closeOnce(pair.pumpFD)
            socketPair = nil
            self.pumpFDCloser = nil
            throw TeleportPackageError.connectionFailed("TLS transport connect failed: \(error.localizedDescription)")
        }

        return pair.libssh2FD
    }

    // MARK: - Close

    /// Tear down the transport: stop the pump, cancel the NWConnection,
    /// and close the pump end of the socketpair. The libssh2-facing FD is
    /// NOT closed here — it is owned by `SSHSession`'s `AtomicSocket`
    /// (which closes it after `libssh2_session_free`), because libssh2
    /// reads/writes that FD directly. Closing it here would double-close.
    ///
    /// Safe to call multiple times.
    func close() {
        pumpTask?.cancel()
        pumpTask = nil
        connection?.cancel()
        connection = nil
        if let pair = socketPair {
            // Close only the pump end, through the single-owner guard: the
            // pump loops may already have closed it. The libssh2FD is left
            // open for `AtomicSocket.close()`.
            pumpFDCloser?.closeOnce(pair.pumpFD)
            pumpFDCloser = nil
            socketPair = nil
        }
        logger.info("tls_transport_close host=\(self.host, privacy: .public)")
    }

    // MARK: - Pump internals

    /// Wait for the NWConnection to reach `.ready` (TLS handshake done).
    private func waitForReady(connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // OSAllocatedUnfairLock is Sendable; the stateUpdateHandler
            // closure runs on an arbitrary queue, so a Sendable lock avoids
            // the captured-var concurrency warning.
            let resumed = OSAllocatedUnfairLock(initialState: false)

            connection.stateUpdateHandler = { state in
                // Diagnose stalls: log every transition (esp. .waiting —
                // sandbox-denied paths sit there forever).
                switch state {
                case .waiting(let error):
                    self.logger.error("tls_conn_waiting error=\(String(describing: error), privacy: .public)")
                case .ready:
                    self.logger.info("tls_conn_ready")
                case .failed(let error):
                    self.logger.error("tls_conn_failed error=\(String(describing: error), privacy: .public)")
                case .cancelled:
                    self.logger.info("tls_conn_cancelled")
                default:
                    break
                }
                switch state {
                case .ready:
                    let already = resumed.withLock { isResumed -> Bool in
                        if isResumed { return true }
                        isResumed = true
                        return false
                    }
                    if !already { continuation.resume() }
                case .failed(let error):
                    let already = resumed.withLock { isResumed -> Bool in
                        if isResumed { return true }
                        isResumed = true
                        return false
                    }
                    if !already { continuation.resume(throwing: error) }
                case .cancelled:
                    let already = resumed.withLock { isResumed -> Bool in
                        if isResumed { return true }
                        isResumed = true
                        return false
                    }
                    if !already {
                        continuation.resume(throwing: TeleportPackageError.connectionFailed("TLS transport cancelled"))
                    }
                default:
                    break
                }
            }
        }
    }

    /// The bidirectional pump. Two loops run concurrently:
    ///   - NWConnection -> pumpFD: receive from NWConnection, write to pumpFD.
    ///   - pumpFD -> NWConnection: read from pumpFD, send via NWConnection.
    ///
    /// Both loops exit when either side hits EOF or errors, then close the
    /// pump end so libssh2's reads on the libssh2FD return EOF. The
    /// libssh2FD itself is closed by `AtomicSocket` (it owns that end);
    /// the pump never closes libssh2FD to avoid racing FD reuse.
    ///
    /// Both socketpair ends are `O_NONBLOCK`, so no thread can be blocked in
    /// `read(pumpFD)`; the shared `PumpFDCloser`'s `shutdown`+`close` neither
    /// deadlocks nor changes the pump's exit path.
    ///
    /// `nonisolated` so the pump's `read()`/`write()` syscalls on the pump FD
    /// (O_NONBLOCK; EAGAIN yields) run on the detached task's thread without
    /// hopping onto the actor (which would serialize + stall the pump).
    nonisolated private func runPump(
        connection: NWConnection,
        pair: SocketPair,
        pumpFDCloser: PumpFDCloser,
        logger pumpLog: Logger
    ) async {
        pumpLog.info("pump_start libssh2FD=\(pair.libssh2FD) pumpFD=\(pair.pumpFD)")
        await withTaskGroup(of: Void.self) { group in
            // NWConnection -> pumpFD
            group.addTask {
                await self.pumpNWToFD(connection: connection, pumpFD: pair.pumpFD, pumpFDCloser: pumpFDCloser, log: pumpLog)
            }
            // pumpFD -> NWConnection
            group.addTask {
                await self.pumpFDToNW(pumpFD: pair.pumpFD, connection: connection, log: pumpLog)
            }
            // When either loop exits, cancel the other and close the pump end
            // so libssh2's reads on libssh2FD return EOF. The loops close it
            // on their own EOF/error paths too; `PumpFDCloser` makes the
            // second close a no-op instead of an fd-reuse hazard.
            await group.next()
            group.cancelAll()
            pumpFDCloser.closeOnce(pair.pumpFD)
            connection.cancel()
        }
    }

    /// NWConnection -> pumpFD: receive bytes, write them to the pump FD for
    /// libssh2 to read. Loops until receive returns nil (EOF/error).
    nonisolated private func pumpNWToFD(
        connection: NWConnection,
        pumpFD: Int32,
        pumpFDCloser: PumpFDCloser,
        log: Logger
    ) async {
        var nwToFDBytes: Int = 0
        while !Task.isCancelled {
            // NWConnection.receive has only a completion-handler form; bridge
            // it to async via a continuation. The completion is @Sendable.
            let received: Data?
            do {
                received = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, _, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: content)
                        }
                    }
                }
            } catch {
                // NWConnection receive error — EOF or reset. Close the pump
                // FD so libssh2 sees the broken connection.
                log.error("pump_nw_to_fd_error bytes=\(nwToFDBytes) error=\(String(describing: error), privacy: .public)")
                pumpFDCloser.closeOnce(pumpFD)
                return
            }
            guard let data = received, !data.isEmpty else {
                // EOF.
                log.info("pump_nw_to_fd_eof bytes=\(nwToFDBytes)")
                pumpFDCloser.closeOnce(pumpFD)
                return
            }
            nwToFDBytes += data.count
            if nwToFDBytes == data.count {
                // First bytes delivered to libssh2 (the server banner or
                // proxy response) — the handshake is progressing.
                log.info("pump_nw_to_fd_first_bytes count=\(data.count) total=\(nwToFDBytes)")
            }
            // Write all bytes to the pump FD (may need multiple writes),
            // yielding on EAGAIN so a full socketpair buffer never pins a
            // cooperative-pool thread.
            if !(await writeAllToPumpFD(fd: pumpFD, data: data)) {
                // Write error (EPIPE / EBADF) — pump FD is broken.
                log.error("pump_nw_to_fd_write_fail errno=\(Darwin.errno)")
                pumpFDCloser.closeOnce(pumpFD)
                return
            }
        }
        log.info("pump_nw_to_fd_cancelled bytes=\(nwToFDBytes)")
    }

    /// pumpFD -> NWConnection: read bytes from the pump FD (written by
    /// libssh2), send them via the NWConnection. Loops until read returns
    /// EOF or the task is cancelled. Reads never hard-block: the fd is
    /// O_NONBLOCK and EAGAIN yields via `Task.sleep`, so the cooperative
    /// pool thread stays available to the other pump loop + handshake loop.
    nonisolated private func pumpFDToNW(pumpFD: Int32, connection: NWConnection, log: Logger) async {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buffer.deallocate() }
        var fdToNWBytes: Int = 0
        while !Task.isCancelled {
            let n = Darwin.read(pumpFD, buffer, 64 * 1024)
            if n > 0 {
                let data = Data(bytes: buffer, count: n)
                fdToNWBytes += n
                if fdToNWBytes == n {
                    // First bytes from libssh2 (its banner) — the handshake is
                    // writing; the pump must forward them to the server.
                    log.info("pump_fd_to_nw_first_bytes count=\(n) total=\(fdToNWBytes)")
                }
                // NWConnection.send has only a completion-handler form. Bridge to
                // async + treat the completion error as a stop signal.
                let sendError: NWError? = await withCheckedContinuation { (continuation: CheckedContinuation<NWError?, Never>) in
                    connection.send(content: data, completion: .contentProcessed { error in
                        continuation.resume(returning: error)
                    })
                }
                if sendError != nil {
                    // NWConnection send error — stop.
                    log.error("pump_fd_to_nw_send_error bytes=\(fdToNWBytes) error=\(String(describing: sendError), privacy: .public)")
                    return
                }
            } else if n == 0 {
                // EOF — stop sending.
                log.info("pump_fd_to_nw_eof_or_err ret=0 bytes=\(fdToNWBytes)")
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                // No bytes yet — yield so the pool thread serves the other
                // pump loop + the handshake loop.
                try? await Task.sleep(nanoseconds: 5_000_000)
            } else {
                // Hard error — stop sending.
                log.info("pump_fd_to_nw_eof_or_err ret=\(n) errno=\(Darwin.errno) bytes=\(fdToNWBytes)")
                return
            }
        }
        log.info("pump_fd_to_nw_cancelled bytes=\(fdToNWBytes)")
    }

    /// Write all bytes to `fd`, yielding on EAGAIN (O_NONBLOCK socketpair)
    /// so a full buffer never pins a cooperative-pool thread.
    /// Returns false on EOF/error.
    nonisolated private func writeAllToPumpFD(fd: Int32, data: Data) async -> Bool {
        var written = 0
        while written < data.count {
            let n = data.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return Darwin.write(fd, base.advanced(by: written), data.count - written)
            }
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

#endif // canImport(Network)
