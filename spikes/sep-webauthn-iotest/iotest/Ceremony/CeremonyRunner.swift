// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  CeremonyRunner.swift
//  iotest
//
//  Session 1.7 — drives the WKWebView WebAuthn ceremony end-to-end and
//  reports the status of each of the four sub-questions:
//
//    1. Face ID prompt appears (navigator.credentials.get invokes the
//       platform authenticator).
//    2. Passwordless login succeeds (the web session is established —
//       /webapi/mfa/login/finishsession returns a bearer token + the
//       __Host-session cookie is set).
//    3. Privilege-token re-auth works (POST /webapi/users/privilege/token
//       with a fresh WebAuthn assertion returns a privilege token string).
//    4. Privilege token is extractable via JS injection (the token string
//       is readable from the webview's JS context).
//
//  The runner does NOT drive the ceremony by clicking the web UI's buttons.
//  Instead it injects JS that calls the same Teleport web-API endpoints the
//  web UI calls (mfaLoginBegin → navigator.credentials.get → mfaLoginFinishSession
//  → privilege/token), so the ceremony is deterministic and observable.
//  The webview's WebAuthn stack (not VVTerm) handles the Face ID prompt —
//  VVTerm only kicks off navigator.credentials.get and observes the result.
//
//  All step results are emitted as structured os_log lines (greppable by CI
//  with `grep -F "[IOTEST]"`) AND surfaced to the SwiftUI log panel.
//
//  Implementation note (same pattern as WebAuthnProbe): evaluateJavaScript
//  does NOT await JS Promises. navigator.credentials.get() returns a Promise,
//  so the injected JS stores the result in window.__iotestCeremony* globals
//  and Swift polls window.__iotestCeremonyDone until true, then reads
//  window.__iotestCeremonyResult. This keeps the deployment target at 16.1
//  (callAsyncJavaScript is iOS 17+).
//

import Foundation
import OSLog
import WebKit

// MARK: - Log markers

enum CeremonyLog {
    static let logger = Logger(subsystem: "it.pcad.vvterm.iotest", category: "ceremony")

    // ── Step 1: Face ID prompt ─────────────────────────────────────────
    static func ceremonyLoginBeginPosted(challengeLength: Int) {
        logger.notice("[IOTEST] ceremony_login_begin_posted challenge=\(challengeLength)")
    }
    static func ceremonyFaceIDPromptStarted() {
        logger.notice("[IOTEST] ceremony_faceid_prompt_started")
    }
    static func ceremonyFaceIDPromptResolved() {
        logger.notice("[IOTEST] ceremony_faceid_prompt_resolved")
    }
    static func ceremonyFaceIDPromptRejected(_ reason: String) {
        logger.error("[IOTEST] ceremony_faceid_prompt_rejected reason=\(reason, privacy: .public)")
    }

    // ── Step 2: passwordless login ─────────────────────────────────────
    static func ceremonyLoginFinishPosted(status: Int, hasToken: Bool) {
        logger.notice("[IOTEST] ceremony_login_finish_posted status=\(status) has_token=\(hasToken ? "true" : "false")")
    }
    static func ceremonyLoginSucceeded(tokenPrefix: String) {
        logger.notice("[IOTEST] ceremony_login_succeeded token_prefix=\(tokenPrefix, privacy: .public)")
    }
    static func ceremonyLoginFailed(status: Int, body: String) {
        logger.error("[IOTEST] ceremony_login_failed status=\(status) body=\(body, privacy: .public)")
    }

    // ── Step 3: privilege-token re-auth ────────────────────────────────
    static func ceremonyPrivilegeBeginPosted(challengeLength: Int) {
        logger.notice("[IOTEST] ceremony_privilege_begin_posted challenge=\(challengeLength)")
    }
    static func ceremonyPrivilegeFaceIDPromptStarted() {
        logger.notice("[IOTEST] ceremony_privilege_faceid_prompt_started")
    }
    static func ceremonyPrivilegeTokenPosted(status: Int, hasToken: Bool) {
        logger.notice("[IOTEST] ceremony_privilege_token_posted status=\(status) has_token=\(hasToken ? "true" : "false")")
    }
    static func ceremonyPrivilegeTokenSucceeded(tokenLength: Int) {
        logger.notice("[IOTEST] ceremony_privilege_token_succeeded length=\(tokenLength)")
    }
    static func ceremonyPrivilegeTokenFailed(status: Int, body: String) {
        logger.error("[IOTEST] ceremony_privilege_token_failed status=\(status) body=\(body, privacy: .public)")
    }

    // ── Step 4: privilege token extraction ──────────────────────────────
    static func ceremonyPrivilegeTokenExtracted(tokenPrefix: String) {
        logger.notice("[IOTEST] ceremony_privilege_token_extracted prefix=\(tokenPrefix, privacy: .public)")
    }
    static func ceremonyPrivilegeTokenExtractionFailed(_ reason: String) {
        logger.error("[IOTEST] ceremony_privilege_token_extraction_failed reason=\(reason, privacy: .public)")
    }

    // ── Generic ────────────────────────────────────────────────────────
    static func ceremonyStep(_ step: String, _ message: String) {
        logger.notice("[IOTEST] ceremony_step \(step, privacy: .public) \(message, privacy: .public)")
    }
    static func ceremonyJsError(_ message: String) {
        logger.error("[IOTEST] ceremony_js_error=\(message, privacy: .public)")
    }
    static func ceremonyResult(_ summary: String) {
        logger.notice("[IOTEST] ceremony_result \(summary, privacy: .public)")
    }
}

// MARK: - Step state

enum CeremonyStepStatus: String {
    case pending, inProgress, done, failed
}

struct CeremonyStep: Identifiable {
    let id: Int
    let title: String
    var status: CeremonyStepStatus = .pending
    var detail: String = ""
}

// MARK: - Runner

@MainActor
final class CeremonyRunner: NSObject, ObservableObject {
    @Published var steps: [CeremonyStep] = []
    @Published var overallStatus: String = "idle"   // idle | running | passed | failed
    @Published var privilegeToken: String = ""
    @Published var sessionTokenPreview: String = ""
    @Published var log: [String] = []

    private var webView: WKWebView?
    private var pollCount = 0
    private let maxPolls = 150  // 150 × 200ms = 30s timeout for each async JS step

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func resetSteps() {
        steps = [
            CeremonyStep(id: 1, title: "Face ID prompt appears"),
            CeremonyStep(id: 2, title: "Passwordless login succeeds"),
            CeremonyStep(id: 3, title: "Privilege-token re-auth works"),
            CeremonyStep(id: 4, title: "Privilege token extractable"),
        ]
        overallStatus = "idle"
        privilegeToken = ""
        sessionTokenPreview = ""
        log = []
    }

    // MARK: - Run the ceremony

    /// Runs the full 4-step ceremony. Assumes the webview has already loaded
    /// https://teleport.pcad.it/web/login (the ProbeView loads it on appear;
    /// the Ceremony tab shares the same webview instance via the model).
    func runCeremony() async {
        guard let webView else {
            appendLog("ERROR: no webView attached")
            overallStatus = "failed"
            return
        }
        resetSteps()
        overallStatus = "running"
        appendLog("Starting ceremony…")

        // ── Step 1+2: passwordless login ───────────────────────────────
        // One injected JS block does: begin → credentials.get (Face ID) →
        // finishsession. We poll for completion because credentials.get is
        // a Promise that evaluateJavaScript can't await.
        do {
            try await runPasswordlessLogin(webView: webView)
        } catch {
            overallStatus = "failed"
            CeremonyLog.ceremonyResult("FAILED at login: \(error.localizedDescription)")
            appendLog("FAILED at login: \(error.localizedDescription)")
            return
        }

        // ── Step 3+4: privilege token ───────────────────────────────────
        do {
            try await runPrivilegeToken(webView: webView)
        } catch {
            overallStatus = "failed"
            CeremonyLog.ceremonyResult("FAILED at privilege token: \(error.localizedDescription)")
            appendLog("FAILED at privilege token: \(error.localizedDescription)")
            return
        }

        overallStatus = "passed"
        CeremonyLog.ceremonyResult("PASSED — all 4 sub-questions confirmed")
        appendLog("=== PASSED — all 4 sub-questions confirmed ===")
    }

    // MARK: - Step 1+2: passwordless login

    private func runPasswordlessLogin(webView: WKWebView) async throws {
        setStep(1, .inProgress)
        setStep(2, .inProgress)

        // Inject the login script. It stores results in window.__iotestLogin*
        // globals and flips window.__iotestLoginDone when complete (or on error).
        appendLog("[1/4] Injecting passwordless-login JS …")
        CeremonyLog.ceremonyStep("login", "injecting JS")

        try await webView.evaluateJavaScriptAsync(loginJS)

        // Poll for completion.
        let result = try await pollForResult(
            webView: webView,
            doneKey: "window.__iotestLoginDone === true",
            resultKey: "JSON.stringify(window.__iotestLoginResult)",
            stepName: "login"
        )

        // Parse + emit markers.
        guard let data = result.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CeremonyError.parse("login result JSON: \(result)")
        }

        // Step 1: did the Face ID prompt resolve? (credentials.get didn't throw)
        let faceIDRejected = parsed["faceIDRejected"] as? String
        if let reason = faceIDRejected, !reason.isEmpty {
            CeremonyLog.ceremonyFaceIDPromptRejected(reason)
            appendLog("[1/4] Face ID rejected: \(reason)")
            setStep(1, .failed, reason)
            setStep(2, .failed, "Face ID rejected")
            throw CeremonyError.faceIDRejected(reason)
        }
        // If we got here, credentials.get() resolved (Face ID presented + assertion built).
        CeremonyLog.ceremonyFaceIDPromptResolved()
        appendLog("[1/4] Face ID prompt resolved (assertion built)")
        setStep(1, .done, "Face ID prompt appeared + resolved")

        // Step 2: did finishsession return a token?
        let loginStatus = parsed["loginStatus"] as? Int ?? 0
        let sessionToken = parsed["sessionToken"] as? String ?? ""
        let loginBody = parsed["loginBody"] as? String ?? ""
        let challengeLen = parsed["challengeLength"] as? Int ?? 0

        CeremonyLog.ceremonyLoginBeginPosted(challengeLength: challengeLen)
        CeremonyLog.ceremonyLoginFinishPosted(status: loginStatus, hasToken: !sessionToken.isEmpty)

        if loginStatus == 200 && !sessionToken.isEmpty {
            let prefix = String(sessionToken.prefix(12))
            sessionTokenPreview = prefix + "…"
            CeremonyLog.ceremonyLoginSucceeded(tokenPrefix: prefix)
            appendLog("[2/4] Login succeeded (status 200, token \(prefix)…)")
            setStep(2, .done, "status \(loginStatus), token \(prefix)…")
        } else {
            CeremonyLog.ceremonyLoginFailed(status: loginStatus, body: loginBody)
            appendLog("[2/4] Login failed: HTTP \(loginStatus): \(loginBody)")
            setStep(2, .failed, "HTTP \(loginStatus)")
            throw CeremonyError.loginFailed(status: loginStatus, body: loginBody)
        }
    }

    // MARK: - Step 3+4: privilege token

    private func runPrivilegeToken(webView: WKWebView) async throws {
        setStep(3, .inProgress)
        setStep(4, .inProgress)

        appendLog("[3/4] Injecting privilege-token JS …")
        CeremonyLog.ceremonyStep("privilege", "injecting JS")

        try await webView.evaluateJavaScriptAsync(privilegeJS)

        let result = try await pollForResult(
            webView: webView,
            doneKey: "window.__iotestPrivilegeDone === true",
            resultKey: "JSON.stringify(window.__iotestPrivilegeResult)",
            stepName: "privilege"
        )

        guard let data = result.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CeremonyError.parse("privilege result JSON: \(result)")
        }

        let faceIDRejected = parsed["faceIDRejected"] as? String ?? ""
        let privilegeStatus = parsed["privilegeStatus"] as? Int ?? 0
        let privilegeToken = parsed["privilegeToken"] as? String ?? ""
        let privilegeBody = parsed["privilegeBody"] as? String ?? ""
        let challengeLen = parsed["challengeLength"] as? Int ?? 0

        if !faceIDRejected.isEmpty {
            CeremonyLog.ceremonyFaceIDPromptRejected("privilege: \(faceIDRejected)")
            appendLog("[3/4] Face ID rejected: \(faceIDRejected)")
            setStep(3, .failed, faceIDRejected)
            setStep(4, .failed, "Face ID rejected")
            throw CeremonyError.faceIDRejected("privilege: \(faceIDRejected)")
        }

        CeremonyLog.ceremonyPrivilegeBeginPosted(challengeLength: challengeLen)
        CeremonyLog.ceremonyPrivilegeTokenPosted(status: privilegeStatus, hasToken: !privilegeToken.isEmpty)

        if privilegeStatus == 200 && !privilegeToken.isEmpty {
            self.privilegeToken = privilegeToken
            CeremonyLog.ceremonyPrivilegeTokenSucceeded(tokenLength: privilegeToken.count)
            appendLog("[3/4] Privilege token issued (status 200, \(privilegeToken.count) chars)")
            setStep(3, .done, "status \(privilegeStatus), \(privilegeToken.count) chars")
        } else {
            CeremonyLog.ceremonyPrivilegeTokenFailed(status: privilegeStatus, body: privilegeBody)
            appendLog("[3/4] Privilege token failed: HTTP \(privilegeStatus): \(privilegeBody)")
            setStep(3, .failed, "HTTP \(privilegeStatus)")
            throw CeremonyError.privilegeFailed(status: privilegeStatus, body: privilegeBody)
        }

        // Step 4: the token was already extracted via JS (we just read it).
        // Confirm it's non-empty + emit the extraction marker.
        let prefix = String(privilegeToken.prefix(12))
        CeremonyLog.ceremonyPrivilegeTokenExtracted(tokenPrefix: prefix)
        appendLog("[4/4] Privilege token extracted via JS (prefix \(prefix)…)")
        setStep(4, .done, "extracted via evaluateJavaScript")
    }

    // MARK: - JS polling helper

    /// Polls `doneKey` every 200ms until true (or maxPolls), then reads
    /// `resultKey` and returns the JSON string. Same pattern as WebAuthnProbe.
    private func pollForResult(webView: WKWebView, doneKey: String, resultKey: String, stepName: String) async throws -> String {
        pollCount = 0
        while pollCount < maxPolls {
            pollCount += 1
            let done: Any?
            do {
                done = try await webView.evaluateJavaScriptAsync(doneKey)
            } catch {
                throw CeremonyError.js("poll \(stepName): \(error.localizedDescription)")
            }
            if (done as? Bool) == true {
                // Read the result.
                let result: Any?
                do {
                    result = try await webView.evaluateJavaScriptAsync(resultKey)
                } catch {
                    throw CeremonyError.js("read \(stepName): \(error.localizedDescription)")
                }
                guard let str = result as? String else {
                    throw CeremonyError.js("read \(stepName): non-string result \(String(describing: result))")
                }
                return str
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        throw CeremonyError.timeout(stepName, maxPolls * 200)
    }

    // MARK: - Step helpers

    private func setStep(_ id: Int, _ status: CeremonyStepStatus, _ detail: String = "") {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[idx].status = status
        if !detail.isEmpty { steps[idx].detail = detail }
    }

    private func appendLog(_ line: String) {
        log.append(line)
    }
}

// MARK: - Errors

enum CeremonyError: LocalizedError {
    case faceIDRejected(String)
    case loginFailed(status: Int, body: String)
    case privilegeFailed(status: Int, body: String)
    case parse(String)
    case js(String)
    case timeout(String, Int)

    var errorDescription: String? {
        switch self {
        case .faceIDRejected(let r):     return "Face ID rejected: \(r)"
        case .loginFailed(let s, let b):  return "Login failed: HTTP \(s): \(b)"
        case .privilegeFailed(let s, let b): return "Privilege token failed: HTTP \(s): \(b)"
        case .parse(let m):              return "parse: \(m)"
        case .js(let m):                 return "JS: \(m)"
        case .timeout(let s, let ms):   return "timeout: \(s) after \(ms)ms"
        }
    }
}

// MARK: - WKWebView async evaluateJavaScript (iOS 16-compatible)

extension WKWebView {
    /// Async wrapper around evaluateJavaScript that throws on error.
    /// Uses the completion-handler variant (not callAsyncJavaScript) to
    /// keep the deployment target at iOS 16.1.
    func evaluateJavaScriptAsync(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            self.evaluateJavaScript(js) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}
