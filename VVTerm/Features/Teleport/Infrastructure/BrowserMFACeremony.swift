// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  BrowserMFACeremony.swift
//  VVTerm
//
//  The Browser MFA assertion ceremony.
//
//  This orchestrates the existing-device assertion (the Phase 2 step 3 that
//  1.10 skipped). The flow mirrors lib/client/sso/ceremony.go MFACeremony.Run
//  (the `case chal.BrowserMFAChallenge != nil:` branch):
//    1. Start a loopback NWListener (BrowserMFAListener) → get clientCallbackURL.
//    2. CreateAuthenticateChallenge with ContextUser + MANAGE_DEVICES +
//       BrowserMFATSHRedirectURL = clientCallbackURL.
//    3. Read BrowserMFAChallenge.request_id from the response.
//    4. Open https://<host>/web/mfa/browser/<request_id> in
//       ASWebAuthenticationSession (Safari). The callback scheme is irrelevant
//       — ASWebAuth cannot intercept an http://127.0.0.1 redirect, so we don't
//       use its completion handler for the response.
//    5. Await the BrowserMFAListener continuation → the decrypted
//       CredentialAssertionResponse.
//    6. Build ExistingMFAResponse.Browser = { request_id, webauthn_response }.
//    7. Cancel the ASWebAuthenticationSession + the listener.
//
//  IMPORTANT: the user must be logged into the Teleport web UI in Safari
//  BEFORE this ceremony runs, because the PUT /webapi/mfa/browser/:id
//  endpoint is behind WithAuth (lib/web/apiserver.go:1166). For the spike,
//  the user is instructed to log into teleport.pcad.it/web first.
//

import Foundation
import os.log
import AuthenticationServices
import UIKit
#if canImport(Network)
import NIOCore
import SwiftProtobuf
import Network
#endif

// MARK: - Errors

enum BrowserMFACeremonyError: Error, LocalizedError {
    case noBrowserMFAChallenge
    case safariFailed(String)
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBrowserMFAChallenge: return "server did not return a BrowserMFAChallenge (is BrowserMFATSHRedirectURL set + does the user have a Browser WebAuthn device?)"
        case .safariFailed(let s): return "Safari presentation failed: \(s)"
        case .listenerFailed(let s): return "loopback listener failed: \(s)"
        }
    }
}

// MARK: - Ceremony

/// Runs the Browser MFA assertion ceremony.
///
/// `@MainActor` because it presents ASWebAuthenticationSession (Face ID /
/// Safari must be on the main thread).
@MainActor
final class BrowserMFACeremony: NSObject {

    /// The ASWebAuthenticationSession (kept alive so it isn't deallocated
    /// while the Safari sheet is presented).
    private var webAuthSession: ASWebAuthenticationSession?

    /// The loopback listener.
    private var listener: BrowserMFAListener?

    /// Run the ceremony. Returns the ExistingMFAResponse.Browser to send in
    /// CreateRegisterChallenge.
    ///
    /// - Parameters:
    ///   - conn: the gRPC connection (already dialed in step 1).
    ///   - host: the Teleport proxy hostname (e.g. "teleport.pcad.it").
    /// - Returns: the ExistingMFAResponse.Browser (RequestId + WebauthnResponse).
    func run(conn: TeleportGRPCConnection, host: String) async throws -> Proto_BrowserMFAResponse {
        #if canImport(Network)
        // ── 1. Start the loopback listener ────────────────────────────────
        let listener = BrowserMFAListener()
        self.listener = listener
        let clientCallbackURL: String
        do {
            clientCallbackURL = try await listener.start()
        } catch {
            throw BrowserMFACeremonyError.listenerFailed(error.localizedDescription)
        }
        BrowserMFACeremonyLog.logger.info("listener on \(clientCallbackURL, privacy: .public)")

        // ── 2. CreateAuthenticateChallenge with BrowserMFATSHRedirectURL ──
        var authReq = Proto_CreateAuthenticateChallengeRequest()
        authReq.contextUser = Proto_ContextUser()
        authReq.challengeExtensions = Proto_ChallengeExtensions()
        authReq.challengeExtensions.scope = .manageDevices
        authReq.browserMfaTshRedirectURL = clientCallbackURL  // field 9
        BrowserMFACeremonyLog.logger.info("create_auth_challenge ContextUser MANAGE_DEVICES + BrowserMFATSHRedirectURL")

        let authChal: Proto_MFAAuthenticateChallenge = try await conn.unary(
            path: "/proto.AuthService/CreateAuthenticateChallenge",
            request: authReq,
            responseType: Proto_MFAAuthenticateChallenge.self
        )

        // ── 3. Read the BrowserMFAChallenge ──────────────────────────────
        guard authChal.hasBrowserMfaChallenge, !authChal.browserMfaChallenge.requestID.isEmpty else {
            // The server didn't populate BrowserMFAChallenge. This means either:
            //  - the user has no Browser-grouped WebAuthn device, or
            //  - enableBrowserMFA is false, or
            //  - the BrowserMFATSHRedirectURL was rejected by ValidateClientRedirect.
            throw BrowserMFACeremonyError.noBrowserMFAChallenge
        }
        let requestID = authChal.browserMfaChallenge.requestID
        BrowserMFACeremonyLog.logger.info("got_challenge request_id=\(requestID.prefix(16), privacy: .public)…")

        // ── 4. Open Safari to /web/mfa/browser/<id> ───────────────────────
        let browserMFAURL = "https://\(host)/web/mfa/browser/\(requestID)"
        BrowserMFACeremonyLog.logger.info("open_safari \(browserMFAURL, privacy: .public)")
        // We use ASWebAuthenticationSession to present Safari in-app. The
        // callback scheme "vvterm" is set but won't fire for the loopback
        // redirect — we cancel the session after the listener receives the
        // callback. (See session 1.11 results note Q3.)
        await openSafari(url: URL(string: browserMFAURL)!)

        // ── 5. Await the listener ─────────────────────────────────────────
        let webauthnResp: Proto_CredentialAssertionResponse
        do {
            webauthnResp = try await listener.waitForResponse()
        } catch {
            // Make sure to cancel the Safari sheet on error.
            webAuthSession?.cancel()
            webAuthSession = nil
            listener.cancel()
            throw error
        }
        BrowserMFACeremonyLog.logger.info("got_callback webauthn id=\(webauthnResp.id.prefix(16), privacy: .public)…")

        // ── 6. Build ExistingMFAResponse.Browser ──────────────────────────
        var response = Proto_BrowserMFAResponse()
        response.requestID = requestID
        response.webauthnResponse = webauthnResp

        // ── 7. Cancel the Safari sheet + listener ─────────────────────────
        webAuthSession?.cancel()
        webAuthSession = nil
        listener.cancel()
        self.listener = nil

        BrowserMFACeremonyLog.logger.info("done ExistingMFAResponse.Browser built")
        return response
        #else
        throw BrowserMFACeremonyError.safariFailed("Browser MFA requires Apple platform (Network.framework)")
        #endif
    }

    // MARK: - Safari presentation

    /// Open the URL via ASWebAuthenticationSession. Presents Safari in-app.
    /// The completion handler is a no-op for the response — we don't use it
    /// (the loopback redirect is not intercepted by ASWebAuth; the listener
    /// is the actual response channel). We only need to know Safari opened.
    private func openSafari(url: URL) async {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "vvterm") { _, error in
                // This fires if the user dismisses the Safari sheet, or if
                // the web UI happens to redirect to vvterm:// (it won't for
                // Browser MFA — the redirect is http://127.0.0.1:...). We log
                // it but don't resume — the continuation was already resumed
                // on start(), and the listener is the real gate.
                if let error {
                    BrowserMFACeremonyLog.logger.info("safari_callback error: \(error.localizedDescription, privacy: .public)")
                } else {
                    BrowserMFACeremonyLog.logger.info("safari_callback session ended (dismissed or redirected to vvterm://)")
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            webAuthSession = session
            let started = session.start()
            BrowserMFACeremonyLog.logger.info("safari_started \(started)")
            // Resume immediately — we only care that Safari opened. The
            // listener (already started) is the real gate.
            continuation.resume()
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension BrowserMFACeremony: ASWebAuthenticationPresentationContextProviding {
    @MainActor
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}

// MARK: - Logging

/// Shared logger for the Browser MFA ceremony. Uses VVTerm's logging convention
/// (subsystem = bundle id, category = feature).
enum BrowserMFACeremonyLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "TeleportBrowserMFA")
}
