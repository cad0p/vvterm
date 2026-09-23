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
#if canImport(Network)
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
/// `@MainActor` because it presents the in-app browser session (Safari must
/// be on the main thread).
@MainActor
final class BrowserMFACeremony: NSObject {

    /// The injected logging seam (the host passes `AppTeleportLogging`; tests
    /// pass a spy or the package default).
    private let logging: any TeleportLogging
    private let logger: Logger

    /// The injected browser presenter (owns `ASWebAuthenticationSession` +
    /// the callback scheme + the presentation anchor).
    private let presenter: any BrowserMFAPresenting

    /// The live browser session (kept alive so it isn't deallocated while the
    /// Safari sheet is presented).
    private var webAuthSession: (any BrowserMFASessionHandle)?

    /// The loopback listener.
    private var listener: BrowserMFAListener?

    init(logging: any TeleportLogging, presenter: any BrowserMFAPresenting) {
        self.logging = logging
        self.logger = logging.logger(category: "TeleportBrowserMFA")
        self.presenter = presenter
        super.init()
    }

    /// Run the ceremony. Returns the ExistingMFAResponse.Browser to send in
    /// CreateRegisterChallenge.
    ///
    /// The ceremony OWNS the entire Browser MFA flow, mirroring the spike's
    /// `BrowserMFACeremony.run(conn:host:)`:
    ///   1. Start the loopback `BrowserMFAListener` → get a real
    ///      `clientCallbackURL` (e.g. `http://localhost:<port>/callback`).
    ///   2. Call `grpcClient.createAuthenticateChallenge(...)` with the real
    ///      loopback URL in `browserMfaTshRedirectURL` (field 9).
    ///   3. Read `BrowserMFAChallenge.requestID` from the response.
    ///   4. Open Safari to `/web/mfa/browser/<request_id>`.
    ///   5. Await the loopback listener callback.
    ///   6. Build + return `Proto_BrowserMFAResponse`.
    ///
    /// The ceremony MUST call `createAuthenticateChallenge` itself (after
    /// starting the listener), not receive a pre-fetched challenge — a bogus
    /// `localhost:0` URL is rejected by Teleport's `ValidateClientRedirect`
    /// → "unable to create MFA challenges" (gRPC code 7).
    ///
    /// - Parameters:
    ///   - grpcClient: the connected Teleport gRPC client (used for the
    ///     `CreateAuthenticateChallenge` call with the real loopback URL).
    ///   - host: the Teleport proxy hostname (e.g. "teleport.pcad.it").
    /// - Returns: the ExistingMFAResponse.Browser (RequestId + WebauthnResponse).
    func run(
        grpcClient: any TeleportGRPCClienting,
        host: String
    ) async throws -> Proto_BrowserMFAResponse {
        #if canImport(Network)
        // ── 1. Start the loopback listener ────────────────────────────────
        let listener = BrowserMFAListener(logger: logger)
        self.listener = listener
        // Every early exit (start failure, challenge failure, missing
        // challenge, wait error) must tear the loopback listener down.
        // `cancel()` is idempotent, so the explicit cancel on the success
        // path stays as-is.
        defer {
            listener.cancel()
            self.listener = nil
        }
        let clientCallbackURL: String
        do {
            clientCallbackURL = try await listener.start()
        } catch {
            throw BrowserMFACeremonyError.listenerFailed(error.localizedDescription)
        }
        // Never log the full callback URL: its secret_key query is a session
        // credential and would leak into exported diagnostics reports.
        let redactedCallbackURL = clientCallbackURL.components(separatedBy: "?").first ?? clientCallbackURL
        logger.info("listener on \(redactedCallbackURL, privacy: .public)")

        // ── 2. CreateAuthenticateChallenge with BrowserMFATSHRedirectURL ──
        // The ceremony passes the REAL loopback URL (a non-zero, OS-assigned
        // port) — never the bogus localhost:0 sentinel that broke the live
        // device. Teleport's ValidateClientRedirect rejects invalid URLs.
        logger.info("create_auth_challenge ContextUser MANAGE_DEVICES + BrowserMFATSHRedirectURL")
        let authChal = try await grpcClient.createAuthenticateChallenge(
            browserMFATSHRedirectURL: clientCallbackURL
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
        logger.info("got_challenge request_id=\(requestID.prefix(16), privacy: .public)…")

        // ── 4. Open Safari to /web/mfa/browser/<id> ───────────────────────
        let browserMFAURL = "https://\(host)/web/mfa/browser/\(requestID)"
        // Log only the request-id prefix (as above): the full id is a bearer
        // for the MFA challenge and must not land in diagnostics reports.
        logger.info("open_safari https://\(host, privacy: .public)/web/mfa/browser/\(requestID.prefix(16), privacy: .public)…")
        // We present Safari in-app via the injected presenter (the callback
        // scheme "vvterm" is set host-side but won't fire for the loopback
        // redirect — we cancel the session after the listener receives the
        // callback). (See session 1.11 results note Q3.)
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
        logger.info("got_callback webauthn id=\(webauthnResp.id.prefix(16), privacy: .public)…")

        // ── 6. Build ExistingMFAResponse.Browser ──────────────────────────
        var response = Proto_BrowserMFAResponse()
        response.requestID = requestID
        response.webauthnResponse = webauthnResp

        // ── 7. Cancel the Safari sheet + listener ─────────────────────────
        webAuthSession?.cancel()
        webAuthSession = nil
        listener.cancel()
        self.listener = nil

        logger.info("done ExistingMFAResponse.Browser built")
        return response
        #else
        throw BrowserMFACeremonyError.safariFailed("Browser MFA requires Apple platform (Network.framework)")
        #endif
    }

    // MARK: - Safari presentation

    /// Present the URL via the injected browser presenter. The completion
    /// handler is a no-op for the response — we don't use it (the loopback
    /// redirect is not intercepted by ASWebAuth; the listener is the actual
    /// response channel). We only need to know the session started; the
    /// completion logs stay here in the ceremony.
    private func openSafari(url: URL) async {
        // Capture the logger by value: the completion handler runs on an
        // arbitrary queue and must not retain the ceremony through `self`.
        let logger = self.logger
        let session = await presenter.present(url: url) { error in
            // This fires if the user dismisses the Safari sheet, or if the
            // web UI happens to redirect to vvterm:// (it won't for Browser
            // MFA — the redirect is http://127.0.0.1:...). We log it but
            // don't resume — the listener is the real gate.
            if let error {
                logger.info("safari_callback error: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("safari_callback session ended (dismissed or redirected to vvterm://)")
            }
        }
        logger.info("safari_started \(session.didStart)")
        webAuthSession = session
    }
}
