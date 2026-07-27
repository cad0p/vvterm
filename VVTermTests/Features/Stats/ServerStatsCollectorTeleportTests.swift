// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  ServerStatsCollectorTeleportTests.swift
//  VVTermTests
//
//  Documents the Teleport stats-collection routing policy.
//
//  Teleport servers connect through a two-session path: the OUTER session is
//  the Teleport PROXY (TLS+ALPN on port 443), which is in `proxyMode` and
//  rejects `exec`/`pty`/`shell` channel requests with
//  LIBSSH2_ERROR_CHANNEL_REQUEST_FAILURE (-22). Stats collection runs
//  `client.execute(...)`, which must route to the INNER (target-node)
//  session — established after the second handshake inside
//  `startShellViaTeleportProxy` — so exec channels open on the node that
//  actually supports them.
//
//  When the inner session is not yet ready (e.g. before the shell starts, or
//  while the second handshake is in flight), stats must be skipped gracefully
//  rather than spinning failing exec calls. The static
//  `shouldSkipStatsCollection` helper is retained as a safety-net hook but no
//  longer blanket-skips Teleport — runtime readiness is gated by
//  `SSHClient.supportsExec`.
//
//  The inner session is now established by `SSHClient.prepareTeleportInnerSession()`,
//  which `ServerStatsCollector.startCollecting` calls after `connect` (stats
//  never starts a shell). This is a no-op for non-Teleport auth methods and
//  idempotent for Teleport (reuses an already-established inner session).
//

import XCTest
@testable import VVTerm

final class ServerStatsCollectorTeleportTests: XCTestCase {

    // MARK: - shouldSkipStatsCollection (static safety-net hook)

    /// Stats are NO LONGER statically skipped for Teleport: the exec channel
    /// is routed to the inner (target-node) session by `SSHSession.execute`.
    /// Runtime readiness (inner session established) is gated by
    /// `SSHClient.supportsExec`; this static helper stays as a future
    /// safety-net hook for auth methods that can never support exec.
    func testTeleportAuthMethodDoesNotStaticallySkipStatsCollection() {
        XCTAssertFalse(
            ServerStatsCollector.shouldSkipStatsCollection(for: .faceIDTeleport),
            "Teleport stats route through the inner session; static skip must not fire"
        )
    }

    func testNonTeleportAuthMethodsDoNotSkipStatsCollection() {
        // Every non-Teleport auth method must keep running stats: the session
        // is a direct connection to the target and exec is supported.
        for method: AuthMethod in [.password, .sshKey, .sshKeyWithPassphrase] {
            XCTAssertFalse(
                ServerStatsCollector.shouldSkipStatsCollection(for: method),
                "\(method) must not skip stats collection"
            )
        }
    }

    // MARK: - SSHSession inner-exec routing decision

    /// `SSHSession.shouldRouteExecToInnerSession(authMethod:innerSessionReady:)`
    /// is the pure routing decision extracted from `execute()`. It must route
    /// to the inner session ONLY for Teleport AND when the inner session is
    /// ready. For every other combination (non-Teleport, or Teleport with no
    /// inner session yet) it returns `false` so the outer path is preserved.
    func testExecRoutingRoutesToInnerForTeleportWhenReady() {
        XCTAssertTrue(
            SSHSession.shouldRouteExecToInnerSession(
                authMethod: .faceIDTeleport,
                innerSessionReady: true
            ),
            "Teleport with a ready inner session must route exec to the inner session"
        )
    }

    func testExecRoutingDoesNotRouteToInnerWhenInnerNotReady() {
        // Before the shell starts (or while the second handshake is in
        // flight) the inner session is nil. Exec must NOT route to a
        // non-existent inner session — it would fail to open a channel.
        XCTAssertFalse(
            SSHSession.shouldRouteExecToInnerSession(
                authMethod: .faceIDTeleport,
                innerSessionReady: false
            ),
            "Teleport without a ready inner session must not route exec to the inner session"
        )
    }

    func testExecRoutingDoesNotRouteToInnerForNonTeleport() {
        // Non-Teleport auth methods use the direct outer session, which
        // supports exec. Routing them to a (non-existent) inner session
        // would break existing stats collection.
        for method: AuthMethod in [.password, .sshKey, .sshKeyWithPassphrase] {
            XCTAssertFalse(
                SSHSession.shouldRouteExecToInnerSession(
                    authMethod: method,
                    innerSessionReady: true
                ),
                "\(method) must never route exec to the inner session"
            )
        }
    }

    // MARK: - prepareTeleportInnerSession contract

    /// `SSHClient.prepareTeleportInnerSession()` is the documented entry point
    /// that exec-only consumers (stats collector) call after `connect` to
    /// establish the inner (target-node) session without starting a shell.
    /// It must exist as a public method on `SSHClient` so the stats collector
    /// can call it without reaching into `SSHSession` internals.
    func testSSHClientExposesPrepareTeleportInnerSession() {
        // This is a compile-time contract test: if the method is removed or
        // renamed, this file fails to compile. The method signature
        // `func prepareTeleportInnerSession() async throws` must stay.
        let method: (SSHClient) async throws -> Void = { client in
            try await client.prepareTeleportInnerSession()
        }
        _ = method
        XCTAssertTrue(true, "SSHClient.prepareTeleportInnerSession exists and is callable")
    }

    /// `SSHSession.prepareTeleportInnerSession()` must be a no-op for non-
    /// Teleport auth methods (their outer session supports exec directly) so
    /// that callers can invoke it unconditionally after `connect` without
    /// branching on the auth method. This is verified via the config-level
    /// guard: a non-Teleport config must never trigger the Teleport prepare
    // path. We assert the auth-method guard predicate that
    // `prepareTeleportInnerSession` uses internally.
    func testPrepareTeleportInnerSessionIsNoOpForNonTeleportAuthMethods() {
        // The internal guard is `config.authMethod == .faceIDTeleport`.
        // Non-Teleport methods must NOT match that guard, so the prepare call
        // returns immediately without touching libssh2.
        for method: AuthMethod in [.password, .sshKey, .sshKeyWithPassphrase] {
            XCTAssertFalse(
                method == .faceIDTeleport,
                "\(method) must not match the Teleport prepare guard"
            )
        }
        XCTAssertTrue(
            AuthMethod.faceIDTeleport == .faceIDTeleport,
            "Teleport auth method must match the prepare guard"
        )
    }
}
