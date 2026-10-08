// SPDX-License-Identifier: MIT
//
//  BrowserMFACeremonyLoopbackURLTests.swift
//  VVTermTests
//
//  Regression coverage for the Browser MFA ceremony loopback URL.
//
//  The live-device failure "unable to create MFA challenges" (gRPC code 7)
//  was caused by the coordinator passing a BOGUS `http://localhost:0/callback`
//  URL to `CreateAuthenticateChallenge` — port 0 is not a valid listener, and
//  Teleport's `ValidateClientRedirect` rejects it. The spike's ceremony owns
//  the entire flow: it starts its own `BrowserMFAListener`, gets a REAL
//  OS-assigned port, then calls `CreateAuthenticateChallenge` with that URL.
//
//  These tests pin that contract: the ceremony MUST call
//  `createAuthenticateChallenge` with a `browserMFATSHRedirectURL` whose port
//  is a real, non-zero, OS-assigned listener port — never the sentinel
//  `localhost:0` that broke the live device.
//
//  The gRPC-channel trick: the mock gRPC client returns a default
//  `Proto_MFAAuthenticateChallenge()` (no `browserMfaChallenge` set), so the
//  ceremony throws `noBrowserMFAChallenge` AFTER capturing the URL but BEFORE
//  opening Safari. This lets us assert the URL without mocking ASWebAuth.
//  (The listener seam added by #401 is separate: the fail-fast test and the
//  #405 presentation tests inject a listener stub; the other tests in this
//  class use the real one.)
//
//  See:
//  - VVTerm/Features/Teleport/Infrastructure/BrowserMFACeremony.swift
//  - spike: spikes/sep-webauthn-iotest/iotest/GRPC/BrowserMFACeremony.swift
//  - live-device failure: "Browser MFA ceremony failed: grpc(7): unable to
//    create MFA challenges"
//

import XCTest
import Security
@testable import VVTerm

@MainActor
final class BrowserMFACeremonyLoopbackURLTests: XCTestCase {

    /// A mock `TeleportGRPCClienting` that captures the
    /// `browserMFATSHRedirectURL` passed to `createAuthenticateChallenge`
    /// and returns a default (empty) challenge so the ceremony throws
    /// `noBrowserMFAChallenge` before opening Safari.
    private final class CapturingGRPCClient: TeleportGRPCClienting {
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
            // Return an empty challenge — the ceremony throws
            // noBrowserMFAChallenge before reaching Safari.
            return Proto_MFAAuthenticateChallenge()
        }

        func createRegisterChallenge(
            existingMFAResponse: Proto_MFAAuthenticateResponse?
        ) async throws -> Proto_MFARegisterChallenge {
            return Proto_MFARegisterChallenge()
        }

        func addMFADeviceSync(
            deviceName: String,
            newMFAResponse: Proto_MFARegisterResponse
        ) async throws {}

        func disconnect() async {}
    }

    /// The ceremony MUST pass a real loopback URL — never the sentinel
    /// `http://localhost:0/callback` that broke the live device
    /// ("unable to create MFA challenges", gRPC code 7).
    ///
    /// A real URL looks like `http://localhost:<non-zero-port>/callback?secret_key=<hex>`.
    func testCeremony_passesRealLoopbackURLToCreateAuthenticateChallenge() async {
        let client = CapturingGRPCClient()
        let ceremony = BrowserMFACeremony(logging: DefaultTeleportLogging(), presenter: RecordingBrowserMFAPresenter())

        // The ceremony throws noBrowserMFAChallenge because the mock returns
        // an empty challenge — but only AFTER it has started the listener and
        // called createAuthenticateChallenge with the real loopback URL.
        do {
            _ = try await ceremony.run(grpcClient: client, host: "teleport.pcad.it")
            XCTFail("ceremony should have thrown noBrowserMFAChallenge for an empty challenge")
        } catch {
            // expected — noBrowserMFAChallenge or a listener-derived error.
            // We only care that the URL was captured.
        }

        guard let url = client.capturedRedirectURL else {
            XCTFail("ceremony did not call createAuthenticateChallenge (no URL captured)")
            return
        }

        // 1. Must NOT be the broken sentinel — port 0 is not a valid listener.
        XCTAssertFalse(
            url.contains("localhost:0") || url.contains("localhost:0/"),
            "ceremony must not pass the bogus localhost:0 sentinel; got: \(url)"
        )

        // 2. Must be an http://localhost URL on a non-zero port.
        XCTAssertTrue(
            url.hasPrefix("http://localhost:"),
            "ceremony must pass an http://localhost:<port>/... URL; got: \(url)"
        )

        // 3. The port must be non-zero. Extract the port between "localhost:"
        //    and the next "/".
        let afterHost = url.dropFirst("http://localhost:".count)
        let portStr = afterHost.prefix { $0 != "/" && $0 != "?" }
        guard let port = Int(portStr), port > 0 else {
            XCTFail("ceremony must pass a non-zero OS-assigned port; got port=\(portStr) in \(url)")
            return
        }
        XCTAssertGreaterThan(
            port, 0,
            "ceremony must pass a real listener port (>0); got: \(url)"
        )

        // 4. Must carry the /callback path + secret_key (the listener contract).
        XCTAssertTrue(
            url.contains("/callback"),
            "ceremony URL must include the /callback path; got: \(url)"
        )
        XCTAssertTrue(
            url.contains("secret_key="),
            "ceremony URL must include the secret_key query param; got: \(url)"
        )
    }

    /// Regression: the ceremony must OWN the listener + the gRPC call. The
    /// coordinator must NOT pre-fetch the challenge with a bogus URL and then
    /// pass it to the ceremony. This test verifies the ceremony calls
    /// `createAuthenticateChallenge` exactly once (its own call, not a
    /// coordinator pre-fetch).
    func testCeremony_ownsCreateAuthenticateChallengeCall() async {
        let client = CapturingGRPCClient()
        let ceremony = BrowserMFACeremony(logging: DefaultTeleportLogging(), presenter: RecordingBrowserMFAPresenter())

        do {
            _ = try await ceremony.run(grpcClient: client, host: "teleport.pcad.it")
        } catch {
            // expected noBrowserMFAChallenge
        }

        XCTAssertNotNil(
            client.capturedRedirectURL,
            "ceremony must call createAuthenticateChallenge itself (the spike's single-ceremony flow)"
        )
    }

    /// The approval page is the server's Browser MFA UI: the ceremony must
    /// open `https://<host>/web/mfa/browser/<request_id>`. A wrong path or a
    /// truncated request id sends the user to a page that cannot approve the
    /// pending request.
    ///
    /// Issue #405: the presentation is observed through the injected listener
    /// seam instead of the #397 45 s `approvalPagePresentationTolerance`
    /// spin. The ceremony records `present` before the stub's
    /// `waitForResponse()` throws `waitReached`, so the terminating await
    /// asserts the presentation without racing the ceremony's `@MainActor`
    /// hops, and the stub's immediate throw keeps a regression red instead of
    /// hanging into the job's execution allowance. The #397 escalation rule
    /// ("a stall surviving 45 s needs a structural gate on the ceremony's
    /// progress, not another increase") is satisfied by construction: the
    /// tolerance is deleted, not extended.
    func testCeremony_opensTheServerApprovalPageForTheChallengeRequestID() async throws {
        let client = ChallengeReturningGRPCClient(requestID: "abcdefghijklmnopqrstuvwxyz012345")
        let presenter = RecordingBrowserMFAPresenter()
        let stub = StubBrowserMFAListener()
        let ceremony = BrowserMFACeremony(
            logging: DefaultTeleportLogging(),
            presenter: presenter,
            makeListener: { _ in stub }
        )

        do {
            _ = try await ceremony.run(grpcClient: client, host: "teleport.pcad.it")
            XCTFail("the ceremony must terminate at the stub listener's wait")
        } catch is StubBrowserMFAListenerError {
            // expected terminal path: the stub's waitForResponse() throws waitReached
        } catch {
            XCTFail("expected StubBrowserMFAListenerError.waitReached, got \(error)")
        }

        XCTAssertEqual(presenter.presentedURLs.count, 1, "the ceremony must present the approval page exactly once")
        let presented = try XCTUnwrap(presenter.presentedURLs.first)
        XCTAssertEqual(
            presented.absoluteString,
            "https://teleport.pcad.it/web/mfa/browser/\(client.requestID)"
        )
        XCTAssertEqual(stub.cancelCount, 1, "the ceremony's defer must cancel the injected listener")
    }

    /// A browser session whose `start()` returned false can never deliver an
    /// approval, so the ceremony must fail fast with `.safariFailed` instead
    /// of waiting out the 180 s listener deadline (A7). The ceremony takes its
    /// loopback listener through the `makeListener` seam, so this test drives
    /// the guard with a stub: the stub's `waitForResponse()` throws
    /// immediately, a reverted guard therefore fails deterministically instead
    /// of hanging into the job's execution allowance, and no wall clock races
    /// the product path.
    ///
    /// Escalation satisfied (issue #401): #326 raised the old race budget
    /// 2 s → 30 s and recorded that a stall surviving the budget must be met
    /// with a structural gate on the ceremony's progress, not another
    /// increase. Run 37604704636 (job 112742518141) saw this test survive the
    /// 30 s budget while the listener bind and the challenge had completed
    /// ~15–20 ms in (the exact test-start timestamp is inferred from the
    /// suite-internal clock), so the structural seam (injecting the listener)
    /// is the recorded next step and the 30 s race is deleted, not extended.
    /// The typed `.safariFailed` catch is the primary assertion; the stub's
    /// `waitCount` is a diagnostic that keeps the guard-before-wait ordering
    /// explicit.
    func testCeremonyFailsFastWhenTheBrowserSessionDidNotStart() async {
        let client = ChallengeReturningGRPCClient(requestID: "abcdefghijklmnopqrstuvwxyz012345")
        let presenter = NotStartedBrowserMFAPresenter()
        let stub = StubBrowserMFAListener()
        let ceremony = BrowserMFACeremony(
            logging: DefaultTeleportLogging(),
            presenter: presenter,
            makeListener: { _ in stub }
        )

        do {
            _ = try await ceremony.run(grpcClient: client, host: "teleport.pcad.it")
            XCTFail("the ceremony must fail fast when the browser session did not start")
        } catch let error as BrowserMFACeremonyError {
            guard case .safariFailed(let message) = error,
                  message == "the in-app browser session did not start" else {
                XCTFail("expected .safariFailed(\"the in-app browser session did not start\"), got \(error)")
                return
            }
        } catch {
            // The A7 guard did not fire: the ceremony reached the injected
            // listener's wait, which throws immediately (the stub never
            // suspends). No `return` is deliberate: the counterfactual then
            // reports both this catch-all and the `waitCount == 0` assertion
            // below, naming the guard-vs-wait failure mode twice.
            XCTFail("expected .safariFailed, got \(error)")
        }

        XCTAssertEqual(presenter.handle?.cancelCount, 1, "the defer must cancel the not-started session")
        XCTAssertEqual(stub.cancelCount, 1, "the defer must cancel the listener")
        XCTAssertEqual(stub.waitCount, 0, "the A7 guard must fire before the listener wait")
        XCTAssertEqual(client.capturedRedirectURL, stub.callbackURL,
                       "the ceremony must drive the injected listener's URL into the challenge call")
    }

    /// A gRPC stub that answers the challenge request with a real
    /// `BrowserMFAChallenge` so the ceremony proceeds to the Safari step.
    private final class ChallengeReturningGRPCClient: TeleportGRPCClienting {
        let requestID: String
        private(set) var capturedRedirectURL: String?

        init(requestID: String) {
            self.requestID = requestID
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
            capturedRedirectURL = browserMFATSHRedirectURL
            var challenge = Proto_MFAAuthenticateChallenge()
            var browser = Proto_BrowserMFAChallenge()
            browser.requestID = requestID
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
}

/// A listener stub shared by the #401 fail-fast test and the two #405
/// presentation tests. It returns a per-instance callback URL (a fresh
/// `UUID` secret keeps the redaction suite's `secret_key` leak oracle
/// high-entropy) and its `waitForResponse()` throws immediately, so the
/// tests observe the recorded presentation without racing a wall clock and
/// the counterfactual (the A7 guard reverted) reds deterministically instead
/// of hanging into the job's execution allowance. All calls arrive from the
/// `@MainActor` ceremony, so main-actor serialization is the justification
/// for `@unchecked Sendable`.
final class StubBrowserMFAListener: BrowserMFAListening, @unchecked Sendable {
    let callbackURL = "http://localhost:54321/callback?secret_key=\(UUID().uuidString)"
    private(set) var waitCount = 0
    private(set) var cancelCount = 0

    func start() async throws -> String { callbackURL }

    func waitForResponse() async throws -> Proto_CredentialAssertionResponse {
        waitCount += 1
        throw StubBrowserMFAListenerError.waitReached
    }

    func cancel() { cancelCount += 1 }
}

enum StubBrowserMFAListenerError: Error { case waitReached }
