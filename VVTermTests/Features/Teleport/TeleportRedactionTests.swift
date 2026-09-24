// SPDX-License-Identifier: MIT
//
//  TeleportRedactionTests.swift
//  VVTerm
//
//  Redaction coverage for the Teleport logging contract: the callback
//  `secret_key`, the full loopback callback URL, a clear headless id, and a
//  full browser-MFA request id must never reach a logger payload.
//
//  Two layers, because the unified log cannot prove everything on its own:
//
//   1. Runtime readback — a spy logging seam emits into a unique subsystem
//      and the test reads the composed messages back from the process's own
//      log store. This layer pins everything that is decided *before* the
//      interpolation: the callback URL is truncated at `?`, the request id is
//      truncated to a 16-character prefix, and the HTTP error log carries the
//      status instead of the response body (`…httpFailureLogsTheStatusNotTheBody`,
//      the scripted-failure path). Those hold regardless of how the log store
//      treats privacy.
//
//   2. Source-level annotations — the log store does not apply privacy
//      masking on the iOS Simulator: every level (`.public`, `.private`,
//      `.private(mask:)`) reads back in the clear there, while on macOS
//      `.private`/`.private(mask:)` are redacted. A runtime assertion that a
//      value is absent therefore cannot distinguish "annotated" from
//      "unannotated" on the simulator, so the annotation *form* is pinned at
//      the source level instead (`…LogsArePrivacyAnnotated`).
//

#if DEBUG
import Foundation
import OSLog
import Security
import XCTest
@testable import VVTerm

@MainActor
final class TeleportRedactionTests: XCTestCase {

    /// A logging seam that emits into a unique subsystem so the test can read
    /// back exactly the payloads the subject logged.
    private final class SpySubsystemLogging: TeleportLogging, @unchecked Sendable {
        let subsystem = "vvterm.tests.teleport-redaction.\(UUID().uuidString)"

        func logger(category: String) -> Logger {
            Logger(subsystem: subsystem, category: category)
        }
    }

    private func loggedMessages(subsystem: String) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-120))
        return try store.getEntries(at: position)
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == subsystem }
            .map(\.composedMessage)
    }

    /// Polls the unified log until an entry containing `needle` arrives, then
    /// returns every message logged for the subsystem. The needle must be the
    /// entry under test (not an earlier one), otherwise the snapshot can be
    /// taken before that entry lands.
    private func waitForLog(
        subsystem: String,
        containing needle: String,
        timeout: TimeInterval = 10
    ) async throws -> [String] {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var messages: [String] = []
        while ContinuousClock.now < deadline {
            messages = try loggedMessages(subsystem: subsystem)
            if messages.contains(where: { $0.contains(needle) }) {
                return messages
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("timed out waiting for a log entry containing \(needle); saw: \(messages)")
        return messages
    }

    /// The repository root, derived from this file's location.
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportRedactionTests.swift
            .deletingLastPathComponent()  // Teleport/
            .deletingLastPathComponent()  // Features/
            .deletingLastPathComponent()  // VVTermTests/
    }

    // MARK: - BrowserMFACeremony

    /// A gRPC stub that captures the redirect URL and returns a challenge with
    /// a long request id so truncation is observable.
    private final class CeremonyGRPCStub: TeleportGRPCClienting {
        static let fullRequestID = "abcdefghijklmnopqrstuvwxyz0123456789"
        var capturedRedirectURL: String?

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
            capturedRedirectURL = browserMFATSHRedirectURL
            var challenge = Proto_MFAAuthenticateChallenge()
            var browser = Proto_BrowserMFAChallenge()
            browser.requestID = Self.fullRequestID
            challenge.browserMfaChallenge = browser
            return challenge
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

    /// A gRPC stub that fails the way a real proxy can: the server's error
    /// message echoes the redirect URL (and therefore the per-run secret).
    private final class FailingCeremonyGRPCStub: TeleportGRPCClienting {
        struct ServerError: Error, CustomStringConvertible {
            let message: String
            var description: String { message }
        }

        var capturedRedirectURL: String?

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
            capturedRedirectURL = browserMFATSHRedirectURL
            throw ServerError(
                message: "unable to create MFA challenges: invalid redirect \(browserMFATSHRedirectURL)"
            )
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

    func testBrowserMFACeremony_neverLogsTheSecretOrTheFullRequestID() async throws {
        let logging = SpySubsystemLogging()
        let client = CeremonyGRPCStub()
        let presenter = RecordingBrowserMFAPresenter()
        let ceremony = BrowserMFACeremony(logging: logging, presenter: presenter)

        let run = Task { try await ceremony.run(grpcClient: client, host: "teleport.pcad.it") }
        let presentDeadline = ContinuousClock.now + .seconds(15)
        while presenter.presentedURLs.isEmpty, ContinuousClock.now < presentDeadline {
            await Task.yield()
        }
        XCTAssertEqual(presenter.presentedURLs.count, 1, "the ceremony must present the approval page")
        run.cancel()
        _ = try? await run.value

        let messages = try await waitForLog(
            subsystem: logging.subsystem,
            containing: "browser MFA challenge received"
        )

        guard let redirectURL = client.capturedRedirectURL,
              let secret = URLComponents(string: redirectURL)?
                  .queryItems?
                  .first(where: { $0.name == "secret_key" })?
                  .value
        else {
            return XCTFail("the ceremony did not pass a callback URL to the gRPC client")
        }
        XCTAssertFalse(secret.isEmpty)

        for message in messages {
            XCTAssertFalse(
                message.contains(secret),
                "the per-run secret_key leaked into a log payload: \(message)"
            )
            XCTAssertFalse(
                message.contains("secret_key="),
                "the full callback URL (with its query) leaked into a log payload: \(message)"
            )
            XCTAssertFalse(
                message.contains(CeremonyGRPCStub.fullRequestID),
                "the full request id leaked into a log payload: \(message)"
            )
        }
    }

    /// The error path: a server message that embeds the redirect URL must not
    /// reach the log, because that URL carries the per-run `secret_key`.
    func testBrowserMFACeremony_errorPathNeverLogsTheSecret() async throws {
        let logging = SpySubsystemLogging()
        let client = FailingCeremonyGRPCStub()
        let ceremony = BrowserMFACeremony(logging: logging, presenter: RecordingBrowserMFAPresenter())

        do {
            _ = try await ceremony.run(grpcClient: client, host: "teleport.pcad.it")
            XCTFail("the ceremony must surface the gRPC failure")
        } catch {
            // Expected: the stub rejects the challenge request.
        }

        guard let redirectURL = client.capturedRedirectURL,
              let secret = URLComponents(string: redirectURL)?
                  .queryItems?
                  .first(where: { $0.name == "secret_key" })?
                  .value
        else {
            return XCTFail("the ceremony did not pass a callback URL to the gRPC client")
        }

        let messages = try await waitForLog(
            subsystem: logging.subsystem,
            containing: "CreateAuthenticateChallenge failed"
        )
        for message in messages {
            XCTAssertFalse(
                message.contains(secret),
                "the per-run secret_key leaked into the error log payload: \(message)"
            )
            XCTAssertFalse(
                message.contains("secret_key="),
                "the redirect URL leaked into the error log payload: \(message)"
            )
        }
    }

    // MARK: - TeleportBootstrapCoordinator

    func testTeleportBootstrapCoordinator_neverLogsASecretOrAResponseBody() async throws {
        let logging = SpySubsystemLogging()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeFixtureSuccessResponse()

        let coordinator = TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: MockTeleportKeyRing(),
            safariPresenter: nil,
            logging: logging,
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            tlsKeyPairGenerator: try TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"))

        let messages = try await waitForLog(
            subsystem: logging.subsystem,
            containing: "headlessAuthenticationID="
        )

        // The entry under test exists (a vacuous pass otherwise).
        XCTAssertTrue(
            messages.contains(where: { $0.contains("headlessAuthenticationID=") }),
            "the coordinator must log the headless-authentication entry; saw: \(messages)"
        )
        for message in messages {
            XCTAssertFalse(
                message.contains("secret_key="),
                "a secret_key leaked into a log payload: \(message)"
            )
        }
    }

    /// The failure path: a `HeadlessError.http` carries the server's raw
    /// response body, which must not reach the log. Pins the status-only
    /// redaction in `handlePostFailure` (the round-1 security finding).
    func testTeleportBootstrapCoordinator_httpFailureLogsTheStatusNotTheBody() async throws {
        let logging = SpySubsystemLogging()
        let http = MockTeleportHTTPClient()
        let bodyMarker = "server-response-body-marker"
        http.scriptedHeadlessResponse = nil
        http.scriptedHeadlessError = HeadlessError.http(status: 403, body: bodyMarker)

        let coordinator = TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: MockTeleportKeyRing(),
            safariPresenter: nil,
            logging: logging,
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            tlsKeyPairGenerator: try TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"))

        let messages = try await waitForLog(subsystem: logging.subsystem, containing: "POST failed")
        XCTAssertTrue(
            messages.contains(where: { $0.contains("POST failed: HTTP 403") }),
            "the failure log must carry the status; saw: \(messages)"
        )
        for message in messages {
            XCTAssertFalse(
                message.contains(bodyMarker),
                "the HTTP response body leaked into a log payload: \(message)"
            )
        }
    }

    /// The transport failure path logs the locale-stable `URLError.Code`, not
    /// the OS message — and never the raw error. This scripts a transport
    /// failure whose message embeds an `NSError` carrying
    /// `NSErrorFailingURLKey` with a `?token=` query (the shape URLSession
    /// produces); a future raw-`error` interpolation would print that userInfo
    /// and leak the token, so assert it stays out of the `.public` log.
    func testTeleportBootstrapCoordinator_transportFailureLogsTheCodeNotTheFailingURL() async throws {
        let logging = SpySubsystemLogging()
        let http = MockTeleportHTTPClient()
        let token = "transport-redaction-token-marker"
        let failingURL = URL(
            string: "https://teleport.pcad.it/webapi/headless/login?token=\(token)"
        )!
        let underlying = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [NSURLErrorFailingURLErrorKey: failingURL]
        )
        http.scriptedHeadlessError = HeadlessError.transport(
            String(describing: underlying),
            code: .cannotConnectToHost
        )

        let coordinator = TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: MockTeleportKeyRing(),
            safariPresenter: nil,
            logging: logging,
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            tlsKeyPairGenerator: try TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"))

        let messages = try await waitForLog(subsystem: logging.subsystem, containing: "POST failed")
        XCTAssertTrue(
            messages.contains(where: {
                $0.contains(
                    "POST failed: transport code=\(URLError.Code.cannotConnectToHost.rawValue)"
                )
            }),
            "the transport failure log must carry the code; saw: \(messages)"
        )
        for message in messages {
            XCTAssertFalse(
                message.contains(token),
                "the failing URL's token leaked into a log payload: \(message)"
            )
            XCTAssertFalse(
                message.contains(failingURL.absoluteString),
                "the failing URL leaked into a log payload: \(message)"
            )
        }
    }

    /// The unified log does not apply privacy masking on the iOS Simulator, so
    /// the runtime readback above cannot distinguish an annotated
    /// interpolation from a bare one. Pin the annotation form at the source
    /// level: every interpolation of the headless id must be private.
    ///
    /// Limitation (round-2 NIT): the filter keys on the two known log
    /// literals, so a future headless-id log without either literal (e.g. a
    /// bare `logger.info("starting \(headlessID)")`) is invisible here. The
    /// exact-count assertion still catches additions to the pinned literals.
    func testTeleportBootstrapCoordinator_headlessIDLogsArePrivacyAnnotated() throws {
        let sourceURL = repositoryRoot()
            .appendingPathComponent("VVTerm/Features/Teleport/Application/TeleportBootstrapCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let headlessLines = source
            .components(separatedBy: "\n")
            .filter { $0.contains("headlessAuthenticationID=") || $0.contains("opening Safari to") }

        XCTAssertEqual(
            headlessLines.count,
            2,
            "expected exactly two headless-id log lines to review; found: \(headlessLines)"
        )
        for line in headlessLines {
            XCTAssertTrue(
                line.contains("privacy: .private"),
                "the headless id must be logged with a privacy annotation: \(line)"
            )
        }
    }

    // MARK: - TeleportRegistrationCoordinator

    /// `CreateRegisterChallenge` is a server-derived `GRPCError`: the log
    /// carries the case/status, never the server's message (which can echo
    /// request fields).
    func testTeleportRegistrationCoordinator_createRegisterChallengeLogsTheStatusNotTheServerMessage() async throws {
        let logging = SpySubsystemLogging()
        let marker = "register-challenge-server-message-marker"
        let grpc = FailingRegistrationGRPCStub(
            createRegisterChallengeError: GRPCError.grpc(status: 7, message: marker)
        )
        let coordinator = TeleportRegistrationCoordinator(
            grpcClient: grpc,
            browserMFACeremony: FirstDeviceBrowserMFACeremonyStub(),
            keyRing: MockTeleportKeyRing(),
            logging: logging,
            signer: MockSEPKeySigner(outcome: .success),
            webAuthnBuilder: ScriptedWebAuthnBuilderStub()
        )

        await coordinator.begin(
            cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"),
            deviceName: "test-device",
            bootstrapResult: try Self.makeBootstrapResult()
        )

        let messages = try await waitForLog(
            subsystem: logging.subsystem,
            containing: "CreateRegisterChallenge failed"
        )
        XCTAssertTrue(
            messages.contains(where: { $0.contains("CreateRegisterChallenge failed: grpc(status: 7)") }),
            "the failure log must carry the gRPC status; saw: \(messages)"
        )
        for message in messages {
            XCTAssertFalse(
                message.contains(marker),
                "the server's gRPC message leaked into a log payload: \(message)"
            )
        }
    }

    /// `AddMFADeviceSync` is the other server-derived `GRPCError` on the
    /// registration path; same status-only log contract.
    func testTeleportRegistrationCoordinator_addMFADeviceSyncLogsTheStatusNotTheServerMessage() async throws {
        let logging = SpySubsystemLogging()
        let marker = "add-mfa-server-message-marker"
        let grpc = FailingRegistrationGRPCStub(
            registerChallenge: Self.makeRegisterChallenge(rpID: "teleport.pcad.it"),
            addMFADeviceSyncError: GRPCError.grpc(status: 6, message: marker)
        )
        let coordinator = TeleportRegistrationCoordinator(
            grpcClient: grpc,
            browserMFACeremony: FirstDeviceBrowserMFACeremonyStub(),
            keyRing: MockTeleportKeyRing(),
            logging: logging,
            signer: MockSEPKeySigner(outcome: .success),
            webAuthnBuilder: ScriptedWebAuthnBuilderStub()
        )

        await coordinator.begin(
            cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"),
            deviceName: "test-device",
            bootstrapResult: try Self.makeBootstrapResult()
        )

        let messages = try await waitForLog(
            subsystem: logging.subsystem,
            containing: "AddMFADeviceSync failed"
        )
        XCTAssertTrue(
            messages.contains(where: { $0.contains("AddMFADeviceSync failed: grpc(status: 6)") }),
            "the failure log must carry the gRPC status; saw: \(messages)"
        )
        for message in messages {
            XCTAssertFalse(
                message.contains(marker),
                "the server's gRPC message leaked into a log payload: \(message)"
            )
        }
    }

    // MARK: - TeleportLoginCoordinator

    /// `login/begin` is a headless HTTP call: a non-2xx carries the raw server
    /// body, so the log must carry the status only.
    func testTeleportLoginCoordinator_loginBeginLogsTheStatusNotTheServerBody() async throws {
        let logging = SpySubsystemLogging()
        let marker = "login-begin-server-body-marker"
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = Self.makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginError = HeadlessError.http(status: 403, body: marker)

        let coordinator = TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: logging,
            signer: signer,
            webAuthnBuilder: ScriptedWebAuthnBuilderStub(),
            keyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        let messages = try await waitForLog(
            subsystem: logging.subsystem,
            containing: "login/begin failed"
        )
        XCTAssertTrue(
            messages.contains(where: { $0.contains("login/begin failed: HTTP 403") }),
            "the failure log must carry the status; saw: \(messages)"
        )
        for message in messages {
            XCTAssertFalse(
                message.contains(marker),
                "the HTTP response body leaked into a log payload: \(message)"
            )
        }
    }

    /// `login/finish` is the second unlisted site of the same class: its
    /// `HeadlessError.http` body must not reach the log either.
    func testTeleportLoginCoordinator_loginFinishLogsTheStatusNotTheServerBody() async throws {
        let logging = SpySubsystemLogging()
        let marker = "login-finish-server-body-marker"
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = Self.makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginFinishError = HeadlessError.http(status: 500, body: marker)

        let coordinator = TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: logging,
            signer: signer,
            webAuthnBuilder: ScriptedWebAuthnBuilderStub(),
            keyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        let messages = try await waitForLog(
            subsystem: logging.subsystem,
            containing: "login/finish failed"
        )
        XCTAssertTrue(
            messages.contains(where: { $0.contains("login/finish failed: HTTP 500") }),
            "the failure log must carry the status; saw: \(messages)"
        )
        for message in messages {
            XCTAssertFalse(
                message.contains(marker),
                "the HTTP response body leaked into a log payload: \(message)"
            )
        }
    }

    // The login path's *production* error type is `GRPCError.http2`, not
    // `HeadlessError.http`: `LiveTeleportHTTPClient.loginBegin` throws
    // `GRPCError.http2("login/begin HTTP <status>: <body>")` on a non-200, so
    // the raw body travels inside the error's message. These two tests pin the
    // production type — the `HeadlessError` cases above exercise the mock's
    // type and would have passed even while this path leaked.
    func testTeleportLoginCoordinator_loginBeginRedactsTheProductionGRPCErrorType() async throws {
        let logging = SpySubsystemLogging()
        let marker = "login-begin-production-body-marker"
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = Self.makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginError = GRPCError.http2("login/begin HTTP 403: \(marker)")

        let coordinator = TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: logging,
            signer: signer,
            webAuthnBuilder: ScriptedWebAuthnBuilderStub(),
            keyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        let messages = try await waitForLog(
            subsystem: logging.subsystem,
            containing: "login/begin failed"
        )
        XCTAssertTrue(
            messages.contains(where: { $0.contains("login/begin failed: http2") }),
            "the failure log must carry the gRPC case only; saw: \(messages)"
        )
        for message in messages {
            XCTAssertFalse(
                message.contains(marker),
                "the HTTP response body leaked into a log payload: \(message)"
            )
        }
    }

    /// `login/finish` throws the same production type.
    func testTeleportLoginCoordinator_loginFinishRedactsTheProductionGRPCErrorType() async throws {
        let logging = SpySubsystemLogging()
        let marker = "login-finish-production-body-marker"
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = Self.makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginFinishError = GRPCError.http2("login/finish HTTP 500: \(marker)")

        let coordinator = TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: logging,
            signer: signer,
            webAuthnBuilder: ScriptedWebAuthnBuilderStub(),
            keyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        let messages = try await waitForLog(
            subsystem: logging.subsystem,
            containing: "login/finish failed"
        )
        XCTAssertTrue(
            messages.contains(where: { $0.contains("login/finish failed: http2") }),
            "the failure log must carry the gRPC case only; saw: \(messages)"
        )
        for message in messages {
            XCTAssertFalse(
                message.contains(marker),
                "the HTTP response body leaked into a log payload: \(message)"
            )
        }
    }

    // MARK: - Helpers

    private static func makeRegisteredKeyRing(
        clusterId: UUID,
        credentialID: Data
    ) -> MockTeleportKeyRing {
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

    private static func makeBootstrapResult() throws -> TeleportBootstrapCoordinator.BootstrapResult {
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

    private static func makeRegisterChallenge(rpID: String) -> Proto_MFARegisterChallenge {
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

    // MARK: - Test doubles

    /// A registration gRPC stub that can fail either server-derived call with
    /// a scripted error carrying a server message.
    private final class FailingRegistrationGRPCStub: TeleportGRPCClienting {
        var createRegisterChallengeError: Error?
        var registerChallenge = Proto_MFARegisterChallenge()
        var addMFADeviceSyncError: Error?

        init(
            registerChallenge: Proto_MFARegisterChallenge = Proto_MFARegisterChallenge(),
            createRegisterChallengeError: Error? = nil,
            addMFADeviceSyncError: Error? = nil
        ) {
            self.registerChallenge = registerChallenge
            self.createRegisterChallengeError = createRegisterChallengeError
            self.addMFADeviceSyncError = addMFADeviceSyncError
        }

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
            if let error = createRegisterChallengeError { throw error }
            return registerChallenge
        }

        func addMFADeviceSync(
            deviceName: String,
            newMFAResponse: Proto_MFARegisterResponse
        ) async throws {
            if let error = addMFADeviceSyncError { throw error }
        }

        func disconnect() async {}
    }

    /// Forces the registration coordinator down the first-device path (no
    /// existing Browser MFA device).
    private final class FirstDeviceBrowserMFACeremonyStub: BrowserMFACeremonyRunning {
        func run(
            grpcClient: any TeleportGRPCClienting,
            host: String
        ) async throws -> Proto_BrowserMFAResponse {
            throw BrowserMFACeremonyError.noBrowserMFAChallenge
        }
    }

    /// A WebAuthn builder stub that returns plausible scripted responses so
    /// the coordinators reach their server-derived calls.
    private final class ScriptedWebAuthnBuilderStub: TeleportWebAuthnBuilding {
        func register(
            origin: String,
            rpID: String,
            challenge: Data,
            credentialID: Data,
            publicKeyRaw: Data,
            signer: any WebAuthnSigner
        ) throws -> CredentialCreationResponse {
            CredentialCreationResponse(
                id: "credential-id",
                type: "public-key",
                rawId: Data([1, 2, 3, 4]).base64URLEncodedString(),
                response: AuthenticatorAttestationResponse(
                    clientDataJSON: Data([1, 2, 3]).base64URLEncodedString(),
                    attestationObject: Data([4, 5, 6]).base64URLEncodedString()
                )
            )
        }

        func login(
            origin: String,
            rpID: String,
            challenge: Data,
            credentialID: Data,
            userHandle: Data?,
            signer: any WebAuthnSigner
        ) throws -> CredentialAssertionResponse {
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
}

#endif
