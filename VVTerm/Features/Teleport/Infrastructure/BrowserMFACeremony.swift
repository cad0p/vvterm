// SPDX-License-Identifier: MIT
//
//  BrowserMFACeremony.swift
//  VVTerm
//
//  The existing-device Browser MFA ceremony (Phase 2, step 2).
//
//  The ceremony owns the whole flow: it starts the loopback
//  `BrowserMFAListener`, calls `CreateAuthenticateChallenge` with that
//  listener's real callback URL, opens the approval page in an in-app
//  browser, and awaits the sealed assertion on the loopback listener. The
//  challenge must be created *after* the listener is up — the server
//  validates the redirect URL, and a placeholder `localhost:0` is rejected.
//
//  The Safari session is only a presentation channel: the response arrives on
//  the loopback callback, so the presenter's completion handler feeds
//  diagnostics only. Both the browser session and the listener are torn down
//  on every exit path.
//
//  Logging is redacted: the callback URL is logged without its query (the
//  query carries the per-run secret), and request IDs are truncated.
//

import Foundation
import os.log
#if canImport(Network)
import Network
#endif

// MARK: - Errors

/// Errors surfaced by `BrowserMFACeremony`.
nonisolated enum BrowserMFACeremonyError: Error, LocalizedError {
    case noBrowserMFAChallenge
    case safariFailed(String)
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBrowserMFAChallenge:
            return "server did not return a BrowserMFAChallenge (is BrowserMFATSHRedirectURL set + does the user have a Browser WebAuthn device?)"
        case .safariFailed(let message):
            return "Safari presentation failed: \(message)"
        case .listenerFailed(let message):
            return "loopback listener failed: \(message)"
        }
    }
}

// MARK: - Ceremony

/// Runs one Browser MFA ceremony for the authenticated user.
@MainActor
final class BrowserMFACeremony: NSObject {

    /// The ceremony's logger (category `TeleportBrowserMFA`).
    private let logger: Logger
    /// The in-app browser presenter.
    private let presenter: any BrowserMFAPresenting

    init(logging: any TeleportLogging, presenter: any BrowserMFAPresenting) {
        self.logger = logging.logger(category: "TeleportBrowserMFA")
        self.presenter = presenter
        super.init()
    }

    /// Starts the listener, creates the challenge against its real callback
    /// URL, presents the approval page, and returns the assertion.
    ///
    /// - Throws: `BrowserMFACeremonyError.noBrowserMFAChallenge` when the
    ///   user has no existing WebAuthn device (the first-device path),
    ///   `.listenerFailed` when the loopback listener cannot start, and
    ///   `.safariFailed` when the approval page cannot be presented.
    func run(
        grpcClient: any TeleportGRPCClienting,
        host: String
    ) async throws -> Proto_BrowserMFAResponse {
        #if canImport(Network)
        let listener = BrowserMFAListener(logger: logger)
        var safariHandle: (any BrowserMFASessionHandle)?
        defer {
            safariHandle?.cancel()
            listener.cancel()
        }

        let callbackURL: String
        do {
            callbackURL = try await listener.start()
        } catch {
            throw BrowserMFACeremonyError.listenerFailed(String(describing: error))
        }
        // The query carries the per-run secret key; log only the origin+path.
        let redactedCallbackURL = callbackURL.components(separatedBy: "?").first ?? callbackURL
        logger.info("browser MFA callback listening at \(redactedCallbackURL, privacy: .public)")

        let challenge: Proto_MFAAuthenticateChallenge
        do {
            challenge = try await grpcClient.createAuthenticateChallenge(
                browserMFATSHRedirectURL: callbackURL
            )
        } catch {
            // The server's gRPC message can echo the redirect URL, which
            // carries the per-run secret_key — log the error's shape only.
            logger.error("browser MFA CreateAuthenticateChallenge failed: \(TeleportErrorRedaction.grpcFailure(error), privacy: .public)")
            throw error
        }

        guard challenge.hasBrowserMfaChallenge,
              !challenge.browserMfaChallenge.requestID.isEmpty
        else {
            throw BrowserMFACeremonyError.noBrowserMFAChallenge
        }
        let requestID = challenge.browserMfaChallenge.requestID
        logger.info("browser MFA challenge received request_id=\(String(requestID.prefix(16)), privacy: .public)")

        guard let approvalURL = URL(string: "https://\(host)/web/mfa/browser/\(requestID)") else {
            throw BrowserMFACeremonyError.safariFailed("could not build the approval URL")
        }

        let logger = self.logger
        safariHandle = await presenter.present(url: approvalURL) { error in
            // The loopback callback is the response channel; this completion
            // only records that the browser session ended (and how).
            if let error = error as NSError? {
                logger.info("browser MFA safari finished error=\(error.domain):\(error.code)")
            } else {
                logger.info("browser MFA safari finished")
            }
        }
        guard let safariHandle, safariHandle.didStart else {
            throw BrowserMFACeremonyError.safariFailed("the in-app browser session did not start")
        }

        let assertion = try await listener.waitForResponse()
        logger.info("browser MFA assertion received")
        var response = Proto_BrowserMFAResponse()
        response.requestID = requestID
        response.webauthnResponse = assertion
        return response
        #else
        throw BrowserMFACeremonyError.safariFailed("browser MFA requires the Network framework")
        #endif
    }
}
