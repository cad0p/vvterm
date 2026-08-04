// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportServerIntegrationTests.swift
//  VVTerm
//
//  Milestone M1b of issue #83 — drive the app's real SSH stack against a
//  real Teleport cluster (TLS Routing on :443).
//
//  The cluster is booted by `scripts/ci/teleport-server.sh`
//  (install/start/bootstrap), which writes a source-able env file
//  (`$RUNNER_TEMP/vvterm-teleport/vvterm-teleport.env`) with
//  `VVTERM_TELEPORT_*` fixtures. `.github/workflows/teleport-e2e.yml`
//  sources that file into the xcodebuild process; env vars propagate to the
//  simulator test process (same mechanism as `VVTERM_UNREACHABLE_TEST_HOST`
//  in PR CI).
//
//  In PR CI the env is absent, so the E2E test is skipped via the
//  `.enabled(if:)` trait (evaluated at run time in the test runner process)
//  and costs ~0s. The negative test needs no server and runs everywhere.
//  Both tests use fresh cluster UUIDs and clean up the keyring, so they are
//  safe to run in parallel with each other and with the rest of the suite.
//

import Foundation
import Testing
@testable import VVTerm

struct TeleportServerIntegrationTests {

    /// True when `scripts/ci/teleport-server.sh` fixtures are present. Read
    /// at run time by the `.enabled(if:)` trait below — absent in PR CI/dev
    /// (skipped), present in the teleport-e2e workflow (runs).
    private static var teleportEnvPresent: Bool {
        ProcessInfo.processInfo.environment["VVTERM_TELEPORT_CERT"] != nil
    }

    /// Full E2E: TLS+ALPN dial of the proxy, `proxy:<node>:0` subsystem,
    /// outer + inner libssh2 handshakes, cert auth, and exec routed to the
    /// target node.
    @Test(.enabled(if: teleportEnvPresent)) @MainActor
    func teleportSSHConnectsThroughTLSRoutingAndExecutes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let cert = environment["VVTERM_TELEPORT_CERT"] else {
            throw SSHError.connectionFailed(
                "VVTERM_TELEPORT_CERT missing despite .enabled(if:) — env changed between trait eval and test body"
            )
        }
        let key = environment["VVTERM_TELEPORT_KEY"] ?? ""
        let caCerts = environment["VVTERM_TELEPORT_CA_CERTS"] ?? ""
        let clusterName = environment["VVTERM_TELEPORT_CLUSTER_NAME"] ?? "ci-cluster"
        let host = environment["VVTERM_TELEPORT_HOST"] ?? "127.0.0.1"
        let port = Int(environment["VVTERM_TELEPORT_PORT"] ?? "443") ?? 443
        let node = environment["VVTERM_TELEPORT_NODE"] ?? "ci-node"
        let login = environment["VVTERM_TELEPORT_LOGIN"] ?? "ci-user"

        let clusterId = UUID()
        // For Teleport, `Server.name` IS the node name (`proxy:<node>:0`),
        // `host`/`port` are the PROXY endpoint.
        let server = Server(
            id: clusterId,
            workspaceId: UUID(),
            name: node,
            host: host,
            port: port,
            username: login,
            connectionMode: .standard,
            authMethod: .faceIDTeleport
        )

        // Seed the keyring singleton the SSH path reads from. `storeLoginCert`
        // guards on an existing credential record (it requires a registered
        // SEP key), so seed the record via `storeBootstrapCert` first — same
        // cert, same validity window. The ed25519 private key goes to the
        // keychain; `clear` wipes both stores.
        let keyRing = TeleportKeyRing.shared
        keyRing.storeClusterTLSState(
            TeleportClusterTLSState(clusterName: clusterName, clusterCAPEMs: [caCerts]),
            for: clusterId
        )
        let validBefore = Date().addingTimeInterval(3600)
        keyRing.storeBootstrapCert(cert, validBefore: validBefore, for: clusterId)
        keyRing.storeLoginCert(cert, validBefore: validBefore, for: clusterId)
        try keyRing.storeEd25519PrivateKey(Data(key.utf8), for: clusterId)
        defer { keyRing.clear(for: clusterId) }

        let client = SSHClient()
        do {
            let session = try await client.connect(
                to: server,
                credentials: ServerCredentials(serverId: clusterId)
            )
            #expect(await session.isConnected)
            // Open the `proxy:<node>:0` subsystem channel + second libssh2
            // handshake so exec routes to the inner (node) session.
            try await client.prepareTeleportInnerSession()
            let output = try await client.execute("echo VVTERM_TELEPORT_E2E_OK")
            #expect(output.contains("VVTERM_TELEPORT_E2E_OK"))
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// Ungated negative: with no keyring state for the cluster,
    /// `connectTeleportTLS` throws `teleportCertMissing` BEFORE any network
    /// dial — so this fails fast even though `127.0.0.1:1` has no listener.
    @Test
    func teleportConnectFailsFastWithoutKeyringState() async throws {
        let server = Server(
            id: UUID(),
            workspaceId: UUID(),
            name: "nonexistent-node",
            host: "127.0.0.1",
            port: 1,
            username: "ci-user",
            connectionMode: .standard,
            authMethod: .faceIDTeleport
        )
        let client = SSHClient()
        await #expect(throws: SSHError.self) {
            try await client.connect(
                to: server,
                credentials: ServerCredentials(serverId: server.id)
            )
        }
    }
}
