// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportIssuedCertValidatorTests.swift
//  VVTermTests
//
//  Pure tests for the post-issuance certificate binding checks.
//
//  Fixture certs (public material under Fixtures/OpenSSH/) are valid
//  2026-01-01 → 2036-01-01; `TeleportFixtureSupport.fixtureClock` pins the
//  clock just before expiry so the TTL check passes with a 1h request.
//

#if DEBUG
import Foundation
import Security
import Testing
@testable import VVTerm

struct TeleportIssuedCertValidatorTests {

    private static let requestedTTL: TimeInterval = 3600

    // MARK: - SSH certificate binding

    @Test
    func acceptsMatchingUserCert() throws {
        guard let expectedBlob = OpenSSHCertificate.parseAuthorizedKeysLine(TeleportFixtureSupport.fixedSSHPublicKey)?.blob else {
            Issue.record("fixture key did not parse")
            return
        }
        let result = TeleportIssuedCertValidator.validateIssuedUserCert(
            TeleportFixtureSupport.fixedIssuedUserCert,
            expectedPublicKeyBlob: expectedBlob,
            requestedTTL: Self.requestedTTL,
            now: TeleportFixtureSupport.fixtureClock
        )
        switch result {
        case .success(let cert):
            #expect(cert.certType == .user)
            #expect(cert.validPrincipals == ["alice"])
        case .failure(let failure):
            Issue.record("expected success, got \(failure)")
        }
    }

    @Test
    func rejectsMismatchedPublicKey() throws {
        guard let expectedBlob = OpenSSHCertificate.parseAuthorizedKeysLine(TeleportFixtureSupport.otherSSHPublicKey)?.blob else {
            Issue.record("fixture key did not parse")
            return
        }
        let result = TeleportIssuedCertValidator.validateIssuedUserCert(
            TeleportFixtureSupport.fixedIssuedUserCert,
            expectedPublicKeyBlob: expectedBlob,
            requestedTTL: Self.requestedTTL,
            now: TeleportFixtureSupport.fixtureClock
        )
        #expect(result.failure == .publicKeyMismatch)
    }

    @Test
    func rejectsHostCertificate() throws {
        guard let expectedBlob = OpenSSHCertificate.parseAuthorizedKeysLine(TeleportFixtureSupport.otherSSHPublicKey)?.blob else {
            Issue.record("fixture key did not parse")
            return
        }
        let result = TeleportIssuedCertValidator.validateIssuedUserCert(
            TeleportFixtureSupport.hostCertLine,
            expectedPublicKeyBlob: expectedBlob,
            requestedTTL: Self.requestedTTL,
            now: TeleportFixtureSupport.fixtureClock
        )
        #expect(result.failure == .notAUserCertificate)
    }

    @Test
    func rejectsNonCertificate() {
        let result = TeleportIssuedCertValidator.validateIssuedUserCert(
            TeleportFixtureSupport.fixedSSHPublicKey,
            expectedPublicKeyBlob: Data([0x01]),
            requestedTTL: Self.requestedTTL,
            now: TeleportFixtureSupport.fixtureClock
        )
        #expect(result.failure == .notAnSSHCertificate)
    }

    @Test
    func rejectsCertExpiryBeyondRequestedTTL() throws {
        guard let expectedBlob = OpenSSHCertificate.parseAuthorizedKeysLine(TeleportFixtureSupport.fixedSSHPublicKey)?.blob else {
            Issue.record("fixture key did not parse")
            return
        }
        // 2027-01-01: the fixture cert (expires 2036) is far beyond a 1h TTL.
        let result = TeleportIssuedCertValidator.validateIssuedUserCert(
            TeleportFixtureSupport.fixedIssuedUserCert,
            expectedPublicKeyBlob: expectedBlob,
            requestedTTL: Self.requestedTTL,
            now: Date(timeIntervalSince1970: 1_798_761_600)
        )
        guard case .invalidValidityWindow = result.failure else {
            Issue.record("expected invalidValidityWindow, got \(String(describing: result.failure))")
            return
        }
    }

    @Test
    func rejectsAlreadyExpiredCert() throws {
        guard let expectedBlob = OpenSSHCertificate.parseAuthorizedKeysLine(TeleportFixtureSupport.fixedSSHPublicKey)?.blob else {
            Issue.record("fixture key did not parse")
            return
        }
        // 2036-06-01: past the fixture validity window.
        let result = TeleportIssuedCertValidator.validateIssuedUserCert(
            TeleportFixtureSupport.fixedIssuedUserCert,
            expectedPublicKeyBlob: expectedBlob,
            requestedTTL: Self.requestedTTL,
            now: Date(timeIntervalSince1970: 2_095_843_200)
        )
        guard case .invalidValidityWindow = result.failure else {
            Issue.record("expected invalidValidityWindow, got \(String(describing: result.failure))")
            return
        }
    }

    @Test
    func rejectsCertWithoutPrincipals() {
        // Synthesize a user cert blob with an empty principals list bound to
        // a known ed25519 key blob.
        let key = Data(repeating: 0x22, count: 32)
        var blob = Data()
        blob.append(OpenSSHCertificate.sshString(Data("ssh-ed25519-cert-v01@openssh.com".utf8)))
        blob.append(OpenSSHCertificate.sshString(Data(repeating: 0x11, count: 32)))
        blob.append(OpenSSHCertificate.sshString(key))
        blob.append(Self.uint64(0))
        blob.append(Self.uint32(1))  // user
        blob.append(OpenSSHCertificate.sshString(Data("no-principals".utf8)))
        blob.append(OpenSSHCertificate.sshString(Data()))
        blob.append(Self.uint64(0))
        blob.append(Self.uint64(2_000_000_000))
        blob.append(OpenSSHCertificate.sshString(Data()))
        blob.append(OpenSSHCertificate.sshString(Data()))
        blob.append(OpenSSHCertificate.sshString(Data()))
        blob.append(OpenSSHCertificate.sshString(Data(repeating: 0x33, count: 51)))
        blob.append(OpenSSHCertificate.sshString(Data(repeating: 0x44, count: 64)))

        let expectedBlob = OpenSSHCertificate.sshString(Data("ssh-ed25519".utf8))
            + OpenSSHCertificate.sshString(key)
        let result = TeleportIssuedCertValidator.validateIssuedUserCert(
            blob.base64EncodedString(),
            expectedPublicKeyBlob: expectedBlob,
            requestedTTL: Self.requestedTTL,
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )
        #expect(result.failure == .noPrincipals)
    }

    @Test
    func rejectsNotYetValidCert() {
        let key = Data(repeating: 0x22, count: 32)
        var blob = Data()
        blob.append(OpenSSHCertificate.sshString(Data("ssh-ed25519-cert-v01@openssh.com".utf8)))
        blob.append(OpenSSHCertificate.sshString(Data(repeating: 0x11, count: 32)))
        blob.append(OpenSSHCertificate.sshString(key))
        blob.append(Self.uint64(0))
        blob.append(Self.uint32(1))
        blob.append(OpenSSHCertificate.sshString(Data("not-yet".utf8)))
        // valid principals: one string containing the concatenated principal
        // strings (OpenSSH PROTOCOL.certkeys).
        blob.append(OpenSSHCertificate.sshString(OpenSSHCertificate.sshString(Data("alice".utf8))))
        blob.append(Self.uint64(2_000_000_000))  // valid after far future
        blob.append(Self.uint64(2_000_003_600))
        blob.append(OpenSSHCertificate.sshString(Data()))
        blob.append(OpenSSHCertificate.sshString(Data()))
        blob.append(OpenSSHCertificate.sshString(Data()))
        blob.append(OpenSSHCertificate.sshString(Data(repeating: 0x33, count: 51)))
        blob.append(OpenSSHCertificate.sshString(Data(repeating: 0x44, count: 64)))

        let expectedBlob = OpenSSHCertificate.sshString(Data("ssh-ed25519".utf8))
            + OpenSSHCertificate.sshString(key)
        let result = TeleportIssuedCertValidator.validateIssuedUserCert(
            blob.base64EncodedString(),
            expectedPublicKeyBlob: expectedBlob,
            requestedTTL: Self.requestedTTL,
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )
        guard case .invalidValidityWindow = result.failure else {
            Issue.record("expected invalidValidityWindow, got \(String(describing: result.failure))")
            return
        }
    }

    // MARK: - TLS certificate binding

    @Test
    func acceptsMatchingTLSCert() throws {
        let keyPair = try TeleportFixtureSupport.makeFixedTLSGenerator().keyPair
        let failure = TeleportIssuedCertValidator.validateTLSCertBinding(
            TeleportFixtureSupport.fixtureString("loopback-tls/server.pem"),
            expectedPrivateKey: keyPair.privateKey
        )
        #expect(failure == nil)
    }

    @Test
    func rejectsMismatchedTLSCert() throws {
        var error: Unmanaged<CFError>?
        let otherKey = try #require(SecKeyCreateRandomKey(
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
            ] as CFDictionary,
            &error
        ))
        let failure = TeleportIssuedCertValidator.validateTLSCertBinding(
            TeleportFixtureSupport.fixtureString("loopback-tls/server.pem"),
            expectedPrivateKey: otherKey
        )
        #expect(failure == .tlsPublicKeyMismatch)
    }

    @Test
    func rejectsUnreadableTLSCert() throws {
        let keyPair = try TeleportFixtureSupport.makeFixedTLSGenerator().keyPair
        let failure = TeleportIssuedCertValidator.validateTLSCertBinding(
            "not a pem",
            expectedPrivateKey: keyPair.privateKey
        )
        #expect(failure == .tlsCertificateUnreadable)
    }

    // MARK: - Helpers

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
}

private extension Result where Success == OpenSSHCertificate, Failure == TeleportIssuedCertValidator.Failure {
    var failure: TeleportIssuedCertValidator.Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

#endif
