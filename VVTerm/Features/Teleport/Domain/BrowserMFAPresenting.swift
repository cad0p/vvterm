// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  BrowserMFAPresenting.swift
//  VVTerm
//
//  The package-movable presenter seam for the Browser-MFA ceremony.
//
//  The ceremony must hold the presented session alive until the loopback
//  listener resolves (the redirect is `http://localhost:...`, which
//  `ASWebAuthenticationSession` cannot intercept), so the seam is
//  handle-based rather than the fire-and-forget
//  `WebAuthenticationSessionPresenting` used by the Phase-1 headless flow.
//
//  The host adapter owns `ASWebAuthenticationSession`, the `vvterm` callback
//  scheme, and the presentation anchor (`UIApplication.shared` /
//  `NSApp.keyWindow`). The ceremony keeps the listener lifecycle, the gRPC
//  call, request-ID validation, the response build, and all logging —
//  including the Safari completion logs, which are delivered through the
//  completion closure this seam carries.
//

import Foundation

/// A handle to one presented in-app browser session. The ceremony keeps it
/// alive until the listener resolves, then cancels it.
protocol BrowserMFASessionHandle: AnyObject, Sendable {
    /// Whether the session started (`ASWebAuthenticationSession.start()`).
    /// Mirrors the `safari_started <bool>` log line.
    var didStart: Bool { get }

    /// Cancel/dismiss the session. Safe to call multiple times.
    func cancel()
}

/// Presents the Browser-MFA approval URL in an in-app browser.
protocol BrowserMFAPresenting: Sendable {
    /// Present `url` and return once the session has started.
    ///
    /// - Parameters:
    ///   - url: the `/web/mfa/browser/<request_id>` approval URL.
    ///   - completion: fires when the session ends (user dismissed the sheet
    ///     or the web UI redirected to `vvterm://`). The ceremony owns the
    ///     logging for this callback; the presenter only forwards it.
    /// - Returns: a handle the ceremony cancels when the listener resolves.
    func present(
        url: URL,
        completion: @escaping @Sendable (Error?) -> Void
    ) async -> any BrowserMFASessionHandle
}
