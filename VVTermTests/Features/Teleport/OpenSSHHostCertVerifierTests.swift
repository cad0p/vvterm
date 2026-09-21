// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  OpenSSHHostCertVerifierTests.swift
//  VVTermTests
//
//  Fixture-driven coverage for the Host CA host-certificate verifier.
//
//  Fixtures (public material under Fixtures/OpenSSH/): an ed25519 Host CA,
//  host certs over ed25519 / ECDSA / RSA keys, a foreign-CA host cert, an
//  expired host cert, and a user cert. Tampered variants are produced at
//  test time by mutating the signature bytes.
//

#if DEBUG
import Foundation
import Testing
@testable import VVTerm

struct OpenSSHHostCertVerifierTests {

    /// 2027-01-01 — inside the fixture certs' 2026-01-01 → 2036-01-01 window.
    private static let validNow = Date(timeIntervalSince1970: 1_798_761_600)

    private static let caEd25519 = TeleportFixtureSupport
        .fixtureString("OpenSSH/ca_ed25519.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private static let caForeign = TeleportFixtureSupport
        .fixtureString("OpenSSH/ca_foreign.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private static let ed25519HostCert = TeleportFixtureSupport
        .fixtureString("OpenSSH/host-cert-ed25519.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private static let ecdsaHostCert = TeleportFixtureSupport
        .fixtureString("OpenSSH/host-cert-ecdsa.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private static let rsaHostCert = TeleportFixtureSupport
        .fixtureString("OpenSSH/host-cert-rsa.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private static let foreignHostCert = TeleportFixtureSupport
        .fixtureString("OpenSSH/host-cert-foreign.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private static let expiredHostCert = TeleportFixtureSupport
        .fixtureString("OpenSSH/host-cert-expired.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private static let userCert = TeleportFixtureSupport
        .fixtureString("OpenSSH/user-cert-ed25519.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    private static func blob(_ line: String) throws -> Data {
        guard let parsed = OpenSSHCertificate.parseAuthorizedKeysLine(line) else {
            throw TeleportFixtureSupportError.tlsKeyPairUnavailable
        }
        return parsed.blob
    }

    // MARK: - Happy paths

    @Test
    func verifiesEd25519HostCert() throws {
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(Self.ed25519HostCert),
            expectedPrincipals: ["testhost"],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .verified)
    }

    @Test
    func verifiesEcdsaHostCertSignedByEd25519CA() throws {
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(Self.ecdsaHostCert),
            expectedPrincipals: ["testhost"],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .verified)
    }

    @Test
    func verifiesRsaHostCertSignedByEd25519CA() throws {
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(Self.rsaHostCert),
            expectedPrincipals: ["other"],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .verified)
    }

    // MARK: - Failures

    @Test
    func rejectsCertFromAnUnpinnedCA() throws {
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(Self.foreignHostCert),
            expectedPrincipals: ["testhost"],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .noMatchingCAKey)
    }

    @Test
    func verifiesForeignCAWhenItIsPinned() throws {
        // Sanity: the foreign cert does verify against its own CA — the
        // previous failure is about pinning, not corruption.
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(Self.foreignHostCert),
            expectedPrincipals: ["testhost"],
            checkingKeys: [Self.caForeign],
            now: Self.validNow
        )
        #expect(result == .verified)
    }

    @Test
    func rejectsExpiredCert() throws {
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(Self.expiredHostCert),
            expectedPrincipals: ["testhost"],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .expired)
    }

    @Test
    func rejectsWrongPrincipal() throws {
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(Self.ed25519HostCert),
            expectedPrincipals: ["not-this-host"],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .principalMismatch)
    }

    @Test
    func rejectsEmptyExpectedPrincipals() throws {
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(Self.ed25519HostCert),
            expectedPrincipals: [],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .principalMismatch)
    }

    @Test
    func rejectsTamperedSignature() throws {
        var blob = try Self.blob(Self.ed25519HostCert)
        // The signature is the trailing SSH string; flipping the last byte
        // keeps the blob structurally parseable but invalidates the signature.
        blob[blob.count - 1] ^= 0xFF
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: blob,
            expectedPrincipals: ["testhost"],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .badSignature)
    }

    /// An authorized_keys CA blob is exactly string(type) + string(material):
    /// trailing bytes must not be ignored (another parser could read them), so
    /// the mutated CA must not match the cert's signature key.
    @Test
    func rejectsCheckingKeyBlobWithTrailingBytes() throws {
        let parts = Self.caEd25519.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        let mutatedBlob = try Self.blob(Self.caEd25519) + Data([0xAB])
        let mutatedLine = "\(parts[0]) \(mutatedBlob.base64EncodedString())"
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(Self.ed25519HostCert),
            expectedPrincipals: ["testhost"],
            checkingKeys: [mutatedLine],
            now: Self.validNow
        )
        #expect(result == .noMatchingCAKey)
    }

    /// A signature blob is exactly string(type) + string(signature): trailing
    /// bytes must invalidate the signature instead of being ignored.
    @Test
    func rejectsSignatureBlobWithTrailingBytes() throws {
        let parsed = try #require(OpenSSHCertificate.parse(blob: try Self.blob(Self.ed25519HostCert)))
        let tampered = parsed.signedData + OpenSSHCertificate.sshString(parsed.signatureBlob + Data([0x00]))
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: tampered,
            expectedPrincipals: ["testhost"],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .badSignature)
    }

    /// Empty expected principals are ignored, not treated as a wildcard: a
    /// real principal alongside one still matches.
    @Test
    func emptyExpectedPrincipalsAreIgnored() throws {
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(Self.ed25519HostCert),
            expectedPrincipals: ["", "testhost"],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .verified)
    }

    @Test
    func rejectsNonCertificateBlob() throws {
        let plain = TeleportFixtureSupport
            .fixtureString("OpenSSH/hostkey_ed25519.pub")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(plain),
            expectedPrincipals: ["testhost"],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .notACertificate)
    }

    @Test
    func rejectsUserCertificateAsHostCertificate() throws {
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(Self.userCert),
            expectedPrincipals: ["alice"],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .notACertificate)
    }

    @Test
    func rejectsMissingCheckingKeys() throws {
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: try Self.blob(Self.ed25519HostCert),
            expectedPrincipals: ["testhost"],
            checkingKeys: [],
            now: Self.validNow
        )
        #expect(result == .noMatchingCAKey)
    }

    @Test
    func reportsUnsupportedRsaCAKeyType() throws {
        // A structurally valid host cert whose signature key is an RSA
        // authorized_keys blob: the verifier finds the matching pinned key
        // but reports the unsupported CA type (fail closed).
        let rsaCA = TeleportFixtureSupport
            .fixtureString("OpenSSH/hostkey_rsa.pub")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rsaCABlob = try Self.blob(rsaCA)
        let certBlob = Self.syntheticHostCert(signatureKeyBlob: rsaCABlob)
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: certBlob,
            expectedPrincipals: ["testhost"],
            checkingKeys: [rsaCA],
            now: Self.validNow
        )
        #expect(result == .unsupportedCAKeyType("ssh-rsa"))
    }

    /// OpenSSH's "no expiry" encoding (`validBefore == 0`) is not acceptable
    /// for a host certificate: it must always be time-bounded.
    @Test
    func rejectsHostCertificateWithoutAnExpiry() throws {
        let certBlob = Self.syntheticHostCert(
            signatureKeyBlob: try Self.blob(Self.caEd25519),
            validBefore: 0
        )
        let result = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: certBlob,
            expectedPrincipals: ["testhost"],
            checkingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(result == .expired)
    }

    /// Oversized ECDSA signature components must be rejected, never truncated
    /// to 32 bytes; a legitimate leading zero byte still normalizes.
    @Test
    func ecdsaSignatureEncodingRejectsOversizedComponentsWithoutTruncating() {
        let oversizedR = Data([0x01]) + Data(repeating: 0x00, count: 31) + Data([0x01])
        let s = Data(repeating: 0x01, count: 32)
        let oversized = OpenSSHCertificate.sshString(oversizedR) + OpenSSHCertificate.sshString(s)
        #expect(OpenSSHECDSASignature.rawSignature(from: oversized) == nil)

        let paddedR = Data([0x00]) + Data(repeating: 0x01, count: 32)
        let padded = OpenSSHCertificate.sshString(paddedR) + OpenSSHCertificate.sshString(s)
        #expect(OpenSSHECDSASignature.rawSignature(from: padded)?.count == 64)
    }

    // MARK: - Synthetic cert helper

    /// Build a structurally valid ed25519 host certificate with a chosen
    /// signature key blob, validity end, and dummy signature (used for the
    /// unsupported-CA, no-expiry, and no-principal paths).
    static func syntheticHostCert(
        signatureKeyBlob: Data,
        validBefore: UInt64 = 2_082_758_400
    ) -> Data {
        func string(_ value: String) -> Data { OpenSSHCertificate.sshString(Data(value.utf8)) }
        func string(_ value: Data) -> Data { OpenSSHCertificate.sshString(value) }
        func uint32(_ value: UInt32) -> Data {
            Data([
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF),
            ])
        }
        func uint64(_ value: UInt64) -> Data {
            var data = Data()
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
            return data
        }

        var blob = Data()
        blob.append(string("ssh-ed25519-cert-v01@openssh.com"))
        blob.append(string(Data(repeating: 0x11, count: 32)))
        blob.append(string(Data(repeating: 0x22, count: 32)))
        blob.append(uint64(0))
        blob.append(uint32(2))  // host
        blob.append(string("synthetic-host"))
        // valid principals: one string whose payload is a concatenated
        // sequence of SSH strings (OpenSSH PROTOCOL.certkeys).
        blob.append(string(string("testhost")))
        blob.append(uint64(1_767_225_600))  // 2026-01-01
        blob.append(uint64(validBefore))    // 2036-01-01 by default
        blob.append(string(""))
        blob.append(string(""))
        blob.append(string(""))
        blob.append(string(signatureKeyBlob))
        // Signature blob: `string(algorithm) || string(signature)`.
        blob.append(string(string("ssh-ed25519") + string(Data(repeating: 0x44, count: 64))))
        return blob
    }
}

#endif
