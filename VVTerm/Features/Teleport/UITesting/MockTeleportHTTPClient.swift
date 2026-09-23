// SPDX-License-Identifier: MIT
//
//  MockTeleportHTTPClient.swift
//  VVTerm
//
//  A mock `TeleportHTTPClienting` for unit tests. Scripts the Phase-1
//  headless login response (or error) so the bootstrap coordinator can be
//  exercised without a real Teleport server.
//
//  Unlike the UI-test mocks (MockTeleportBootstrapCoordinator), this mocks
//  the *infrastructure* seam — letting the REAL
//  `TeleportBootstrapCoordinator` run its state machine while controlling
//  only the HTTP + Safari layer. This is what proves the coordinator's
//  success path and (via a hosted SwiftUI parent) the view-wiring
//  regression where the coordinator is orphaned by parent body re-evals.
//

#if DEBUG
import Foundation
import Security

/// A mock Teleport web-api HTTP client. Returns a scripted
/// `HeadlessLoginResponse` (or throws) on `headlessLogin`.
@MainActor
final class MockTeleportHTTPClient: TeleportHTTPClienting {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}

    /// The scripted Phase-1 response. `nil` means throw the scripted error.
    var scriptedHeadlessResponse: HeadlessLoginResponse?

    /// The scripted Phase-1 error. Thrown when
    /// `scriptedHeadlessResponse == nil`.
    var scriptedHeadlessError: Error?

    /// The scripted Phase-3 `/mfa/login/begin` response.
    var scriptedLoginBeginResponse: LoginBeginResponse?

    /// The scripted Phase-3 `/mfa/login/finish` response.
    var scriptedLoginFinishResponse: LoginFinishResponse?

    /// The scripted Phase-3 `/mfa/login/finish` error.
    var scriptedLoginFinishError: Error?

    /// The number of times `headlessLogin` was called.
    private(set) var headlessLoginCallCount = 0

    /// The number of times `loginFinish` was called.
    private(set) var loginFinishCallCount = 0

    /// An optional delay applied before returning the scripted response,
    /// so tests can race the POST against parent body re-evaluations.
    var scriptedDelay: TimeInterval = 0

    func headlessLogin(
        baseURL: URL,
        user: String,
        headlessAuthenticationID: String,
        sshPubKeyB64: String,
        tlsPubKeyB64: String?,
        ttl: Int64
    ) async throws -> HeadlessLoginResponse {
        headlessLoginCallCount += 1
        if scriptedDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(scriptedDelay * 1_000_000_000))
        }
        if let response = scriptedHeadlessResponse {
            return response
        }
        if let error = scriptedHeadlessError {
            throw error
        }
        // Default: a minimal valid success response (cert + tls_cert +
        // host_signers). Tests that want a different outcome should set
        // `scriptedHeadlessResponse` / `scriptedHeadlessError` explicitly.
        return MockTeleportHTTPClient.makeSuccessResponse(clusterName: "teleport.pcad.it")
    }

    // MARK: - Login begin/finish (Phase 3)

    func loginBegin(baseURL: URL) async throws -> LoginBeginResponse {
        if let response = scriptedLoginBeginResponse {
            return response
        }
        return MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
    }

    func loginFinish(
        baseURL: URL,
        assertion: CredentialAssertionResponse,
        sshPubKey: Data,
        ttl: Int64
    ) async throws -> LoginFinishResponse {
        loginFinishCallCount += 1
        if let error = scriptedLoginFinishError {
            throw error
        }
        if let response = scriptedLoginFinishResponse {
            return response
        }
        throw GRPCError.transport("MockTeleportHTTPClient.loginFinish not scripted")
    }

    // MARK: - Response factory

    /// Build a minimal success response with base64(PEM) cert + tls_cert.
    static func makeSuccessResponse(clusterName: String) -> HeadlessLoginResponse {
        let certPEM = "-----BEGIN CERTIFICATE-----\nmock-bootstrap-cert\n-----END CERTIFICATE-----\n"
        let tlsPEM = "-----BEGIN CERTIFICATE-----\nmock-tls-cert\n-----END CERTIFICATE-----\n"
        let certB64 = Data(certPEM.utf8).base64EncodedString()
        let tlsB64 = Data(tlsPEM.utf8).base64EncodedString()
        let hostSigner = HeadlessLoginResponse.TrustedCerts(
            clusterName: clusterName,
            checkingKeys: [],
            tlsCerts: [tlsB64]
        )
        return HeadlessLoginResponse(
            cert: certB64,
            tlsCert: tlsB64,
            hostSigners: [hostSigner]
        )
    }

    // MARK: - Fixture-bound responses (post-issuance binding checks)

    /// A clock pinned just before the fixture certificates expire, so the
    /// coordinator's issued-cert TTL check passes with the default 1h TTL.
    /// 2035-12-31T23:55:00Z; the fixture certs expire 2036-01-01T00:00:00Z.
    nonisolated static let fixtureClock = Date(timeIntervalSince1970: 2_082_758_100)

    /// The fixture SSH public key (`userkey_ed25519.pub`) the fixture
    /// user certificate is bound to.
    nonisolated static var fixedSSHPublicKey: String {
        (try? fixtureString("VVTermTests/Features/Teleport/Fixtures/OpenSSH/userkey_ed25519.pub")) ?? ""
    }

    /// The fixture user certificate (`user-cert-ed25519.pub`).
    nonisolated static var fixedIssuedUserCert: String {
        (try? fixtureString("VVTermTests/Features/Teleport/Fixtures/OpenSSH/user-cert-ed25519.pub")) ?? ""
    }

    /// The fixture TLS certificate + key (`loopback-tls/server.pem|p12`).
    nonisolated static func fixedTLSKeyPair() -> TLSKeyPair? {
        guard let data = try? Data(contentsOf: fixtureURL("VVTermTests/Features/Teleport/Fixtures/loopback-tls/server.p12")) else {
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
              let pem = try? fixtureString("VVTermTests/Features/Teleport/Fixtures/loopback-tls/server.pem") else {
            return nil
        }
        return TLSKeyPair(privateKey: privateKey, publicKeyPEM: pem)
    }

    /// A success response whose `cert` / `tls_cert` are bound to the fixture
    /// keypair + TLS keypair — i.e. it passes `TeleportIssuedCertValidator`
    /// when the coordinator is driven with `fixedSSHPublicKey` /
    /// `fixedTLSKeyPair()` and `fixtureClock`.
    nonisolated static func makeFixtureSuccessResponse(clusterName: String = "teleport.pcad.it") -> HeadlessLoginResponse {
        let certPEM = fixedIssuedUserCert
        let tlsPEM = (try? fixtureString("VVTermTests/Features/Teleport/Fixtures/loopback-tls/server.pem")) ?? ""
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
    nonisolated static func makeFixtureLoginBeginResponse() -> LoginBeginResponse {
        LoginBeginResponse(
            webauthnChallenge: LoginBeginResponse.WebauthnAssertion(
                publicKey: LoginBeginResponse.WebauthnAssertion.PublicKey(
                    challenge: Data([1, 2, 3, 4]).base64URLEncodedString(),
                    rpId: nil
                )
            )
        )
    }

    /// A `login/finish` response carrying the fixture user certificate.
    nonisolated static func makeFixtureLoginFinishResponse() -> LoginFinishResponse {
        LoginFinishResponse(
            cert: Data(fixedIssuedUserCert.utf8).base64EncodedString(),
            hostSigners: nil
        )
    }

    private nonisolated static func fixtureURL(_ repoRelativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(repoRelativePath)
    }

    private nonisolated static func fixtureString(_ repoRelativePath: String) throws -> String {
        try String(contentsOf: fixtureURL(repoRelativePath), encoding: .utf8)
    }
}
#endif
