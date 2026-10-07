// SPDX-License-Identifier: MIT
//
//  BrowserMFAListening.swift
//  VVTerm
//
//  The loopback listener surface the Browser MFA ceremony drives. A seam so
//  tests can drive the fail-fast path without a real loopback bind (issue
//  #401); production always gets `BrowserMFAListener`.
//

import Foundation

/// The loopback listener surface the Browser MFA ceremony drives. A seam so
/// tests can drive the fail-fast path without a real loopback bind (issue
/// #401); production always gets `BrowserMFAListener`.
///
/// `nonisolated` is load-bearing: the app target sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unmarked protocol would
/// be MainActor-isolated and the `nonisolated` production conformer would not
/// satisfy it.
nonisolated protocol BrowserMFAListening: AnyObject, Sendable {
    func start() async throws -> String
    func waitForResponse() async throws -> Proto_CredentialAssertionResponse
    func cancel()
}
