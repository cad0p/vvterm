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

    // MARK: - Server KEX_INIT parser

    /// Build a synthetic SSH banner + KEX_INIT chunk matching RFC 4253 §6/§7.1
    /// so the parser can be validated without a live Teleport server.
    private static func makeKexInitChunk(
        banner: String = "SSH-2.0-Teleport",
        kex: String = "curve25519-sha256,curve25519-sha256@libssh.org",
        hostkey: String = "ssh-ed25519,rsa-sha2-256,rsa-sha2-512",
        cryptC2S: String = "aes128-gcm@openssh.com,aes256-gcm@openssh.com",
        cryptS2C: String = "aes128-gcm@openssh.com,aes256-gcm@openssh.com",
        macC2S: String = "hmac-sha2-256-etm@openssh.com",
        macS2C: String = "hmac-sha2-256-etm@openssh.com",
        compC2S: String = "none,zlib@openssh.com",
        compS2C: String = "none,zlib@openssh.com"
    ) -> Data {
        var payloadBody = Data()
        payloadBody.append(20) // SSH_MSG_KEXINIT
        payloadBody.append(contentsOf: [UInt8](repeating: 0, count: 16)) // cookie
        for list in [kex, hostkey, cryptC2S, cryptS2C, macC2S, macS2C, compC2S, compS2C] {
            appendNameList(&payloadBody, list)
        }
        // languages_c2s + languages_s2c (empty name-lists)
        appendNameList(&payloadBody, "")
        appendNameList(&payloadBody, "")
        // first_kex_packet_follows (false) + reserved (uint32)
        payloadBody.append(0)
        payloadBody.append(contentsOf: [0, 0, 0, 0])
        // Pad so (packet_length_field + padding_length_byte + payloadBody +
        // padding) is a multiple of the block size (8 for the no-cipher
        // phase), with at least 4 bytes of padding (RFC 4253 §6).
        // packet_length = 1 (padding_len byte) + payloadBody.count + padding.
        let blockSize = 8
        let paddingMin = 4
        let fixedOverhead = 4 + 1 + payloadBody.count // packet_length + padding_len + payloadBody
        var paddingLength = blockSize - (fixedOverhead % blockSize)
        if paddingLength < paddingMin { paddingLength += blockSize }
        let packetLength = UInt32(1 + payloadBody.count + paddingLength)
        var packet = Data()
        appendUInt32BE(&packet, packetLength)
        packet.append(UInt8(paddingLength))
        packet.append(payloadBody)
        packet.append(contentsOf: [UInt8](repeating: 0, count: paddingLength))
        var chunk = Data()
        chunk.append(contentsOf: Array("\(banner)\r\n".utf8))
        chunk.append(packet)
        return chunk
    }

    private static func appendNameList(_ data: inout Data, _ list: String) {
        let bytes = Array(list.utf8)
        appendUInt32BE(&data, UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    private static func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    @Test
    func parseServerKexInitExtractsAlgorithmNameLists() throws {
        // A correctly-formed banner + KEX_INIT must yield all eight
        // algorithm name-lists the server offered. This is the diagnostic
        // path that surfaces "what Teleport offered" next to "what libssh2
        // offered" when a KEX mismatch is reported live.
        let chunk = Self.makeKexInitChunk()
        let parsed = try #require(SSHTLSTransport.parseServerKexInit(chunk))
        #expect(parsed.kex == "curve25519-sha256,curve25519-sha256@libssh.org")
        #expect(parsed.hostkey == "ssh-ed25519,rsa-sha2-256,rsa-sha2-512")
        #expect(parsed.cryptC2S == "aes128-gcm@openssh.com,aes256-gcm@openssh.com")
        #expect(parsed.cryptS2C == "aes128-gcm@openssh.com,aes256-gcm@openssh.com")
        #expect(parsed.macC2S == "hmac-sha2-256-etm@openssh.com")
        #expect(parsed.macS2C == "hmac-sha2-256-etm@openssh.com")
        #expect(parsed.compC2S == "none,zlib@openssh.com")
        #expect(parsed.compS2C == "none,zlib@openssh.com")
    }

    @Test
    func parseServerKexInitReturnsNilForUnexpectedMessageType() {
        // If the first packet after the banner is not SSH_MSG_KEXINIT (20)
        // the parser must return nil so the pump logs a skip reason rather
        // than mis-parsing a different message as algorithm name-lists.
        var chunk = Self.makeKexInitChunk()
        // Banner ends right before the packet_length; the msg-type byte is
        // at offset (banner.len + \r\n) + 4 (packet_length) + 1 (padding_len).
        let bannerEnd = "SSH-2.0-Teleport\r\n".utf8.count
        let msgTypeOffset = bannerEnd + 4 + 1
        chunk[msgTypeOffset] = 21 // not 20
        #expect(SSHTLSTransport.parseServerKexInit(chunk) == nil)
    }

    @Test
    func parseServerKexInitReturnsNilForTruncatedChunk() {
        // A chunk that ends inside the packet_length field must return nil
        // (pump logs `truncated_packet_length`) rather than reading past the
        // buffer.
        let full = Self.makeKexInitChunk()
        let bannerEnd = "SSH-2.0-Teleport\r\n".utf8.count
        let truncated = full.prefix(bannerEnd + 2) // only 2 of 4 length bytes
        #expect(SSHTLSTransport.parseServerKexInit(Data(truncated)) == nil)
    }

    @Test
    func parseServerKexInitHandlesEmptyNameLists() throws {
        // Some servers (or a misconfigured Teleport) may offer an empty
        // name-list for a category. The parser must return "" for that
        // field and keep parsing the rest, so the log shows the gap.
        let chunk = Self.makeKexInitChunk(
            kex: "curve25519-sha256",
            hostkey: "", // server offers no hostkey algorithms
            cryptC2S: "aes128-gcm@openssh.com"
        )
        let parsed = try #require(SSHTLSTransport.parseServerKexInit(chunk))
        #expect(parsed.kex == "curve25519-sha256")
        #expect(parsed.hostkey == "")
        #expect(parsed.cryptC2S == "aes128-gcm@openssh.com")
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
