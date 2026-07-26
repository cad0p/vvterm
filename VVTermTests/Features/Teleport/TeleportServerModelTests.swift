// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportServerModelTests.swift
//  VVTermTests
//
//  Documents the Teleport model reinterpretation: for
//  `authMethod == .faceIDTeleport`, `Server.host` holds the TARGET NODE
//  (e.g. `pcad-dev.teleport.pcad.it`), mirroring how `tsh ssh
//  pier@pcad-dev` works — the user names the node, and the proxy host
//  comes from the cluster config (`TeleportCluster.host`).
//
//  Previously `Server.host` was (incorrectly) reused as the Teleport proxy
//  host and `TeleportCluster` was derived from `Server.host`/`port`/
//  `username`. That conflated the target node with the proxy endpoint.
//
//  This is a MODEL REINTERPRETATION, not a schema change: `Server`'s
//  `Codable` is unchanged. Existing Teleport servers (whose `host` still
//  holds the proxy host) require a one-time migration to populate the
//  target node + stored cluster — that migration is intentionally NOT
//  implemented here (see the comment on `Server.host`).
//
//  See:
//    - VVTerm/Features/Servers/Domain/Server.swift (Server.host comment)
//    - VVTerm/Features/Teleport/Domain/TeleportCluster.swift (host = proxy)
//    - VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift
//      (`teleportCluster` + `proxyHost(storedProxyHost:formHost:)`)
//

import XCTest
@testable import VVTerm

final class TeleportServerModelTests: XCTestCase {

    // MARK: - Server.host is the target node for .faceIDTeleport

    /// For a `.faceIDTeleport` server, `Server.host` holds the target node
    /// the user wants to reach (e.g. `pcad-dev.teleport.pcad.it`), NOT the
    /// Teleport proxy host. This mirrors `tsh ssh pier@pcad-dev`, where the
    /// user names the node and the proxy comes from the cluster config.
    func testFaceIDTeleportServer_hostIsTargetNode_notProxyHost() {
        let server = Server(
            workspaceId: UUID(),
            name: "pcad-dev",
            host: "pcad-dev.teleport.pcad.it",  // target node
            port: 443,
            username: "pier",
            authMethod: .faceIDTeleport
        )

        XCTAssertEqual(server.host, "pcad-dev.teleport.pcad.it")
        XCTAssertNotEqual(
            server.host,
            "teleport.pcad.it",
            "Server.host must NOT be the proxy host for .faceIDTeleport"
        )
    }

    /// `Server`'s `Codable` is unchanged by this reinterpretation — `host`
    /// still round-trips as a plain `String`. This guards against accidental
    /// schema drift.
    func testFaceIDTeleportServer_codableRoundTrip_preservesHost() throws {
        let server = Server(
            workspaceId: UUID(),
            name: "pcad-dev",
            host: "pcad-dev.teleport.pcad.it",
            port: 443,
            username: "pier",
            authMethod: .faceIDTeleport
        )

        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(Server.self, from: data)

        XCTAssertEqual(decoded.host, "pcad-dev.teleport.pcad.it")
        XCTAssertEqual(decoded.authMethod, .faceIDTeleport)
    }

    // MARK: - TeleportCluster.host is the proxy host

    /// The Teleport proxy host lives on `TeleportCluster.host` (established
    /// during bootstrap), distinct from `Server.host` (the target node).
    func testTeleportCluster_hostIsProxyHost_distinctFromServerHost() {
        let cluster = TeleportCluster(
            host: "teleport.pcad.it",  // proxy host
            port: 443,
            username: "pier"
        )

        XCTAssertEqual(cluster.host, "teleport.pcad.it")
        XCTAssertNotEqual(
            cluster.host,
            "pcad-dev.teleport.pcad.it",
            "TeleportCluster.host is the PROXY host, not the target node"
        )
    }

    // MARK: - ServerFormSheet.teleportCluster uses the stored proxy host

    /// `ServerFormSheet.teleportCluster` must NOT derive its `host` from the
    /// form's `host` field (which is now the target node). When a stored
    /// proxy host is available (captured at bootstrap), it must be used
    /// instead.
    ///
    /// The resolution is extracted into the testable static helper
    /// `ServerFormSheet.proxyHost(storedProxyHost:formHost:)` so it can be
    /// asserted without hosting the full SwiftUI form.
    func testServerFormSheet_proxyHost_prefersStoredProxyHost_overFormHost() {
        let resolved = ServerFormSheet.proxyHost(
            storedProxyHost: "teleport.pcad.it",      // captured at bootstrap
            formHost: "pcad-dev.teleport.pcad.it"     // target node (form field)
        )

        XCTAssertEqual(
            resolved,
            "teleport.pcad.it",
            "teleportCluster must use the stored proxy host, not the form's host field"
        )
    }

    /// When no stored proxy host exists (e.g. a server that hasn't been
    /// bootstrapped yet under the new model), the form's `host` field is
    /// used as the fallback — preserving the bootstrap flow where the user
    /// enters the proxy host in the bootstrap sheet.
    func testServerFormSheet_proxyHost_fallsBackToFormHost_whenNoStoredProxy() {
        let resolved = ServerFormSheet.proxyHost(
            storedProxyHost: nil,
            formHost: "teleport.pcad.it"
        )

        XCTAssertEqual(resolved, "teleport.pcad.it")
    }

    /// A stored proxy host that is empty/whitespace is treated as absent, so
    /// the form host is used instead (guards against stale empty captures).
    func testServerFormSheet_proxyHost_ignoresBlankStoredProxyHost() {
        let resolved = ServerFormSheet.proxyHost(
            storedProxyHost: "   ",
            formHost: "teleport.pcad.it"
        )

        XCTAssertEqual(resolved, "teleport.pcad.it")
    }

    /// End-to-end documentation of the new semantics: the target node and the
    /// proxy host are two different values, living on two different models.
    func testTeleportModel_targetNode_and_proxyHost_areDistinct() {
        let targetNode = "pcad-dev.teleport.pcad.it"  // Server.host
        let proxyHost = "teleport.pcad.it"             // TeleportCluster.host

        let server = Server(
            workspaceId: UUID(),
            name: "pcad-dev",
            host: targetNode,
            port: 443,
            username: "pier",
            authMethod: .faceIDTeleport
        )
        let cluster = TeleportCluster(
            id: server.id,
            host: proxyHost,
            port: server.port,
            username: server.username
        )

        XCTAssertEqual(server.host, targetNode, "Server.host = target node")
        XCTAssertEqual(cluster.host, proxyHost, "TeleportCluster.host = proxy host")
        XCTAssertNotEqual(server.host, cluster.host)
    }
}
