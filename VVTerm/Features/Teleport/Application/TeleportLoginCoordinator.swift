// SPDX-License-Identifier: MIT
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
import Combine
import os.log

/// The state of a Phase 3 login attempt.
enum TeleportLoginState: Equatable {
    case idle
    /// The Face ID prompt is showing (SecKeyCreateSignature is blocking).
    case awaitingFaceID
    /// The login/finish POST is in flight.
    case fetchingCert
    /// The cert is issued + stored. The `certValidUntil` drives the
    /// "Certificate valid for …" copy in the login sheet; `logins` are the
    /// cert's non-internal principals (wire order) the setup picker offers as
    /// the host login.
    case success(certValidUntil: Date, logins: [String])
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

    /// Cancel an in-flight login: bump the request generation and write the
    /// terminal `.failed(.faceIDCancelled)` state. It does NOT cancel the
    /// in-flight `login/begin`/`login/finish` request and cannot dismiss a live
    /// Face ID prompt (`SecKeyCreateSignature` is uninterruptible); the bump
    /// bounds the *writes*, not the flow. The scheduled teardown the view runs
    /// after `latchDismissal()` closes the dismissal window.
    func cancel() async

    /// Latch a dismissal synchronously, before the async teardown is scheduled.
    ///
    /// The generation bump lands in the same MainActor turn as the view's
    /// `.onDisappear`/Cancel action, so a continuation that has not yet passed
    /// its next re-take cannot start a keyring write or a terminal `.success`
    /// after the user dismissed the flow. A write already in flight is not
    /// stopped, and `cancel()` still performs the teardown; this only closes
    /// the window between the dismissal and the teardown task starting.
    ///
    /// Declared without a protocol-extension default so every conformer must
    /// decide explicitly (a default no-op would let a future conformer silently
    /// not latch).
    func latchDismissal()
}

extension TeleportLoginState {
    /// Whether dismissing the login sheet must tear the flow down.
    ///
    /// `.success` is the Phase-3 hand-off (the sheet shows the host-login step
    /// and Continue persists the row), so a dismissal then must not cancel the
    /// issued cert. A `.failed` state is gate-false: the paths that produce it
    /// have already latched/run `cancel()` (the toolbar Cancel, a Face ID
    /// cancel surfacing as a `SignerError`), and every other `.failed`
    /// producer returns from `begin` immediately afterwards. That holds even
    /// though the cancel-written `.failed` is reached while
    /// `login/begin`/`login/finish` may still be in flight — the latch, not
    /// this gate, is what drops those continuations. Every in-flight state
    /// does: the `begin` task is still running and (across the HTTP awaits)
    /// can still write after the sheet is gone. Exhaustive switch with no
    /// `default`, so a future state cannot silently mis-map.
    var dismissalRequiresTeardown: Bool {
        switch self {
        case .idle, .awaitingFaceID, .fetchingCert: return true
        case .success, .failed: return false
        }
    }
}

@MainActor
final class TeleportLoginCoordinator: ObservableObject, TeleportLoginCoordinating {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    @Published private(set) var state: TeleportLoginState = .idle

    /// The injected HTTP client (wraps loginBegin + loginFinish). Defaults
    /// to the shared `TeleportHTTPClient` in production; injectable for tests.
    private let httpClient: any TeleportHTTPClienting

    /// The injected credential store (reads the credentialID + userHandle;
    /// stores the fresh cert).
    private let keyRing: any TeleportCredentialStore

    /// The injected SEP signer (loads the persistent SEP key + signs the
    /// WebAuthn assertion). Defaults to a real `SecureEnclaveSigner`; UI
    /// tests inject a `MockSEPKeySigner` to script Face ID outcomes.
    private let signer: any TeleportSEPSigning

    /// The injected WebAuthn builder wrapper. Defaults to the real impl.
    private let webAuthnBuilder: any TeleportWebAuthnBuilding

    /// Generates the ed25519 keypair the certificate is requested against.
    /// Injectable so tests can bind a fixture certificate to a known key.
    private let keyPairGenerator: any TeleportSSHKeyPairGenerating

    /// The clock used for the issued-certificate validity checks.
    private let now: () -> Date

    /// Monotonic token identifying the current login attempt. Bumped by
    /// `begin` and `cancel` (and by the dismissal latch), so a continuation
    /// from an older attempt cannot write state or keyring state after a newer
    /// attempt — or a cancel — took over. The #222/#239 shape, applied to the
    /// login coordinator.
    private var requestGeneration = 0

    /// Whether a dismissal has been latched for this flow. Semantic first (it
    /// makes `begin` terminal) and the ordering point the wiring tests await.
    /// Concrete-only (`private(set)`, no protocol getter): only
    /// `latchDismissal()` is called through the existential, and the tests hold
    /// the concrete type.
    private(set) var isDismissalLatched = false

    private let logger: Logger

    init(
        httpClient: any TeleportHTTPClienting,
        keyRing: any TeleportCredentialStore,
        logging: any TeleportLogging,
        signer: any TeleportSEPSigning = SecureEnclaveSigner(),
        webAuthnBuilder: any TeleportWebAuthnBuilding = TeleportWebAuthnBuilder(),
        keyPairGenerator: any TeleportSSHKeyPairGenerating = LiveTeleportSSHKeyPairGenerator(),
        now: @escaping () -> Date = Date.init
    ) {
        self.httpClient = httpClient
        self.keyRing = keyRing
        self.logger = logging.logger(category: "teleport-login")
        self.signer = signer
        self.webAuthnBuilder = webAuthnBuilder
        self.keyPairGenerator = keyPairGenerator
        self.now = now
    }

    func begin(cluster: TeleportCluster) async {
        // Terminal after a dismissal latch: a stray retry after the sheet was
        // dismissed must not re-arm the flow (the latch is per-flow and never
        // reset, because a coordinator is one sheet and a fresh presentation
        // gets a fresh coordinator).
        guard !isDismissalLatched else { return }
        // Bump the generation so a continuation from a previous attempt cannot
        // write state this attempt owns.
        requestGeneration &+= 1
        let generation = requestGeneration
        state = .idle
        logger.info("beginning login for cluster \(cluster.host, privacy: .private(mask: .hash))")

        // ── Load the registered SEP key + userHandle ────────────────────
        // The credentialID + userHandle were persisted at Phase 2. The SEP
        // key itself is in the Secure Enclave (loaded via loadKey).
        let registeredCredentialID = await keyRing.registeredCredentialID(for: cluster.id)
        // A `cancel()`/newer `begin()` during the read owns the state now; this
        // continuation must not use the result.
        guard generation == requestGeneration else { return }
        guard let credentialID = registeredCredentialID else {
            logger.error("no registered SEP key for cluster \(cluster.id.uuidString, privacy: .public)")
            state = .failed(.noRegisteredKey)
            return
        }
        let userHandle = await keyRing.registeredUserHandle(for: cluster.id)
        guard generation == requestGeneration else { return }
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
            // A `cancel()`/newer `begin()` during the request owns the state
            // now; this continuation must not use the response.
            guard generation == requestGeneration else { return }
        } catch {
            // The catch runs before any post-await guard, so the re-take must
            // be its first statement: a stale continuation must not write
            // `.failed` over the newer attempt's state.
            guard generation == requestGeneration else { return }
            // A wire-derived failure can carry the raw server body —
            // `HeadlessError.http(status:body:)` is what the live client now
            // throws for a non-200 login call (#236); a `GRPCError` from the
            // gRPC/HTTP-2 layer still reaches this catch. Log the case/status
            // only. The descriptive text stays in the UI state via
            // `mapHTTPError`.
            logger.error("login/begin failed: \(TeleportErrorRedaction.wireFailure(error), privacy: .public)")
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
        let rpID: String
        switch TeleportWebAuthnRPID.resolve(serverProvided: assertion.publicKey.rpId, cluster: cluster) {
        case .success(let resolved):
            rpID = resolved
        case .failure(let error):
            // The rejection text embeds the *server-provided* rpID, so the log
            // payload carries the case only; the descriptive text is in the UI
            // state below.
            let shape = error.logSafeDescription
            logger.error("login/begin rpID rejected (\(shape, privacy: .public))")
            state = .failed(.server("login/begin: \(error.errorDescription ?? "WebAuthn rpID rejected")"))
            return
        }
        logger.info("login/begin: challenge \(challenge.count)B, rpID=\(rpID, privacy: .private(mask: .hash))")

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
            // The OSStatus (a non-secret local integer) is the only triage
            // signal when a locale message collides with a specific state,
            // so log it alongside the message.
            if let signerError = error as? SignerError,
               case .biometricSigningFailed(_, let status) = signerError {
                logger.error(
                    "WebAuthn.login failed: OSStatus \(status, privacy: .public), \(error.localizedDescription, privacy: .public)"
                )
            } else {
                logger.error("WebAuthn.login failed: \(error.localizedDescription, privacy: .public)")
            }
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
        let (sshPubKey, sshPrivateKeyPEM) = keyPairGenerator.generateKeyPair(comment: "vvterm-teleport-login")
        let sshPubKeyBytes = Data((sshPubKey + "\n").utf8)
        let ttl: Int64 = 3_600_000_000_000  // 1h in ns (server clamps)
        let requestedTTLSeconds = TimeInterval(ttl) / 1_000_000_000

        let finishResp: LoginFinishResponse
        do {
            finishResp = try await httpClient.loginFinish(
                baseURL: baseURL,
                assertion: assertionResp,
                sshPubKey: sshPubKeyBytes,
                ttl: ttl
            )
            // A `cancel()`/newer `begin()` during the request owns the state
            // now; this continuation must not use the response.
            guard generation == requestGeneration else { return }
        } catch {
            // The catch runs before any post-await guard, so the re-take must
            // be its first statement: a stale continuation must not write
            // `.failed` over the newer attempt's state.
            guard generation == requestGeneration else { return }
            // Same class as `login/begin` above: a wire-derived failure whose
            // log payload carries the case/status only, never the raw body.
            logger.error("login/finish failed: \(TeleportErrorRedaction.wireFailure(error), privacy: .public)")
            state = .failed(mapHTTPError(error))
            return
        }

        guard let cert = finishResp.cert, !cert.isEmpty else {
            logger.error("login/finish returned no cert")
            state = .failed(.server("login/finish: no cert in response"))
            return
        }

        // The cert is base64(PEM) — Go's `[]byte` marshals as base64.
        // Decode to the actual PEM string before storing (the bootstrap
        // coordinator does the same; the SSHClient cert seam expects the
        // raw authorized_keys/PEM string, not a base64 wrapper).
        guard let certPEMData = Data(base64Encoded: cert),
              let certPEM = String(data: certPEMData, encoding: .utf8) else {
            logger.error("failed to base64-decode login cert")
            state = .failed(.unknown("cert base64 decode failed"))
            return
        }

        // The cert's ValidBefore. The HTTP response doesn't include it
        // directly — it's embedded in the PEM cert. Parse it from the SSH
        // cert blob (OpenSSH cert format). The client contract is to store
        // only a certificate bound to the keypair it generated, so the
        // binding is verified before anything is persisted.
        guard let sshKeyBlob = OpenSSHCertificate.parseAuthorizedKeysLine(sshPubKey)?.blob else {
            logger.error("failed to parse the generated ssh public key")
            state = .failed(.unknown("generated ssh key parse failed"))
            return
        }
        let validation = TeleportIssuedCertValidator.validateIssuedUserCert(
            certPEM,
            expectedPublicKeyBlob: sshKeyBlob,
            requestedTTL: requestedTTLSeconds,
            now: now()
        )
        let certValidBefore: Date
        let issuedCertificate: OpenSSHCertificate
        switch validation {
        case .success(let cert):
            // The certificate must belong to the Teleport user this row is
            // configured with: the connect path resolves the SSH username from
            // the cert's principals, so a foreign cert (a different keyID)
            // would authenticate as the wrong identity. Clear whatever the row
            // holds and fail closed.
            guard cert.keyID == cluster.username else {
                // No username in the log: identity values use the default
                // (private) interpolation and never `.public`.
                logger.error(
                    "issued certificate keyID does not match the configured Teleport user for cluster \(cluster.id.uuidString, privacy: .public) — rejecting and clearing the credential"
                )
                await keyRing.clear(for: cluster.id)
                // The clear is already in flight when a supersession lands, so
                // it is allowed to commit (§1.4); only the terminal state is
                // withheld.
                guard generation == requestGeneration else { return }
                state = .failed(.server("Certificate user binding check failed: the certificate does not belong to this Teleport user"))
                return
            }
            issuedCertificate = cert
            certValidBefore = cert.validBeforeDate
        case .failure(let failure):
            logger.error(
                "issued certificate rejected: \(failure.errorDescription ?? "unknown", privacy: .public)"
            )
            state = .failed(.server("Certificate binding check failed: \(failure.errorDescription ?? "unknown")"))
            return
        }

        // Refresh the pinned Host CA checking keys from the login response.
        // The update is additions-only (the keyring rejects a refresh that
        // would drop a pinned key); a rejected refresh keeps the existing
        // anchors and requires re-bootstrap. `domain_name` must name the
        // cluster that owns the pinned state, and an accepted refresh can
        // only add key blobs: `clusterCAPEMs` (the outer TLS anchors) are
        // never touched, so this unauthenticated channel cannot change the
        // TLS-leg trust anchors. Additions cannot evict a pinned key; first
        // capture remains TOFU, an accepted risk.
        if let hostSigners = finishResp.hostSigners, let first = hostSigners.first {
            let pinnedClusterName = await keyRing.clusterTLSState(for: cluster.id)?.clusterName
            guard generation == requestGeneration else { return }
            if TeleportHostKeyUpdatePolicy.matchesPinnedCluster(
                domainName: first.domainName,
                pinnedClusterName: pinnedClusterName
            ) {
                let update = await keyRing.updateClusterHostKeys(first.checkingKeys, for: cluster.id)
                guard generation == requestGeneration else { return }
                if update == .rejectedWouldDropPinnedKeys {
                    logger.error(
                        "Host CA key refresh rejected for cluster \(cluster.id.uuidString, privacy: .public) — pinned anchors kept; re-bootstrap required"
                    )
                }
            } else {
                logger.error(
                    "Host CA key refresh skipped for cluster \(cluster.id.uuidString, privacy: .public) — login response domain_name does not match the pinned cluster name"
                )
            }
        }

        // Store the fresh cert and its paired ed25519 private key as one
        // atomic pair: the key write and the record commit land in one
        // non-suspending body, so a supersession can land a complete pair, the
        // previous complete pair, or nothing — never a mixed pair. The single
        // writes remain seed/test primitives; no coordinator calls them.
        let privKeyData: Data
        if let data = sshPrivateKeyPEM.data(using: .utf8) {
            privKeyData = data
        } else {
            // Unreachable today (`String.data(using: .utf8)` is total), but a
            // nil here cannot write a pair: route it through the same
            // store-failure outcome rather than committing half a credential.
            await finishWithStoreFailure(generation: generation, cluster: cluster)
            return
        }
        do {
            try await keyRing.storeCredentialPair(
                certPEM,
                validBefore: certValidBefore,
                privateKeyPEM: privKeyData,
                policy: .login,
                for: cluster.id
            )
        } catch {
            // Deliberate behaviour change: after a pair-write throw nothing
            // from this attempt is guaranteed stored (the write is key-first,
            // and a failure leaves the previous complete pair intact or
            // nothing), so the terminal state is derived from the store's real
            // state instead of the old false "the cert is stored, so readiness
            // is correct".
            logger.error("failed to store the login credential pair: \(error.localizedDescription, privacy: .public)")
            await finishWithStoreFailure(generation: generation, cluster: cluster)
            return
        }
        // Re-take after the pair store: a superseded attempt must not reach the
        // terminal state.
        guard generation == requestGeneration else { return }
        logger.info("login succeeded — cert \(certPEM.count) chars, valid until \(certValidBefore.debugDescription, privacy: .public)")

        state = .success(
            certValidUntil: certValidBefore,
            logins: TeleportHostLogin.nonInternalPrincipals(of: issuedCertificate)
        )
    }

    /// The pair write threw (or could not be attempted). Nothing from this
    /// attempt is guaranteed stored, so the terminal state is derived from the
    /// store's real state: a usable prior pair keeps the user signed in with
    /// the **stored** cert's validity; otherwise the flow fails and the user
    /// can retry.
    private func finishWithStoreFailure(generation: Int, cluster: TeleportCluster) async {
        guard generation == requestGeneration else { return }
        guard let snapshot = await keyRing.liveCredentialSnapshot(for: cluster.id),
              let storedCert = OpenSSHCertificate.parse(authorizedKeysOrPEM: snapshot.certPEM) else {
            // The snapshot read is an await too; a supersession during it must
            // not write a stale failure over the newer state.
            guard generation == requestGeneration else { return }
            state = .failed(.unknown("credentials could not be stored"))
            return
        }
        guard generation == requestGeneration else { return }   // the read is an await too
        state = .success(
            certValidUntil: storedCert.validBeforeDate,
            logins: TeleportHostLogin.nonInternalPrincipals(of: storedCert)
        )
    }

    func cancel() async {
        logger.info("cancelling login")
        // Bump before the state write so a stale continuation cannot overwrite
        // `.faceIDCancelled`.
        requestGeneration &+= 1
        // There's no way to cancel a blocking SecKeyCreateSignature from
        // outside (the LAContext is internal to the signer). The user
        // cancels via the Face ID prompt's Cancel button, which surfaces
        // as a SignerError → .faceIDCancelled. We just reset the state.
        //
        // This does NOT cancel the in-flight `login/begin`/`login/finish`
        // request and cannot dismiss a live Face ID prompt; the generation
        // bump bounds the *writes*, not the flow.
        state = .failed(.faceIDCancelled)
    }

    /// Latch a dismissal synchronously, before the async teardown is
    /// scheduled. Idempotent (the toolbar Cancel followed by `.onDisappear`
    /// double-latches harmlessly) and per-flow (never reset).
    func latchDismissal() {
        guard !isDismissalLatched else { return }
        requestGeneration &+= 1
        isDismissalLatched = true
    }

    // MARK: - Error mapping

    /// Map an HTTP/URLSession error to a `TeleportLoginError`.
    private func mapHTTPError(_ error: Error) -> TeleportLoginError {
        // The concrete HTTP client wraps URLSession errors in HeadlessError
        // (shared with Phase 1). Phase 3 has no timeout-specific UX, so every
        // transport failure is a network loss — classified on the case, not
        // on the OS-localized message.
        if let headlessError = error as? HeadlessError {
            switch headlessError {
            case .transport:
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
    /// Internal (not private) so the mapping is unit-testable directly.
    func mapSignerError(_ error: Error) -> TeleportLoginError {
        let msg = error.localizedDescription.lowercased()

        // A message that carries a *more specific* state than the generic
        // cancel wins. The legacy LAError-flavored strings are matched first:
        //   - .biometryLockout → "lockout"
        //   - .biometryNotEnrolled → "not enrolled" / "not available"
        if msg.contains("lockout") {
            return .faceIDUnavailable("Face ID is locked. Enter your passcode to unlock Face ID, then try again.")
        }
        if msg.contains("not enrolled") || msg.contains("not available") || msg.contains("biometry") {
            return .faceIDUnavailable("Face ID isn't available. Set up Face ID in iOS Settings.")
        }

        // Otherwise the typed OSStatus decides. The biometric prompt fails
        // through `SecKeyCreateSignature` with a Security-framework status in
        // `NSOSStatusErrorDomain` (there is no `LAContext` on this path), so
        // `errSecUserCanceled` classifies a cancel locale-independently: a
        // non-English message matches nothing above and lands here. Only the
        // cancel code is mapped — `errSecAuthFailed` is a generic
        // authentication failure, and claiming "Face ID is locked" for it
        // would be a new lie.
        if let signerError = error as? SignerError,
           case .biometricSigningFailed(_, let status) = signerError,
           status == errSecUserCanceled {
            return .faceIDCancelled
        }

        // Locale-dependent cancel fallback for untyped signer failures.
        if msg.contains("cancel") {
            return .faceIDCancelled
        }
        return .faceIDUnavailable(error.localizedDescription)
    }
}
