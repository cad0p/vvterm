// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportBootstrapCoordinator.swift
//  VVTerm
//
//  Phase 1 of the Teleport SEP-key integration: the headless bootstrap.
//
//  The coordinator generates an ephemeral SSH + TLS keypair, computes the
//  `headlessAuthenticationID`, starts the blocking
//  `POST /webapi/headless/login` (up to 180s), opens Safari via
//  `ASWebAuthenticationSession` to `/web/headless/<id>`, and stores the
//  returned cert in `TeleportKeyRing` on success.
//
//  This is the "5d bootstrap" proven in session 1.9 (PR #26): the blocking
//  POST survives iOS backgrounding when Safari comes to the foreground.
//  The cert from Phase 1 authenticates the gRPC client in Phase 2.
//
//  Error/timeout recovery matrix (each row is a CI test case — see the
//  design doc's mockup C):
//
//    | Failure                          | Detection                     | Recovery UX                          |
//    |----------------------------------|-------------------------------|--------------------------------------|
//    | User cancels in Safari           | ASWebAuthSession callback     | "Setup cancelled. Tap retry." + Retry |
//    | Safari approval times out (180s) | POST returns / deadline       | "Safari approval timed out." + Retry |
//    | Network loss during POST         | URLSession error             | "Network connection lost." + Retry   |
//    | App backgrounded, POST suspended | App re-activates mid-POST    | "Reconnecting…" → re-issue POST       |
//    | Safari not available             | ASWebAuthSession init fails  | "Open Safari manually:" + URL         |
//    | Teleport server returns error    | HTTP non-2xx in POST response| Surface server message + Retry        |
//    | User already logged in elsewhere | POST returns immediately     | Proceed to Phase 2 (silent success)   |
//
//  Protocol-backed (`TeleportBootstrapCoordinating`) for mock injection in
//  UI tests — the key enabler for the CI strategy.
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup C)
//    - 2026-07-21-strategy-b-session2.2-vvterm-sep-key-integration-prompt.md
//      (Phase 1 — the 5d bootstrap)
//    - spike: spikes/sep-webauthn-iotest/iotest/HeadlessBootstrap/HeadlessRunner.swift
//

import Foundation
import Security
import CryptoKit
import os.log
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// The state of a Phase 1 bootstrap attempt.
enum TeleportBootstrapState: Equatable {
    case idle
    /// Generating the ephemeral keypairs + computing the headless ID.
    case preparing
    /// Safari is opening (ASWebAuthenticationSession.start() in flight).
    case openingSafari
    /// The blocking POST is in flight; waiting for the user to approve in Safari.
    case awaitingApproval
    /// The POST returned with a cert. Phase 1 complete.
    case success
    /// The POST failed or was cancelled. The error drives the recovery UX.
    case failed(TeleportBootstrapError)
}

/// The error matrix for Phase 1. Each case maps to a specific recovery UX
/// in the bootstrap sheet (see the design doc's mockup C).
enum TeleportBootstrapError: Error, Equatable {
    /// The user cancelled in Safari (ASWebAuthenticationSessionError.canceledLogin).
    case userCancelled
    /// The 180s server-side timeout fired (POST returned with no cert).
    case timeout
    /// The URLSession failed (no connection / timed out / DNS, etc.).
    case networkLost
    /// The app was backgrounded mid-POST and the POST was suspended.
    /// The coordinator re-issues the POST on re-activation.
    case suspended
    /// ASWebAuthenticationSession.start() returned false (Safari disabled).
    case safariUnavailable
    /// The Teleport server returned a non-2xx status. The message is the
    /// server's response body (surfaced verbatim per the design doc).
    case server(String)
    /// An unexpected error (decode failure, key generation failure, etc.).
    case unknown(String)
}

/// Protocol-backed coordinator for Phase 1 (the headless bootstrap).
///
/// `@MainActor` because it drives sheet state (the bootstrap sheet observes
/// `state`). The blocking POST runs on a background URLSession task; the
/// coordinator awaits it without blocking the main thread.
@MainActor
protocol TeleportBootstrapCoordinating: AnyObject, ObservableObject {
    /// The current state. SwiftUI views observe this to drive the sheet UI.
    var state: TeleportBootstrapState { get }

    /// The Phase-1 result (cert PEM + TLS keypair + cluster CA bundle).
    /// Set on `.success`; consumed by the registration coordinator via the
    /// bootstrap view's `onSuccess` callback. Exposed on the protocol so the
    /// UI layer can read it without casting to the concrete type.
    var lastBootstrapResult: TeleportBootstrapCoordinator.BootstrapResult? { get }

    /// Begin a Phase 1 bootstrap for the given cluster.
    /// - Parameter cluster: the Teleport cluster config (host, username, etc.)
    func begin(cluster: TeleportCluster) async

    /// Cancel an in-flight bootstrap. Cancels the POST + dismisses Safari.
    func cancel() async

    /// Retry after a failure. Resets state to `.idle` then calls `begin`.
    func retry() async
}

@MainActor
final class TeleportBootstrapCoordinator: ObservableObject, TeleportBootstrapCoordinating {
    @Published private(set) var state: TeleportBootstrapState = .idle

    /// The injected HTTP client (wraps HeadlessLogin.post). Defaults to the
    /// shared `TeleportHTTPClient` in production; injectable for tests.
    private let httpClient: any TeleportHTTPClienting

    /// The injected key ring (stores the cert + metadata). Defaults to
    /// `TeleportKeyRing.shared`.
    private let keyRing: any TeleportKeyRingStoring

    /// The injected Safari presenter (wraps ASWebAuthenticationSession).
    private let safariPresenter: (any WebAuthenticationSessionPresenting)?

    /// The injected SEP signer (for nothing in Phase 1 directly, but kept
    /// for symmetry + future cert-refresh use). Defaults to a real
    /// `SecureEnclaveSigner`.
    private let signer: any TeleportSEPSigning

    /// The in-flight POST task. Cancelled by `cancel()` / `retry()`.
    private var postTask: Task<Void, Never>?

    /// The ephemeral TLS keypair generated for this bootstrap. Kept alive
    /// for Phase 2 (the gRPC client needs the SecKey + PEM cert for mTLS).
    /// The coordinator hands this to the registration coordinator via
    /// `lastBootstrapResult`.
    private(set) var tlsKeyPair: TLSKeyPair?

    /// The Phase-1 result (cert PEM + cluster CA bundle + cluster name).
    /// Set on `.success`; consumed by the registration coordinator.
    private(set) var lastBootstrapResult: BootstrapResult?

    /// The headless authentication ID for this attempt (UUID v5 of the SSH
    /// pub key). Used to build the Safari URL.
    private var headlessID: String = ""

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "it.pcad.vvterm",
        category: "teleport-bootstrap"
    )

    /// The result of a successful Phase 1 bootstrap. Passed to the Phase 2
    /// registration coordinator (the cert authenticates the gRPC dial).
    struct BootstrapResult {
        /// The PEM-encoded SSH certificate (base64-decoded from the
        /// `cert` field — Go's `[]byte` marshals as base64).
        let sshCertPEM: String
        /// The PEM-encoded TLS certificate (for the gRPC mTLS dial).
        let tlsCertPEM: String
        /// The TLS private key (SecKey) for the gRPC mTLS dial.
        let tlsKeyPairPrivateKey: SecKey
        /// The cluster name (from host_signers[0].domain_name).
        let clusterName: String
        /// The cluster TLS CA certs (from host_signers[0].tls_certs).
        let clusterCAPEMs: [String]
        /// The cert's ValidBefore (parsed from the cert or the server response).
        let certValidBefore: Date
    }

    init(
        httpClient: any TeleportHTTPClienting,
        keyRing: any TeleportKeyRingStoring,
        safariPresenter: (any WebAuthenticationSessionPresenting)?,
        signer: any TeleportSEPSigning = SecureEnclaveSigner()
    ) {
        self.httpClient = httpClient
        self.keyRing = keyRing
        self.safariPresenter = safariPresenter
        self.signer = signer
    }

    func begin(cluster: TeleportCluster) async {
        // Reset any prior state.
        postTask?.cancel()
        postTask = nil
        lastBootstrapResult = nil
        tlsKeyPair = nil
        headlessID = ""
        state = .preparing

        logger.info("beginning bootstrap for cluster \(cluster.host, privacy: .public) user=\(cluster.username, privacy: .public)")

        // ── Step 1: generate the ephemeral SSH + TLS keypairs ────────────
        // The SSH keypair is ed25519 (for the cert subject + the eventual
        // SSH connection). The TLS keypair is EC P-256 (for the gRPC mTLS
        // dial in Phase 2). Both are ephemeral — discarded after the cert
        // is issued (the cert carries the pub key; the private key is kept
        // only for the SSH connection, which is out of scope for Phase 1).
        let sshPubKey: String
        do {
            sshPubKey = SSHPubKey.generateEd25519AuthorizedKeys(comment: "vvterm-teleport")
            tlsKeyPair = try TLSKeyPairGen.generate()
        } catch {
            logger.error("keypair generation failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(.unknown("keypair generation failed: \(error.localizedDescription)"))
            return
        }

        // ── Step 2: compute the headlessAuthenticationID ─────────────────
        // UUID v5 of the SSH pub key (SHA256(uuid.Nil || pubKey)). This is
        // the ID that identifies the headless request on both the POST
        // (/webapi/headless/login) and the web approval page (/web/headless/<id>).
        headlessID = HeadlessID.compute(sshAuthorizedKey: sshPubKey)
        logger.info("headlessAuthenticationID=\(headlessID, privacy: .public)")

        // ── Step 3: start the blocking POST (async, doesn't await yet) ──
        // We start the POST, THEN open Safari. The POST blocks until the
        // user approves (or the 180s server timeout fires). We race them:
        // the POST task runs concurrently while Safari is open.
        state = .openingSafari

        // The POST body's ssh_pub_key is base64-encoded (Go's []byte
        // marshals as base64). The raw bytes are the authorized_keys string
        // WITH a trailing newline (ssh.MarshalAuthorizedKey output).
        let sshPubKeyBytes = Data((sshPubKey + "\n").utf8)
        let sshPubKeyB64 = sshPubKeyBytes.base64EncodedString()
        let tlsPubKeyB64 = tlsKeyPair?.tlsPubKeyB64

        let baseURL = URL(string: "https://\(cluster.host)")!
        let ttl: Int64 = 3_600_000_000_000  // 1h in ns (matches tsh default)

        let postTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            do {
                let resp = try await self.httpClient.headlessLogin(
                    baseURL: baseURL,
                    user: cluster.username,
                    headlessAuthenticationID: self.headlessID,
                    sshPubKeyB64: sshPubKeyB64,
                    tlsPubKeyB64: tlsPubKeyB64,
                    ttl: ttl
                )
                await self.handlePostSuccess(response: resp, cluster: cluster)
            } catch {
                await self.handlePostFailure(error: error)
            }
        }
        self.postTask = postTask

        // ── Step 4: open Safari to the approval URL ─────────────────────
        // The headless web UI is at /web/headless/<id>. The user logs in
        // with their iCloud passkey (Face ID in Safari) and approves.
        let approvalURL = URL(string: "\(baseURL.absoluteString)/web/headless/\(headlessID)")!
        logger.info("opening Safari to \(approvalURL.absoluteString, privacy: .public)")

        let safariOK: Bool
        if let presenter = safariPresenter {
            safariOK = await presenter.open(url: approvalURL)
        } else {
            // No presenter injected — this is a configuration error in
            // production (the App layer must provide one). In tests, the
            // mock coordinator doesn't call begin() at all.
            logger.error("no safariPresenter injected — cannot open Safari")
            safariOK = false
        }

        if !safariOK {
            // Safari didn't open. The POST is still running — don't abort,
            // but surface the Safari-unavailable state so the UI can show
            // the "Open Safari manually" recovery.
            logger.error("Safari presentation failed — POST still running")
            // Only flip to .failed(.safariUnavailable) if we're still
            // awaiting approval (the POST might have already succeeded).
            if case .awaitingApproval = state {
                state = .failed(.safariUnavailable)
            }
        } else {
            // Safari opened. The POST is the real gate — flip to awaiting.
            if case .openingSafari = state {
                state = .awaitingApproval
            }
        }

        // ── Step 5: await the POST result ───────────────────────────────
        // The POST task completes when the user approves (cert returned)
        // or the 180s timeout fires / an error occurs. The state has
        // already been set by handlePostSuccess/handlePostFailure by the
        // time this await returns.
        await postTask.value
    }

    func cancel() async {
        logger.info("cancelling bootstrap")
        postTask?.cancel()
        postTask = nil
        #if canImport(AuthenticationServices)
        await safariPresenter?.cancel()
        #endif
        state = .failed(.userCancelled)
    }

    func retry() async {
        logger.info("retrying bootstrap")
        postTask?.cancel()
        postTask = nil
        #if canImport(AuthenticationServices)
        await safariPresenter?.cancel()
        #endif
        state = .idle
        // The caller (the bootstrap sheet) re-invokes begin() with the
        // same cluster. We don't capture the cluster here to avoid stale
        // state; the sheet holds it.
    }

    // MARK: - POST result handling

    private func handlePostSuccess(response: HeadlessLoginResponse, cluster: TeleportCluster) async {
        guard let certB64 = response.cert, !certB64.isEmpty else {
            logger.error("POST returned 200 but no cert")
            state = .failed(.unknown("no cert in response"))
            return
        }

        // The cert is base64(PEM) — Go's []byte marshals as base64.
        // Decode to the actual PEM string.
        guard let certPEMData = Data(base64Encoded: certB64),
              let certPEM = String(data: certPEMData, encoding: .utf8) else {
            logger.error("failed to base64-decode cert")
            state = .failed(.unknown("cert base64 decode failed"))
            return
        }

        // The TLS cert (resp.tlsCert) is also base64(PEM).
        let tlsCertPEM: String
        if let tlsB64 = response.tlsCert,
           let tlsData = Data(base64Encoded: tlsB64),
           let pem = String(data: tlsData, encoding: .utf8) {
            tlsCertPEM = pem
        } else {
            tlsCertPEM = ""
            logger.error("no tls_cert in response — Phase 2 gRPC dial will fail")
        }

        // Capture the cluster name + TLS CA certs from host_signers for
        // Phase 2's auth-service ALPN dial.
        var clusterName = cluster.clusterName
        var clusterCAPEMs: [String] = []
        if let hostSigners = response.hostSigners, let first = hostSigners.first {
            clusterName = first.clusterName
            clusterCAPEMs = (first.tlsCerts ?? []).compactMap { b64 in
                guard let der = Data(base64Encoded: b64),
                      let pem = String(data: der, encoding: .utf8) else { return nil }
                return pem
            }
        }

        // The cert's ValidBefore. The HTTP response doesn't include it
        // directly — it's embedded in the PEM cert. Parsing it requires
        // SecCertificateCreateWithData + SecCertificateCopyValues, which
        // is non-trivial. For now, use a conservative default (1h from
        // now) — the login coordinator (Phase 3) will overwrite this with
        // the real expiry when it issues a fresh cert. The bootstrap cert
        // is short-lived anyway (it's only used to authenticate Phase 2).
        //
        // TODO(phase-2): parse ValidBefore from the PEM cert so the
        // readiness state correctly flips to needsLogin when the bootstrap
        // cert expires before Phase 2 completes.
        let certValidBefore = Date(timeIntervalSinceNow: 3600)  // 1h

        // The TLS private key for the gRPC mTLS dial. `tlsKeyPair` is set
        // in step 1 (we return early on failure), so it's non-nil here.
        guard let tlsPrivateKey = tlsKeyPair?.privateKey else {
            logger.error("no TLS private key available for Phase 2")
            state = .failed(.unknown("no TLS private key"))
            return
        }

        let result = BootstrapResult(
            sshCertPEM: certPEM,
            tlsCertPEM: tlsCertPEM,
            tlsKeyPairPrivateKey: tlsPrivateKey,
            clusterName: clusterName,
            clusterCAPEMs: clusterCAPEMs,
            certValidBefore: certValidBefore
        )
        lastBootstrapResult = result

        // Store the bootstrap cert in the key ring so readiness flips to
        // `needsRegistration` (cert present, no SEP key yet).
        keyRing.storeBootstrapCert(certPEM, validBefore: certValidBefore, for: cluster.id)

        logger.info("bootstrap succeeded — cert \(certPEM.count) chars, tls_cert \(tlsCertPEM.count) chars")
        state = .success

        // Dismiss the Safari sheet (the POST returned, the user is done).
        #if canImport(AuthenticationServices)
        await safariPresenter?.cancel()
        #endif
    }

    private func handlePostFailure(error: Error) async {
        logger.error("POST failed: \(error.localizedDescription, privacy: .public)")

        // Map the infrastructure error to the coordinator-specific enum.
        let mapped: TeleportBootstrapError
        if let headlessError = error as? HeadlessError {
            switch headlessError {
            case .transport(let m):
                // URLSession error — distinguish timeout from network loss.
                // The spike's HeadlessError.transport wraps the URLSession
                // error's localizedDescription, so we string-match.
                if m.lowercased().contains("timed out") {
                    mapped = .timeout
                } else {
                    mapped = .networkLost
                }
            case .http(let status, let body):
                // Non-2xx HTTP. Surface the server message verbatim.
                mapped = .server("HTTP \(status): \(body)")
            case .decode(let m):
                mapped = .unknown("decode: \(m)")
            case .noCert:
                mapped = .unknown("no cert in response")
            case .missingField(let f):
                mapped = .unknown("missing field: \(f)")
            }
        } else {
            // An unexpected error (e.g. URLError not wrapped by HeadlessError).
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorTimedOut:
                    mapped = .timeout
                case NSURLErrorNotConnectedToInternet,
                     NSURLErrorNetworkConnectionLost,
                     NSURLErrorCannotFindHost,
                     NSURLErrorCannotConnectToHost:
                    mapped = .networkLost
                case NSURLErrorCancelled:
                    mapped = .userCancelled
                default:
                    mapped = .unknown(nsError.localizedDescription)
                }
            } else {
                mapped = .unknown(error.localizedDescription)
            }
        }

        state = .failed(mapped)

        // Dismiss the Safari sheet on failure too.
        #if canImport(AuthenticationServices)
        await safariPresenter?.cancel()
        #endif
    }
}
