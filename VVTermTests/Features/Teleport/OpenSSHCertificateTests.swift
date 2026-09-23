// SPDX-License-Identifier: MIT
//
//  OpenSSHCertificateTests.swift
//  VVTermTests
//
//  Fixture-driven coverage for the OpenSSH SSH certificate wire parser.
//
//  The fixtures under `Fixtures/OpenSSH/` are public material generated with
//  `ssh-keygen` (public keys + certificates only — no CA private key is
//  committed; see the fixture README):
//
//    - ca_ed25519.pub          the test CA public key
//    - ca_foreign.pub          a second, unrelated CA public key
//    - host-cert-ed25519.pub   host cert (principals testhost,other), valid
//                              2026-01-01 → 2036-01-01
//    - host-cert-ecdsa.pub     host cert over an ECDSA key
//    - host-cert-rsa.pub       host cert over an RSA key
//    - user-cert-ed25519.pub   user cert (principal alice)
//    - host-cert-foreign.pub   host cert signed by the foreign CA
//    - host-cert-expired.pub   host cert valid 2020-01-01 → 2021-01-01
//
//  The certificate validity values are absolute (not relative to test-run
//  time) so the assertions never age.
//

import Foundation
import Testing
@testable import VVTerm

struct OpenSSHCertificateTests {

    // MARK: - Field walk

    @Test
    func parsesEd25519HostCertificateFields() throws {
        let cert = try #require(OpenSSHCertificate.parse(authorizedKeysOrPEM: Self.ed25519HostCert))

        #expect(cert.certKeyType == "ssh-ed25519-cert-v01@openssh.com")
        #expect(cert.certType == .host)
        #expect(cert.keyID == "host-cert-ed25519")
        #expect(cert.serial == 0)
        #expect(cert.validPrincipals == ["testhost", "other"])
        #expect(cert.validAfter == 1_767_225_600)   // 2026-01-01T00:00:00Z
        #expect(cert.validBefore == 2_082_758_400)  // 2036-01-01T00:00:00Z
        #expect(cert.validAfterDate == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(cert.validBeforeDate == Date(timeIntervalSince1970: 2_082_758_400))
        #expect(cert.reserved.isEmpty)
    }

    @Test
    func certifiedPublicKeyMatchesThePlainAuthorizedKeysKeyBlob() throws {
        // The `public key` field in the cert must reconstruct the same blob as
        // the authorized_keys line of the certified key. This is the byte
        // comparison the login/binding check (W3) relies on.
        let cases: [(cert: String, key: String)] = [
            (Self.ed25519HostCert, Self.ed25519HostKey),
            (Self.ecdsaHostCert, Self.ecdsaHostKey),
            (Self.rsaHostCert, Self.rsaHostKey),
        ]

        for (certLine, keyLine) in cases {
            let cert = try #require(OpenSSHCertificate.parse(authorizedKeysOrPEM: certLine))
            let (_, plainBlob) = try #require(OpenSSHCertificate.parseAuthorizedKeysLine(keyLine))
            #expect(cert.publicKeyBlob == plainBlob, "cert key blob mismatch for \(cert.certKeyType)")
        }
    }

    @Test
    func parsesEcdsaCertificateWithTwoPublicKeyFields() throws {
        // ECDSA certs carry curve + Q as two SSH strings; the old parser
        // skipped exactly one string and mis-read everything after it.
        let cert = try #require(OpenSSHCertificate.parse(authorizedKeysOrPEM: Self.ecdsaHostCert))
        #expect(cert.certKeyType == "ecdsa-sha2-nistp256-cert-v01@openssh.com")
        #expect(cert.certType == .host)
        #expect(cert.validPrincipals == ["testhost", "other"])
        #expect(cert.validBefore == 2_082_758_400)
    }

    @Test
    func parsesRsaCertificateWithTwoPublicKeyFields() throws {
        let cert = try #require(OpenSSHCertificate.parse(authorizedKeysOrPEM: Self.rsaHostCert))
        #expect(cert.certKeyType == "ssh-rsa-cert-v01@openssh.com")
        #expect(cert.certType == .host)
        #expect(cert.validPrincipals == ["testhost", "other"])
        #expect(cert.validBefore == 2_082_758_400)
    }

    @Test
    func parsesUserCertificate() throws {
        let cert = try #require(OpenSSHCertificate.parse(authorizedKeysOrPEM: Self.userCert))
        #expect(cert.certType == .user)
        #expect(cert.keyID == "user-cert-ed25519")
        #expect(cert.validPrincipals == ["alice"])
    }

    @Test
    func signatureKeyBlobIsTheParsedCaKey() throws {
        let cert = try #require(OpenSSHCertificate.parse(authorizedKeysOrPEM: Self.ed25519HostCert))
        let (_, caBlob) = try #require(OpenSSHCertificate.parseAuthorizedKeysLine(Self.caEd25519))
        #expect(cert.signatureKeyBlob == caBlob)
    }

    @Test
    func signedDataExcludesOnlyTheSignatureField() throws {
        let cert = try #require(OpenSSHCertificate.parse(authorizedKeysOrPEM: Self.ed25519HostCert))
        let (_, rawBlob) = try #require(OpenSSHCertificate.parseAuthorizedKeysLine(Self.ed25519HostCert))
        // signedData = blob up to the signature field's length prefix.
        let signatureFieldLength = 4 + cert.signatureBlob.count
        #expect(cert.signedData.count == rawBlob.count - signatureFieldLength)
        #expect(rawBlob.prefix(cert.signedData.count) == cert.signedData)
        #expect(!cert.signatureBlob.isEmpty)
    }

    // MARK: - Expiry parser delegation

    @Test
    func expiryParserReadsValidBeforeFromTheCertBlob() throws {
        let expected = Date(timeIntervalSince1970: 2_082_758_400)
        #expect(SSHCertExpiryParser.validBefore(pem: Self.ed25519HostCert) == expected)
        #expect(SSHCertExpiryParser.validBefore(pem: Self.ecdsaHostCert) == expected)
        #expect(SSHCertExpiryParser.validBefore(pem: Self.rsaHostCert) == expected)
    }

    @Test
    func expiryParserReadsExpiredCertValidity() throws {
        let expected = Date(timeIntervalSince1970: 1_609_459_200)  // 2021-01-01
        #expect(SSHCertExpiryParser.validBefore(pem: Self.expiredHostCert) == expected)
    }

    // MARK: - Malformed input

    @Test
    func truncatedBlobReturnsNil() throws {
        let (_, blob) = try #require(OpenSSHCertificate.parseAuthorizedKeysLine(Self.ed25519HostCert))
        #expect(OpenSSHCertificate.parse(blob: blob.dropLast()) == nil)
        #expect(OpenSSHCertificate.parse(blob: blob.prefix(10)) == nil)
        #expect(OpenSSHCertificate.parse(blob: Data()) == nil)
    }

    @Test
    func trailingGarbageAfterSignatureReturnsNil() throws {
        let (_, blob) = try #require(OpenSSHCertificate.parseAuthorizedKeysLine(Self.ed25519HostCert))
        #expect(OpenSSHCertificate.parse(blob: blob + Data([0x00])) == nil)
    }

    @Test
    func nonCertificateKeyTypeReturnsNil() throws {
        // A plain (non-cert) authorized_keys line must not parse as a cert.
        #expect(OpenSSHCertificate.parse(authorizedKeysOrPEM: Self.ed25519HostKey) == nil)
        #expect(OpenSSHCertificate.parse(authorizedKeysOrPEM: "not base64 !!") == nil)
        #expect(OpenSSHCertificate.parse(authorizedKeysOrPEM: "") == nil)
    }

    @Test
    func unknownCertificateKeyKindReturnsNil() {
        // `sk-ssh-ed25519@openssh.com` certs carry an extra application
        // string; the parser must fail closed rather than mis-walk them.
        var blob = OpenSSHCertificate.sshString(Data("sk-ssh-ed25519@openssh.com-cert-v01@openssh.com".utf8))
        blob.append(OpenSSHCertificate.sshString(Data([1, 2, 3])))
        #expect(OpenSSHCertificate.parse(blob: blob) == nil)
    }

    @Test
    func invalidCertTypeReturnsNil() {
        // Build a syntactically complete ed25519 cert blob whose type field
        // is 3 (neither user nor host). The parse must fail closed.
        func string(_ value: String) -> Data { OpenSSHCertificate.sshString(Data(value.utf8)) }
        func string(_ value: Data) -> Data { OpenSSHCertificate.sshString(value) }

        var blob = Data()
        blob.append(string("ssh-ed25519-cert-v01@openssh.com"))
        blob.append(string(Data(repeating: 0x11, count: 32)))  // nonce
        blob.append(string(Data(repeating: 0x22, count: 32)))  // public key
        blob.append(Self.uint64(0))                            // serial
        blob.append(Self.uint32(3))                            // type (invalid)
        blob.append(string(""))                                // key id
        blob.append(string(""))                                // principals
        blob.append(Self.uint64(0))                            // valid after
        blob.append(Self.uint64(0))                            // valid before
        blob.append(string(""))                                // critical options
        blob.append(string(""))                                // extensions
        blob.append(string(""))                                // reserved
        blob.append(string(Data(repeating: 0x33, count: 51)))  // signature key
        blob.append(string(Data(repeating: 0x44, count: 64)))  // signature

        #expect(OpenSSHCertificate.parse(blob: blob) == nil)
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    private static func uint64(_ value: UInt64) -> Data {
        var data = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
        return data
    }

    // MARK: - Authorized keys line parsing

    @Test
    func parsesPlainAuthorizedKeysLine() throws {
        let parsed = try #require(OpenSSHCertificate.parseAuthorizedKeysLine(Self.caEd25519))
        #expect(parsed.keyType == "ssh-ed25519")
        #expect(!parsed.blob.isEmpty)
    }

    @Test
    func parsesCertAuthorizedKeysLineWithComment() throws {
        let parsed = try #require(OpenSSHCertificate.parseAuthorizedKeysLine(Self.ed25519HostCert))
        #expect(parsed.keyType == "ssh-ed25519-cert-v01@openssh.com")
    }

    @Test
    func parsesKnownHostsCertAuthorityLine() throws {
        // known_hosts `@cert-authority` lines prefix hostnames before the key.
        let line = "@cert-authority teleport.pcad.it,*.teleport.pcad.it \(Self.caEd25519)"
        let parsed = try #require(OpenSSHCertificate.parseAuthorizedKeysLine(line))
        #expect(parsed.keyType == "ssh-ed25519")
        let (_, expected) = try #require(OpenSSHCertificate.parseAuthorizedKeysLine(Self.caEd25519))
        #expect(parsed.blob == expected)
    }

    @Test
    func parsesPEMWrappedCertificate() throws {
        let (_, blob) = try #require(OpenSSHCertificate.parseAuthorizedKeysLine(Self.ed25519HostCert))
        let b64 = blob.base64EncodedString()
        let pem = "-----BEGIN SSH CERTIFICATE-----\n\(b64)\n-----END SSH CERTIFICATE-----\n"
        let cert = try #require(OpenSSHCertificate.parse(authorizedKeysOrPEM: pem))
        #expect(cert.validBefore == 2_082_758_400)
    }

    // MARK: - Validity helper

    @Test
    func isValidRespectsTheCertificateWindow() throws {
        let cert = try #require(OpenSSHCertificate.parse(authorizedKeysOrPEM: Self.ed25519HostCert))
        #expect(cert.isValid(at: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(!cert.isValid(at: Date(timeIntervalSince1970: 1_600_000_000)))
        #expect(!cert.isValid(at: Date(timeIntervalSince1970: 2_100_000_000)))
        // Clock skew tolerance at both ends.
        #expect(cert.isValid(at: Date(timeIntervalSince1970: 1_767_225_500), clockSkew: 120))
    }

    // MARK: - Fixtures

    private static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OpenSSH/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static let caEd25519 = try! fixture("ca_ed25519.pub")
    static let caForeign = try! fixture("ca_foreign.pub")
    static let ed25519HostKey = try! fixture("hostkey_ed25519.pub")
    static let ecdsaHostKey = try! fixture("hostkey_ecdsa.pub")
    static let rsaHostKey = try! fixture("hostkey_rsa.pub")
    static let ed25519HostCert = try! fixture("host-cert-ed25519.pub")
    static let ecdsaHostCert = try! fixture("host-cert-ecdsa.pub")
    static let rsaHostCert = try! fixture("host-cert-rsa.pub")
    static let userCert = try! fixture("user-cert-ed25519.pub")
    static let foreignHostCert = try! fixture("host-cert-foreign.pub")
    static let expiredHostCert = try! fixture("host-cert-expired.pub")
}
