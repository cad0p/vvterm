// SPDX-License-Identifier: MIT
//
//  ServerCloudKitCodecTests.swift
//  VVTermTests
//
//  Codec coverage for the CloudKit serialization of `Server`, focused on the
//  additive Teleport field `teleportHostLogin`:
//    - `toRecord` writes the value and clears the key when nil;
//    - `init?(from:)` reads it back;
//    - the decode seam drops a shape-invalid value to nil.
//
//  See:
//    - VVTerm/Features/Servers/Domain/Server+CloudKit.swift
//    - VVTerm/Features/Servers/Domain/Server.swift (shape validation)
//

import CloudKit
import Foundation
import Testing
@testable import VVTerm

struct ServerCloudKitCodecTests {

    private func makeServer(teleportHostLogin: String?) -> Server {
        Server(
            id: UUID(),
            workspaceId: UUID(),
            name: "pcad-dev",
            host: "teleport.pcad.it",
            port: 443,
            username: "pier",
            teleportHostLogin: teleportHostLogin,
            authMethod: .faceIDTeleport
        )
    }

    @Test
    func recordRoundTripsTeleportHostLogin() {
        let server = makeServer(teleportHostLogin: "deploy")
        let record = server.toRecord()

        #expect(record["teleportHostLogin"] as? String == "deploy")

        let decoded = Server(from: record)
        #expect(decoded?.teleportHostLogin == "deploy")
        #expect(decoded?.username == "pier")
    }

    @Test
    func recordClearsTeleportHostLoginWhenNil() {
        let record = makeServer(teleportHostLogin: nil).toRecord()
        #expect(record["teleportHostLogin"] == nil)
        #expect(Server(from: record)?.teleportHostLogin == nil)
    }

    @Test
    func recordDecodeDropsShapeInvalidTeleportHostLogin() {
        let valid = makeServer(teleportHostLogin: "deploy").toRecord()

        for invalid in ["", "   ", "de\nploy", String(repeating: "a", count: 256)] {
            let record = makeServer(teleportHostLogin: "deploy").toRecord()
            record["teleportHostLogin"] = invalid
            #expect(
                Server(from: record)?.teleportHostLogin == nil,
                "an invalid host login must decode as nil, got \(invalid.debugDescription)"
            )
        }

        // Sanity: the fixture record itself is valid.
        #expect(Server(from: valid)?.teleportHostLogin == "deploy")
    }

    @Test
    func recordRoundTripsAnAtSignLogin() {
        // Teleport logins may contain `@` (e.g. Kerberos-style principals);
        // the shape validation must not reject it.
        let server = makeServer(teleportHostLogin: "deploy@example.com")
        #expect(Server(from: server.toRecord())?.teleportHostLogin == "deploy@example.com")
    }
}
