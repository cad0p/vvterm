// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  iotestApp.swift
//  iotest
//
//  Session 1.6a — minimal iOS app that loads a WKWebView against
//  https://teleport.pcad.it/web/login and probes the WebAuthn JS surface.
//  Built for the iOS Simulator smoke test (CI); the device run proves the
//  ceremony.
//
//  Session 1.9 — added the "Headless" tab.
//  Session 1.10 — added the "Full Flow" tab (cert → gRPC → SEP-key → login).
//  Session 1.11 — added Browser MFA types (BrowserMFAChallenge, BrowserMFAResponse,
//    CreateAuthenticateChallengeRequest.browser_mfa_tsh_redirect_url) + a
//    loopback NWListener + the Browser MFA ceremony, to solve the existing-
//    device assertion via Safari (bypassing the AASA-gated
//    ASAuthorizationPlatformPublicKeyCredentialAssertion).
//
//  The app now has three screens:
//    - Probe:     the 1.6a scaffolding probe.
//    - Headless:  the 1.9 headless bootstrap (standalone).
//    - Full Flow: the 1.10 full chain (Phase 1 reuses Headless, Phase 2 is
//                 the gRPC SEP-key registration, Phase 3 is passwordless
//                 login with the registered key).
//

import SwiftUI
import OSLog

@main
struct iotestApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ProbeView()
                    .tabItem { Label("Probe", systemImage: "stethoscope") }
                HeadlessView()
                    .tabItem { Label("Headless", systemImage: "key.fill") }
                FullFlowView()
                    .tabItem { Label("Full Flow", systemImage: "link.badge.plus") }
            }
            .onAppear {
                // Run the headless ID self-check on launch so CI can grep
                // for the headless_id_fixture_match marker.
                _ = HeadlessID.selfCheck()
                // Emit the Browser MFA compile-marker so CI can assert the
                // 1.11 proto types + ceremony compiled (the ceremony itself
                // can't run on the simulator — no real cluster + no Safari
                // redirect loopback in CI — but the types must compile).
                BrowserMFACompileCheck.emitMarker()
            }
        }
    }
}

/// A compile-time + runtime marker proving the session 1.11 Browser MFA
/// types + ceremony are wired into the build. Referencing the types here
/// forces the compiler to type-check them (catching proto field mismatches,
/// missing imports, etc.) even though the ceremony only runs on-device.
enum BrowserMFACompileCheck {
    static func emitMarker() {
        // Touch each 1.11 type so a typo / missing field fails the build
        // rather than silently dead-stripping the code.
        var chal = Proto_BrowserMFAChallenge()
        chal.requestID = "compile-check"
        var resp = Proto_BrowserMFAResponse()
        resp.requestID = chal.requestID
        resp.webauthnResponse = Proto_CredentialAssertionResponse()
        var authReq = Proto_CreateAuthenticateChallengeRequest()
        authReq.browserMfaTshRedirectURL = "http://127.0.0.1:1/callback?secret_key=00"
        var mfaResp = Proto_MFAAuthenticateResponse()
        mfaResp.browser = resp
        // Reference the ceremony + listener types (proves they compile).
        _ = BrowserMFACeremony.self
        _ = BrowserMFAListener.self
        let logger = Logger(subsystem: "it.pcad.vvterm.iotest", category: "browser-mfa-compile-check")
        logger.notice("[IOTEST] browser_mfa_types_compiled=true request_id=\(chal.requestID, privacy: .public)")
    }
}
