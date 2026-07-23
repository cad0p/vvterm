// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  HeadlessRunner.swift
//  iotest
//
//  Session 1.9 — drives the 5d headless bootstrap flow and reports the
//  status of each step. The flow is:
//
//    1. Generate an ephemeral ed25519 SSH keypair (reuse SSHPubKey).
//    2. Compute headlessAuthenticationID = NewHeadlessAuthenticationID(pubKey).
//    3. Start POST /webapi/headless/login (blocks until approval or 180s).
//    4. Open https://teleport.pcad.it/web/headless/<id> in
//       ASWebAuthenticationSession (primary) or UIApplication.open (fallback).
//    5. User logs in with their iCloud passkey (Face ID in Safari), taps
//       Approve, does the approval WebAuthn assertion.
//    6. The blocking POST returns {cert, host_signers}.
//
//  All step results are emitted as structured os_log lines (greppable by CI
//  with `grep -F "[IOTEST]"`) AND surfaced to the SwiftUI log panel.
//
//  The runner is @MainActor because it publishes to SwiftUI. The blocking
//  POST runs on a background thread via async/await (URLSession.data is
//  non-blocking under the hood).
//

import Foundation
import OSLog
import AuthenticationServices
import UIKit

// MARK: - Log markers

enum HeadlessLog {
    static let logger = Logger(subsystem: "it.pcad.vvterm.iotest", category: "headless")

    // ── Step 1: keypair generated ─────────────────────────────────────
    static func keypairGenerated(pubKeyPrefix: String) {
        logger.notice("[IOTEST] headless_keypair_generated pub_key_prefix=\(pubKeyPrefix, privacy: .public)")
    }

    // ── Step 2: headlessAuthenticationID computed ──────────────────────
    static func headlessIDComputed(id: String) {
        logger.notice("[IOTEST] headless_id_computed id=\(id, privacy: .public)")
    }

    // ── Step 3: blocking POST started ──────────────────────────────────
    static func headlessPostStarted(user: String) {
        logger.notice("[IOTEST] headless_post_started user=\(user, privacy: .public)")
    }
    static func headlessPostReturned(status: Int, hasCert: Bool, hasHostSigners: Bool) {
        logger.notice("[IOTEST] headless_post_returned status=\(status) has_cert=\(hasCert ? "true" : "false") has_host_signers=\(hasHostSigners ? "true" : "false")")
    }
    static func headlessPostFailed(_ reason: String) {
        logger.error("[IOTEST] headless_post_failed reason=\(reason, privacy: .public)")
    }

    // ── Step 4: Safari opened ──────────────────────────────────────────
    static func headlessSafariOpened(method: String, url: String) {
        logger.notice("[IOTEST] headless_safari_opened method=\(method, privacy: .public) url=\(url, privacy: .public)")
    }
    static func headlessSafariFailed(_ reason: String) {
        logger.error("[IOTEST] headless_safari_failed reason=\(reason, privacy: .public)")
    }

    // ── Step 5: user approved (POST returned with cert) ─────────────────
    static func headlessApproved(certLength: Int) {
        logger.notice("[IOTEST] headless_approved cert_length=\(certLength)")
    }

    // ── Step 6: cert extracted ─────────────────────────────────────────
    static func headlessCertExtracted(certPrefix: String) {
        logger.notice("[IOTEST] headless_cert_extracted prefix=\(certPrefix, privacy: .public)")
    }

    // ── Generic ────────────────────────────────────────────────────────
    static func headlessStep(_ step: String, _ message: String) {
        logger.notice("[IOTEST] headless_step \(step, privacy: .public) \(message, privacy: .public)")
    }
    static func headlessResult(_ summary: String) {
        logger.notice("[IOTEST] headless_result \(summary, privacy: .public)")
    }
}

// MARK: - Step state

enum HeadlessStepStatus: String {
    case pending, inProgress, done, failed
}

struct HeadlessStep: Identifiable {
    let id: Int
    let title: String
    var status: HeadlessStepStatus = .pending
    var detail: String = ""
}

// MARK: - Runner

@MainActor
final class HeadlessRunner: NSObject, ObservableObject {
    @Published var steps: [HeadlessStep] = []
    @Published var overallStatus: String = "idle"   // idle | running | passed | failed
    @Published var certBase64: String = ""
    @Published var tlsCertPEM: String = ""
    @Published var headlessID: String = ""
    @Published var approvalURL: String = ""
    @Published var log: [String] = []
    /// Which Safari-presentation method was used ("aswebauth" or "uiapplication").
    @Published var safariMethod: String = ""
    /// How long the blocking POST took (seconds), if it returned.
    @Published var postDuration: Double = 0
    /// The error if the POST failed (the iOS-backgrounding signal).
    @Published var postError: String = ""

    /// The ephemeral TLS keypair generated for this bootstrap. The public key
    /// is sent as `tls_pub_key` so Teleport issues a TLS cert; the private key
    /// is kept for Phase 2 (gRPC mTLS dial). Session 1.10.
    var tlsKeyPair: TLSKeyPair?

    /// The ASWebAuthenticationSession (if using that path).
    private var webAuthSession: ASWebAuthenticationSession?

    /// The Teleport web proxy base URL.
    let baseURL = URL(string: "https://teleport.pcad.it")!
    /// The callback scheme for ASWebAuthenticationSession. The headless web
    /// UI doesn't redirect on approval (it shows "approved"), so this is
    /// only used for session.cancel() to dismiss the tab after the POST
    /// returns. See HeadlessRequest.tsx:88-93.
    let callbackScheme = "vvterm"

    func resetSteps() {
        steps = [
            HeadlessStep(id: 1, title: "Generate ephemeral SSH keypair"),
            HeadlessStep(id: 2, title: "Compute headlessAuthenticationID"),
            HeadlessStep(id: 3, title: "Start blocking POST /webapi/headless/login"),
            HeadlessStep(id: 4, title: "Open Safari to /web/headless/<id>"),
            HeadlessStep(id: 5, title: "User approves (POST returns)"),
            HeadlessStep(id: 6, title: "Cert extracted"),
        ]
        overallStatus = "idle"
        certBase64 = ""
        tlsCertPEM = ""
        headlessID = ""
        approvalURL = ""
        log = []
        safariMethod = ""
        postDuration = 0
        postError = ""
        tlsKeyPair = nil
        webAuthSession = nil
    }

    // MARK: - Run the bootstrap

    /// Runs the full 5d headless bootstrap. The `user` is the Teleport
    /// username; `useASWebAuth` selects the Safari-presentation method
    /// (true = ASWebAuthenticationSession, false = UIApplication.open).
    func runBootstrap(user: String, useASWebAuth: Bool) async {
        resetSteps()
        overallStatus = "running"
        appendLog("Starting headless bootstrap (user=\(user), method=\(useASWebAuth ? "ASWebAuthenticationSession" : "UIApplication.open"))…")
        HeadlessLog.headlessResult("started user=\(user) method=\(useASWebAuth ? "aswebauth" : "uiapplication")")

        // ── Step 1: generate the ephemeral SSH keypair ──────────────────
        // SSHPubKey.generateEd25519AuthorizedKeys generates a fresh
        // Curve25519 keypair internally and returns the OpenSSH authorized_keys
        // string. The private key is discarded — the spike only needs the
        // pub key for the POST (the cert comes back in the response).
        // Production (session 2.2) will keep the private key for the SSH
        // connection, but for 1.9 we only prove the bootstrap half.
        setStep(1, .inProgress)
        let sshPubKey = SSHPubKey.generateEd25519AuthorizedKeys(comment: "vvterm-headless-spike")
        let pubKeyPrefix = String(sshPubKey.prefix(32))
        HeadlessLog.keypairGenerated(pubKeyPrefix: pubKeyPrefix)
        // Session 1.10: also generate an ephemeral EC P-256 TLS keypair so
        // Teleport issues a TLS cert we can use for the gRPC mTLS dial.
        do {
            tlsKeyPair = try TLSKeyPairGen.generate()
            HeadlessLog.headlessStep("tls_keypair", "generated P-256 keypair")
        } catch {
            HeadlessLog.headlessPostFailed("TLS keypair generation failed: \(error.localizedDescription)")
        }
        appendLog("[1/6] SSH keypair generated: \(pubKeyPrefix)…")
        setStep(1, .done, "ed25519, pub \(pubKeyPrefix.prefix(20))…")

        // ── Step 2: compute headlessAuthenticationID ────────────────────
        setStep(2, .inProgress)
        headlessID = HeadlessID.compute(sshAuthorizedKey: sshPubKey)
        HeadlessLog.headlessIDComputed(id: headlessID)
        appendLog("[2/6] headlessAuthenticationID = \(headlessID)")
        setStep(2, .done, headlessID)

        // ── Step 3: start the blocking POST (async, doesn't await yet) ──
        // We start the POST, THEN open Safari. The POST blocks until the
        // user approves. We race them: the POST task runs concurrently while
        // Safari is open.
        setStep(3, .inProgress)
        // The POST body's ssh_pub_key is base64-encoded (Go's []byte
        // marshals as base64). The raw bytes are the authorized_keys string
        // WITH a trailing newline (ssh.MarshalAuthorizedKey output).
        let sshPubKeyBytes = Data((sshPubKey + "\n").utf8)
        let sshPubKeyB64 = sshPubKeyBytes.base64EncodedString()
        let req = HeadlessLoginReq(
            user: user,
            headlessAuthenticationID: headlessID,
            sshPubKey: sshPubKeyB64,
            tlsPubKey: tlsKeyPair?.tlsPubKeyB64,
            ttl: 3_600_000_000_000,  // 1h in ns (matches tsh default)
            compatibility: ""
        )
        HeadlessLog.headlessPostStarted(user: user)
        appendLog("[3/6] POST /webapi/headless/login started (blocks until approval or 180s)…")

        let postTask = Task<(HeadlessLoginResponse?, Double, HeadlessError?), Never> {
            let start = Date()
            do {
                let resp = try await HeadlessLogin.post(baseURL: self.baseURL, req: req)
                let elapsed = Date().timeIntervalSince(start)
                let hasCert = (resp.cert ?? "").isEmpty == false
                let hasHostSigners = (resp.hostSigners ?? []).isEmpty == false
                HeadlessLog.headlessPostReturned(status: 200, hasCert: hasCert, hasHostSigners: hasHostSigners)
                return (resp, elapsed, nil)
            } catch let he as HeadlessError {
                let elapsed = Date().timeIntervalSince(start)
                HeadlessLog.headlessPostFailed(he.errorDescription ?? "?")
                return (nil, elapsed, he)
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                HeadlessLog.headlessPostFailed(error.localizedDescription)
                return (nil, elapsed, HeadlessError.transport(error.localizedDescription))
            }
        }

        // ── Step 4: open Safari to the approval URL ─────────────────────
        setStep(4, .inProgress)
        approvalURL = "\(baseURL.absoluteString)/web/headless/\(headlessID)"
        let method = useASWebAuth ? "aswebauth" : "uiapplication"
        safariMethod = method
        HeadlessLog.headlessSafariOpened(method: method, url: approvalURL)
        appendLog("[4/6] Opening Safari (\(method)): \(approvalURL)")

        let safariOK: Bool
        if useASWebAuth {
            safariOK = await openSafariASWebAuth(url: URL(string: approvalURL)!)
        } else {
            safariOK = await openSafariUIApplication(url: URL(string: approvalURL)!)
        }
        if !safariOK {
            setStep(4, .failed, "Safari did not open")
            // Don't abort — the POST is still running. The user might approve
            // via another device (tsh headless approve). Log + continue.
            HeadlessLog.headlessSafariFailed("Safari presentation failed")
            appendLog("[4/6] WARNING: Safari presentation failed — POST still running")
        } else {
            setStep(4, .done, method)
        }

        // ── Step 5+6: await the POST result ─────────────────────────────
        setStep(5, .inProgress)
        setStep(6, .inProgress)
        appendLog("[5/6] Waiting for POST to return (user must approve in Safari)…")

        let (resp, elapsed, postErr) = await postTask.value
        postDuration = elapsed

        if let postErr {
            postError = postErr.errorDescription ?? "?"
            setStep(5, .failed, postError)
            setStep(6, .failed, "POST failed")
            overallStatus = "failed"
            HeadlessLog.headlessResult("FAILED at POST: \(postError) (took \(String(format: "%.1f", elapsed))s)")
            appendLog("[5/6] FAILED: \(postError) (took \(String(format: "%.1f", elapsed))s)")
            // Cancel the ASWebAuthenticationSession if it's still open.
            webAuthSession?.cancel()
            return
        }

        guard let resp, let cert = resp.cert, !cert.isEmpty else {
            setStep(5, .failed, "no cert in response")
            setStep(6, .failed, "no cert")
            overallStatus = "failed"
            HeadlessLog.headlessResult("FAILED: no cert in response (took \(String(format: "%.1f", elapsed))s)")
            appendLog("[5/6] FAILED: no cert in response (took \(String(format: "%.1f", elapsed))s)")
            webAuthSession?.cancel()
            return
        }

        certBase64 = cert
        // The TLS cert (resp.tlsCert) is a Go []byte marshaled as base64,
        // so it's base64(PEM). Decode to the actual PEM string for Phase 2.
        // (Same for resp.cert — it's base64(PEM) too; 1.9 stored it as-is.)
        if let tlsB64 = resp.tlsCert,
           let tlsPEMData = Data(base64Encoded: tlsB64),
           let tlsPEM = String(data: tlsPEMData, encoding: .utf8) {
            tlsCertPEM = tlsPEM
        } else {
            tlsCertPEM = ""
        }
        let certLen = cert.count
        HeadlessLog.headlessApproved(certLength: certLen)
        appendLog("[5/6] POST returned (took \(String(format: "%.1f", elapsed))s, cert \(certLen) chars, tls_cert \(tlsCertPEM.count) chars)")
        setStep(5, .done, "approved, \(String(format: "%.1f", elapsed))s")

        // Step 6: cert extracted.
        let certPrefix = String(cert.prefix(24))
        HeadlessLog.headlessCertExtracted(certPrefix: certPrefix)
        appendLog("[6/6] Cert extracted (prefix \(certPrefix)…)")
        setStep(6, .done, "prefix \(certPrefix.prefix(16))…")

        overallStatus = "passed"
        HeadlessLog.headlessResult("PASSED — cert returned in \(String(format: "%.1f", elapsed))s via \(method)")
        appendLog("=== PASSED — cert returned in \(String(format: "%.1f", elapsed))s via \(method) ===")

        // Cancel the ASWebAuthenticationSession to dismiss the Safari tab.
        webAuthSession?.cancel()
    }

    // MARK: - Safari presentation

    /// Open the URL via ASWebAuthenticationSession. This presents Safari
    /// in-app (not a full app switch), which may keep VVTerm's process
    /// more active than UIApplication.open. The callback scheme is only
    /// used for auto-dismiss; the headless web UI doesn't redirect on
    /// approval (per HeadlessRequest.tsx:88-93), so the callback won't
    /// fire naturally — we cancel the session manually after the POST
    /// returns.
    ///
    /// We resume the continuation as soon as `start()` succeeds, because
    /// we only need to know Safari *opened* (not whether it *closed*).
    /// The blocking POST is the real gate; the ASWebAuthenticationSession
    /// callback (if it ever fires) is a bonus we log but don't await on.
    private func openSafariASWebAuth(url: URL) async -> Bool {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { _, error in
                // The callback fires if the web UI redirects to vvterm://
                // (it doesn't, per HeadlessRequest.tsx:88-93) or if the
                // user dismisses the sheet. We log it but don't resume —
                // the continuation was already resumed on start().
                if let error {
                    HeadlessLog.headlessSafariFailed("aswebauth callback: \(error.localizedDescription)")
                }
            }
            // presentationContextProvider is needed on iOS 13+.
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            webAuthSession = session
            let started = session.start()
            // Resume immediately — we only care that Safari opened. The
            // POST task (already started) is the real gate.
            continuation.resume(returning: started)
        }
    }

    /// Open the URL via UIApplication.open (full app switch to Safari).
    /// Strictly worse for process-keep-alive than ASWebAuthenticationSession,
    /// but worth testing as a comparison.
    @MainActor
    private func openSafariUIApplication(url: URL) async -> Bool {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Step helpers

    private func setStep(_ id: Int, _ status: HeadlessStepStatus, _ detail: String = "") {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[idx].status = status
        if !detail.isEmpty { steps[idx].detail = detail }
    }

    private func appendLog(_ line: String) {
        log.append(line)
    }

    /// Build a full log dump for the "Copy logs" button. Includes the
    /// key results (headless ID, cert, POST duration, status) followed
    /// by the complete log panel, so the user can paste it into a results
    /// note without needing Xcode's console.
    func fullLogDump() -> String {
        var lines: [String] = []
        lines.append("=== Session 1.9 Headless Bootstrap — results ===")
        lines.append("Status: \(overallStatus)")
        lines.append("Method: \(safariMethod)")
        lines.append("Headless ID: \(headlessID)")
        lines.append("POST duration: \(String(format: "%.1f", postDuration))s")
        if !postError.isEmpty {
            lines.append("POST error: \(postError)")
        }
        if !certBase64.isEmpty {
            lines.append("Cert length: \(certBase64.count) chars")
            lines.append("Cert (first 80): \(String(certBase64.prefix(80)))")
        }
        lines.append("")
        lines.append("=== Log ===")
        lines.append(contentsOf: log)
        return lines.joined(separator: "\n")
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension HeadlessRunner: ASWebAuthenticationPresentationContextProviding {
    @MainActor
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Return the key window of the active scene. On iOS this is the
        // app's main window.
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}
