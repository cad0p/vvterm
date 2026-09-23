// SPDX-License-Identifier: MIT
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

    /// 2026-10-01T00:00:00Z — inside the public-chain fixture leaf's validity
    /// (2026-09-04 → 2026-11-27); pinned so the fixture cannot age out.
    static let publicChainVerifyDate = Date(timeIntervalSince1970: 1_790_812_800)

    /// 2026-09-21T23:36:39Z — inside the short-lived EKU fixture leaf's
    /// 30-day validity window.
    static let shortLivedEKUVerifyDate = Date(timeIntervalSince1970: 1_790_033_799)

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
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
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
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
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
            allowedALPNs: [expectedALPN, "h2"]
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
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
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
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
        )
        #expect(!result.ok)
    }

    /// The pinned anchors must be exclusive of the system trust store. The
    /// fixture is a live public chain (www.google.com → GTS WR2) that
    /// validates against the system roots, so it is the only test shape that
    /// distinguishes "anchors added" from "anchors only": if
    /// `SecTrustSetAnchorCertificatesOnly(true)` were dropped, the system
    /// store would be added back and this chain would pass.
    @Test
    func pinnedAnchorsAreExclusiveOfTheSystemStore() throws {
        let leaf = try Self.certificate("public-chain/google-leaf.pem")
        let intermediate = try Self.certificate("public-chain/google-intermediate.pem")
        let pinnedCA = try Self.certificate("loopback-ca.pem")
        let trust = try Self.trust(chain: [leaf, intermediate])
        Self.pin(trust, to: Self.publicChainVerifyDate)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [pinnedCA],
            serverNames: ["www.google.com"],
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
        )
        #expect(
            !result.ok,
            "a system-trusted chain must not pass when only the pinned Host CA is an allowed anchor"
        )
    }

    /// A short-lived leaf whose EKU allows only clientAuth must be rejected
    /// on the primary SSL-policy path (not just by the long-lived fallback).
    @Test
    func shortLivedClientAuthOnlyLeafIsRejectedOnThePrimaryPath() throws {
        let leaf = try Self.certificate("short-lived-eku/clientauth-leaf.pem")
        let ca = try Self.certificate("short-lived-eku/ca.pem")
        let trust = try Self.trust(leaf: leaf)
        Self.pin(trust, to: Self.shortLivedEKUVerifyDate)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: ["localhost"],
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
        )
        #expect(!result.ok, "a clientAuth-only leaf must be rejected even when short-lived")
    }

    /// Positive control for the fixture CA: the same CA's serverAuth leaf
    /// verifies, proving the rejection above is EKU-specific.
    @Test
    func shortLivedServerAuthLeafStillVerifies() throws {
        let leaf = try Self.certificate("short-lived-eku/serverauth-leaf.pem")
        let ca = try Self.certificate("short-lived-eku/ca.pem")
        let trust = try Self.trust(leaf: leaf)
        Self.pin(trust, to: Self.shortLivedEKUVerifyDate)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: ["localhost"],
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
        )
        #expect(result.ok, "the serverAuth control leaf must verify: \(String(describing: result.error))")
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
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
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
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
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
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
        )
        #expect(!result.ok)
    }

    // MARK: - Long-lived-cert fallback: EKU / keyUsage enforcement

    /// The long-lived fallback is the production path for the real cluster
    /// leaf, so its BasicX509 re-evaluation must still enforce the leaf's key
    /// purpose. A clientAuth-only leaf signed by the pinned CA must not be
    /// accepted for a TLS server role.
    @Test
    func longLivedClientAuthOnlyLeafIsRejected() throws {
        let leaf = try Self.certificate("longlived-clientauth.pem")
        let ca = try Self.certificate("longlived-ca.pem")
        let trust = try Self.trust(leaf: leaf)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "localhost"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
        )
        #expect(!result.ok, "a clientAuth-only leaf must not be accepted as a TLS server")
    }

    /// Same fallback path, but the leaf's keyUsage excludes digitalSignature.
    @Test
    func longLivedKeyEnciphermentOnlyLeafIsRejected() throws {
        let leaf = try Self.certificate("longlived-keyenc.pem")
        let ca = try Self.certificate("longlived-ca.pem")
        let trust = try Self.trust(leaf: leaf)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "localhost"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
        )
        #expect(!result.ok, "a keyEncipherment-only leaf must not be accepted as a TLS server")
    }

    /// Positive control: the same CA + a long-lived serverAuth leaf with
    /// digitalSignature still verifies, so the rejections above are the EKU /
    /// keyUsage rule, not the anchor or the fallback itself.
    @Test
    func longLivedServerAuthLeafStillVerifies() throws {
        let leaf = try Self.certificate("longlived-serverauth.pem")
        let ca = try Self.certificate("longlived-ca.pem")
        let trust = try Self.trust(leaf: leaf)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "localhost"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
        )
        #expect(result.ok, "a long-lived serverAuth leaf must still verify: \(String(describing: result.error))")
    }

    /// A CA certificate must not be accepted as the TLS server leaf, even
    /// when it carries a matching SAN and serverAuth EKU. The fixture is
    /// long-lived, so the BasicX509 + explicit-SAN fallback (the production
    /// path for the real cluster leaf) is the deciding evaluation.
    @Test
    func longLivedCAPresentedAsLeafIsRejected() throws {
        let leaf = try Self.certificate("longlived-ca-as-leaf.pem")
        let trust = try Self.trust(leaf: leaf)

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [leaf],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "localhost"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
        )
        #expect(!result.ok, "a CA certificate must not be accepted as a TLS leaf")
    }

    /// Precondition for the rejection above: the CA-as-leaf fixture is
    /// long-lived, so the SSL policy fails on the validity cap and `verify`
    /// reaches the BasicX509 + explicit-SAN fallback. Without the
    /// basicConstraints rule, that fallback would accept the certificate
    /// (matching SAN, serverAuth EKU, digitalSignature keyUsage).
    @Test
    func caPresentedAsLeafWouldPassTheOtherFallbackChecks() throws {
        let leaf = try Self.certificate("longlived-ca-as-leaf.pem")
        #expect(TeleportTLSTrust.certificate(leaf, matchesName: "localhost"))
        #expect(TeleportTLSTrust.certificateAllowsTLSServerUse(leaf))
        #expect(TeleportTLSTrust.certificateIsCA(leaf))

        let trust = try Self.trust(
            leaf: leaf,
            policy: SecPolicyCreateSSL(true, "localhost" as CFString)
        )
        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        #expect(!SecTrustEvaluateWithError(trust, &error))
        guard let error else {
            Issue.record("expected the SSL policy to fail with a validity-period error")
            return
        }
        #expect(CFErrorGetCode(error) == errSecCertificateValidityPeriodTooLong)
    }

    /// A short-lived CA-as-leaf certificate reaches the primary SSL-policy
    /// evaluation (not the validity-period fallback), so the CA-as-leaf rule
    /// must be enforced there too. The precondition pins that the platform's
    /// SSL policy accepts this fixture: `verify` is the deciding evaluation.
    @Test
    func shortLivedCAPresentedAsLeafIsRejectedOnThePrimaryPath() throws {
        let leaf = try Self.certificate("shortlived-ca-as-leaf.pem")
        let policyDate = Self.captureDate.addingTimeInterval(86_400)

        let preconditionTrust = try Self.trust(
            leaf: leaf,
            policy: SecPolicyCreateSSL(true, "localhost" as CFString)
        )
        Self.pin(preconditionTrust, to: policyDate)
        SecTrustSetAnchorCertificates(preconditionTrust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(preconditionTrust, true)
        var sslError: CFError?
        let sslAccepted = SecTrustEvaluateWithError(preconditionTrust, &sslError)
        #expect(
            sslAccepted,
            "precondition: the SSL policy accepts the short-lived CA fixture"
        )

        let trust = try Self.trust(leaf: leaf)
        Self.pin(trust, to: policyDate)
        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [leaf],
            serverNames: TeleportTLSTrust.sshServerNames(dialHost: "localhost"),
            negotiatedALPN: SSHTLSTransport.alpnProtocol,
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
        )
        #expect(!result.ok, "a CA certificate must not be accepted as a TLS leaf")
    }

    /// RFC 5280 forbids repeated extensions. A certificate with
    /// basicConstraints CA:TRUE followed by CA:FALSE must fail closed rather
    /// than let the later value mask the earlier one.
    @Test
    func duplicateRecognizedExtensionsFailClosed() throws {
        let valid = try Self.certificate("server.pem")
        #expect(TeleportTLSTrust.parseExtensions(der: SecCertificateCopyData(valid) as Data) != nil)

        let pem = try Self.fixtureString("loopback-tls/duplicate-basicconstraints.pem")
        let der = try TeleportTLSTrust.pemToDER(pem: pem, label: "CERTIFICATE")
        #expect(TeleportTLSTrust.parseExtensions(der: der) == nil)

        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(TeleportTLSTrust.certificateIsCA(certificate))
        #expect(!TeleportTLSTrust.certificateAllowsTLSServerUse(certificate))
    }

    // MARK: - DER walker strictness

    /// Positive control: the synthetic DER builder produces extensions the
    /// walker accepts, including the optional pathLenConstraint.
    @Test
    func syntheticBasicConstraintsFixturesParse() {
        let ca = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Self.tlv(0x01, Data([0xFF])))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: ca)?.basicConstraintsIsCA == true)

        let leaf = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Data())
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: leaf)?.basicConstraintsIsCA == false)

        let pathLen = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(
                0x30,
                Self.tlv(0x01, Data([0xFF])) + Self.tlv(0x02, Data([0x01]))
            )
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: pathLen)?.basicConstraintsIsCA == true)
    }

    /// Extensions are the final TBSCertificate component: a certificate with
    /// a field after the [3] extensions field must fail closed instead of
    /// silently ignoring the trailing component.
    @Test
    func tbsFieldAfterExtensionsFailsClosed() {
        let extensionElement = Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Data())
        )
        let extensions = Self.tlv(0x30, extensionElement)
        let extensionsField = Self.tlv(0xA3, extensions)
        let trailing = Self.tlv(0x0C, Data("x".utf8))
        let tbsCertificate = Self.tlv(0x30, extensionsField + trailing)
        let der = Self.tlv(0x30, tbsCertificate)
        #expect(TeleportTLSTrust.parseExtensions(der: der) == nil)
    }

    /// `SEQUENCE { BOOLEAN FALSE, BOOLEAN TRUE }` reads as non-CA to a
    /// first-element walker while another parser could read CA:TRUE; the
    /// extension must fail closed instead of deciding on the prefix.
    @Test
    func basicConstraintsWithTrailingBooleanFailsClosed() {
        let der = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(
                0x30,
                Self.tlv(0x01, Data([0x00])) + Self.tlv(0x01, Data([0xFF]))
            )
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: der) == nil)
    }

    /// A dangling tag byte after the recognized fields is not a clean end:
    /// the walker must not accept the successfully-read prefix.
    @Test
    func basicConstraintsWithDanglingTagFailsClosed() {
        let der = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(
                0x30,
                Self.tlv(0x01, Data([0x00])) + Data([0x82])
            )
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: der) == nil)
    }

    /// A truncated long-form length consumes the remaining bytes without
    /// producing an element; the walker must not treat that as a clean end.
    @Test
    func basicConstraintsWithTruncatedLongFormLengthFailsClosed() {
        let der = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(
                0x30,
                Self.tlv(0x01, Data([0x00])) + Data([0x82, 0x85])
            )
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: der) == nil)
    }

    /// The empty-sequence shortcut must also require a clean end: a malformed
    /// non-empty sequence whose first element cannot be read is not empty.
    @Test
    func basicConstraintsWithMalformedFirstElementFailsClosed() {
        let der = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Data([0x82]))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: der) == nil)
    }

    /// Positive controls for the strictness rules above: a well-formed empty
    /// basicConstraints sequence still parses as non-CA and a long-form
    /// length that fits is still accepted, so the rejections are the
    /// truncation rule and not the parser refusing valid encodings.
    @Test
    func wellFormedBasicConstraintsEncodingsStillParse() {
        let empty = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Data())
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: empty)?.basicConstraintsIsCA == false)

        // SEQUENCE { BOOLEAN FALSE, INTEGER 2 } with a short-form length is
        // covered above; exercise the long-form length path instead.
        let longForm = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(
                0x30,
                Self.tlv(0x01, Data([0xFF])) + Self.tlv(0x02, Data(repeating: 0x01, count: 0x82))
            )
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: longForm)?.basicConstraintsIsCA == true)
    }

    /// Trailing bytes after the outer Certificate SEQUENCE would be ignored
    /// by this walker while another parser could read them, so the DER entry
    /// point must fail closed.
    @Test
    func trailingBytesAfterCertificateSequenceFailClosed() {
        let certificate = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Data())
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: certificate)?.basicConstraintsIsCA == false)
        #expect(TeleportTLSTrust.parseExtensions(der: certificate + Data([0x00])) == nil)
    }

    /// DER requires the minimum number of length octets (X.690 §8.1.3.5): a
    /// long-form length that could be encoded shorter, or that carries a
    /// redundant leading zero octet, must fail closed.
    @Test
    func nonMinimalLongFormLengthFailsClosed() {
        let extensionElement = Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Data())
        )
        let extensions = Self.tlv(0x30, extensionElement)
        let extensionsField = Self.tlv(0xA3, extensions)
        let tbsCertificate = Self.tlv(0x30, extensionsField)

        // 0x81 NN encodes a length below 0x80 in long form.
        let longFormForShort = Data([0x30, 0x81, UInt8(tbsCertificate.count)]) + tbsCertificate
        #expect(TeleportTLSTrust.parseExtensions(der: longFormForShort) == nil)

        // 0x82 0x00 NN carries a redundant leading zero octet.
        let leadingZero = Data([0x30, 0x82, 0x00, UInt8(tbsCertificate.count)]) + tbsCertificate
        #expect(TeleportTLSTrust.parseExtensions(der: leadingZero) == nil)

        // Positive control: the same content with a minimal length parses.
        let minimal = Self.tlv(0x30, tbsCertificate)
        #expect(TeleportTLSTrust.parseExtensions(der: minimal)?.basicConstraintsIsCA == false)
    }

    /// pathLenConstraint must be a non-negative, minimally-encoded INTEGER:
    /// an empty, redundant-leading-zero, or negative encoding could be read
    /// differently by another parser, so it fails closed.
    @Test
    func nonMinimalPathLenConstraintFailsClosed() {
        let empty = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Self.tlv(0x01, Data([0xFF])) + Self.tlv(0x02, Data()))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: empty) == nil)

        let leadingZero = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Self.tlv(0x01, Data([0xFF])) + Self.tlv(0x02, Data([0x00, 0x01])))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: leadingZero) == nil)

        let negative = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Self.tlv(0x01, Data([0xFF])) + Self.tlv(0x02, Data([0xFF])))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: negative) == nil)

        // Positive controls: the minimal encodings of the same values parse.
        let minimalZero = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Self.tlv(0x01, Data([0xFF])) + Self.tlv(0x02, Data([0x00])))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: minimalZero)?.basicConstraintsIsCA == true)

        let minimalPositive = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Self.tlv(0x01, Data([0xFF])) + Self.tlv(0x02, Data([0x00, 0x80])))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: minimalPositive)?.basicConstraintsIsCA == true)
    }

    /// A pathLenConstraint without cA TRUE is not valid DER: the constraint
    /// is only defined when the cA boolean is asserted, so the walker must
    /// not accept it.
    @Test
    func pathLenConstraintWithoutCAFailsClosed() {
        let der = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Self.tlv(0x01, Data([0x00])) + Self.tlv(0x02, Data([0x01])))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: der) == nil)
    }

    /// A high-tag-number-form tag byte carries additional tag bytes this
    /// reader does not consume; misreading the next byte as a length must be
    /// impossible, so it fails closed.
    @Test
    func highTagNumberFormFailsClosed() {
        let der = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Self.tlv(0x01, Data([0x00])) + Data([0x9F, 0x01, 0x00]))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: der) == nil)
    }

    /// A non-canonical OID spelling of a recognized extension must fail
    /// closed rather than being skipped as unrecognized: a basicConstraints
    /// read as absent would let a CA act as a leaf.
    @Test
    func nonMinimalOIDFailsClosed() {
        // 2.5.29.19 with a redundant leading 0x80 group in the first
        // subidentifier.
        let der = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x80, 0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Self.tlv(0x01, Data([0xFF])))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: der) == nil)

        // Positive control: the canonical spelling still parses.
        let canonical = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Self.tlv(0x01, Data([0xFF])))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: canonical)?.basicConstraintsIsCA == true)
    }

    @Test
    func keyUsageWithTrailingElementFailsClosed() {
        let valid = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x0F],
            value: Self.tlv(0x03, Data([0x07, 0x80]))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: valid)?.keyUsageBits == [0x80])

        let trailing = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x0F],
            value: Self.tlv(0x03, Data([0x07, 0x80])) + Self.tlv(0x02, Data([0x01]))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: trailing) == nil)
    }

    @Test
    func subjectAltNameWithTrailingElementFailsClosed() {
        let names = Self.tlv(0x30, Self.tlv(0x82, Data("example.com".utf8)))
        let valid = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x11],
            value: names
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: valid)?.dnsNames == ["example.com"])

        let trailing = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x11],
            value: names + Self.tlv(0x02, Data([0x01]))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: trailing) == nil)
    }

    @Test
    func extendedKeyUsageWithTrailingElementFailsClosed() {
        let serverAuth = Self.tlv(0x06, Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]))
        let valid = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x25],
            value: Self.tlv(0x30, serverAuth)
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: valid)?.hasExtendedKeyUsage == true)

        let trailing = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x25],
            value: Self.tlv(0x30, serverAuth + Self.tlv(0x02, Data([0x01])))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: trailing) == nil)
    }

    @Test
    func recognizedExtensionWithTrailingFieldFailsClosed() {
        let der = Self.syntheticCertificate(extension: Self.extensionElement(
            oid: [0x55, 0x1D, 0x13],
            value: Self.tlv(0x30, Data()),
            trailing: Self.tlv(0x02, Data([0x01]))
        ))
        #expect(TeleportTLSTrust.parseExtensions(der: der) == nil)
    }

    /// A keyUsage extension with a set unused trailing bit is malformed DER
    /// and must fail the server-use check.
    @Test
    func keyUsageUnusedBitsAreValidated() throws {
        let leaf = try Self.certificate("server.pem")
        #expect(TeleportTLSTrust.certificateAllowsTLSServerUse(leaf))

        let der = SecCertificateCopyData(leaf) as Data
        guard let patchedDER = Self.patchingKeyUsageUnusedBit(in: der),
              let patched = SecCertificateCreateWithData(nil, patchedDER as CFData) else {
            Issue.record("could not build the malformed keyUsage fixture")
            return
        }
        #expect(!TeleportTLSTrust.certificateAllowsTLSServerUse(patched))
    }

    /// Precondition for the rejection tests above: the generated leaves are
    /// long-lived, so Apple's SSL policy fails with
    /// `errSecCertificateValidityPeriodTooLong` and `verify` takes the
    /// BasicX509 + explicit SAN fallback (the path under test).
    @Test
    func longLivedLeavesTakeTheValidityPeriodFallback() throws {
        let leaf = try Self.certificate("longlived-clientauth.pem")
        let ca = try Self.certificate("longlived-ca.pem")
        let trust = try Self.trust(
            leaf: leaf,
            policy: SecPolicyCreateSSL(true, "localhost" as CFString)
        )
        SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        #expect(!SecTrustEvaluateWithError(trust, &error))
        guard let error else {
            Issue.record("expected the SSL policy to fail with a validity-period error")
            return
        }
        #expect(CFErrorGetCode(error) == errSecCertificateValidityPeriodTooLong)
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
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
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
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
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
    func nilALPNIsAccepted() throws {
        // Teleport serves the SSH route's host certificate without a
        // `NextProtos` list before v17, so the server legitimately negotiates
        // no ALPN; the Host-CA chain + name remain the security gate.
        let result = try Self.happyPathResult(negotiatedALPN: nil)
        #expect(result.ok)
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

    /// Set the DER-forbidden trailing bit of the first keyUsage BIT STRING
    /// (the fixture's extension value is short-form). Returns nil when the
    /// extension cannot be located.
    private static func patchingKeyUsageUnusedBit(in der: Data) -> Data? {
        guard let oidRange = der.range(of: Data([0x55, 0x1D, 0x0F])) else { return nil }
        var index = oidRange.upperBound
        // Extension ::= SEQUENCE { OID, [BOOLEAN], OCTET STRING }
        if index < der.count, der[index] == 0x01 { index += 3 }
        guard index + 1 < der.count, der[index] == 0x04 else { return nil }
        let octetLength = Int(der[index + 1])
        let octetStart = index + 2
        guard octetLength >= 3, octetStart + octetLength <= der.count else { return nil }
        // Inside the OCTET STRING: BIT STRING ::= 03 len unused payload
        guard der[octetStart] == 0x03 else { return nil }
        let unusedIndex = octetStart + 2
        guard unusedIndex + 1 < octetStart + octetLength else { return nil }
        let unusedBits = der[unusedIndex]
        guard unusedBits > 0, unusedBits <= 7 else { return nil }
        var patched = der
        patched[unusedIndex + 1] |= UInt8((1 << Int(unusedBits)) - 1)
        return patched
    }

    /// Build a minimal certificate DER: Certificate ::= SEQUENCE { tbs } with
    /// the tbsCertificate carrying only the [3] extensions field the walker
    /// reads. The walker does not validate the other TBS fields.
    private static func syntheticCertificate(extension extensionElement: Data) -> Data {
        let extensions = tlv(0x30, extensionElement)
        let extensionsField = tlv(0xA3, extensions)
        let tbsCertificate = tlv(0x30, extensionsField)
        return tlv(0x30, tbsCertificate)
    }

    /// Extension ::= SEQUENCE { extnID OID, extnValue OCTET STRING, trailing }.
    private static func extensionElement(
        oid: [UInt8],
        value: Data,
        trailing: Data = Data()
    ) -> Data {
        tlv(0x30, tlv(0x06, Data(oid)) + tlv(0x04, value) + trailing)
    }

    private static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + derLength(content.count) + content
    }

    private static func derLength(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

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
            allowedALPNs: [SSHTLSTransport.alpnProtocol]
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

    private static func trust(chain: [SecCertificate], policy: SecPolicy? = nil) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            chain as CFArray,
            policy ?? SecPolicyCreateBasicX509(),
            &trust
        )
        guard status == errSecSuccess, let trust else {
            throw TeleportTLSTrustError.malformedPEM("SecTrustCreateWithCertificates OSStatus \(status)")
        }
        return trust
    }

    private static func trust(leaf: SecCertificate, policy: SecPolicy? = nil) throws -> SecTrust {
        try trust(chain: [leaf], policy: policy)
    }

    private static func pin(_ trust: SecTrust, to date: Date) {
        SecTrustSetVerifyDate(trust, date as CFDate)
    }
}

#endif // canImport(Network)
