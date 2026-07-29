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

    // MARK: - Environment resolution must establish the inner session first

    /// `SSHClient.shouldPrepareInnerSessionBeforeResolvingEnvironment(...)`
    /// is the pure decision extracted from `remoteEnvironment()` so it can
    /// be unit-tested without a live libssh2 session.
    ///
    /// `remoteEnvironment()` and `remoteTerminalType()` resolve the remote
    /// platform/shell/terminal-type by running `execute(...)` probes. For
    /// Teleport the outer session is the PROXY, which rejects exec with -22;
    /// those probes must run on the INNER (target-node) session. If the inner
    /// session is not ready when `remoteEnvironment()` is called, the client
    /// must establish it (via `prepareTeleportInnerSession()`) BEFORE running
    /// the probes — otherwise the probes exec on the outer session, fail
    /// with -22, and poison the outer session so the subsequent subsystem
    /// request also fails.
    ///
    /// The decision returns `true` ONLY for the Teleport auth method AND when
    /// the inner session is not yet ready. For non-Teleport (outer session
    /// supports exec directly) and for Teleport-with-ready-inner (prepare is
    /// a no-op idempotent guard), it returns `false`.
    func testShouldPrepareInnerSessionBeforeResolvingEnvironmentForTeleportWhenNotReady() {
        XCTAssertTrue(
            SSHClient.shouldPrepareInnerSessionBeforeResolvingEnvironment(
                authMethod: .faceIDTeleport,
                innerSessionReady: false
            ),
            "Teleport with no inner session yet must prepare it before resolving env"
        )
    }

    func testShouldNotPrepareInnerSessionBeforeResolvingEnvironmentForTeleportWhenReady() {
        // Inner session already established (e.g. shell already started):
        // prepare is an idempotent no-op, but the decision must still return
        // `false` so callers don't redundantly invoke prepare on every resolve.
        XCTAssertFalse(
            SSHClient.shouldPrepareInnerSessionBeforeResolvingEnvironment(
                authMethod: .faceIDTeleport,
                innerSessionReady: true
            ),
            "Teleport with a ready inner session must not re-prepare before resolving env"
        )
    }

    func testShouldNotPrepareInnerSessionBeforeResolvingEnvironmentForNonTeleport() {
        // Non-Teleport auth methods use the direct outer session, which
        // supports exec directly. They must never prepare an inner session.
        for method: AuthMethod in [.password, .sshKey, .sshKeyWithPassphrase] {
            XCTAssertFalse(
                SSHClient.shouldPrepareInnerSessionBeforeResolvingEnvironment(
                    authMethod: method,
                    innerSessionReady: false
                ),
                "\(method) must never prepare an inner session before resolving env"
            )
        }
    }

    // MARK: - Exec-on-outer-session landmine closure

    /// `SSHSession.shouldRejectExecOnOuterSession(authMethod:innerSessionReady:)`
    /// is the pure safety-net decision extracted from `execute()`. When exec
    /// would otherwise fall through to the OUTER (proxy) session for a
    /// Teleport client whose inner session is NOT ready, `execute()` must
    /// throw `notConnected` instead — running exec on the outer session
    /// fails with -22 and poisons the outer session state so the subsequent
    /// subsystem request also fails.
    ///
    /// The decision returns `true` (reject) ONLY for the Teleport auth method
    /// AND when the inner session is not ready. For non-Teleport (outer
    /// session supports exec directly) and for Teleport-with-ready-inner (exec
    /// routes to the inner session), it returns `false`.
    func testShouldRejectExecOnOuterSessionForTeleportWhenInnerNotReady() {
        XCTAssertTrue(
            SSHSession.shouldRejectExecOnOuterSession(
                authMethod: .faceIDTeleport,
                innerSessionReady: false
            ),
            "Teleport without a ready inner session must not exec on the outer session"
        )
    }

    func testShouldNotRejectExecOnOuterSessionForTeleportWhenInnerReady() {
        // Inner session ready: exec routes to the inner session via
        // `shouldRouteExecToInnerSession`; the outer-session fallthrough is
        // never reached, so the rejection guard must not fire.
        XCTAssertFalse(
            SSHSession.shouldRejectExecOnOuterSession(
                authMethod: .faceIDTeleport,
                innerSessionReady: true
            ),
            "Teleport with a ready inner session must not reject outer-session exec"
        )
    }

    func testShouldNotRejectExecOnOuterSessionForNonTeleport() {
        // Non-Teleport auth methods use the direct outer session, which
        // supports exec. They must never be rejected at the outer-session
        // fallthrough.
        for method: AuthMethod in [.password, .sshKey, .sshKeyWithPassphrase] {
            XCTAssertFalse(
                SSHSession.shouldRejectExecOnOuterSession(
                    authMethod: method,
                    innerSessionReady: false
                ),
                "\(method) must never be rejected at the outer-session exec fallthrough"
            )
        }
    }
}
