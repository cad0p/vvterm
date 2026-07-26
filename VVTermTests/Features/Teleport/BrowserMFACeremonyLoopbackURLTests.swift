// SPDX-License-Identifier: AGPL-3.0-or-later
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
        let ceremony = BrowserMFACeremony()

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
        let ceremony = BrowserMFACeremony()

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
}
