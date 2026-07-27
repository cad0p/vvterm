// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  ServerStatsCollectorTeleportTests.swift
//  VVTermTests
//
//  Documents the Teleport stats-collection skip.
//
//  Teleport servers connect through a two-session path: the OUTER session is
//  the Teleport PROXY (TLS+ALPN on port 443), which is in `proxyMode` and
//  rejects `exec`/`pty`/`shell` channel requests with
//  LIBSSH2_ERROR_CHANNEL_REQUEST_FAILURE (-22). Stats collection runs
//  `client.execute(...)`, which opens an exec channel on the session it's
//  given — for Teleport that's the proxy session, so every probe fails.
//
//  This mirrors the `remoteEnvironment()` / `remoteTerminalType()` skip in
//  `SSHClient.startShell`. Stats are unavailable until they're routed through
//  the inner (target node) session; until then the collector must skip exec.
//

import XCTest
@testable import VVTerm

final class ServerStatsCollectorTeleportTests: XCTestCase {

    // MARK: - shouldSkipStatsCollection

    func testTeleportAuthMethodSkipsStatsCollection() {
        XCTAssertTrue(
            ServerStatsCollector.shouldSkipStatsCollection(for: .faceIDTeleport),
            "Teleport proxy sessions reject exec with -22; stats must be skipped"
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
}
