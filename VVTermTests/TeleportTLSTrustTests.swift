// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportTLSTrustTests.swift
//  VVTermTests
//
//  Verification tests for the Teleport ALPN server-certificate trust.
//
//  Fixtures:
//    - Fixtures/hostca-x509.pem   real pcad.it Host CA x509 (captured 2026-09-21)
//    - Fixtures/proxy-leaf.der    real live ALPN `teleport-proxy-ssh` leaf
//    - Fixtures/loopback-tls/     generated test CA + leaves (see README)
//
//  The real live leaf is evaluated with `SecTrustSetVerifyDate` pinned to the
//  capture date so the test never ages out.
//

#if canImport(Network)
import Foundation
import Network
import Security
import Testing
@testable import VVTerm

struct TeleportTLSTrustTests {

    /// Capture instant of the real fixtures (2026-09-21T15:33Z).
    static let captureDate = Date(timeIntervalSince1970: 1_790_004_826)

    // MARK: - Happy paths

    @Test
    func generatedCAAndLeafVerifyForSSHRoute() throws {
        let leaf = try Self.certificate("server.pem")
        let ca = try Self.certificate("loopback-ca.pem")
        let trust = try Self.trust(leaf: leaf)
        Self.pin(trust, to: Self.captureDate)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "localhost"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            requiredALPN: SSHTLSTransport.alpnProtocol
        )
        #expect(result.ok, "expected the fixture CA/leaf to verify: \(String(describing: result.error))")
    }

    @Test
    func realLiveLeafVerifiesAgainstRealHostCA() throws {
        let leaf = try Self.derCertificate("proxy-leaf.der")
        let ca = try Self.certificate("hostca-x509.pem")
        let trust = try Self.trust(leaf: leaf)
        Self.pin(trust, to: Self.captureDate)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "teleport.pcad.it"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            requiredALPN: SSHTLSTransport.alpnProtocol
        )
        #expect(result.ok, "the live proxy leaf must verify against the captured Host CA: \(String(describing: result.error))")
    }

    @Test
    func realLiveLeafVerifiesForAuthRouteName() throws {
        // The proxy leaf carries a `*.teleport.cluster.local` TLS SAN, so the
        // encoded auth route name used by the gRPC leg must match.
        let leaf = try Self.derCertificate("proxy-leaf.der")
        let ca = try Self.certificate("hostca-x509.pem")
        let trust = try Self.trust(leaf: leaf)
        Self.pin(trust, to: Self.captureDate)

        let encodedCluster = TeleportTLSTrust.encodedClusterName("teleport.pcad.it")
        let expectedALPN = "teleport-auth@\(encodedCluster)"
        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.authServerNames(clusterName: "teleport.pcad.it"),
            negotiatedALPN: expectedALPN,
            requiredALPN: expectedALPN
        )
        #expect(result.ok, "expected the live leaf to match the encoded auth route name: \(String(describing: result.error))")
    }

    @Test
    func realLiveLeafIsRejectedForWrongName() throws {
        // The real leaf is long-lived, so the SSL policy takes the BasicX509
        // + SAN fallback; a name that is not covered by the SANs must still
        // be rejected.
        let leaf = try Self.derCertificate("proxy-leaf.der")
        let ca = try Self.certificate("hostca-x509.pem")
        let trust = try Self.trust(leaf: leaf)
        Self.pin(trust, to: Self.captureDate)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: ["not-teleport.pcad.it"],
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            requiredALPN: SSHTLSTransport.alpnProtocol
        )
        #expect(!result.ok)
    }

    @Test
    func sanMatchingHandlesWildcardsAndIPs() throws {
        let leaf = try Self.derCertificate("proxy-leaf.der")
        #expect(TeleportTLSTrust.certificate(leaf, matchesName: "teleport.pcad.it"))
        #expect(TeleportTLSTrust.certificate(leaf, matchesName: "foo.teleport.cluster.local"))
        #expect(TeleportTLSTrust.certificate(leaf, matchesName: "127.0.0.1"))
        #expect(TeleportTLSTrust.certificate(leaf, matchesName: "::1"))
        #expect(!TeleportTLSTrust.certificate(leaf, matchesName: "a.b.teleport.cluster.local"))
        #expect(!TeleportTLSTrust.certificate(leaf, matchesName: "teleport.cluster.local.evil.com"))
        #expect(!TeleportTLSTrust.certificate(leaf, matchesName: "not-teleport.pcad.it"))
    }

    // MARK: - Chain failures

    @Test
    func foreignCAIsRejected() throws {
        // The real proxy leaf anchored to the loopback test CA (a foreign CA).
        let leaf = try Self.derCertificate("proxy-leaf.der")
        let ca = try Self.certificate("loopback-ca.pem")
        let trust = try Self.trust(leaf: leaf)
        Self.pin(trust, to: Self.captureDate)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "teleport.pcad.it"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            requiredALPN: SSHTLSTransport.alpnProtocol
        )
        #expect(!result.ok)
    }

    @Test
    func selfSignedLeafIsRejected() throws {
        let leaf = try Self.certificate("self-signed.pem")
        let ca = try Self.certificate("loopback-ca.pem")
        let trust = try Self.trust(leaf: leaf)
        Self.pin(trust, to: Self.captureDate)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "localhost"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            requiredALPN: SSHTLSTransport.alpnProtocol
        )
        #expect(!result.ok)
    }

    @Test
    func expiredLeafIsRejected() throws {
        let leaf = try Self.certificate("server-expired.pem")
        let ca = try Self.certificate("loopback-ca.pem")
        let trust = try Self.trust(leaf: leaf)
        Self.pin(trust, to: Self.captureDate)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "localhost"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            requiredALPN: SSHTLSTransport.alpnProtocol
        )
        #expect(!result.ok)
    }

    @Test
    func wrongNameIsRejected() throws {
        let leaf = try Self.certificate("server-wrongname.pem")
        let ca = try Self.certificate("loopback-ca.pem")
        let trust = try Self.trust(leaf: leaf)
        Self.pin(trust, to: Self.captureDate)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "teleport.pcad.it"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            requiredALPN: SSHTLSTransport.alpnProtocol
        )
        #expect(!result.ok)
    }

    @Test
    func basicX509PolicyTrustIsStillRejectedForWrongName() throws {
        // Network.framework does not document the policy attached to its
        // trust. The verifier must not trust that policy (a BasicX509 policy
        // accepts any Host-CA chain). Build a trust with BasicX509 and a
        // wrong-name cert; the verifier must still reject.
        let leaf = try Self.certificate("server-wrongname.pem")
        let ca = try Self.certificate("loopback-ca.pem")
        let trust = try Self.trust(leaf: leaf, policy: SecPolicyCreateBasicX509())
        Self.pin(trust, to: Self.captureDate)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "teleport.pcad.it"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            requiredALPN: SSHTLSTransport.alpnProtocol
        )
        #expect(!result.ok)
    }

    @Test
    func emptyAnchorsAreRejected() throws {
        let leaf = try Self.certificate("server.pem")
        let trust = try Self.trust(leaf: leaf)
        Self.pin(trust, to: Self.captureDate)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "localhost"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            requiredALPN: SSHTLSTransport.alpnProtocol
        )
        #expect(!result.ok)
    }

    // MARK: - ALPN enforcement

    @Test
    func h2ALPNIsRejected() throws {
        let result = try Self.happyPathResult(negotiatedALPN: "h2")
        #expect(!result.ok)
    }

    @Test
    func nilALPNIsRejected() throws {
        let result = try Self.happyPathResult(negotiatedALPN: nil)
        #expect(!result.ok)
    }

    @Test
    func authALPNIsRejectedOnTheSSHRoute() throws {
        let encodedCluster = TeleportTLSTrust.encodedClusterName("ci-cluster")
        let result = try Self.happyPathResult(
            negotiatedALPN: "teleport-auth@\(encodedCluster)"
        )
        #expect(!result.ok)
    }

    // MARK: - Anchor parsing

    @Test
    func anchorsDedupeAndSkipMalformedEntries() throws {
        let caPEM = try Self.fixtureString("loopback-tls/loopback-ca.pem")
        let anchors = TeleportTLSTrust.anchors(fromPEMs: [
            caPEM,
            caPEM,
            "not a pem at all",
            "-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----",
        ])
        #expect(anchors.count == 1)
    }

    @Test
    func anchorsAreEmptyForMalformedInput() {
        #expect(TeleportTLSTrust.anchors(fromPEMs: ["not a pem", "-----BEGIN CERTIFICATE-----\n!!!\n-----END CERTIFICATE-----"]).isEmpty)
    }

    // MARK: - Names

    @Test
    func sshServerNamesIncludeDialHostAndClusterLocal() {
        #expect(TeleportTLSTrust.sshServerNames(dialHost: "teleport.pcad.it") == ["teleport.pcad.it", "teleport.cluster.local"])
    }

    @Test
    func authServerNamesUseTheEncodedClusterName() {
        let names = TeleportTLSTrust.authServerNames(clusterName: "ci-cluster")
        let hex = "ci-cluster".utf8.map { String(format: "%02x", $0) }.joined()
        #expect(names == ["\(hex).teleport.cluster.local", "teleport.cluster.local"])
    }

    // MARK: - Helpers

    private static func happyPathResult(negotiatedALPN: String?) throws -> (ok: Bool, error: CFError?) {
        let leaf = try certificate("server.pem")
        let ca = try certificate("loopback-ca.pem")
        let trust = try trust(leaf: leaf)
        pin(trust, to: captureDate)
        return TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "localhost"),
            negotiatedALPN: negotiatedALPN,
            requiredALPN: SSHTLSTransport.alpnProtocol
        )
    }

    private static func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Features/Teleport/Fixtures/\(relativePath)")
    }

    private static func fixtureString(_ relativePath: String) throws -> String {
        try String(contentsOf: fixtureURL(relativePath), encoding: .utf8)
    }

    private static func certificate(_ relativePath: String) throws -> SecCertificate {
        // Loopback TLS fixtures live in `Fixtures/loopback-tls/`; the real
        // Host CA / leaf fixtures live directly in `Fixtures/`.
        let resolved = FileManager.default.fileExists(atPath: fixtureURL(relativePath).path)
            ? relativePath
            : "loopback-tls/\(relativePath)"
        let pem = try fixtureString(resolved)
        let der = try TeleportTLSTrust.pemToDER(pem: pem, label: "CERTIFICATE")
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TeleportTLSTrustError.malformedPEM(resolved)
        }
        return certificate
    }

    private static func derCertificate(_ relativePath: String) throws -> SecCertificate {
        let der = try Data(contentsOf: fixtureURL(relativePath))
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TeleportTLSTrustError.malformedPEM(relativePath)
        }
        return certificate
    }

    private static func trust(leaf: SecCertificate, policy: SecPolicy? = nil) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            [leaf] as CFArray,
            policy ?? SecPolicyCreateBasicX509(),
            &trust
        )
        guard status == errSecSuccess, let trust else {
            throw TeleportTLSTrustError.malformedPEM("SecTrustCreateWithCertificates OSStatus \(status)")
        }
        return trust
    }

    private static func pin(_ trust: SecTrust, to date: Date) {
        SecTrustSetVerifyDate(trust, date as CFDate)
    }
}

#endif // canImport(Network)
