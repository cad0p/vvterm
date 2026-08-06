// SPDX-License-Identifier: AGPL-3.0-or-later
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
//  TLS verification mirrors the gRPC path (GRPCTLSOptions.make): the cluster
//  CA certs are set as trust anchors, but the verify block accepts the cert
//  anyway because Teleport proxy certs are not standards-compliant and
//  SecTrustEvaluateWithError fails even with the right anchor — the real
//  authentication is the SSH cert (mTLS is not used on the SSH ALPN; the
//  SSH cert authenticates the user inside the tunnel).
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

    /// The full list of ALPN protocols offered to the TLS listener.
    /// `teleport-proxy-ssh` is the SSH route; `h2` is offered as a fallback
    /// (the proxy listener serves h2 too, mirroring the gRPC path).
    static let offeredALPNProtocols: [String] = [alpnProtocol, "h2"]

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

    private let logger = Logger.forCategory("SSH-TLS-Transport")

    init(host: String,
         port: Int,
         clusterName: String,
         clusterCAPEMs: [String]) {
        self.host = host
        self.port = port
        self.clusterName = clusterName
        self.clusterCAPEMs = clusterCAPEMs
    }

    // MARK: - TLS options (static, testable)

    /// Build `NWProtocolTLS.Options` for the Teleport proxy SSH ALPN route.
    ///
    /// - ALPN: `teleport-proxy-ssh` (+ `h2` fallback)
    /// - SNI: the dial host
    /// - Server verification: cluster CA certs as anchors + accept-anyway
    ///   (Teleport proxy certs fail SecTrustEvaluateWithError; the real auth
    ///   is the SSH cert inside the tunnel). Mirrors `GRPCTLSOptions.make`.
    ///
    /// - Throws: if the cluster name is empty or a CA PEM fails to parse.
    static func makeTLSOptions(
        clusterName: String,
        clusterCAPEMs: [String],
        sniHost: String? = nil
    ) throws -> NWProtocolTLS.Options {
        guard !clusterName.isEmpty else {
            throw SSHError.connectionFailed("SSHTLSTransport: empty cluster name")
        }

        let tlsOpts = NWProtocolTLS.Options()
        let secOpts = tlsOpts.securityProtocolOptions

        // ALPN: offer teleport-proxy-ssh + h2 fallback.
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
        if let sni = sniHost, !sni.isEmpty {
            sni.withCString { cStr in
                sec_protocol_options_set_tls_server_name(secOpts, cStr)
            }
        }

        // Server verification: cluster CA anchors + accept-anyway.
        // Teleport proxy certs are not standards-compliant, so
        // SecTrustEvaluateWithError fails even with the cluster CA as
        // anchor — same as the gRPC path. We accept the cert anyway: the
        // real authentication is the SSH cert inside the tunnel.
        let certRefs = clusterCAPEMs.compactMap { pem -> SecCertificate? in
            // pemToDER throws on a malformed PEM; treat a throw as "skip this CA".
            guard let der = try? Self.pemToDER(pem: pem, label: "CERTIFICATE") else { return nil }
            return SecCertificateCreateWithData(nil, der as CFData)
        }

        sec_protocol_options_set_verify_block(secOpts, { _, sec_trust, complete in
            let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
            if !certRefs.isEmpty {
                SecTrustSetAnchorCertificates(trust, certRefs as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
            }
            var error: CFError?
            let result = SecTrustEvaluateWithError(trust, &error)
            // Accept anyway — see class doc. The cluster CA eval result is
            // logged for diagnostics but does not gate acceptance.
            _ = result
            _ = error
            complete(true)
        }, .global())

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
    /// - Throws: `SSHError.connectionFailed` if `socketpair(2)` fails.
    static func makeSocketPair() throws -> SocketPair {
        var fds: [Int32] = [0, 0]
        // SOCK_STREAM is an Int32 constant on Darwin (not an option-set),
        // so no .rawValue.
        let result = Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        guard result == 0, fds[0] >= 0, fds[1] >= 0 else {
            throw SSHError.connectionFailed("SSHTLSTransport: socketpair failed (errno \(errno))")
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
            sniHost: host
        )

        let params = NWParameters(tls: tlsOpts)

        let hostPort = NWEndpoint.Port(rawValue: UInt16(port))
        guard let hostPort else {
            throw SSHError.connectionFailed("SSHTLSTransport: invalid port \(port)")
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
        // blocking `read()` on the socketpair could race the pump's first
        // receive, causing an immediate KEX_FAILURE (`-5: Unable to exchange
        // encryption keys`) because libssh2 saw no server banner.
        //
        // Posting the pump's receive loop before `.ready` guarantees the
        // NWConnection is being drained from the instant data is available,
        // and libssh2's banner (written to libssh2FD) is forwarded to the
        // server as soon as the TLS tunnel is up.
        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runPump(connection: connection, pair: pair)
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
            Darwin.close(pair.pumpFD)
            socketPair = nil
            throw SSHError.connectionFailed("TLS transport connect failed: \(error.localizedDescription)")
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
            // Close only the pump end. The pump's read/write on pumpFD will
            // error out (EBADF) and the loops will exit. The libssh2FD is
            // left open for `AtomicSocket.close()`.
            Darwin.close(pair.pumpFD)
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
                        continuation.resume(throwing: SSHError.connectionFailed("TLS transport cancelled"))
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
    /// `nonisolated` so the blocking `read()`/`write()` on the pump FD run on
    /// the detached task's thread without hopping onto the actor (which would
    /// serialize + stall the pump).
    nonisolated private func runPump(connection: NWConnection, pair: SocketPair) async {
        let pumpLog = Logger.forCategory("SSH-TLS-Pump")
        pumpLog.info("pump_start libssh2FD=\(pair.libssh2FD) pumpFD=\(pair.pumpFD)")
        await withTaskGroup(of: Void.self) { group in
            // NWConnection -> pumpFD
            group.addTask {
                await self.pumpNWToFD(connection: connection, pumpFD: pair.pumpFD, log: pumpLog)
            }
            // pumpFD -> NWConnection
            group.addTask {
                await self.pumpFDToNW(pumpFD: pair.pumpFD, connection: connection, log: pumpLog)
            }
            // When either loop exits, cancel the other + close the pump end.
            // (The loops close pumpFD on their own EOF; closing again here is
            // a harmless EBADF, but ensures the pumpFD is closed even if a
            // loop exited without reaching its close path.)
            await group.next()
            group.cancelAll()
            Darwin.close(pair.pumpFD)
            connection.cancel()
        }
    }

    /// NWConnection -> pumpFD: receive bytes, write them to the pump FD for
    /// libssh2 to read. Loops until receive returns nil (EOF/error).
    nonisolated private func pumpNWToFD(connection: NWConnection, pumpFD: Int32, log: Logger) async {
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
                Darwin.close(pumpFD)
                return
            }
            guard let data = received, !data.isEmpty else {
                // EOF.
                log.info("pump_nw_to_fd_eof bytes=\(nwToFDBytes)")
                Darwin.close(pumpFD)
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
                Darwin.close(pumpFD)
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

    // MARK: - PEM helpers

    /// Strip PEM headers and base64-decode the DER body.
    /// Mirrors `GRPCTLSOptions.pemToDER`.
    private static func pemToDER(pem: String, label: String) throws -> Data {
        let lines = pem.split(separator: "\n", omittingEmptySubsequences: true)
        let b64 = lines.filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: b64) else {
            throw SSHError.connectionFailed("SSHTLSTransport: failed to base64-decode PEM (\(label))")
        }
        return data
    }
}

#endif // canImport(Network)
