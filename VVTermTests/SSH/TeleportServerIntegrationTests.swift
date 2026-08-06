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
import Security
import Testing
@testable import VVTerm

struct TeleportServerIntegrationTests {

    /// True when `scripts/ci/teleport-server.sh` fixtures are present. Read
    /// at run time by the `.enabled(if:)` trait below — absent in PR CI/dev
    /// (skipped), present in the teleport-e2e workflow (runs).
    private static var teleportEnvPresent: Bool {
        ProcessInfo.processInfo.environment["VVTERM_TELEPORT_CERT"] != nil
    }

    /// True only on the M4 ceremony leg: a `webauthn` cluster where the
    /// harness also minted the device-less app user + TLS identity
    /// (VVTERM_TELEPORT_APP_TLS_*). The ceremony test skips on `off`/`otp`
    /// legs and in PR CI.
    private static var webauthnCeremonyEnvPresent: Bool {
        let env = ProcessInfo.processInfo.environment
        return teleportEnvPresent
            && env["VVTERM_TELEPORT_SECOND_FACTOR"] == "webauthn"
            && env["VVTERM_TELEPORT_APP_TLS_CERT"] != nil
    }

    /// Full E2E: TLS+ALPN dial of the proxy, `proxy:<node>:0` subsystem,
    /// outer + inner libssh2 handshakes, cert auth, and exec routed to the
    /// target node.
    @Test(.enabled(if: teleportEnvPresent), .timeLimit(.minutes(3))) @MainActor
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
        // The 30s default connect budget is tight for a contended CI runner
        // (the off leg's outer handshake has stalled 18-30s+ there); give
        // the E2E path headroom. The app default is unchanged.
        await client.setConnectTimeout(.seconds(90))
        do {
            let session = try await client.connect(
                to: server,
                credentials: ServerCredentials(serverId: clusterId)
            )
            #expect(await session.isConnected)
            // Open the `proxy:<node>:0` subsystem channel + second libssh2
            // handshake so exec routes to the inner (node) session.
            try await client.prepareTeleportInnerSession()
            // The node's exec-session startup can stall behind the CI
            // cluster's lite-backend write-lock pileups (observed: 1-4.5s
            // transactions queueing the session.start audit write, "Child
            // process never became ready" after ~20s). The default 20s
            // exec budget is too tight for that — give it headroom; the
            // assertion still verifies the output.
            let output = try await client.execute(
                "echo VVTERM_TELEPORT_E2E_OK",
                timeout: .seconds(60)
            )
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

    /// M4 (issue #83): the app's REAL Phase-2 + Phase-3 ceremonies against
    /// the live webauthn cluster, signed by an injected software signer.
    ///
    /// Phase 2 (registration): the gRPC AuthService dial (TLS + ALPN
    /// teleport-auth@<hex(cluster)>.teleport.cluster.local + mTLS with the
    /// tctl-minted TLS identity), CreateAuthenticateChallenge (empty for the
    /// device-less ci-app user → first-device path, no Safari ceremony),
    /// CreateRegisterChallenge, software-key attestation, AddMFADeviceSync
    /// (passwordless usage).
    ///
    /// Phase 3 (login): mfa/login/begin {passwordless:true} → assertion
    /// (UV + userHandle echo) → mfa/login/finish with the SSH pub key in
    /// both `pub_key` (v16) and `ssh_pub_key` (v17) fields → cert issued.
    ///
    /// This is the app-side counterpart of the Python harness's smokes:
    /// same server, same wire shapes, but through the app's own
    /// coordinators, WebAuthn builders, and HTTP/gRPC clients.
    @Test(.enabled(if: webauthnCeremonyEnvPresent), .timeLimit(.minutes(4))) @MainActor
    func teleportPhase2RegistrationAndPhase3PasswordlessLoginCeremony() async throws {
        let environment = ProcessInfo.processInfo.environment
        let cert = environment["VVTERM_TELEPORT_CERT"] ?? ""
        let clusterName = environment["VVTERM_TELEPORT_CLUSTER_NAME"] ?? "ci-cluster"
        let host = environment["VVTERM_TELEPORT_HOST"] ?? "127.0.0.1"
        let port = Int(environment["VVTERM_TELEPORT_PORT"] ?? "443") ?? 443
        let appUser = environment["VVTERM_TELEPORT_APP_USER"] ?? "ci-app"
        let tlsCert = environment["VVTERM_TELEPORT_APP_TLS_CERT"] ?? ""
        let tlsKeyPEM = environment["VVTERM_TELEPORT_APP_TLS_KEY"] ?? ""
        let tlsCAs = environment["VVTERM_TELEPORT_APP_TLS_CAS"] ?? ""
        guard !cert.isEmpty, !tlsCert.isEmpty, !tlsKeyPEM.isEmpty, !tlsCAs.isEmpty else {
            throw TeleportCeremonyError.fixturesMissing
        }

        let clusterId = UUID()
        let cluster = TeleportCluster(
            id: clusterId,
            host: host,
            port: port,
            username: appUser,
            rpID: host,
            clusterName: clusterName
        )

        // ONE software signer shared by the keyring, the registration
        // coordinator, and the login coordinator (the keys live in its
        // in-memory dictionary — a fresh instance per run).
        let signer = SoftwareSigner()
        let keyRing = TeleportKeyRing(signer: signer)
        defer { keyRing.clear(for: clusterId) }

        // The Phase-1 stand-in: the harness-minted TLS identity (tctl auth
        // sign --format=tls), the same shape Phase 1's headless login
        // returns (ssh cert + TLS cert + cluster CA bundle + private key).
        let tlsKey = try importRSAPrivateKey(pem: tlsKeyPEM)
        let bootstrapResult = TeleportBootstrapCoordinator.BootstrapResult(
            sshCertPEM: cert,
            tlsCertPEM: tlsCert,
            tlsKeyPairPrivateKey: tlsKey,
            clusterName: clusterName,
            clusterCAPEMs: [tlsCAs],
            certValidBefore: Date().addingTimeInterval(3600)
        )

        // ── Phase 2: register the app's first (passwordless) device ──────
        let registration = TeleportRegistrationCoordinator(
            grpcClient: LiveTeleportGRPCClient(),
            browserMFACeremony: LiveBrowserMFACeremony(),
            keyRing: keyRing,
            signer: signer,
            webAuthnBuilder: TeleportWebAuthnBuilder()
        )
        await registration.begin(
            cluster: cluster,
            deviceName: "ci-app-device",
            bootstrapResult: bootstrapResult
        )
        guard case .success = registration.state else {
            throw TeleportCeremonyError.registrationFailed(String(describing: registration.state))
        }
        #expect(keyRing.registeredCredentialID(for: clusterId) != nil)
        #expect(keyRing.registeredUserHandle(for: clusterId) != nil)

        // ── Phase 3: passwordless login with the registered device ───────
        let login = TeleportLoginCoordinator(
            httpClient: LiveTeleportHTTPClient(),
            keyRing: keyRing,
            signer: signer,
            webAuthnBuilder: TeleportWebAuthnBuilder()
        )
        await login.begin(cluster: cluster)
        guard case .success = login.state else {
            throw TeleportCeremonyError.loginFailed(String(describing: login.state))
        }
    }

    /// Import an RSA PKCS#1 PEM private key (BEGIN RSA PRIVATE KEY — the
    /// format `tctl auth sign --format=tls` writes) into a SecKey.
    private func importRSAPrivateKey(pem: String) throws -> SecKey {
        let lines = pem.components(separatedBy: .newlines).filter {
            !$0.hasPrefix("-----")
        }
        guard let der = Data(base64Encoded: lines.joined()) else {
            throw TeleportCeremonyError.keyImportFailed("base64 decode failed")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            der as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            let msg = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw TeleportCeremonyError.keyImportFailed(msg)
        }
        return key
    }
}

/// Errors thrown by the M4 ceremony test when a coordinator ends in a
/// non-success state (the coordinator states are the assertion surface).
private enum TeleportCeremonyError: Error, CustomStringConvertible {
    case fixturesMissing
    case keyImportFailed(String)
    case registrationFailed(String)
    case loginFailed(String)

    var description: String {
        switch self {
        case .fixturesMissing:
            return "M4 ceremony fixtures missing (need webauthn leg + app identity)"
        case .keyImportFailed(let m):
            return "TLS private key import failed: \(m)"
        case .registrationFailed(let s):
            return "Phase-2 registration ended in \(s)"
        case .loginFailed(let s):
            return "Phase-3 login ended in \(s)"
        }
    }
}
