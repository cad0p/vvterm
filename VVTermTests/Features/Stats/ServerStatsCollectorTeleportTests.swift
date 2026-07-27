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
}
