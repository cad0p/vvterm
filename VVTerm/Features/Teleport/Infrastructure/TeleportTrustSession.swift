// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportTrustSession.swift
//  VVTerm
//
//  The URLSession used for Teleport webapi calls (Phase 1 headless login +
//  Phase 3 passwordless login).
//
//  The webapi endpoint is served with the cluster's public TLS certificate
//  (`teleport.pcad.it` uses the system-trusted public PKI), so the session
//  uses standard system trust evaluation: certificate chain + hostname, no
//  custom delegate and no trust override. A private/self-signed web cert is
//  not supported (a user-pinned web CA is a follow-up, never a silent
//  bypass).
//

import Foundation

/// The shared webapi session for Teleport calls.
enum TeleportTrustSession {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // The Phase-1 headless POST blocks server-side up to 180s — keep a
        // generous request timeout so iOS doesn't kill the task early.
        config.timeoutIntervalForRequest = 200
        config.timeoutIntervalForResource = 200
        return URLSession(configuration: config)
    }()
}
