// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportServerModelTests.swift
//  VVTermTests
//
//  Documents the Teleport model: for `authMethod == .faceIDTeleport`,
//  `Server.host` is the PROXY host (e.g. `teleport.pcad.it`) and
//  `Server.name` (the display name) is the TARGET NODE name (e.g. `pcad-dev`).
//
//  This mirrors how `tsh ssh pier@pcad-dev` works: the user names the node,
//  and the proxy host is separate. For VVTerm, the user enters:
//    Name: pcad-dev          (display name + Teleport node name)
//    Host: teleport.pcad.it   (proxy host)
//    Port: 443
//    User: pier
//
//  The node name (`Server.name`) goes into the `proxy:<node>:0` subsystem
//  string. The proxy host (`Server.host`) is used for TLS+ALPN dial + bootstrap.
//
//  This is a MODEL REINTERPRETATION, not a schema change: `Server`'s
//  `Codable` is unchanged. The `name` field has always existed (display name);
//  for Teleport servers it now also serves as the node name.
//

import XCTest
@testable import VVTerm

final class TeleportServerModelTests: XCTestCase {

    /// For `.faceIDTeleport`, `Server.name` is the target node name and
    /// `Server.host` is the proxy host. They are distinct values.
    func testFaceIDTeleportServer_nameIsNode_hostIsProxy() {
        let server = Server(
            workspaceId: UUID(),
            name: "pcad-dev",              // display name = node name
            host: "teleport.pcad.it",      // proxy host
            port: 443,
            username: "pier",
            authMethod: .faceIDTeleport
        )

        XCTAssertEqual(server.name, "pcad-dev", "Server.name = node name")
        XCTAssertEqual(server.host, "teleport.pcad.it", "Server.host = proxy host")
        XCTAssertNotEqual(server.name, server.host)
    }

    /// `Server`'s `Codable` round-trips unchanged (guards against schema drift).
    func testFaceIDTeleportServer_codableRoundTrip_preservesNameAndHost() throws {
        let original = Server(
            workspaceId: UUID(),
            name: "pcad-dev",
            host: "teleport.pcad.it",
            port: 443,
            username: "pier",
            authMethod: .faceIDTeleport
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Server.self, from: encoded)

        XCTAssertEqual(decoded.name, "pcad-dev")
        XCTAssertEqual(decoded.host, "teleport.pcad.it")
        XCTAssertEqual(decoded.authMethod, .faceIDTeleport)
    }

    /// The Teleport node name may contain dots (per Teleport's `nodename`
    /// config: "alphanumeric characters, dots, and hyphens"). This is distinct
    /// from the proxy host — the name is used as-is in the subsystem string.
    func testTeleportNodeName_mayContainDots() {
        let server = Server(
            workspaceId: UUID(),
            name: "web.frontend.01",       // node name with dots
            host: "teleport.pcad.it",
            port: 443,
            username: "pier",
            authMethod: .faceIDTeleport
        )

        XCTAssertEqual(server.name, "web.frontend.01")
    }

    /// `TeleportCluster.host` is the proxy host, distinct from `Server.name`
    /// (the node name). `TeleportCluster` is derived from `Server.host`/`port`/
    /// `username` at bootstrap.
    func testTeleportCluster_hostIsProxyHost_distinctFromServerName() {
        let server = Server(
            workspaceId: UUID(),
            name: "pcad-dev",
            host: "teleport.pcad.it",
            port: 443,
            username: "pier",
            authMethod: .faceIDTeleport
        )
        let cluster = TeleportCluster(
            id: server.id,
            host: server.host,
            port: server.port,
            username: server.username
        )

        XCTAssertEqual(cluster.host, "teleport.pcad.it", "TeleportCluster.host = proxy host")
        XCTAssertEqual(server.name, "pcad-dev", "Server.name = node name")
        XCTAssertNotEqual(server.name, cluster.host)
    }

    /// End-to-end: `SSHSessionConfig.teleportNodeName` carries the node name
    /// (`Server.name`) so the SSHClient can build the `proxy:<node>:0`
    /// subsystem string without a separate lookup.
    func testSSHSessionConfig_carriesTeleportNodeName() {
        let config = SSHSessionConfig(
            host: "teleport.pcad.it",
            port: 443,
            username: "pier",
            connectionMode: .standard,
            authMethod: .faceIDTeleport,
            credentials: ServerCredentials(
                serverId: UUID(),
                password: nil
            ),
            teleportNodeName: "pcad-dev"
        )

        XCTAssertEqual(config.host, "teleport.pcad.it")
        XCTAssertEqual(config.teleportNodeName, "pcad-dev")
    }
}
