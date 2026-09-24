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

#if DEBUG
import Foundation
import Security
import XCTest
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

    /// Constructs and releases the coordinator graph synchronously.
    func testCoordinatorGraphReleasesSynchronouslyWithoutTrapping() {
        let defaults = UserDefaults(suiteName: "TeleportSynchronousReleaseTests") ?? .standard
        let logging = DefaultTeleportLogging()

        autoreleasepool {
            let keyRing = TeleportKeyRing(
                signer: MockSEPKeySigner(outcome: .success),
                logging: logging,
                config: TeleportKeychainConfig(
                    keychainService: "app.vivy.vvterm.tests",
                    defaults: defaults
                )
            )
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
    }
}

#endif
