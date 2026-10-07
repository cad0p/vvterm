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
//  The seam: the mock gRPC client returns a default
//  `Proto_MFAAuthenticateChallenge()` (no `browserMfaChallenge` set), so the
//  ceremony throws `noBrowserMFAChallenge` AFTER capturing the URL but BEFORE
//  opening Safari. This lets us assert the URL without mocking ASWebAuth.
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
    /// Host-state tolerance, not retry machinery: the wait for
    /// `presenter.presentedURLs` is `approvalPagePresentationTolerance` (45 s),
    /// not the 15 s this test originally raced with. `BrowserMFACeremony` is
    /// `@MainActor`, and on a loaded simulator runner the listener bind plus
    /// the ceremony's MainActor hops can be starved far past 15 s — measured
    /// 2026-10-07 (PR #395, required `unit-tests` job of run 37577383467, job
    /// 112652747154): this test ran 103.073 s and `presentedURLs` was still
    /// empty when the 15 s budget expired, while the suite's next case bound
    /// its listener and passed in 1.4 s. The class is recorded in #326 (the
    /// fail-fast budget 2 s → 30 s) and #336/#337 (four sequential 15 s
    /// listener binds starved ≈65 s → a 20 s tolerance). 45 s is 3× the
    /// product's 15 s single-listener-start timeout (`BrowserMFAListener`
    /// `.defaultStartTimeout`) and keeps headroom over the measured single-hop
    /// starvation; it still discriminates, because the URL must be presented
    /// before the bound (the `XCTUnwrap` below fails otherwise) and the
    /// product's own listener deadline is 180 s, so the bound still proves
    /// prompt presentation rather than eventual. The observed failure spent
    /// 103.073 s on a 15 s budget (the rest was the ceremony's cancel drain);
    /// 45 s plus the same ≈88 s drain is ≈133 s, inside the job's 180 s
    /// per-test allowance. Escalation (recorded, not implied): if a stall ever
    /// survives 45 s, the next step is a structural gate on the ceremony's
    /// progress, not another increase.
    func testCeremony_opensTheServerApprovalPageForTheChallengeRequestID() async throws {
        let client = ChallengeReturningGRPCClient(requestID: "abcdefghijklmnopqrstuvwxyz012345")
        let presenter = RecordingBrowserMFAPresenter()
        let ceremony = BrowserMFACeremony(logging: DefaultTeleportLogging(), presenter: presenter)

        let run = Task { try await ceremony.run(grpcClient: client, host: "teleport.pcad.it") }
        let deadline = ContinuousClock.now + Self.approvalPagePresentationTolerance
        while presenter.presentedURLs.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
        }
        run.cancel()
        _ = try? await run.value

        let presented = try XCTUnwrap(presenter.presentedURLs.first)
        XCTAssertEqual(
            presented.absoluteString,
            "https://teleport.pcad.it/web/mfa/browser/\(client.requestID)"
        )
    }

    /// A browser session whose `start()` returned false can never deliver an
    /// approval, so the ceremony must fail fast with `.safariFailed` instead
    /// of waiting out the 180 s listener deadline (A7). The run is raced
    /// against `failFastBudget` so the counterfactual (the guard reverted)
    /// fails cleanly instead of hanging to the job's execution allowance.
    ///
    /// Host-state tolerance, not retry machinery: the budget is 30 s, not the
    /// 2 s this test originally raced with. `BrowserMFACeremony` is
    /// `@MainActor`, and on a loaded simulator runner its first MainActor hop
    /// can be delayed far past 2 s — measured 2026-10-01 (PR #326, required
    /// `unit-tests` job of run 36888810089): the ceremony's own logs show it
    /// reached the challenge ~16 s after the test started, so the timer won
    /// and `failedFast` came back false while the guard itself was intact.
    /// 30 s still discriminates hard against the 180 s listener deadline the
    /// guard exists to avoid, and the counterfactual still fails cleanly:
    /// `run.cancel()` is honoured by the ceremony's listener wait, so that
    /// failure lands at the budget, not at the job's 180 s allowance.
    /// Escalation (recorded, not implied): if a stall ever survives 30 s, the
    /// next step is a structural gate on the ceremony's progress, not another
    /// increase.
    func testCeremonyFailsFastWhenTheBrowserSessionDidNotStart() async {
        let client = ChallengeReturningGRPCClient(requestID: "abcdefghijklmnopqrstuvwxyz012345")
        let presenter = NotStartedBrowserMFAPresenter()
        let ceremony = BrowserMFACeremony(
            logging: DefaultTeleportLogging(),
            presenter: presenter
        )

        let run = Task { try await ceremony.run(grpcClient: client, host: "teleport.pcad.it") }
        let failedFast = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                do {
                    _ = try await run.value
                    return false
                } catch let error as BrowserMFACeremonyError {
                    guard case .safariFailed(let message) = error,
                          message == "the in-app browser session did not start"
                    else {
                        return false
                    }
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.failFastBudget)
                run.cancel()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(
            failedFast,
            "a browser session that did not start must fail the ceremony fast with .safariFailed"
        )
        XCTAssertEqual(
            presenter.handle?.cancelCount,
            1,
            "the ceremony's defer must cancel the not-started session"
        )
    }

    /// The host-state-tolerant budget for the fail-fast race above. See that
    /// test's doc comment for the measurement and the escalation rule.
    private static let failFastBudget: Duration = .seconds(30)

    /// The host-state-tolerant wait for the approval-page presentation in
    /// `testCeremony_opensTheServerApprovalPageForTheChallengeRequestID`. See
    /// that test's doc comment for the measurement and the escalation rule.
    private static let approvalPagePresentationTolerance: Duration = .seconds(45)

    /// A gRPC stub that answers the challenge request with a real
    /// `BrowserMFAChallenge` so the ceremony proceeds to the Safari step.
    private final class ChallengeReturningGRPCClient: TeleportGRPCClienting {
        let requestID: String

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
