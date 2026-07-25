// SPDX-License-Identifier: AGPL-3.0-or-later
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

/// A mock Teleport web-api HTTP client. Returns a scripted
/// `HeadlessLoginResponse` (or throws) on `headlessLogin`.
@MainActor
final class MockTeleportHTTPClient: TeleportHTTPClienting {
    /// The scripted Phase-1 response. `nil` means throw the scripted error.
    var scriptedHeadlessResponse: HeadlessLoginResponse?

    /// The scripted Phase-1 error. Thrown when
    /// `scriptedHeadlessResponse == nil`.
    var scriptedHeadlessError: Error?

    /// The number of times `headlessLogin` was called.
    private(set) var headlessLoginCallCount = 0

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

    // MARK: - Login begin/finish (Phase 3) — not used by bootstrap tests

    func loginBegin(baseURL: URL) async throws -> LoginBeginResponse {
        throw GRPCError.transport("MockTeleportHTTPClient.loginBegin not scripted")
    }

    func loginFinish(
        baseURL: URL,
        assertion: CredentialAssertionResponse,
        sshPubKey: Data,
        ttl: Int64
    ) async throws -> LoginFinishResponse {
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
}
#endif
