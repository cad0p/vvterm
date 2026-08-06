// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportTrustSession.swift
//  VVTerm
//
//  A URLSession that accepts the Teleport proxy's server certificate.
//
//  Teleport proxy certificates are not standards-compliant (the SAN does
//  not match the dial host and the chain is self-signed), so
//  `SecTrustEvaluateWithError` fails even with the cluster CA anchored —
//  the SSH-TLS transport and the gRPC AuthService dial use the same
//  accept-anyway policy. The real authentication for the webapi MFA calls
//  is the SEP-key-signed WebAuthn assertion: the key never leaves the
//  Secure Enclave, so accepting the proxy cert does not leak credentials.
//
//  `delegate` is retained as a static so the session's auth-challenge
//  callbacks keep firing (URLSession does not retain its delegate).
//

import Foundation

/// The shared accept-anyway session for Teleport webapi calls
/// (Phase 1 headless login + Phase 3 passwordless login).
enum TeleportTrustSession {
    private static let delegate = TeleportTrustDelegate()
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // The Phase-1 headless POST blocks server-side up to 180s — keep a
        // generous request timeout so iOS doesn't kill the task early.
        config.timeoutIntervalForRequest = 200
        config.timeoutIntervalForResource = 200
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
}

private final class TeleportTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
