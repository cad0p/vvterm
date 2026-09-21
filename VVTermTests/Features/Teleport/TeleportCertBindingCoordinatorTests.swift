// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportCertBindingCoordinatorTests.swift
//  VVTermTests
//
//  Coordinator-level coverage for the issued-certificate binding checks:
//  the login (Phase 3) and bootstrap (Phase 1) coordinators must store
//  nothing when the issued cert does not match the generated keypair.
//

#if DEBUG
import Foundation
import Security
import Testing
@testable import VVTerm

@MainActor
struct TeleportCertBindingCoordinatorTests {

    private func makeCluster() -> TeleportCluster {
        TeleportCluster(host: "teleport.pcad.it", username: "pier")
    }

    private func makeRegisteredKeyRing(clusterId: UUID, credentialID: Data = Data([1, 2, 3, 4])) -> MockTeleportKeyRing {
        let keyRing = MockTeleportKeyRing()
        keyRing.seed(
            clusterId: clusterId,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: credentialID,
                userHandle: Data("user-handle".utf8),
                deviceName: "test-device"
            )
        )
        return keyRing
    }

    private func makeLoginCoordinator(
        http: MockTeleportHTTPClient,
        keyRing: MockTeleportKeyRing,
        credentialID: Data,
        publicKey: String,
        now: @escaping () -> Date
    ) throws -> TeleportLoginCoordinator {
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        return TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            signer: signer,
            keyPairGenerator: FixedTeleportSSHKeyPairGenerator(publicKey: publicKey),
            now: now
        )
    }

    // MARK: - Phase 3 login

    @Test
    func loginStoresCertBoundToTheKeypair() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = MockTeleportHTTPClient.makeFixtureLoginFinishResponse()

        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: keyRing,
            credentialID: credentialID,
            publicKey: TeleportFixtureSupport.fixedSSHPublicKey,
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        #expect(coordinator.state == .success(certValidUntil: Date(timeIntervalSince1970: 2_082_758_400)))
        #expect(keyRing.liveCertPEM(for: cluster.id) == TeleportFixtureSupport.fixedIssuedUserCert)
        #expect(keyRing.liveEd25519PrivateKey(for: cluster.id) != nil)
    }

    @Test
    func loginRejectsCertWithMismatchedKeyAndStoresNothing() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = MockTeleportHTTPClient.makeFixtureLoginFinishResponse()

        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: keyRing,
            credentialID: credentialID,
            publicKey: TeleportFixtureSupport.otherSSHPublicKey,
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        if case .failed = coordinator.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(coordinator.state)")
        }
        #expect(keyRing.liveCertPEM(for: cluster.id) == nil)
        #expect(keyRing.liveEd25519PrivateKey(for: cluster.id) == nil)
    }

    @Test
    func loginRejectsCertWithExcessiveTTLAndStoresNothing() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = MockTeleportHTTPClient.makeFixtureLoginFinishResponse()

        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: keyRing,
            credentialID: credentialID,
            publicKey: TeleportFixtureSupport.fixedSSHPublicKey,
            // 2027-01-01 — far more than 1h before the fixture cert expires.
            now: { Date(timeIntervalSince1970: 1_798_761_600) }
        )
        await coordinator.begin(cluster: cluster)

        if case .failed = coordinator.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(coordinator.state)")
        }
        #expect(keyRing.liveCertPEM(for: cluster.id) == nil)
    }

    @Test
    func loginRejectsHostCertificateAndStoresNothing() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = LoginFinishResponse(
            cert: Data(TeleportFixtureSupport.hostCertLine.utf8).base64EncodedString(),
            hostSigners: nil
        )

        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: keyRing,
            credentialID: credentialID,
            publicKey: TeleportFixtureSupport.otherSSHPublicKey,
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        if case .failed = coordinator.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(coordinator.state)")
        }
        #expect(keyRing.liveCertPEM(for: cluster.id) == nil)
    }

    // MARK: - Phase 1 bootstrap

    private func makeBootstrapCoordinator(
        http: MockTeleportHTTPClient,
        keyRing: MockTeleportKeyRing,
        publicKey: String
    ) throws -> TeleportBootstrapCoordinator {
        TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: keyRing,
            safariPresenter: nil,
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: FixedTeleportSSHKeyPairGenerator(publicKey: publicKey),
            tlsKeyPairGenerator: try TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
    }

    @Test
    func bootstrapStoresCertAndClusterStateWhenEverythingMatches() async throws {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()

        let coordinator = try makeBootstrapCoordinator(
            http: http,
            keyRing: keyRing,
            publicKey: TeleportFixtureSupport.fixedSSHPublicKey
        )
        await coordinator.begin(cluster: cluster)

        #expect(coordinator.state == .success)
        #expect(keyRing.liveCertPEM(for: cluster.id) == TeleportFixtureSupport.fixedIssuedUserCert)
        #expect(keyRing.clusterTLSState(for: cluster.id) != nil)
    }

    @Test
    func bootstrapAbortsWhenIssuedSSHCertMismatchesTheKey() async throws {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()

        let coordinator = try makeBootstrapCoordinator(
            http: http,
            keyRing: keyRing,
            publicKey: TeleportFixtureSupport.otherSSHPublicKey
        )
        await coordinator.begin(cluster: cluster)

        if case .failed = coordinator.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(coordinator.state)")
        }
        #expect(keyRing.liveCertPEM(for: cluster.id) == nil)
        #expect(keyRing.clusterTLSState(for: cluster.id) == nil)
        #expect(coordinator.lastBootstrapResult == nil)
    }

    @Test
    func bootstrapAbortsWhenIssuedTLSCertMismatchesTheKeypair() async throws {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let http = MockTeleportHTTPClient()
        // Same SSH cert/key binding, but the TLS cert is the wrongname
        // fixture (not signed for the fixed TLS keypair).
        let matching = MockTeleportHTTPClient.makeFixtureSuccessResponse()
        let wrongTLS = TeleportFixtureSupport.fixtureString("loopback-tls/server-wrongname.pem")
        http.scriptedHeadlessResponse = HeadlessLoginResponse(
            cert: matching.cert,
            tlsCert: Data(wrongTLS.utf8).base64EncodedString(),
            hostSigners: matching.hostSigners
        )

        let coordinator = try makeBootstrapCoordinator(
            http: http,
            keyRing: keyRing,
            publicKey: TeleportFixtureSupport.fixedSSHPublicKey
        )
        await coordinator.begin(cluster: cluster)

        if case .failed = coordinator.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(coordinator.state)")
        }
        #expect(keyRing.liveCertPEM(for: cluster.id) == nil)
        #expect(coordinator.lastBootstrapResult == nil)
    }
}

#endif
