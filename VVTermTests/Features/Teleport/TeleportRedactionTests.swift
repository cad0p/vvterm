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
import Network
import os
import OSLog
import Security
import XCTest
@testable import VVTerm

@MainActor
final class TeleportRedactionTests: XCTestCase {

    /// Host-state tolerance for the loopback listener's `.ready` wait: the
    /// redaction suite drives a real loopback request through
    /// `BrowserMFAListener`, whose product default is 15 s. Same rationale and
    /// value as `BrowserMFAListenerLoopbackTests.listenerStartTolerance` (#260
    /// host-state class; tolerance, not retry machinery).
    private static let listenerStartTolerance: TimeInterval = 20

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

    /// Polls the unified log until every `needle` has arrived, then returns
    /// every message logged for the subsystem. Waiting for all needles keeps a
    /// per-path assertion from being satisfied by an earlier entry of the same
    /// class, and keeps the marker scan from missing a later line.
    private func waitForLog(
        subsystem: String,
        containingAll needles: [String],
        timeout: TimeInterval = 10
    ) async throws -> [String] {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var messages: [String] = []
        while ContinuousClock.now < deadline {
            messages = try loggedMessages(subsystem: subsystem)
            let missing = needles.filter { needle in
                !messages.contains(where: { $0.contains(needle) })
            }
            if missing.isEmpty {
                return messages
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("timed out waiting for log entries containing \(needles); saw: \(messages)")
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

    /// Every line in `relativeDirectory` (recursively, `.swift` files only)
    /// that contains at least one of `needles`, each prefixed with its
    /// repo-relative path so a failure names the exact site. Walking the tree
    /// — rather than a fixed file list — means a newly added log site inside
    /// it trips the caller's count assertion instead of passing unnoticed.
    /// Every line of every Swift file under `relativeDirectory` when
    /// `needles` is empty (no marker filter); otherwise only the lines
    /// containing at least one needle. The unfiltered form is for class-level
    /// scans that must not be hidden by an unlisted label spelling.
    private func sourceLines(
        under relativeDirectory: String,
        matching needles: [String]
    ) throws -> [String] {
        let root = repositoryRoot().appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var matches: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: url, encoding: .utf8)
            matches.append(
                contentsOf: source
                    .components(separatedBy: "\n")
                    .filter { line in needles.isEmpty || needles.contains(where: { line.contains($0) }) }
                    .map { "\(relativePath): \($0)" }
            )
        }
        return matches.sorted()
    }

    private func sourceLines(
        under relativeDirectory: String,
        matching needle: String
    ) throws -> [String] {
        try sourceLines(under: relativeDirectory, matching: [needle])
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

    // MARK: - BrowserMFAListener

    /// The callback rejection paths must log a static reason without echoing
    /// any query value: `secret_key` is the per-run sealing key, the
    /// `response` envelope decrypts to the WebAuthn assertion, and the
    /// buffered bytes of a truncated head can carry either. These paths used
    /// to fail silently (issue #241), so this drives every one of them over a
    /// real loopback request and asserts both that each reason is logged and
    /// that the marker values never reach a log payload.
    func testBrowserMFAListener_rejectionsLogAReasonWithoutQueryValues() async throws {
        let logging = SpySubsystemLogging()
        let listener = BrowserMFAListener(
            logger: logging.logger(category: "TeleportBrowserMFA"),
            startTimeout: Self.listenerStartTolerance
        )
        _ = try await listener.start()
        defer { listener.cancel() }

        let secretMarker = "redaction-secret-key-\(UUID().uuidString)"
        let responseMarker = "redaction-response-envelope-\(UUID().uuidString)"
        let bothMarkers = [
            URLQueryItem(name: "secret_key", value: secretMarker),
            URLQueryItem(name: "response", value: responseMarker),
        ]

        // A query carrying both values: the envelope does not authenticate,
        // so the listener logs the GCM rejection reason.
        _ = try await sendLoopbackRequest(
            method: "GET",
            path: "/callback",
            queryItems: bothMarkers,
            port: listener.port
        )
        // No response param: the missing-response 400.
        _ = try await sendLoopbackRequest(
            method: "GET",
            path: "/callback",
            queryItems: [URLQueryItem(name: "secret_key", value: secretMarker)],
            port: listener.port
        )
        // The real redirect shape (no secret_key) with an unauthenticated
        // envelope: the same GCM rejection through the genuine browser shape.
        _ = try await sendLoopbackRequest(
            method: "GET",
            path: "/callback",
            queryItems: [URLQueryItem(name: "response", value: responseMarker)],
            port: listener.port
        )
        // A method the callback cannot serve: the 405 path.
        _ = try await sendLoopbackRequest(
            method: "PUT",
            path: "/callback",
            queryItems: bothMarkers,
            port: listener.port
        )
        // A path the listener does not serve: the 404 path.
        _ = try await sendLoopbackRequest(
            method: "GET",
            path: "/not-the-callback",
            queryItems: bothMarkers,
            port: listener.port
        )
        // A head that never reaches `\r\n\r\n`, then a half-close: the
        // buffered bytes carry the markers, so the incomplete-request line
        // must stay static.
        let incompleteResponse = try await sendIncompleteLoopbackRequest(
            Data(
                "GET /callback?\(encodedQuery(bothMarkers)) HTTP/1.1\r\nHost: localhost\r\n".utf8
            ),
            port: listener.port
        )
        XCTAssertTrue(
            incompleteResponse.hasPrefix("HTTP/1.1 400"),
            "a truncated head must be answered 400; got: \(incompleteResponse)"
        )

        let reasons = [
            "envelope authentication failed",
            "missing response parameter",
            "unsupported method",
            "unrecognized path",
            "incomplete request",
        ]
        let messages = try await waitForLog(
            subsystem: logging.subsystem,
            containingAll: reasons.map { "browser MFA callback rejected: \($0)" }
        )
        for reason in reasons {
            XCTAssertTrue(
                messages.contains(where: { $0.contains("browser MFA callback rejected: \(reason)") }),
                "the listener must log '\(reason)'; saw: \(messages)"
            )
        }
        for message in messages {
            XCTAssertFalse(
                message.contains(secretMarker),
                "the secret_key leaked into a log payload: \(message)"
            )
            XCTAssertFalse(
                message.contains(responseMarker),
                "the response envelope leaked into a log payload: \(message)"
            )
        }
    }

    /// Sends one HTTP/1.1 request to the loopback listener and returns the raw
    /// response head. Uses `NWConnection` directly (no ATS involvement).
    private func sendLoopbackRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        port: UInt16
    ) async throws -> String {
        let connection = try loopbackConnection(port: port)
        defer { connection.cancel() }
        let request = Data(
            "\(method) \(path)?\(encodedQuery(queryItems)) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8
        )
        try await startLoopbackConnection(connection)
        try await sendLoopbackBytes(connection, request)
        return try await receiveLoopbackResponse(connection)
    }

    /// Sends a request head that never terminates, half-closes the write side
    /// so the listener observes `isComplete` with an unparsable buffer, and
    /// returns the response head. Drives the incomplete-request path.
    private func sendIncompleteLoopbackRequest(_ data: Data, port: UInt16) async throws -> String {
        let connection = try loopbackConnection(port: port)
        defer { connection.cancel() }
        try await startLoopbackConnection(connection)
        try await sendLoopbackBytes(connection, data)
        try await halfCloseLoopbackConnection(connection)
        return try await receiveLoopbackResponse(connection)
    }

    private func loopbackConnection(port: UInt16) throws -> NWConnection {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw BrowserMFAListenerError.listenerFailed("invalid loopback port \(port)")
        }
        return NWConnection(host: .ipv4(.loopback), port: endpointPort, using: .tcp)
    }

    private func encodedQuery(_ queryItems: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.queryItems = queryItems
        return components.percentEncodedQuery ?? ""
    }

    private func halfCloseLoopbackConnection(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func startLoopbackConnection(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func resumeOnce(_ result: Result<Void, Error>) {
                let alreadyResumed = resumed.withLock { isResumed -> Bool in
                    if isResumed { return true }
                    isResumed = true
                    return false
                }
                guard !alreadyResumed else { return }
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .waiting(let error):
                    resumeOnce(.failure(error))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 15) {
                resumeOnce(.failure(BrowserMFAListenerError.timedOut))
            }
        }
    }

    private func sendLoopbackBytes(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveLoopbackResponse(_ connection: NWConnection) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func resumeOnce(_ result: Result<String, Error>) {
                let alreadyResumed = resumed.withLock { isResumed -> Bool in
                    if isResumed { return true }
                    isResumed = true
                    return false
                }
                guard !alreadyResumed else { return }
                continuation.resume(with: result)
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error {
                    resumeOnce(.failure(error))
                } else {
                    resumeOnce(.success(String(data: data ?? Data(), encoding: .utf8) ?? ""))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 15) {
                resumeOnce(.failure(BrowserMFAListenerError.timedOut))
            }
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

    /// The bootstrap log used to publish the Teleport username
    /// (`user=\(cluster.username, privacy: .public)`), so the Teleport user
    /// reached the unified log and any exported diagnostics. Pin the
    /// **interpolation's own annotation** at the source level for the same
    /// reason as the headless-id pin above: the simulator log store does not
    /// mask privacy on readback.
    ///
    /// Scope, stated honestly: this walks the whole `VVTerm/Features/Teleport`
    /// tree and requires exactly one `user=\(` line there (count tripwire), so
    /// a moved line or a newly added site inside the feature trips the
    /// assertion rather than passing unnoticed. It then matches the whole
    /// interpolation — `\(cluster.username, privacy: .private)` (or
    /// `.sensitive`) — rather than checking that `.private` appears somewhere
    /// on the line, so a second public interpolation on the same line, or a
    /// `.private` that belongs to the dial target, cannot satisfy it. What it
    /// still cannot catch: an alias (`let u = cluster.username`), a site added
    /// outside the walked tree (e.g. `VVTerm/Core/SSH`), or a reformatted
    /// interpolation outside the pattern. The runtime behavior is pinned by
    /// Apple's privacy semantics, not by a simulator readback.
    func testTeleportBootstrapCoordinator_usernameLogsArePrivacyAnnotated() throws {
        let usernameLines = try sourceLines(
            under: "VVTerm/Features/Teleport",
            matching: "user=\\("
        )

        XCTAssertEqual(
            usernameLines.count,
            1,
            "expected exactly one username log line to review; found: \(usernameLines)"
        )

        let privateInterpolation = try NSRegularExpression(
            pattern: #"\\\(cluster\.username,\s*privacy:\s*\.(?:private|sensitive)(?:\(mask:\s*\.hash\))?\)"#
        )
        let publicInterpolation = try NSRegularExpression(
            pattern: #"\\\(cluster\.username,\s*privacy:\s*\.public\)"#
        )
        for line in usernameLines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            XCTAssertEqual(
                privateInterpolation.numberOfMatches(in: line, range: range),
                1,
                "the Teleport username interpolation itself must be annotated `privacy: .private`: \(line)"
            )
            XCTAssertEqual(
                publicInterpolation.numberOfMatches(in: line, range: range),
                0,
                "the Teleport username must not be logged publicly: \(line)"
            )
        }
    }

    /// The SEP device name is logged at both registration sites; it used to be
    /// public (`device=\(deviceName, privacy: .public)`), so the registered
    /// device name reached the unified log and any exported diagnostics.
    /// Aligns with swift-teleport#15, whose package sites are `.private`. Pin
    /// the **interpolation's own annotation** at the source level for the same
    /// reason as the headless-id pin above: the simulator log store does not
    /// mask privacy on readback.
    ///
    /// Scope, stated honestly: this walks the whole `VVTerm/Features/Teleport`
    /// tree and requires exactly two `device=\(` lines there (count tripwire),
    /// so a moved line or a newly added site inside the feature trips the
    /// assertion rather than passing unnoticed. It then matches the whole
    /// interpolation — `\(deviceName, privacy: .private)` (or `.sensitive`) —
    /// rather than checking that `.private` appears somewhere on the line, so
    /// a second public interpolation on the same line, or a `.private` that
    /// belongs to the cluster id, cannot satisfy it. What it still cannot
    /// catch: an alias (`let d = deviceName`), a site added outside the walked
    /// tree (e.g. `VVTerm/Core/SSH`), or a reformatted interpolation outside
    /// the pattern. The runtime behavior is pinned by Apple's privacy
    /// semantics, not by a simulator readback.
    func testDeviceNameLogsArePrivacyAnnotated() throws {
        let deviceNameLines = try sourceLines(
            under: "VVTerm/Features/Teleport",
            matching: "device=\\("
        )

        XCTAssertEqual(
            deviceNameLines.count,
            2,
            "expected exactly two device-name log lines to review; found: \(deviceNameLines)"
        )

        let privateInterpolation = try NSRegularExpression(
            pattern: #"\\\(deviceName,\s*privacy:\s*\.(?:private|sensitive)(?:\(mask:\s*\.hash\))?\)"#
        )
        let publicInterpolation = try NSRegularExpression(
            pattern: #"\\\(deviceName,\s*privacy:\s*\.public\)"#
        )
        for line in deviceNameLines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            XCTAssertEqual(
                privateInterpolation.numberOfMatches(in: line, range: range),
                1,
                "the SEP device-name interpolation itself must be annotated `privacy: .private`: \(line)"
            )
            XCTAssertEqual(
                publicInterpolation.numberOfMatches(in: line, range: range),
                0,
                "the SEP device name must not be logged publicly: \(line)"
            )
        }
    }

    /// The Teleport proxy FQDN is environment metadata of the same class as
    /// the SSH `server.host`, which `SSHClient` hashes
    /// (`privacy: .private(mask: .hash)`). The cluster name and the auth-route
    /// ALPN (`teleport-auth@<hex(clusterName)>`, the FQDN hex-encoded) are the
    /// same value wearing a different label. A `.public` interpolation here
    /// publishes the proxy host in the clear to the unified log and any
    /// exported diagnostics.
    ///
    /// The source-level walk is required for the same reason as the pins
    /// above: the simulator log store does not mask privacy on readback, so
    /// only the annotation *form* is observable. Each expression is pinned by
    /// its exact `privacy: .private(mask: .hash)` interpolation count plus a
    /// zero-match public-interpolation regex. The count doubles as the
    /// non-vacuity guard: a renamed value drops to zero and fails the pin
    /// instead of silently disabling the invariant. The regex matches a whole
    /// interpolation (`\(value, privacy: .public)`), not a line substring, so
    /// the legitimate public siblings on the same line
    /// (`clusterId.uuidString`, `Self.alpnProtocol`, the localized error
    /// description) cannot hide a public FQDN interpolation.
    ///
    /// Scope, stated honestly: this is a formatting heuristic over the marker
    /// list and the pinned expressions — an alias (`let h = cluster.host`), an
    /// unlisted label spelling, a multi-line interpolation, or a reformatted
    /// interpolation escapes it. `testNoFQDNTokenExpressionIsLoggedPublicly`
    /// closes the "new expression name" half of that gap; the name-free
    /// residue (`\(destination, privacy: .public)`) still escapes both.
    ///
    /// The walk covers `VVTerm/Features/Teleport` and `VVTerm/Core/Teleport`.
    /// In `VVTerm/Core/SSH` the comparable sites are handled: `dialHost` and
    /// `nodeName` are hashed (`SSHClient.swift:2457/2520/2615/4208/4221`), the
    /// `teleportProxySubsystem` startup-trace detail is a constant, and `peer=`
    /// stays `.public` by decision — it is a numeric socket address, not the
    /// configured host (the diagnostics redactor masks IPv4 literals only, so
    /// an embedded IPv6 literal would survive; tracked separately). It is a
    /// tripwire, not a proof; the behavioural tests remain the gate.
    func testFQDNClassIsNeverLoggedPublicly() throws {
        // The marker list is the tripwire's reach: a value logged with a
        // spelling not listed here escapes the walk entirely (the package
        // half's security lens S1 — `allowed_alpn=` did). Keep it broad: every
        // FQDN-derived value and every common label spelling.
        let markers = [
            "host=\\(", "dial=\\(", "cluster=\\(", "rpID=\\(",
            "alpn=\\(", "allowed_alpn=\\(", "alpnProto", "negotiatedALPN",
            "\\(host,", "cluster.host", "self.host", "clusterName",
            "name=\\(state.clusterName",
        ]
        let walked = try sourceLines(under: "VVTerm/Features/Teleport", matching: markers)
            + sourceLines(under: "VVTerm/Core/Teleport", matching: markers)

        // Non-vacuity guard: the walk must actually see the FQDN log sites.
        XCTAssertGreaterThanOrEqual(
            walked.count,
            80,
            "the FQDN marker walk found suspiciously few lines; a rename or a moved walk root would silently disable this invariant"
        )

        // Every FQDN-class value expression and the number of private
        // interpolations the host tree must carry: 20 across 16 sites (the
        // `tls_setup` line logs `cluster=` and `alpn=` together, each `gRPC
        // dial` line logs `host=` and `cluster=` together, and the
        // `teleport_tls_verify_failed` line logs `alpn=` and `allowed_alpn=`
        // — the auth-route ALPN is `teleport-auth@<hex(clusterName)>`, i.e.
        // the FQDN hex-encoded). The host/ALPN pins share lines, which is why
        // the interpolation count exceeds the site count.
        let fqdnExpressions: [(expression: String, privateInterpolations: Int)] = [
            (#"cluster\.host"#, 3),
            (#"rpID"#, 2),
            (#"self\.host"#, 5),
            (#"clusterName"#, 3),
            (#"state\.clusterName"#, 1),
            (#"alpnProto"#, 1),
            // The fallback literal is matched tolerantly (`[^"]*`): changing
            // `?? "nil"` to another placeholder must not fail this pin —
            // only the annotation's privacy class matters here.
            (#"negotiatedALPN \?\? "[^"]*""#, 1),
            (#"alpnList"#, 1),
            (#"host"#, 3),
        ]

        for (expression, expected) in fqdnExpressions {
            let privateInterpolation = try NSRegularExpression(
                pattern: #"\("# + expression + #",\s*privacy:\s*\.private\(mask:\s*\.hash\)\)"#
            )
            let publicInterpolation = try NSRegularExpression(
                pattern: #"\("# + expression + #",\s*privacy:\s*\.public\)"#
            )
            var privateCount = 0
            var publicMatches: [String] = []
            for line in walked {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                privateCount += privateInterpolation.numberOfMatches(in: line, range: range)
                if publicInterpolation.numberOfMatches(in: line, range: range) > 0 {
                    publicMatches.append(line)
                }
            }

            XCTAssertEqual(
                privateCount,
                expected,
                "expected \(expected) `privacy: .private(mask: .hash)` interpolation(s) of \(expression); found \(privateCount) — a renamed value would silently disable this invariant"
            )
            XCTAssertTrue(
                publicMatches.isEmpty,
                "an FQDN-class interpolation is logged `privacy: .public`: \(publicMatches)"
            )
        }
    }

    /// Class-level complement to the per-expression pins above: any explicitly
    /// `.public` interpolation whose expression *text* names an FQDN-ish value
    /// fails even when the expression is not one of the pinned names. That is
    /// the "new unlisted spelling" half of the gap (security-lens M1:
    /// `host=\(proxyHost, privacy: .public)` leaves every count unchanged and
    /// no pinned-name regex matches it).
    ///
    /// Exclusions are value-shaped, not name-shaped:
    ///   - `Self.`/type-qualified constants — `Self.alpnProtocol` is the
    ///     literal `teleport-proxy-ssh` protocol string, not a host;
    ///   - counts (`.count`) and UUID renderings (`.uuidString`) — opaque.
    ///
    /// Reach limit, stated honestly: a value logged under a name carrying no
    /// FQDN-ish token (`\(destination, privacy: .public)`) escapes this scan
    /// exactly as it escapes the pins; the token list is the scan's reach.
    func testNoFQDNTokenExpressionIsLoggedPublicly() throws {
        let tokenPattern = try NSRegularExpression(
            pattern: #"(?i)(host|nodename|rpid|alpn|clustername|fqdn|proxyhost|servername)"#
        )
        let interpolation = try NSRegularExpression(
            pattern: #"\(([^()]*),\s*privacy:\s*\.public\)"#
        )
        // Every line of both roots — deliberately NOT marker-filtered: an
        // unlisted label spelling must not hide the line from this scan.
        let lines = try sourceLines(under: "VVTerm/Features/Teleport", matching: [])
            + sourceLines(under: "VVTerm/Core/Teleport", matching: [])

        var offenders: [String] = []
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in interpolation.matches(in: line, range: range) {
                guard let expressionRange = Range(match.range(at: 1), in: line) else { continue }
                let expression = String(line[expressionRange]).trimmingCharacters(in: .whitespaces)
                // Structural exclusions, checked before the token scan so a
                // constant or an opaque identifier cannot be mistaken for a
                // host by a name coincidence.
                guard !expression.hasPrefix("Self."),
                      !expression.hasSuffix(".count"),
                      !expression.hasSuffix(".uuidString")
                else { continue }
                let expressionRangeInExpression = NSRange(
                    expression.startIndex..<expression.endIndex,
                    in: expression
                )
                if tokenPattern.firstMatch(in: expression, range: expressionRangeInExpression) != nil {
                    offenders.append(line)
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "an FQDN-ish expression is logged `privacy: .public`: \(offenders)"
        )
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

    /// The registration counterpart of the login rpID test: the rejection log
    /// names the case and never carries the **server-provided** rpID.
    func testTeleportRegistrationCoordinator_rpIDMismatchLogsTheCaseNotTheServerValue() async throws {
        let logging = SpySubsystemLogging()
        let serverRPID = "server-provided-rpid-marker.example"
        let grpc = FailingRegistrationGRPCStub(
            registerChallenge: Self.makeRegisterChallenge(rpID: serverRPID)
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
            containing: "rpID rejected"
        )
        XCTAssertTrue(
            messages.contains(where: { $0.contains("mismatch") }),
            "the rejection log must name the case; saw: \(messages)"
        )
        for message in messages {
            XCTAssertFalse(
                message.contains(serverRPID),
                "the server-provided rpID leaked into a log payload: \(message)"
            )
        }
    }

    // MARK: - TeleportLoginCoordinator

    /// `login/begin` is a headless HTTP call: a non-2xx carries the raw server
    /// body, so the log must carry the status only. The live client throws
    /// `HeadlessError.http` for it (#236), so this scripts the production
    /// shape and pins the full log line: status present, body absent.
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

    /// `login/finish` is the second site of the same class: its
    /// `HeadlessError.http` body must not reach the log either. Like the
    /// `login/begin` test above, this scripts the production shape (#236).
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

    // A `GRPCError` still reaches the login catch from the gRPC/HTTP-2 layer
    // (the #236 fix removed the login clients' literal status+body packing;
    // `GRPCClient`'s `.http2` carries an `NWError` message). This pins that
    // such an error logs its case only — never `localizedDescription`, which
    // is why `wireFailure` matches `GRPCError` explicitly.
    func testTeleportLoginCoordinator_loginBeginRedactsAGRPCErrorFamilyFailure() async throws {
        let logging = SpySubsystemLogging()
        let marker = "login-begin-grpc-family-marker"
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

    /// The rpID-rejection log must name the rejection *case* without carrying
    /// the **server-provided** rpID, which is a value that came off the wire.
    func testTeleportLoginCoordinator_rpIDMismatchLogsTheCaseNotTheServerValue() async throws {
        let logging = SpySubsystemLogging()
        let serverRPID = "server-provided-rpid-marker.example"
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = Self.makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = LoginBeginResponse(
            webauthnChallenge: .init(
                publicKey: .init(challenge: "Y2hhbGxlbmdl", rpId: serverRPID)
            )
        )

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
            containing: "rpID rejected"
        )
        XCTAssertTrue(
            messages.contains(where: { $0.contains("mismatch") }),
            "the rejection log must name the case; saw: \(messages)"
        )
        for message in messages {
            XCTAssertFalse(
                message.contains(serverRPID),
                "the server-provided rpID leaked into a log payload: \(message)"
            )
        }
    }

    // MARK: - TeleportErrorRedaction

    /// The gRPC family's honest home: `.http2`'s producer is the gRPC/HTTP-2
    /// layer (a variable-arg `NWError` message), not the login HTTP path any
    /// more. Whatever the payload, the renderers keep the case only.
    func testWireFailure_rendersTheGRPCErrorFamiliesAsTheirCaseOnly() {
        let marker = "grpc-payload-marker"
        let http2 = GRPCError.http2("login/begin HTTP 403: \(marker)")
        XCTAssertEqual(TeleportErrorRedaction.wireFailure(http2), "http2")
        XCTAssertEqual(TeleportErrorRedaction.grpcFailure(http2), "http2")
        XCTAssertFalse(TeleportErrorRedaction.wireFailure(http2).contains(marker))
        XCTAssertFalse(TeleportErrorRedaction.grpcFailure(http2).contains(marker))

        let grpc = GRPCError.grpc(status: 7, message: marker)
        XCTAssertEqual(TeleportErrorRedaction.wireFailure(grpc), "grpc(status: 7)")
        XCTAssertEqual(TeleportErrorRedaction.grpcFailure(grpc), "grpc(status: 7)")
        XCTAssertFalse(TeleportErrorRedaction.wireFailure(grpc).contains(marker))
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
