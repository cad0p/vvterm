// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  WebAuthnProbe.swift
//  iotest
//
//  A WKWebView wrapper that loads https://teleport.pcad.it/web/login and
//  injects a JS probe on page load to introspect the WebAuthn surface:
//    1. Does `window.PublicKeyCredential` exist?  (synchronous)
//    2. Does `isUserVerifyingPlatformAuthenticatorAvailable()` resolve?  (Promise)
//    3. Does `getClientCapabilities()` return an object?  (iOS 26+, Promise)
//  Results are emitted as structured log lines AND surfaced to the SwiftUI
//  log panel so the simulator smoke test (CI) can grep the unified log.
//
//  Implementation note: `evaluateJavaScript` does NOT await JS Promises.
//  `isUserVerifyingPlatformAuthenticatorAvailable()` returns a Promise, so
//  we can't evaluate-and-get the result in one call. Instead we inject a
//  probe script that stores the result in `window.__iotestProbe*` globals,
//  then poll `window.__iotestProbeDone` with evaluateJavaScript until it's
//  true, then read `window.__iotestProbeResult`. This avoids needing
//  `callAsyncJavaScript` (iOS 17+) and keeps the deployment target at 16.1.
//

import SwiftUI
import WebKit
import OSLog

/// The structured log the CI workflow greps for. Each marker is a distinct
/// line so `grep` can assert presence/absence precisely.
enum ProbeLog {
    static let logger = Logger(subsystem: "it.pcad.vvterm.iotest", category: "probe")

    // App lifecycle
    static func appLaunched() {
        logger.notice("[IOTEST] app_launched")
    }

    // WebView load
    static func loadStarted(url: String) {
        logger.notice("[IOTEST] load_started url=\(url, privacy: .public)")
    }
    static func loadSucceeded(url: String) {
        logger.notice("[IOTEST] load_succeeded url=\(url, privacy: .public)")
    }
    static func loadFailed(url: String, error: String) {
        logger.error("[IOTEST] load_failed url=\(url, privacy: .public) error=\(error, privacy: .public)")
    }

    // JS probe results — these are the load-bearing markers for the smoke test.
    static func publicKeyCredentialExists(_ exists: Bool) {
        logger.notice("[IOTEST] public_key_credential_exists=\(exists ? "true" : "false")")
    }
    static func platformAuthenticatorAvailable(_ available: Bool) {
        logger.notice("[IOTEST] platform_authenticator_available=\(available ? "true" : "false")")
    }
    static func clientCapabilities(_ json: String) {
        logger.notice("[IOTEST] client_capabilities=\(json, privacy: .public)")
    }
    static func jsInjectionRoundTrip(_ value: String) {
        logger.notice("[IOTEST] js_injection_roundtrip=\(value, privacy: .public)")
    }
    static func jsError(_ message: String) {
        logger.error("[IOTEST] js_error=\(message, privacy: .public)")
    }
}

/// The probe script injected into the page. Stores results in window globals
/// because `evaluateJavaScript` doesn't await Promises — the Swift side polls
/// `window.__iotestProbeDone` then reads `window.__iotestProbeResult`.
///
/// The synchronous part (PublicKeyCredential existence) is written immediately;
/// the async parts (isUserVerifyingPlatformAuthenticatorAvailable,
/// getClientCapabilities) resolve later and flip __iotestProbeDone when done.
private let probeJS = """
(function() {
    window.__iotestProbeResult = {
        publicKeyCredentialExists: (typeof PublicKeyCredential !== "undefined"),
        platformAuthenticatorAvailable: null,
        clientCapabilities: null
    };
    window.__iotestProbeDone = false;
    var pkc = window.__iotestProbeResult.publicKeyCredentialExists;
    var stepsRemaining = 0;
    function maybeFinish() {
        if (stepsRemaining === 0) {
            window.__iotestProbeDone = true;
        }
    }
    if (pkc && typeof PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable === "function") {
        stepsRemaining++;
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().then(function(avail) {
            window.__iotestProbeResult.platformAuthenticatorAvailable = avail;
            stepsRemaining--;
            maybeFinish();
        }).catch(function(e) {
            window.__iotestProbeResult.platformAuthenticatorAvailable = "error: " + e;
            stepsRemaining--;
            maybeFinish();
        });
    }
    if (pkc && typeof PublicKeyCredential.getClientCapabilities === "function") {
        stepsRemaining++;
        PublicKeyCredential.getClientCapabilities().then(function(caps) {
            window.__iotestProbeResult.clientCapabilities = caps;
            stepsRemaining--;
            maybeFinish();
        }).catch(function(e) {
            window.__iotestProbeResult.clientCapabilities = "error: " + e;
            stepsRemaining--;
            maybeFinish();
        });
    }
    maybeFinish();
})();
"""

/// The probe state surfaced to SwiftUI.
struct ProbeState {
    var log: [String] = []
    var lastURL: String = ""
    var loadState: String = "idle"
    var publicKeyCredentialExists: Bool? = nil
    var platformAuthenticatorAvailable: Bool? = nil
}

@MainActor
final class WebAuthnProbeModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var state = ProbeState()
    private var webView: WKWebView?
    private var pollCount = 0
    private let maxPolls = 50  // 50 × 200ms = 10s timeout for the async probe

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Allow inspection of the JS context (simulator/dev only).
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        self.webView = webView
        return webView
    }

    func load(url: URL) {
        appendLog("Loading \(url.absoluteString) …")
        state.loadState = "loading"
        state.lastURL = url.absoluteString
        ProbeLog.loadStarted(url: url.absoluteString)
        var req = URLRequest(url: url)
        // Use a desktop User-Agent so Teleport serves the web UI (not a
        // mobile-redirect) — matches what the production bootstrap targets.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                     "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        webView?.load(req)
    }

    func runProbe() {
        guard let webView else {
            appendLog("ERROR: no webView")
            return
        }
        appendLog("Injecting JS probe …")
        // First: a trivial round-trip to confirm evaluateJavaScript works.
        // This is the load-bearing `js_injection_roundtrip` marker.
        webView.evaluateJavaScript("1+1") { result, error in
            if let error {
                ProbeLog.jsError("roundtrip: \(error.localizedDescription)")
                self.appendLog("JS roundtrip FAILED: \(error.localizedDescription)")
            } else if let n = result as? Int {
                ProbeLog.jsInjectionRoundTrip("\(n)")
                self.appendLog("JS roundtrip OK: 1+1=\(n)")
            } else {
                ProbeLog.jsInjectionRoundTrip(String(describing: result))
                self.appendLog("JS roundtrip OK (non-int): \(String(describing: result))")
            }

            // Inject the probe script (sets window.__iotestProbe* globals).
            webView.evaluateJavaScript(probeJS) { _, injectError in
                if let injectError {
                    ProbeLog.jsError("inject: \(injectError.localizedDescription)")
                    self.appendLog("JS probe inject FAILED: \(injectError.localizedDescription)")
                    return
                }
                self.appendLog("Probe injected. Polling for result …")
                self.pollProbeResult()
            }
        }
    }

    /// Poll `window.__iotestProbeDone` every 200ms until true (or maxPolls).
    /// The synchronous part (PublicKeyCredential exists) is available
    /// immediately; the async parts resolve when the Promises settle.
    private func pollProbeResult() {
        guard let webView else { return }
        pollCount += 1
        if pollCount > maxPolls {
            ProbeLog.jsError("poll: timeout after \(maxPolls * 200)ms")
            appendLog("Poll timeout — reading partial result")
            readProbeResult()
            return
        }
        webView.evaluateJavaScript("window.__iotestProbeDone === true") { result, error in
            if let error {
                ProbeLog.jsError("poll: \(error.localizedDescription)")
                self.appendLog("JS poll FAILED: \(error.localizedDescription)")
                return
            }
            let done = (result as? Bool) ?? false
            if done {
                self.readProbeResult()
            } else {
                // Schedule the next poll. Use DispatchQueue.main.asyncAfter
                // to yield and avoid blocking.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.pollProbeResult()
                }
            }
        }
    }

    /// Read `window.__iotestProbeResult` and emit the structured log lines.
    private func readProbeResult() {
        guard let webView else { return }
        webView.evaluateJavaScript("JSON.stringify(window.__iotestProbeResult)") { result, error in
            if let error {
                ProbeLog.jsError("read: \(error.localizedDescription)")
                self.appendLog("JS read FAILED: \(error.localizedDescription)")
                return
            }
            guard let json = result as? String else {
                ProbeLog.jsError("read: non-string result \(String(describing: result))")
                self.appendLog("JS read FAILED: non-string result")
                return
            }
            self.appendLog("Probe result: \(json)")
            self.parseProbe(json: json)
        }
    }

    private func parseProbe(json: String) {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            ProbeLog.jsError("parse: invalid JSON \(json)")
            appendLog("Failed to parse probe JSON")
            return
        }
        if let pkc = parsed["publicKeyCredentialExists"] as? Bool {
            state.publicKeyCredentialExists = pkc
            ProbeLog.publicKeyCredentialExists(pkc)
        }
        if let avail = parsed["platformAuthenticatorAvailable"] as? Bool {
            state.platformAuthenticatorAvailable = avail
            ProbeLog.platformAuthenticatorAvailable(avail)
        } else if let availStr = parsed["platformAuthenticatorAvailable"] as? String {
            // The Promise rejected or returned a non-bool — log it but still
            // emit the marker so the smoke test can see what happened.
            state.platformAuthenticatorAvailable = nil
            ProbeLog.platformAuthenticatorAvailable(false)
            ProbeLog.jsError("platform_authenticator: \(availStr)")
        }
        if let caps = parsed["clientCapabilities"] {
            let capsJSON = (try? JSONSerialization.data(withJSONObject: caps)) ?? Data()
            let capsString = String(data: capsJSON, encoding: .utf8) ?? "{}"
            ProbeLog.clientCapabilities(capsString)
        }
    }

    private func appendLog(_ line: String) {
        DispatchQueue.main.async {
            self.state.log.append(line)
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.appendLog("Load finished: \(webView.url?.absoluteString ?? "?")")
            self.state.loadState = "loaded"
            ProbeLog.loadSucceeded(url: webView.url?.absoluteString ?? "?")
            self.runProbe()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.appendLog("Load FAILED: \(error.localizedDescription)")
            self.state.loadState = "failed"
            ProbeLog.loadFailed(url: webView.url?.absoluteString ?? "?",
                                error: error.localizedDescription)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.appendLog("Provisional load FAILED: \(error.localizedDescription)")
            self.state.loadState = "failed"
            ProbeLog.loadFailed(url: webView.url?.absoluteString ?? "?",
                                error: error.localizedDescription)
        }
    }
}
