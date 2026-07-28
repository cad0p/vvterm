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
//  construction, and the socketpair plumbing — all deterministic and
//  requiring no live Teleport server (a real TLS handshake against the
//  proxy is covered by live-device validation).
//

#if canImport(Network)
import Darwin
import Foundation
import Network
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
        // cluster name + at least one CA PEM. Mirrors the gRPC path's
        // GRPCTLSOptions.make (cluster CA + accept-anyway verify block).
        let opts = try SSHTLSTransport.makeTLSOptions(
            clusterName: "teleport.pcad.it",
            clusterCAPEMs: [Self.sampleCAPEM]
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
                clusterCAPEMs: [Self.sampleCAPEM]
            )
        }
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

    /// A throwaway self-signed CA PEM (content is irrelevant — the verify
    /// block accepts anyway, mirroring the gRPC path). Must be a valid
    /// PEM envelope so the DER parse in makeTLSOptions succeeds.
    static let sampleCAPEM: String = """
-----BEGIN CERTIFICATE-----
MIIBnzCCAUWgAwIBAgIRAOJ9Z9FqQ2pBb6rFQ3p3qPcwCgYIKoZIzj0EAwIwGTEX
MBUGA1UEChMOdHZ0ZXJtLXRlc3QtY2EwHhcNMjQwMTAxMDAwMDAwWhcNMzQwMTAx
MDAwMDAwWjAZMRcwFQYDVQQKEw50dnRlcm0tdGVzdC1jYTBZMBMGByqGSM49AgEG
CCqGSM49AwEHA0IABBMm9iW2p1rJ0RH9eMehxVjV0Yq3pIQE0l5BWFq8X5mZpGn
2j9p3oq9bE6jQ3p3qPcwXjQgD9aZ9FqQ2pBb6rFQ3p3qPcwSjBIMEGA1UdDgQ8
BBYk9iW2p1rJ0RH9eMehxVjV0Yq3pIQLBgNVHSMEGDAWgBYk9iW2p1rJ0RH9eMe
hxVjV0Yq3pIQAwCgYIKoZIzj0EAwIDSAAwRQIgIh7Z9FqQ2pBb6rFQ3p3qPcwXj
QgD9aZ9FqQ2pBb6rFQ3p3qPcwXjQgD9aZ9FqQ2pBb6rFQ3p3qPcw
-----END CERTIFICATE-----
"""
}

#endif // canImport(Network)
