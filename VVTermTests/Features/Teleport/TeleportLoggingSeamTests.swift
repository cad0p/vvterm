// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportLoggingSeamTests.swift
//  VVTermTests
//
//  Seam-contract coverage for `TeleportLogging`: every host construction
//  path must request the exact category string the app's diagnostics
//  surface expects, and no movable file may reach `Logger.forCategory`
//  directly (the boundary check enforces the latter over the file list).
//

#if DEBUG
import Foundation
import Security
import Testing
import os.log
@testable import VVTerm

/// Records the category strings requested through the logging seam.
private final class SpyTeleportLogging: TeleportLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var categories: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func logger(category: String) -> Logger {
        lock.lock()
        recorded.append(category)
        lock.unlock()
        return Logger(subsystem: "spy", category: category)
    }
}

@MainActor
struct TeleportLoggingSeamTests {

    @Test
    func bootstrapCoordinatorRequestsBootstrapCategory() {
        let spy = SpyTeleportLogging()
        _ = TeleportBootstrapCoordinator(
            httpClient: MockTeleportHTTPClient(),
            keyRing: MockTeleportKeyRing(),
            safariPresenter: nil,
            logging: spy,
            signer: MockSEPKeySigner(outcome: .success)
        )
        #expect(spy.categories == ["teleport-bootstrap"])
    }

    @Test
    func loginCoordinatorRequestsLoginCategory() {
        let spy = SpyTeleportLogging()
        _ = TeleportLoginCoordinator(
            httpClient: MockTeleportHTTPClient(),
            keyRing: MockTeleportKeyRing(),
            logging: spy,
            signer: MockSEPKeySigner(outcome: .success)
        )
        #expect(spy.categories == ["teleport-login"])
    }

    @Test
    func registrationCoordinatorRequestsRegistrationCategory() {
        let spy = SpyTeleportLogging()
        _ = TeleportRegistrationCoordinator(
            grpcClient: MockTeleportGRPCClient(),
            browserMFACeremony: NoopBrowserMFACeremony(),
            keyRing: MockTeleportKeyRing(),
            logging: spy,
            signer: MockSEPKeySigner(outcome: .success)
        )
        #expect(spy.categories == ["teleport-registration"])
    }

    @Test
    func keyRingRequestsKeyringCategory() {
        let spy = SpyTeleportLogging()
        let defaults = UserDefaults(suiteName: "TeleportLoggingSeamTests") ?? .standard
        _ = TeleportKeyRing(
            signer: MockSEPKeySigner(outcome: .success),
            logging: spy,
            config: TeleportKeychainConfig(keychainService: "app.vivy.vvterm.tests", defaults: defaults)
        )
        #expect(spy.categories == ["teleport-keyring"])
    }

    @Test
    func tlsTransportRequestsTLSTransportCategory() {
        let spy = SpyTeleportLogging()
        _ = SSHTLSTransport(
            host: "127.0.0.1",
            port: 443,
            clusterName: "ci-cluster",
            clusterCAPEMs: [],
            logging: spy
        )
        #expect(spy.categories == ["SSH-TLS-Transport"])
    }

    @Test
    func browserMFACeremonyRequestsCeremonyCategory() {
        let spy = SpyTeleportLogging()
        _ = BrowserMFACeremony(logging: spy, presenter: RecordingBrowserMFAPresenter())
        #expect(spy.categories == ["TeleportBrowserMFA"])
    }

    @Test
    func grpcClientRequestsBothClientAndTransportCategories() {
        // Regression guard: the client's own lines stay on `teleport-grpc`,
        // while the transport lines (tls_setup / tls_challenge / conn_* /
        // grpc_identity_deleted) must keep `origin/main`'s `TeleportGRPC`
        // category — `DiagnosticsExporter` filters by subsystem, and the
        // category is the diagnostics surface agents read.
        let spy = SpyTeleportLogging()
        _ = LiveTeleportGRPCClient(logging: spy)
        #expect(spy.categories == ["teleport-grpc", "TeleportGRPC"])
    }

    @Test
    func defaultLoggingBuildsALoggerForAnyCategory() {
        // The package-owned default must not throw or trap; it is the
        // test/non-app host fallback.
        _ = DefaultTeleportLogging().logger(category: "teleport-test")
    }
}

/// Minimal gRPC client stub for coordinator construction.
@MainActor
private final class MockTeleportGRPCClient: TeleportGRPCClienting {
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

/// Minimal ceremony stub for coordinator construction.
@MainActor
private final class NoopBrowserMFACeremony: BrowserMFACeremonyRunning {
    func run(
        grpcClient: any TeleportGRPCClienting,
        host: String
    ) async throws -> Proto_BrowserMFAResponse {
        throw BrowserMFACeremonyError.noBrowserMFAChallenge
    }
}
#endif
