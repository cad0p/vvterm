// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportInfrastructureProtocols.swift
//  VVTerm
//
//  Protocol seams between the Teleport Application layer (coordinators) and
//  the Infrastructure layer (HTTP client, gRPC client, Browser MFA ceremony).
//
//  These protocols exist so the coordinators can be unit/UI-tested with mock
//  implementations — the key enabler for the CI strategy (simulator-only
//  XCUITest of every failure case, including Face ID outcomes, without a
//  real Teleport server, real Safari, or real Face ID).
//
//  The parallel agent's concrete Infrastructure types conform to these
//  protocols:
//    - `TeleportHTTPClient`        → `TeleportHTTPClienting`
//    - `TeleportGRPCClient`        → `TeleportGRPCClienting`
//    - `BrowserMFACeremony`        → `BrowserMFACeremonyRunning`
//    - `ASWebAuthenticationSession`→ `WebAuthenticationSessionPresenting`
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (CI strategy)
//    - 2026-07-21-strategy-b-session2.2-vvterm-sep-key-integration-prompt.md
//      (Phase 1/2/3 method signatures)
//

import Foundation
import Security
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

// MARK: - HTTP client (Phase 1 + Phase 3)

/// The Teleport web-api HTTP client. Wraps the blocking
/// `POST /webapi/headless/login` (Phase 1) and the
/// `/webapi/mfa/login/begin` + `/finish` pair (Phase 3).
///
/// The concrete `TeleportHTTPClient` (ported by the parallel agent) wraps
/// the spike's `HeadlessLogin.post` + the `MFALoginWireTypes` HTTP calls.
protocol TeleportHTTPClienting: AnyObject {
    /// Phase 1: the blocking POST /webapi/headless/login. Blocks until the
    /// user approves in Safari (up to 180s server-side timeout).
    ///
    /// - Parameters:
    ///   - baseURL: the Teleport web proxy base URL (e.g. "https://teleport.pcad.it")
    ///   - user: the Teleport username
    ///   - headlessAuthenticationID: the UUID v5 derived from the SSH pub key
    ///   - sshPubKeyB64: the SSH authorized_keys string, base64-encoded
    ///     (Go's `[]byte` marshals as base64)
    ///   - tlsPubKeyB64: the TLS public key PEM, base64-encoded (optional)
    ///   - ttl: the requested cert TTL in nanoseconds
    /// - Returns: the decoded response (cert + host_signers + tls_cert).
    func headlessLogin(
        baseURL: URL,
        user: String,
        headlessAuthenticationID: String,
        sshPubKeyB64: String,
        tlsPubKeyB64: String?,
        ttl: Int64
    ) async throws -> HeadlessLoginResponse

    /// Phase 3, step 1: POST /webapi/mfa/login/begin (passwordless).
    /// Returns the WebAuthn challenge to sign.
    func loginBegin(baseURL: URL) async throws -> LoginBeginResponse

    /// Phase 3, step 3: POST /webapi/mfa/login/finish. Posts the signed
    /// WebAuthn assertion + a fresh SSH pub key; returns the issued cert.
    func loginFinish(
        baseURL: URL,
        assertion: CredentialAssertionResponse,
        sshPubKey: Data,
        ttl: Int64
    ) async throws -> LoginFinishResponse
}

// MARK: - gRPC client (Phase 2)

/// The Teleport gRPC client for Phase 2 (SEP-key registration). Runs over
/// the auth ALPN route (`teleport-auth@<hex(cluster)>.teleport.cluster.local`)
/// with mTLS using the Phase-1 cert.
///
/// The concrete `TeleportGRPCClient` (ported by the parallel agent) wraps
/// the spike's `TeleportGRPCConnection` + the proto RPCs.
protocol TeleportGRPCClienting: AnyObject {
    /// Connect to the auth service with the Phase-1 cert (mTLS).
    /// Called once per Phase-2 run; the connection is closed on completion.
    func connect(
        host: String,
        clientCertPEM: String,
        privateKey: SecKey,
        clusterName: String,
        clusterCAPEMs: [String]
    ) async throws

    /// Phase 2, step 1: CreateAuthenticateChallenge with ContextUser +
    /// MANAGE_DEVICES scope + BrowserMFATSHRedirectURL. The response carries
    /// the BrowserMFAChallenge (if the user has an existing WebAuthn device).
    func createAuthenticateChallenge(
        browserMFATSHRedirectURL: String
    ) async throws -> Proto_MFAAuthenticateChallenge

    /// Phase 2, step 3: CreateRegisterChallenge with the existing-MFA
    /// response (if any) + WEBAUTHN + PASSWORDLESS. Returns the WebAuthn
    /// challenge + the user handle (user.id).
    func createRegisterChallenge(
        existingMFAResponse: Proto_MFAAuthenticateResponse?
    ) async throws -> Proto_MFARegisterChallenge

    /// Phase 2, step 5: AddMFADeviceSync with the new WebAuthn registration
    /// response. ContextUser cert auth — no privilege token.
    func addMFADeviceSync(
        deviceName: String,
        newMFAResponse: Proto_MFARegisterResponse
    ) async throws

    /// Close the gRPC connection. Safe to call multiple times.
    func disconnect() async
}

// MARK: - Browser MFA ceremony (Phase 2, step 2)

/// The existing-device WebAuthn assertion via Safari (the Browser MFA
/// ceremony). Starts a loopback NWListener, opens Safari to
/// `/web/mfa/browser/<request_id>`, awaits the loopback callback, and
/// returns the decrypted CredentialAssertionResponse.
///
/// The concrete `BrowserMFACeremony` (ported by the parallel agent) is
/// verbatim from the 1.11 spike.
protocol BrowserMFACeremonyRunning: AnyObject {
    /// Run the Browser MFA ceremony.
    ///
    /// - Parameters:
    ///   - host: the Teleport proxy hostname
    ///   - challenge: the CreateAuthenticateChallenge response (carries
    ///     the request_id)
    /// - Returns: the BrowserMFAResponse (request_id + webauthn_response).
    /// - Throws: `BrowserMFACeremonyError.noBrowserMFAChallenge` if the user
    ///   has no existing WebAuthn device (first-device path — the coordinator
    ///   falls back to CreateRegisterChallenge without ExistingMFAResponse).
    func run(
        host: String,
        challenge: Proto_MFAAuthenticateChallenge
    ) async throws -> Proto_BrowserMFAResponse
}

// MARK: - ASWebAuthenticationSession (Phase 1 Safari presentation)

/// A seam over `ASWebAuthenticationSession` so UI tests can inject a mock
/// that doesn't actually open Safari.
///
/// The concrete impl wraps `ASWebAuthenticationSession.start()` + the
/// presentation-context provider. The headless flow doesn't use the callback
/// URL (the web UI doesn't redirect on approval — it shows "approved"), so
/// the completion handler is a no-op; the real gate is the blocking POST.
#if canImport(AuthenticationServices)
protocol WebAuthenticationSessionPresenting: AnyObject {
    /// Open the URL in an in-app Safari sheet. Returns when the session has
    /// started (NOT when it completes — the headless flow races the POST
    /// against Safari, and the POST is the real gate).
    /// - Returns: `true` if Safari opened successfully, `false` otherwise.
    @MainActor
    func open(url: URL) async -> Bool

    /// Cancel the session (dismiss the Safari sheet). Safe to call if no
    /// session is active.
    @MainActor
    func cancel()
}
#endif

// MARK: - WebAuthn builder (Phase 2 + Phase 3)

/// A combined protocol that requires both `WebAuthnSigner` (the builder-facing
/// abstraction — `createKey() -> (credentialID, publicKeyRaw)` +
/// `sign(message:credentialID:)`) and `SEPKeySigning` (the lower-level SecKey-
/// centric lifecycle — `createKey(credentialID:) -> SecKey` + `loadKey` +
/// `sign(digest:with:)`).
///
/// The coordinators need both: `SEPKeySigning` for `loadKey` (readiness +
/// Phase 3 key recovery) and `createKey(credentialID:)` (Phase 2 key
/// creation), and `WebAuthnSigner` for passing to `WebAuthn.register`/`login`.
/// `SecureEnclaveSigner` conforms to both; this protocol lets the coordinators
/// hold a single injected reference that satisfies both, and lets UI tests
/// inject a `MockSEPKeySigner` that conforms to both.
///
/// `& AnyObject` gives us `any TeleportSEPSigning` as a class-existential,
/// which is what the coordinators store.
protocol TeleportSEPSigning: WebAuthnSigner, SEPKeySigning, AnyObject {}

/// `SecureEnclaveSigner` already conforms to both `WebAuthnSigner` (the
/// builder-facing protocol) and `SEPKeySigning` (the SecKey lifecycle
/// protocol), so it satisfies `TeleportSEPSigning` automatically. This
/// extension just declares the conformance; no implementation needed.
extension SecureEnclaveSigner: TeleportSEPSigning {}

/// A seam over the `WebAuthn.register` / `WebAuthn.login` static methods so
/// UI tests can inject a mock that returns scripted responses (including
/// failure cases) without invoking the real CBOR/attestation logic.
///
/// The concrete `TeleportWebAuthnBuilder` forwards to `WebAuthn.register` /
/// `WebAuthn.login` verbatim.
protocol TeleportWebAuthnBuilding: AnyObject {
    /// Build a WebAuthn registration response (Phase 2).
    /// Mirrors `WebAuthn.register(origin:rpID:challenge:credentialID:publicKeyRaw:signer:)`.
    func register(
        origin: String,
        rpID: String,
        challenge: Data,
        credentialID: Data,
        publicKeyRaw: Data,
        signer: any WebAuthnSigner
    ) throws -> CredentialCreationResponse

    /// Build a WebAuthn assertion response (Phase 3).
    /// Mirrors `WebAuthn.login(origin:rpID:challenge:credentialID:userHandle:signer:)`.
    func login(
        origin: String,
        rpID: String,
        challenge: Data,
        credentialID: Data,
        userHandle: Data?,
        signer: any WebAuthnSigner
    ) throws -> CredentialAssertionResponse
}

/// The concrete WebAuthn builder — forwards to the static `WebAuthn` methods.
final class TeleportWebAuthnBuilder: TeleportWebAuthnBuilding {
    func register(
        origin: String,
        rpID: String,
        challenge: Data,
        credentialID: Data,
        publicKeyRaw: Data,
        signer: any WebAuthnSigner
    ) throws -> CredentialCreationResponse {
        try WebAuthn.register(
            origin: origin,
            rpID: rpID,
            challenge: challenge,
            credentialID: credentialID,
            publicKeyRaw: publicKeyRaw,
            signer: signer
        )
    }

    func login(
        origin: String,
        rpID: String,
        challenge: Data,
        credentialID: Data,
        userHandle: Data?,
        signer: any WebAuthnSigner
    ) throws -> CredentialAssertionResponse {
        try WebAuthn.login(
            origin: origin,
            rpID: rpID,
            challenge: challenge,
            credentialID: credentialID,
            userHandle: userHandle,
            signer: signer
        )
    }
}
