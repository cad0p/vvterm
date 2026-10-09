// SPDX-License-Identifier: MIT
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
import TeleportCore
import TeleportAuth
@testable import VVTerm

enum TeleportFixtureSupport {

    /// 2035-12-31T23:55:00Z — the fixture certs expire 2036-01-01T00:00:00Z.
    static let fixtureClock = Date(timeIntervalSince1970: 2_082_758_100)

    /// The fixture SSH public key the fixture user cert is bound to.
    static var fixedSSHPublicKey: String { fixtureString("OpenSSH/userkey_ed25519.pub") }

    /// The fixture user certificate (authorized_keys line).
    static var fixedIssuedUserCert: String { fixtureString("OpenSSH/user-cert-ed25519.pub") }

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

    /// The fixture TLS certificate + key (`loopback-tls/server.pem|p12`).
    /// Rebuilt host-side from the deleted `MockTeleportHTTPClient` fixture
    /// statics (the package mock is fixture-free by design).
    static func fixedTLSKeyPair() -> TLSKeyPair? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/loopback-tls/server.p12")
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        var options: [String: Any] = [kSecImportExportPassphrase as String: "vvterm-test"]
        if #available(macOS 15.0, iOS 18.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[String: Any]],
              let identity = entries.first?[kSecImportItemIdentity as String] else {
            return nil
        }
        let secIdentity = identity as! SecIdentity
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(secIdentity, &privateKey) == errSecSuccess,
              let privateKey,
              let pem = try? fixtureString("loopback-tls/server.pem") else {
            return nil
        }
        return TLSKeyPair(privateKey: privateKey, publicKeyPEM: pem)
    }

    /// `@MainActor` because `FixedTeleportSSHKeyPairGenerator`'s initializer
    /// is MainActor-inferred from the package's global-actor-isolated
    /// generator protocol; Xcode 27 enforces the call-site isolation.
    @MainActor
    static func makeFixedSSHGenerator(publicKey: String = TeleportFixtureSupport.fixedSSHPublicKey) -> FixedTeleportSSHKeyPairGenerator {
        FixedTeleportSSHKeyPairGenerator(publicKey: publicKey)
    }

    /// `@MainActor` for the same reason as `makeFixedSSHGenerator`
    /// (`FixedTeleportTLSKeyPairGenerator` conforms to the package's
    /// global-actor-isolated TLS generator protocol).
    @MainActor
    static func makeFixedTLSGenerator() throws -> FixedTeleportTLSKeyPairGenerator {
        guard let keyPair = Self.fixedTLSKeyPair() else {
            throw TeleportFixtureSupportError.tlsKeyPairUnavailable
        }
        return FixedTeleportTLSKeyPairGenerator(keyPair: keyPair)
    }

    /// Build a synthetic Phase-1 `BootstrapResult` bound to the committed TLS
    /// fixture. The same shape `TeleportRedactionTests` and
    /// `TeleportWebAuthnRPIDTests` construct in their private copies; this one
    /// is shared so the phase-chain and pin suites do not add a fifth copy.
    /// The two existing private copies are intentionally left untouched
    /// (recorded on #369, not refactored).
    @MainActor
    static func makeBootstrapResult() throws -> TeleportBootstrapCoordinator.BootstrapResult {
        let keyPair = try makeFixedTLSGenerator().keyPair
        return TeleportBootstrapCoordinator.BootstrapResult(
            sshCertPEM: fixedIssuedUserCert,
            tlsCertPEM: "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----",
            tlsKeyPairPrivateKey: keyPair.privateKey,
            clusterName: "teleport.pcad.it",
            clusterCAPEMs: [],
            certValidBefore: fixtureClock.addingTimeInterval(3_600)
        )
    }

    // MARK: - Attempt-tagged credential fixtures (the pair-atomicity tests)

    /// 2036-01-01T00:05:00Z — later than the real `Date()` (the live-cert gate
    /// in `TeleportCredential.isCertValid` compares to `Date()`, not to the
    /// injected clock) and inside the requested 1h TTL window from
    /// `fixtureClock`.
    static let attemptCertValidBefore = fixtureClock.addingTimeInterval(600)

    // MARK: - Response factories (host-owned fixture values)

    /// A success response whose `cert` / `tls_cert` are bound to the fixture
    /// keypair + TLS keypair — i.e. it passes `TeleportIssuedCertValidator`
    /// when the coordinator is driven with `fixedSSHPublicKey` /
    /// `fixedTLSKeyPair()` and `fixtureClock`. Rebuilt host-side from the
    /// deleted in-tree mock statics (the package mocks are fixture-free by
    /// design).
    @MainActor
    static func makeFixtureSuccessResponse(clusterName: String = "teleport.pcad.it") -> HeadlessLoginResponse {
        let certPEM = fixedIssuedUserCert
        let tlsPEM = fixtureString("loopback-tls/server.pem")
        let hostSigner = HeadlessLoginResponse.TrustedCerts(
            clusterName: clusterName,
            checkingKeys: [],
            tlsCerts: [Data(tlsPEM.utf8).base64EncodedString()]
        )
        return HeadlessLoginResponse(
            cert: Data(certPEM.utf8).base64EncodedString(),
            tlsCert: Data(tlsPEM.utf8).base64EncodedString(),
            hostSigners: [hostSigner]
        )
    }

    /// A `login/begin` response carrying a challenge and no explicit rpID
    /// (falls back to the cluster's configured rpID / host).
    @MainActor
    static func makeFixtureLoginBeginResponse() -> LoginBeginResponse {
        LoginBeginResponse(
            webauthnChallenge: LoginBeginResponse.WebauthnAssertion(
                publicKey: LoginBeginResponse.WebauthnAssertion.PublicKey(
                    challenge: Data([1, 2, 3, 4]).hostBase64URLString,
                    rpId: nil
                )
            )
        )
    }

    /// A `login/finish` response carrying the fixture user certificate.
    @MainActor
    static func makeFixtureLoginFinishResponse() -> LoginFinishResponse {
        LoginFinishResponse(
            cert: Data(fixedIssuedUserCert.utf8).base64EncodedString(),
            hostSigners: nil
        )
    }
}

enum TeleportFixtureSupportError: Error {
    case tlsKeyPairUnavailable
}

extension Data {
    /// Unpadded base64url, matching the package's wire encoding. The package's
    /// own helper is `package`-visibility and not importable host-side, so the
    /// test target carries this copy.
    var hostBase64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
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
