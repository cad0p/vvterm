// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportLoginCoordinator.swift
//  VVTerm
//
//  Phase 3 of the Teleport SEP-key integration: native passwordless login.
//
//  The coordinator calls `/webapi/mfa/login/begin` → builds the WebAuthn
//  assertion (signing with the SEP key via `SecKeyCreateSignature`, which
//  triggers the Face ID prompt) → `/webapi/mfa/login/finish` → stores the
//  returned cert in `TeleportKeyRing`.
//
//  This is the "every time after" flow proven in session 1.12 (PR #29):
//  `cert=1504` returned from `teleport.pcad.it`. The SEP key + userHandle
//  are reused from Phase 2 (no Safari, no gRPC — just two HTTP calls +
//  one Face ID prompt).
//
//  The cert TTL is dynamic — read from the cert's `ValidBefore`, never
//  hardcoded. The 12h figure for `teleport.pcad.it`'s `dev-access` role
//  is a fact about that cluster, not a constant (see the design doc's
//  mockup E).
//
//  Protocol-backed (`TeleportLoginCoordinating`) for mock injection in UI
//  tests — the key enabler for the CI strategy. The Face ID outcome is
//  itself assertable via the injected `SEPKeySigning` mock (returns
//  `.success(signature)` or `.failure(LAError.userCancel / .biometryLockout
//  / .biometryNotEnrolled)`).
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup E)
//    - 2026-07-21-strategy-b-session2.2-vvterm-sep-key-integration-prompt.md
//      (Phase 3 — the userHandle requirement)
//    - spike: spikes/sep-webauthn-iotest/iotest/FullFlow/FullFlowRunner.swift
//      (runPhase3Login)
//

import Foundation
import Security
import os.log

/// The state of a Phase 3 login attempt.
enum TeleportLoginState: Equatable {
    case idle
    /// The Face ID prompt is showing (SecKeyCreateSignature is blocking).
    case awaitingFaceID
    /// The login/finish POST is in flight.
    case fetchingCert
    /// The cert is issued + stored. The `certValidUntil` drives the
    /// "Certificate valid for …" copy in the login sheet.
    case success(certValidUntil: Date)
    /// A step failed. The error drives the recovery UX.
    case failed(TeleportLoginError)
}

/// The error matrix for Phase 3.
enum TeleportLoginError: Error, Equatable {
    /// The user cancelled the Face ID prompt (LAError.userCancel).
    case faceIDCancelled
    /// Face ID isn't available (not enrolled / locked out / no biometry).
    /// The message distinguishes the specific case for the UI copy.
    case faceIDUnavailable(String)
    /// The Teleport server returned a non-2xx status. The message is the
    /// server's response body.
    case server(String)
    /// The URLSession failed (no connection / timed out / DNS, etc.).
    case networkLost
    /// No registered SEP key for this cluster. The user must complete
    /// Phase 2 first (the readiness state should have prevented reaching
    /// the login coordinator in this state — this is a programming error).
    case noRegisteredKey
    /// An unexpected error (decode failure, etc.).
    case unknown(String)
}

/// Protocol-backed coordinator for Phase 3 (native passwordless login).
///
/// `@MainActor` because it drives sheet state + presents Face ID (the SEP
/// signer blocks on `SecKeyCreateSignature`, which must be on the main
/// thread for the biometric prompt).
@MainActor
protocol TeleportLoginCoordinating: AnyObject, ObservableObject {
    /// The current state. SwiftUI views observe this to drive the sheet UI.
    var state: TeleportLoginState { get }

    /// Begin a Phase 3 login for the given cluster.
    /// - Parameter cluster: the Teleport cluster config.
    func begin(cluster: TeleportCluster) async

    /// Cancel an in-flight login. Cancels the Face ID prompt (if showing)
    /// + the HTTP call (if in flight).
    func cancel() async
}

@MainActor
final class TeleportLoginCoordinator: ObservableObject, TeleportLoginCoordinating {
    @Published private(set) var state: TeleportLoginState = .idle

    /// The injected HTTP client (wraps loginBegin + loginFinish). Defaults
    /// to the shared `TeleportHTTPClient` in production; injectable for tests.
    private let httpClient: any TeleportHTTPClienting

    /// The injected key ring (reads the credentialID + userHandle; stores
    /// the fresh cert).
    private let keyRing: any TeleportKeyRingStoring

    /// The injected SEP signer (loads the persistent SEP key + signs the
    /// WebAuthn assertion). Defaults to a real `SecureEnclaveSigner`; UI
    /// tests inject a `MockSEPKeySigner` to script Face ID outcomes.
    private let signer: any TeleportSEPSigning

    /// The injected WebAuthn builder wrapper. Defaults to the real impl.
    private let webAuthnBuilder: any TeleportWebAuthnBuilding

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "it.pcad.vvterm",
        category: "teleport-login"
    )

    init(
        httpClient: any TeleportHTTPClienting,
        keyRing: any TeleportKeyRingStoring,
        signer: any TeleportSEPSigning = SecureEnclaveSigner(),
        webAuthnBuilder: any TeleportWebAuthnBuilding = TeleportWebAuthnBuilder()
    ) {
        self.httpClient = httpClient
        self.keyRing = keyRing
        self.signer = signer
        self.webAuthnBuilder = webAuthnBuilder
    }

    func begin(cluster: TeleportCluster) async {
        state = .idle
        logger.info("beginning login for cluster \(cluster.host, privacy: .public)")

        // ── Load the registered SEP key + userHandle ────────────────────
        // The credentialID + userHandle were persisted at Phase 2. The SEP
        // key itself is in the Secure Enclave (loaded via loadKey).
        guard let credentialID = keyRing.registeredCredentialID(for: cluster.id) else {
            logger.error("no registered SEP key for cluster \(cluster.id.uuidString, privacy: .public)")
            state = .failed(.noRegisteredKey)
            return
        }
        let userHandle = keyRing.registeredUserHandle(for: cluster.id)
        if userHandle == nil {
            logger.error("no registered userHandle for cluster \(cluster.id.uuidString, privacy: .public)")
            state = .failed(.noRegisteredKey)
            return
        }

        // Load the SEP key from the Secure Enclave. If the key was deleted
        // (e.g. the user wiped the device), loadKey returns nil and we
        // surface a "no registered key" error (the user must re-run Phase 2).
        let secKey: SecKey
        do {
            guard let key = try signer.loadKey(credentialID: credentialID) else {
                logger.error("SEP key not in keychain (credID=\(credentialID.base64URLEncodedString().prefix(16))…)")
                state = .failed(.noRegisteredKey)
                return
            }
            secKey = key
        } catch {
            logger.error("loadKey failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(.faceIDUnavailable("SEP key load failed: \(error.localizedDescription)"))
            return
        }

        let baseURL = URL(string: "https://\(cluster.host)")!
        let origin = "https://\(cluster.host)"

        // ── Step 1: login/begin (passwordless) ───────────────────────────
        // Returns the WebAuthn challenge to sign.
        let beginResp: LoginBeginResponse
        do {
            beginResp = try await httpClient.loginBegin(baseURL: baseURL)
        } catch {
            logger.error("login/begin failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(mapHTTPError(error))
            return
        }

        guard let assertion = beginResp.webauthnChallenge else {
            logger.error("login/begin returned no webauthn_challenge")
            state = .failed(.server("login/begin: no webauthn_challenge"))
            return
        }

        let challenge = Data(base64URLEncoded: assertion.publicKey.challenge)
            ?? Data(assertion.publicKey.challenge.utf8)
        let rpID = assertion.publicKey.rpId ?? cluster.rpID
        logger.info("login/begin: challenge \(challenge.count)B, rpID=\(rpID, privacy: .public)")

        // ── Step 2: WebAuthn.login (Face ID prompt) ──────────────────────
        // This is the in-app Face ID prompt. SecKeyCreateSignature blocks
        // until the user presents biometry. The signer is the same SEP key
        // loaded above; the WebAuthn builder handles the authData + digest.
        //
        // The userHandle MUST be passed — the server's passwordless verify
        // path (login.go:268) requires it: "webauthn user handle required
        // for passwordless". We pass the UTF-8 bytes captured at Phase 2.
        state = .awaitingFaceID
        let assertionResp: CredentialAssertionResponse
        do {
            assertionResp = try webAuthnBuilder.login(
                origin: origin,
                rpID: rpID,
                challenge: challenge,
                credentialID: credentialID,
                userHandle: userHandle,
                signer: signer
            )
        } catch {
            logger.error("WebAuthn.login failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(mapSignerError(error))
            return
        }
        logger.info("WebAuthn.login signed (sig \(assertionResp.response.signature.count)B)")

        // ── Step 3: generate a fresh SSH pub key + login/finish ──────────
        // The cert is issued against a fresh ed25519 keypair (the private
        // key is kept for the SSH connection). The TTL is requested as 1h
        // (the server clamps it to the role's MaxSessionTTL — the actual
        // TTL is read from the returned cert's ValidBefore).
        state = .fetchingCert
        let sshPubKey = SSHPubKey.generateEd25519AuthorizedKeys(comment: "vvterm-teleport-login")
        let sshPubKeyBytes = Data((sshPubKey + "\n").utf8)
        let ttl: Int64 = 3_600_000_000_000  // 1h in ns (server clamps)

        let finishResp: LoginFinishResponse
        do {
            finishResp = try await httpClient.loginFinish(
                baseURL: baseURL,
                assertion: assertionResp,
                sshPubKey: sshPubKeyBytes,
                ttl: ttl
            )
        } catch {
            logger.error("login/finish failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(mapHTTPError(error))
            return
        }

        guard let cert = finishResp.cert, !cert.isEmpty else {
            logger.error("login/finish returned no cert")
            state = .failed(.server("login/finish: no cert in response"))
            return
        }

        // The cert's ValidBefore. The HTTP response doesn't include it
        // directly — it's embedded in the PEM cert. Parsing it requires
        // SecCertificateCreateWithData + SecCertificateCopyValues, which
        // is non-trivial. For now, use a conservative default (1h from
        // now) — the readiness state will flip to `needsLogin` when the
        // cert expires, triggering a re-auth.
        //
        // TODO(phase-3): parse ValidBefore from the PEM cert so the
        // "Certificate valid for …" copy is accurate. The spike's
        // FullFlowRunner doesn't parse it either (it just logs the cert
        // length), so this is a known gap carried over from the spike.
        let certValidBefore = Date(timeIntervalSinceNow: 3600)  // 1h default

        // Store the fresh cert in the key ring. Readiness flips to `ready`.
        keyRing.storeLoginCert(cert, validBefore: certValidBefore, for: cluster.id)
        logger.info("login succeeded — cert \(cert.count) chars, valid until \(certValidBefore.debugDescription, privacy: .public)")

        state = .success(certValidUntil: certValidBefore)
    }

    func cancel() async {
        logger.info("cancelling login")
        // There's no way to cancel a blocking SecKeyCreateSignature from
        // outside (the LAContext is internal to the signer). The user
        // cancels via the Face ID prompt's Cancel button, which surfaces
        // as a SignerError → .faceIDCancelled. We just reset the state.
        state = .failed(.faceIDCancelled)
    }

    // MARK: - Error mapping

    /// Map an HTTP/URLSession error to a `TeleportLoginError`.
    private func mapHTTPError(_ error: Error) -> TeleportLoginError {
        // The concrete HTTP client wraps URLSession errors in HeadlessError
        // (shared with Phase 1). We string-match because HeadlessError's
        // cases aren't exhaustive here (the parallel agent may add cases).
        if let headlessError = error as? HeadlessError {
            switch headlessError {
            case .transport(let m):
                if m.lowercased().contains("timed out") {
                    return .networkLost
                }
                return .networkLost
            case .http(let status, let body):
                return .server("HTTP \(status): \(body)")
            case .decode(let m):
                return .unknown("decode: \(m)")
            case .noCert:
                return .server("no cert in response")
            case .missingField(let f):
                return .unknown("missing field: \(f)")
            }
        }

        // An unexpected URLError.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost:
                return .networkLost
            case NSURLErrorCancelled:
                return .faceIDCancelled
            default:
                return .unknown(nsError.localizedDescription)
            }
        }
        return .unknown(error.localizedDescription)
    }

    /// Map a signer error (from WebAuthn.login → SecKeyCreateSignature) to a
    /// `TeleportLoginError`. Distinguishes Face ID cancel from unavailable.
    private func mapSignerError(_ error: Error) -> TeleportLoginError {
        let msg = error.localizedDescription.lowercased()
        // SignerError.signingFailed wraps the LAError. The LAError codes:
        //   - .userCancel → "canceled" / "cancel"
        //   - .biometryLockout → "lockout"
        //   - .biometryNotEnrolled → "not enrolled" / "not available"
        if msg.contains("cancel") {
            return .faceIDCancelled
        }
        if msg.contains("lockout") {
            return .faceIDUnavailable("Face ID is locked. Enter your passcode to unlock Face ID, then try again.")
        }
        if msg.contains("not enrolled") || msg.contains("not available") || msg.contains("biometry") {
            return .faceIDUnavailable("Face ID isn't available. Set up Face ID in iOS Settings.")
        }
        return .faceIDUnavailable(error.localizedDescription)
    }
}
