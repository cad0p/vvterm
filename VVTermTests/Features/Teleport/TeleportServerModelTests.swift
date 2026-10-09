// SPDX-License-Identifier: MIT
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
//  This remains a MODEL REINTERPRETATION of `name`/`host` for Teleport rows,
//  not a schema change to those fields. The one additive Teleport schema
//  field is `Server.teleportHostLogin` (the certificate principal the SSH
//  session authenticates as, tsh's "host login"), which the setup picker
//  persists and the connect path resolves against the live certificate.
//

import XCTest
import TeleportCore
@testable import VVTerm

@MainActor
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

    /// `Server`'s `Codable` round-trips the additive Teleport fields (guards
    /// against schema drift).
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
        XCTAssertNil(decoded.teleportHostLogin)
    }

    // MARK: - teleportHostLogin (additive schema field)

    /// The chosen host login round-trips through the local `Codable` path.
    func testTeleportHostLogin_codableRoundTrip() throws {
        let original = Server(
            workspaceId: UUID(),
            name: "pcad-dev",
            host: "teleport.pcad.it",
            port: 443,
            username: "pier",
            teleportHostLogin: "deploy",
            authMethod: .faceIDTeleport
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Server.self, from: encoded)

        XCTAssertEqual(decoded.username, "pier", "username stays the Teleport user")
        XCTAssertEqual(decoded.teleportHostLogin, "deploy")
    }

    /// Absent on the wire decodes to nil (legacy rows and non-Teleport rows).
    func testTeleportHostLogin_absentDecodesAsNil() throws {
        let original = Server(
            workspaceId: UUID(),
            name: "pcad-dev",
            host: "teleport.pcad.it",
            port: 443,
            username: "pier",
            authMethod: .faceIDTeleport
        )

        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["teleportHostLogin"])

        object.removeValue(forKey: "teleportHostLogin")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Server.self, from: legacyData)
        XCTAssertNil(decoded.teleportHostLogin)
    }

    /// The decode seam validates shape only: empty/whitespace-only values and
    /// control characters drop to nil, an over-long value drops to nil, and
    /// `@` stays allowed (Teleport logins may contain it).
    func testTeleportHostLogin_decodeValidatesShapeOnly() throws {
        XCTAssertNil(Server.normalizedTeleportHostLogin(nil))
        XCTAssertNil(Server.normalizedTeleportHostLogin(""))
        XCTAssertNil(Server.normalizedTeleportHostLogin("   "))
        XCTAssertNil(Server.normalizedTeleportHostLogin("de\nploy"))
        XCTAssertNil(Server.normalizedTeleportHostLogin(String(repeating: "a", count: 256)))
        XCTAssertEqual(
            Server.normalizedTeleportHostLogin(String(repeating: "a", count: 255)),
            String(repeating: "a", count: 255)
        )
        XCTAssertEqual(Server.normalizedTeleportHostLogin("deploy"), "deploy")
        XCTAssertEqual(Server.normalizedTeleportHostLogin("deploy@example.com"), "deploy@example.com")
        XCTAssertEqual(Server.normalizedTeleportHostLogin(" deploy "), "deploy")
    }

    /// A decoded value that fails the shape check becomes nil (never a
    /// half-valid principal that could reach the SSH username).
    func testTeleportHostLogin_invalidEncodedValueDecodesAsNil() throws {
        let original = Server(
            workspaceId: UUID(),
            name: "pcad-dev",
            host: "teleport.pcad.it",
            port: 443,
            username: "pier",
            authMethod: .faceIDTeleport
        )

        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["teleportHostLogin"] = String(repeating: "a", count: 1024)
        let oversized = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Server.self, from: oversized)
        XCTAssertNil(decoded.teleportHostLogin)
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

    /// `SSHSessionConfig.teleportHostLogin` carries the server row's stored
    /// host login so the connect path can validate it against the live cert's
    /// principals. `config.username` stays the Teleport user.
    func testSSHSessionConfig_carriesTeleportHostLoginSeparatelyFromUsername() {
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
            teleportHostLogin: "deploy",
            teleportNodeName: "pcad-dev"
        )

        XCTAssertEqual(config.username, "pier", "username is the Teleport user")
        XCTAssertEqual(config.teleportHostLogin, "deploy", "teleportHostLogin is the certificate principal")
    }

    /// The fail-closed host-login error is never auto-retried: the connect
    /// path already cleared the credential, so a retry would only loop.
    func testTeleportHostLoginUnresolvableDoesNotAllowAutomaticRetry() {
        XCTAssertFalse(
            SSHError.teleportHostLoginUnresolvable(.noPrincipals).allowsAutomaticReconnectRetry
        )
        XCTAssertFalse(
            SSHError.teleportHostLoginUnresolvable(.ambiguousPrincipalSet(["a", "b"])).allowsAutomaticReconnectRetry
        )
        XCTAssertEqual(
            SSHError.teleportHostLoginUnresolvable(.noPrincipals).localizedDescription,
            TeleportHostLoginFailure.noPrincipals.errorDescription
        )
    }
}
