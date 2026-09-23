// SPDX-License-Identifier: MIT
//
//  TeleportWebAuthnRPIDTests.swift
//  VVTermTests
//
//  Coverage for the WebAuthn RP ID validation (W8):
//    - the pure resolver (configured value wins, empty server value falls
//      back, mismatch fails closed);
//    - the Phase 3 login coordinator (mismatch → .failed and nothing
//      stored; empty → the configured RP ID is used);
//    - the Phase 2 registration coordinator (mismatch → .failed before the
//      SEP key is created; empty → the configured RP ID reaches the
//      WebAuthn builder).
//

#if DEBUG
import Foundation
import Security
import Testing
@testable import VVTerm

@MainActor
struct TeleportWebAuthnRPIDTests {

    private func makeCluster(rpID: String? = nil) -> TeleportCluster {
        TeleportCluster(host: "teleport.pcad.it", username: "pier", rpID: rpID)
    }

    // MARK: - Pure resolver

    @Test
    func resolverUsesClusterHostByDefault() {
        let cluster = makeCluster()
        #expect(cluster.rpID == "teleport.pcad.it")
        for provided in [nil, "", "teleport.pcad.it", "TELEPORT.PCAD.IT"] as [String?] {
            switch TeleportWebAuthnRPID.resolve(serverProvided: provided, cluster: cluster) {
            case .success(let resolved):
                #expect(resolved == "teleport.pcad.it")
            case .failure(let error):
                Issue.record("expected success for \(String(describing: provided)), got \(error)")
            }
        }
    }

    @Test
    func resolverPrefersConfiguredCustomRPID() {
        let cluster = makeCluster(rpID: "custom.pcad.it")
        switch TeleportWebAuthnRPID.resolve(serverProvided: nil, cluster: cluster) {
        case .success(let resolved):
            #expect(resolved == "custom.pcad.it")
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
    }

    @Test
    func resolverRejectsMismatchedServerRPID() {
        let cluster = makeCluster()
        switch TeleportWebAuthnRPID.resolve(serverProvided: "evil.example.com", cluster: cluster) {
        case .success(let resolved):
            Issue.record("expected failure, got \(resolved)")
        case .failure(let error):
            #expect(error == .mismatch(serverProvided: "evil.example.com", expected: "teleport.pcad.it"))
        }
    }

    @Test
    func resolverFailsClosedWhenNothingIsConfigured() {
        let cluster = TeleportCluster(host: "", username: "pier", rpID: "")
        switch TeleportWebAuthnRPID.resolve(serverProvided: nil, cluster: cluster) {
        case .success(let resolved):
            Issue.record("expected failure, got \(resolved)")
        case .failure(let error):
            #expect(error == .missingExpected)
        }
    }

    // MARK: - Phase 3 login coordinator

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
        builder: RecordingWebAuthnBuilder = RecordingWebAuthnBuilder()
    ) throws -> TeleportLoginCoordinator {
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        return TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: signer,
            webAuthnBuilder: builder,
            keyPairGenerator: FixedTeleportSSHKeyPairGenerator(publicKey: TeleportFixtureSupport.fixedSSHPublicKey),
            now: { TeleportFixtureSupport.fixtureClock }
        )
    }

    private func makeLoginBeginResponse(rpID: String?) -> LoginBeginResponse {
        LoginBeginResponse(
            webauthnChallenge: LoginBeginResponse.WebauthnAssertion(
                publicKey: LoginBeginResponse.WebauthnAssertion.PublicKey(
                    challenge: Data([1, 2, 3, 4]).base64URLEncodedString(),
                    rpId: rpID
                )
            )
        )
    }

    @Test
    func loginRejectsMismatchedRPIDAndStoresNothing() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = makeLoginBeginResponse(rpID: "evil.example.com")
        http.scriptedLoginFinishResponse = MockTeleportHTTPClient.makeFixtureLoginFinishResponse()

        let coordinator = try makeLoginCoordinator(http: http, keyRing: keyRing, credentialID: credentialID)
        await coordinator.begin(cluster: cluster)

        guard case .failed(.server(let message)) = coordinator.state else {
            Issue.record("expected .failed(.server), got \(coordinator.state)")
            return
        }
        #expect(message.contains("rpID"))
        // The ceremony must fail before the assertion is signed or the cert
        // is requested.
        #expect(http.loginFinishCallCount == 0)
        #expect(keyRing.liveCertPEM(for: cluster.id) == nil)
    }

    @Test
    func loginFallsBackToConfiguredRPIDWhenServerSendsEmpty() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = makeLoginBeginResponse(rpID: "")
        http.scriptedLoginFinishResponse = MockTeleportHTTPClient.makeFixtureLoginFinishResponse()
        let builder = RecordingWebAuthnBuilder()
        builder.loginResult = .success(RecordingWebAuthnBuilder.assertionResponse())

        let coordinator = try makeLoginCoordinator(http: http, keyRing: keyRing, credentialID: credentialID, builder: builder)
        await coordinator.begin(cluster: cluster)

        #expect(builder.capturedLoginRPID == "teleport.pcad.it")
        #expect(coordinator.state == .success(certValidUntil: Date(timeIntervalSince1970: 2_082_758_400)))
    }

    // MARK: - Phase 2 registration coordinator

    private func makeRegisterChallenge(rpID: String) -> Proto_MFARegisterChallenge {
        var challenge = Proto_MFARegisterChallenge()
        var creation = Proto_CredentialCreation()
        var options = Proto_PublicKeyCredentialCreationOptions()
        options.challenge = Data([1, 2, 3, 4])
        var rp = Proto_RelyingPartyEntity()
        rp.id = rpID
        options.rp = rp
        var user = Proto_UserEntity()
        user.id = "user-1"
        options.user = user
        creation.publicKey = options
        challenge.webauthn = creation
        return challenge
    }

    private func makeBootstrapResult() throws -> TeleportBootstrapCoordinator.BootstrapResult {
        let keyPair = try TeleportFixtureSupport.makeFixedTLSGenerator().keyPair
        return TeleportBootstrapCoordinator.BootstrapResult(
            sshCertPEM: TeleportFixtureSupport.fixedIssuedUserCert,
            tlsCertPEM: "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----",
            tlsKeyPairPrivateKey: keyPair.privateKey,
            clusterName: "teleport.pcad.it",
            clusterCAPEMs: [],
            certValidBefore: TeleportFixtureSupport.fixtureClock.addingTimeInterval(3_600)
        )
    }

    private func makeRegistrationCoordinator(
        grpc: RPIDMockGRPCClient,
        builder: RecordingWebAuthnBuilder = RecordingWebAuthnBuilder()
    ) -> TeleportRegistrationCoordinator {
        TeleportRegistrationCoordinator(
            grpcClient: grpc,
            browserMFACeremony: NoBrowserMFACeremony(),
            keyRing: MockTeleportKeyRing(),
            logging: DefaultTeleportLogging(),
            signer: MockSEPKeySigner(outcome: .success),
            webAuthnBuilder: builder
        )
    }

    @Test
    func registrationRejectsMismatchedRPIDBeforeCreatingTheSEPKey() async throws {
        let cluster = makeCluster()
        let grpc = RPIDMockGRPCClient()
        grpc.registerChallenge = makeRegisterChallenge(rpID: "evil.example.com")
        let builder = RecordingWebAuthnBuilder()
        let coordinator = makeRegistrationCoordinator(grpc: grpc, builder: builder)

        await coordinator.begin(
            cluster: cluster,
            deviceName: "test-device",
            bootstrapResult: try makeBootstrapResult()
        )

        guard case .failed(.server(let message)) = coordinator.state else {
            Issue.record("expected .failed(.server), got \(coordinator.state)")
            return
        }
        #expect(message.contains("rpID"))
        #expect(builder.capturedRegisterRPID == nil)
        #expect(grpc.disconnectCallCount == 1)
    }

    @Test
    func registrationUsesConfiguredRPIDWhenServerSendsEmpty() async throws {
        let cluster = makeCluster()
        let grpc = RPIDMockGRPCClient()
        grpc.registerChallenge = makeRegisterChallenge(rpID: "")
        let builder = RecordingWebAuthnBuilder()
        let coordinator = makeRegistrationCoordinator(grpc: grpc, builder: builder)

        await coordinator.begin(
            cluster: cluster,
            deviceName: "test-device",
            bootstrapResult: try makeBootstrapResult()
        )

        // The builder is reached only after the RP ID check passes; it then
        // throws (recorded), which the coordinator surfaces as a failure.
        #expect(builder.capturedRegisterRPID == "teleport.pcad.it")
        if case .failed = coordinator.state {
            // expected — the recording builder stops the flow.
        } else {
            Issue.record("expected .failed after the recording builder threw, got \(coordinator.state)")
        }
    }
}

// MARK: - Test doubles

/// A WebAuthn builder that records the RP ID it is handed and either throws
/// a sentinel or returns a scripted response.
private final class RecordingWebAuthnBuilder: TeleportWebAuthnBuilding {
    enum BuilderStop: Error { case recorded }

    var capturedLoginRPID: String?
    var capturedRegisterRPID: String?
    var loginResult: Result<CredentialAssertionResponse, Error> = .failure(BuilderStop.recorded)

    func register(
        origin: String,
        rpID: String,
        challenge: Data,
        credentialID: Data,
        publicKeyRaw: Data,
        signer: any WebAuthnSigner
    ) throws -> CredentialCreationResponse {
        capturedRegisterRPID = rpID
        throw BuilderStop.recorded
    }

    func login(
        origin: String,
        rpID: String,
        challenge: Data,
        credentialID: Data,
        userHandle: Data?,
        signer: any WebAuthnSigner
    ) throws -> CredentialAssertionResponse {
        capturedLoginRPID = rpID
        return try loginResult.get()
    }

    static func assertionResponse() -> CredentialAssertionResponse {
        CredentialAssertionResponse(
            id: "credential-id",
            type: "public-key",
            rawId: Data([1, 2, 3, 4]).base64URLEncodedString(),
            response: AuthenticatorAssertionResponse(
                clientDataJSON: Data([1, 2, 3]).base64URLEncodedString(),
                authenticatorData: Data([4, 5, 6]).base64URLEncodedString(),
                signature: Data([7, 8, 9]).base64URLEncodedString(),
                userHandle: Data("user-handle".utf8).base64URLEncodedString()
            )
        )
    }
}

/// A gRPC client stub for the registration coordinator tests.
private final class RPIDMockGRPCClient: TeleportGRPCClienting {
    var registerChallenge = Proto_MFARegisterChallenge()
    private(set) var disconnectCallCount = 0

    func connect(
        host: String,
        clientCertPEM: String,
        privateKey: SecKey,
        clusterName: String,
        clusterCAPEMs: [String]
    ) async throws {}

    func createAuthenticateChallenge(
        browserMFATSHRedirectURL: String
    ) async throws -> Proto_MFAAuthenticateChallenge {
        Proto_MFAAuthenticateChallenge()
    }

    func createRegisterChallenge(
        existingMFAResponse: Proto_MFAAuthenticateResponse?
    ) async throws -> Proto_MFARegisterChallenge {
        registerChallenge
    }

    func addMFADeviceSync(
        deviceName: String,
        newMFAResponse: Proto_MFARegisterResponse
    ) async throws {}

    func disconnect() async {
        disconnectCallCount += 1
    }
}

/// Forces the registration coordinator down the first-device path.
private final class NoBrowserMFACeremony: BrowserMFACeremonyRunning {
    func run(
        grpcClient: any TeleportGRPCClienting,
        host: String
    ) async throws -> Proto_BrowserMFAResponse {
        throw BrowserMFACeremonyError.noBrowserMFAChallenge
    }
}

#endif
