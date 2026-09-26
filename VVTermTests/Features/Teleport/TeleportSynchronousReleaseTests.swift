// SPDX-License-Identifier: MIT
//
//  TeleportSynchronousReleaseTests.swift
//  VVTermTests
//
//  Regression for the isolated-deinit abort (issue #216): the app target
//  sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated class
//  is MainActor-isolated and its compiler-synthesized deinit takes the
//  back-deployed isolated-deinit path, which traps in
//  `TaskLocal::StopLookupScope` when the class is released outside a task
//  context (a synchronous XCTest method) — swiftlang/swift#85663, #88036.
//
//  The failure mode is an `Early unexpected exit` / signal trap in the test
//  host, not an assertion. This test is deliberately a **synchronous**
//  method: passing at all is the assertion.
//
//  Coverage is scoped to the classes that are constructible from a
//  synchronous test. `TeleportGRPCConnection` has a private init and the
//  three `#Preview` coordinators are not constructible; their markers are
//  pure no-ops checked only by the build.
//

#if DEBUG
import Foundation
import Security
import os.log
import XCTest
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
@testable import VVTerm

/// Minimal gRPC stub so the registration coordinator can be constructed.
@MainActor
private final class ReleaseTestGRPCClient: TeleportGRPCClienting {
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
        Proto_MFARegisterChallenge()
    }

    func addMFADeviceSync(
        deviceName: String,
        newMFAResponse: Proto_MFARegisterResponse
    ) async throws {}

    func disconnect() async {}
}

@MainActor
final class TeleportSynchronousReleaseTests: XCTestCase {

    private func makeTestKeyRing() -> TeleportKeyRing {
        let defaults = UserDefaults(suiteName: "TeleportSynchronousReleaseTests") ?? .standard
        return TeleportKeyRing(
            signer: MockSEPKeySigner(outcome: .success),
            logging: DefaultTeleportLogging(),
            config: TeleportKeychainConfig(
                keychainService: "app.vivy.vvterm.tests",
                defaults: defaults
            )
        )
    }

    /// Constructs and releases the coordinator graph synchronously.
    func testCoordinatorGraphReleasesSynchronouslyWithoutTrapping() {
        let logging = DefaultTeleportLogging()

        autoreleasepool {
            let keyRing = makeTestKeyRing()
            let mockKeyRing = MockTeleportKeyRing()
            let http = MockTeleportHTTPClient()
            let signer = MockSEPKeySigner(outcome: .success)
            let safari = MockWebAuthenticationSessionPresenter()
            let presenter = LiveBrowserMFAPresenter()
            let ceremony = BrowserMFACeremony(logging: logging, presenter: presenter)

            let bootstrap = TeleportBootstrapCoordinator(
                httpClient: http,
                keyRing: mockKeyRing,
                safariPresenter: safari,
                logging: logging,
                signer: signer,
                sshKeyPairGenerator: LiveTeleportSSHKeyPairGenerator(),
                tlsKeyPairGenerator: LiveTeleportTLSKeyPairGenerator()
            )
            let login = TeleportLoginCoordinator(
                httpClient: http,
                keyRing: mockKeyRing,
                logging: logging,
                signer: signer,
                webAuthnBuilder: TeleportWebAuthnBuilder(),
                keyPairGenerator: LiveTeleportSSHKeyPairGenerator()
            )
            let liveCeremony = LiveBrowserMFACeremony(logging: logging, presenter: presenter)
            let registration = TeleportRegistrationCoordinator(
                grpcClient: ReleaseTestGRPCClient(),
                browserMFACeremony: liveCeremony,
                keyRing: mockKeyRing,
                logging: logging,
                signer: signer,
                webAuthnBuilder: TeleportWebAuthnBuilder()
            )
            let grpcClient = LiveTeleportGRPCClient(logging: logging)

            _ = (keyRing, bootstrap, login, registration, liveCeremony, grpcClient, ceremony)
        }

        // The concrete UI seams + the UI-test mocks on their own.
        autoreleasepool {
            let safariPresenter = WebAuthenticationSessionPresenter()
            let liveHTTP = LiveTeleportHTTPClient()
            let mockBootstrap = MockTeleportBootstrapCoordinator(scenario: .happyPath)
            let mockLogin = MockTeleportLoginCoordinator(scenario: .faceIDCancelled)
            let mockRegistration = MockTeleportRegistrationCoordinator(scenario: .happyPath)
            _ = (safariPresenter, liveHTTP, mockBootstrap, mockLogin, mockRegistration)
        }

        // The additional classes the #216 audit marked that are constructible
        // from a synchronous test (B7).
        autoreleasepool {
            let storeKeyRing = makeTestKeyRing()
            let credentialStore = TeleportKeyRingCredentialStore(keyRingProvider: { storeKeyRing })
            let composition = TeleportComposition(
                keyRing: makeTestKeyRing(),
                logging: logging,
                browserMFAPresenter: LiveBrowserMFAPresenter()
            )
            let stateHandler = GRPCConnectionStateHandler(host: "teleport.pcad.it", logger: logging.logger(category: "test"))
            let cancelToken = PumpCancelToken()
            let mutex = SessionMutex()
            let pumpCloser = PumpFDCloser()
            let softwareSigner = SoftwareSigner()
            let sepSigner = SecureEnclaveSigner()
            #if canImport(AuthenticationServices)
            let session = ASWebAuthenticationSession(
                url: URL(string: "https://teleport.pcad.it")!,
                callbackURLScheme: "vvterm"
            ) { _, _ in }
            let mfaSession = LiveBrowserMFASession(session: session, didStart: false)
            _ = mfaSession
            #endif
            _ = (
                credentialStore, composition, stateHandler, cancelToken,
                mutex, pumpCloser, softwareSigner, sepSigner
            )
        }
    }
}

#endif
