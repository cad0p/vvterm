// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportFixtureSupport.swift
//  VVTermTests
//
//  Shared test seams for the Teleport coordinators:
//    - fixed SSH/TLS keypair generators bound to the committed fixtures, so
//      the issued-certificate binding checks (W3) are exercisable with a
//      static certificate;
//    - the pinned fixture clock (just before the fixture certs expire), so
//      the TTL check passes with the production 1h request.
//

#if DEBUG
import Foundation
import Security
@testable import VVTerm

enum TeleportFixtureSupport {

    /// 2035-12-31T23:55:00Z — the fixture certs expire 2036-01-01T00:00:00Z.
    static let fixtureClock = MockTeleportHTTPClient.fixtureClock

    /// The fixture SSH public key the fixture user cert is bound to.
    static var fixedSSHPublicKey: String { MockTeleportHTTPClient.fixedSSHPublicKey }

    /// The fixture user certificate (authorized_keys line).
    static var fixedIssuedUserCert: String { MockTeleportHTTPClient.fixedIssuedUserCert }

    /// A different fixture SSH public key (used for mismatch tests).
    static var otherSSHPublicKey: String {
        fixtureString("OpenSSH/hostkey_ed25519.pub")
    }

    /// The fixture ed25519 host certificate (used for wrong-type tests).
    static var hostCertLine: String {
        fixtureString("OpenSSH/host-cert-ed25519.pub")
    }

    static func fixtureString(_ relativePath: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(relativePath)")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func makeFixedSSHGenerator(publicKey: String = TeleportFixtureSupport.fixedSSHPublicKey) -> FixedTeleportSSHKeyPairGenerator {
        FixedTeleportSSHKeyPairGenerator(publicKey: publicKey)
    }

    static func makeFixedTLSGenerator() throws -> FixedTeleportTLSKeyPairGenerator {
        guard let keyPair = MockTeleportHTTPClient.fixedTLSKeyPair() else {
            throw TeleportFixtureSupportError.tlsKeyPairUnavailable
        }
        return FixedTeleportTLSKeyPairGenerator(keyPair: keyPair)
    }
}

enum TeleportFixtureSupportError: Error {
    case tlsKeyPairUnavailable
}

/// Returns a fixed ed25519 public key (the fixture cert's subject key).
final class FixedTeleportSSHKeyPairGenerator: TeleportSSHKeyPairGenerating {
    let publicKey: String
    let privateKeyPEM: String

    init(publicKey: String, privateKeyPEM: String = "fixed-test-ed25519-private-key") {
        self.publicKey = publicKey
        self.privateKeyPEM = privateKeyPEM
    }

    func generateKeyPair(comment: String) -> (publicKey: String, privateKeyPEM: String) {
        (publicKey, privateKeyPEM)
    }
}

/// Returns a fixed TLS keypair (the fixture loopback identity).
final class FixedTeleportTLSKeyPairGenerator: TeleportTLSKeyPairGenerating {
    let keyPair: TLSKeyPair

    init(keyPair: TLSKeyPair) {
        self.keyPair = keyPair
    }

    func generate() throws -> TLSKeyPair {
        keyPair
    }
}

#endif
