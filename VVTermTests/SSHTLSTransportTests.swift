// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  SSHTLSTransportTests.swift
//  VVTermTests
//
//  TDD coverage for the Teleport TLS+ALPN SSH transport.
//
//  Teleport proxies running TLS Routing (default since Teleport 13) host
//  SSH on port 443 behind a TLS listener that negotiates the ALPN protocol
//  `teleport-proxy-ssh` before forwarding bytes to the SSH service. A raw
//  TCP socket to port 443 receives TLS bytes (ServerHello), not an SSH
//  banner, so `libssh2_session_handshake` fails immediately.
//
//  `SSHTLSTransport` bridges `NWConnection` (TLS + ALPN) to libssh2 via a
//  socketpair + pump. These tests verify the ALPN string, the TLS options
//  construction, the socketpair plumbing, and the server-certificate
//  verification through a real in-process loopback TLS listener
//  (`LoopbackTLSServer` + the test-only identities under
//  `Fixtures/loopback-tls/`).
//

#if canImport(Network)
import Darwin
import Foundation
import Network
import Security
import Testing
@testable import VVTerm

struct SSHTLSTransportTests {

    // MARK: - ALPN

    @Test
    func alpnProtocolIsTeleportProxySSH() {
        // RFD 39: SSH on port 443 is reached via ALPN `teleport-proxy-ssh`
        // inside the TLS tunnel. Asserting the constant keeps a typo (e.g.
        // `teleport-proxy` or `teleport-ssh`) from silently breaking the
        // live dial with an opaque handshake failure.
        #expect(SSHTLSTransport.alpnProtocol == "teleport-proxy-ssh")
    }

    @Test
    func offeredALPNProtocolsContainsTeleportProxySSH() {
        // The TLS options offered to NWConnection must include the
        // teleport-proxy-ssh ALPN so the proxy's TLS listener routes the
        // connection to the SSH service.
        let offered = SSHTLSTransport.offeredALPNProtocols
        #expect(offered.contains("teleport-proxy-ssh"))
    }

    @Test
    func makeTLSOptionsBuildsWithoutThrowing() throws {
        // Building the NWProtocolTLS.Options must succeed with a non-empty
        // cluster name, a dial host, and at least one parseable CA PEM.
        let opts = try SSHTLSTransport.makeTLSOptions(
            clusterName: "teleport.pcad.it",
            clusterCAPEMs: [try Self.loopbackCAPEM],
            dialHost: "teleport.pcad.it"
        )
        // The options object is non-nil (would throw on failure). We can't
        // introspect sec_protocol_options ALPN directly, but construction
        // succeeding + the offered-ALPN list (above) covers the wiring.
        _ = opts
    }

    @Test
    func makeTLSOptionsThrowsForEmptyClusterName() {
        #expect(throws: (any Error).self) {
            try SSHTLSTransport.makeTLSOptions(
                clusterName: "",
                clusterCAPEMs: [try Self.loopbackCAPEM],
                dialHost: "teleport.pcad.it"
            )
        }
    }

    @Test
    func makeTLSOptionsThrowsForEmptyDialHost() {
        #expect(throws: (any Error).self) {
            try SSHTLSTransport.makeTLSOptions(
                clusterName: "teleport.pcad.it",
                clusterCAPEMs: [try Self.loopbackCAPEM],
                dialHost: ""
            )
        }
    }

    @Test
    func makeTLSOptionsFailsClosedWhenNoAnchorParses() {
        // A non-empty CA input whose PEMs are all malformed must throw — never
        // fall back to the system trust store.
        #expect(throws: (any Error).self) {
            try SSHTLSTransport.makeTLSOptions(
                clusterName: "teleport.pcad.it",
                clusterCAPEMs: ["not a pem", "-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----"],
                dialHost: "teleport.pcad.it"
            )
        }
        #expect(throws: (any Error).self) {
            try SSHTLSTransport.makeTLSOptions(
                clusterName: "teleport.pcad.it",
                clusterCAPEMs: [],
                dialHost: "teleport.pcad.it"
            )
        }
    }

    // MARK: - Loopback TLS handshake (real listener)

    @Test
    func loopbackHandshakeSucceedsForFixtureCA() async throws {
        let identity = try LoopbackTLSServerTestSupport.identity(named: "server.p12")
        let server = try LoopbackTLSServer(
            identity: identity,
            alpnProtocols: [SSHTLSTransport.alpnProtocol, "h2"]
        )
        defer { server.stop() }

        let transport = Self.transport(server: server, caPEM: Self.loopbackCAPEMUnchecked)
        let fd = try await transport.connect()
        await transport.close()
        #expect(fd >= 0)
        Darwin.close(fd)
    }

    @Test
    func loopbackHandshakeFailsForSelfSignedIdentity() async throws {
        // The listener presents a self-signed cert; the client only anchors
        // the fixture CA — the handshake must fail (no accept-anyway).
        let identity = try LoopbackTLSServerTestSupport.identity(named: "self-signed.p12")
        let server = try LoopbackTLSServer(
            identity: identity,
            alpnProtocols: [SSHTLSTransport.alpnProtocol, "h2"]
        )
        defer { server.stop() }

        let transport = Self.transport(server: server, caPEM: Self.loopbackCAPEMUnchecked)
        await Self.expectConnectThrows(transport)
    }

    @Test
    func loopbackHandshakeFailsForWrongNameIdentity() async throws {
        // CA-signed but no matching name: the SSL policy must reject it.
        let identity = try LoopbackTLSServerTestSupport.identity(named: "server-wrongname.p12")
        let server = try LoopbackTLSServer(
            identity: identity,
            alpnProtocols: [SSHTLSTransport.alpnProtocol, "h2"]
        )
        defer { server.stop() }

        let transport = Self.transport(server: server, caPEM: Self.loopbackCAPEMUnchecked)
        await Self.expectConnectThrows(transport)
    }

    @Test
    func loopbackHandshakeFailsForH2OnlyServer() async throws {
        // An HTTP edge that terminates TLS and negotiates h2 must not be
        // accepted for the SSH route.
        let identity = try LoopbackTLSServerTestSupport.identity(named: "server.p12")
        let server = try LoopbackTLSServer(identity: identity, alpnProtocols: ["h2"])
        defer { server.stop() }

        let transport = Self.transport(server: server, caPEM: Self.loopbackCAPEMUnchecked)
        await Self.expectConnectThrows(transport)
    }

    // MARK: - Socketpair plumbing

    @Test
    func makeSocketPairReturnsTwoValidFDs() throws {
        // The transport bridges NWConnection <-> libssh2 via a socketpair.
        // Both ends must be valid file descriptors (>= 0). The libssh2 end
        // is handed to `libssh2_session_handshake(session, fd)`; the pump
        // end is read/written by the pump coroutine.
        let pair = try SSHTLSTransport.makeSocketPair()
        defer {
            Darwin.close(pair.libssh2FD)
            Darwin.close(pair.pumpFD)
        }
        #expect(pair.libssh2FD >= 0)
        #expect(pair.pumpFD >= 0)
        // The two ends must be distinct FDs.
        #expect(pair.libssh2FD != pair.pumpFD)
    }

    @Test
    func socketPairIsBidirectional() throws {
        // Writes to one end of the socketpair must be readable from the
        // other end. This is the foundation of the pump: NWConnection
        // receive → write to pumpFD → libssh2 reads from libssh2FD, and
        // libssh2 writes to libssh2FD → pump reads from pumpFD →
        // NWConnection send.
        let pair = try SSHTLSTransport.makeSocketPair()
        defer {
            Darwin.close(pair.libssh2FD)
            Darwin.close(pair.pumpFD)
        }

        // libssh2FD → pumpFD
        var out: UInt8 = 0xAB
        let written1 = write(pair.libssh2FD, &out, 1)
        #expect(written1 == 1)
        var in1: UInt8 = 0
        let read1 = read(pair.pumpFD, &in1, 1)
        #expect(read1 == 1)
        #expect(in1 == 0xAB)

        // pumpFD → libssh2FD
        var out2: UInt8 = 0xCD
        let written2 = write(pair.pumpFD, &out2, 1)
        #expect(written2 == 1)
        var in2: UInt8 = 0
        let read2 = read(pair.libssh2FD, &in2, 1)
        #expect(read2 == 1)
        #expect(in2 == 0xCD)
    }

    // MARK: - Helpers

    private static func transport(server: LoopbackTLSServer, caPEM: String) -> SSHTLSTransport {
        SSHTLSTransport(
            host: "127.0.0.1",
            port: Int(server.port),
            clusterName: "ci-cluster",
            clusterCAPEMs: [caPEM]
        )
    }

    private static func expectConnectThrows(_ transport: SSHTLSTransport) async {
        var didThrow = false
        do {
            let fd = try await transport.connect()
            Darwin.close(fd)
        } catch {
            didThrow = true
        }
        await transport.close()
        #expect(didThrow, "expected the loopback TLS handshake to fail")
    }

    /// The generated test CA PEM (`Fixtures/loopback-tls/loopback-ca.pem`).
    static let loopbackCAPEMUnchecked: String = {
        (try? LoopbackTLSServerTestSupport.pemString("loopback-tls/loopback-ca.pem")) ?? ""
    }()

    static var loopbackCAPEM: String {
        get throws {
            try LoopbackTLSServerTestSupport.pemString("loopback-tls/loopback-ca.pem")
        }
    }
}

#endif // canImport(Network)
