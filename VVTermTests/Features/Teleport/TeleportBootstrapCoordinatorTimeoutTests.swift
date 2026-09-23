// SPDX-License-Identifier: MIT
//
//  TeleportBootstrapCoordinatorTimeoutTests.swift
//  VVTermTests
//
//  Pins `TeleportBootstrapCoordinator.handlePostFailure` — the load-bearing
//  error mapping from the Phase-1 blocking POST to the bootstrap sheet's
//  recovery UX. In particular `HeadlessError.transport("…timed out…")` must
//  become `.failed(.timeout)` (the mapping is a localizedDescription string
//  match on the URLSession error the transport wraps).
//
//  The login coordinator has an inert copy of the timeout branch; the
//  bootstrap coordinator is the one that runs for the headless POST, so this
//  suite drives the real coordinator end-to-end with a scripted HTTP client.

#if DEBUG
import XCTest
@testable import VVTerm

@MainActor
final class TeleportBootstrapCoordinatorTimeoutTests: XCTestCase {

    private func makeCluster() -> TeleportCluster {
        TeleportCluster(host: "teleport.pcad.it", username: "pier")
    }

    private func makeCoordinator(http: MockTeleportHTTPClient) -> TeleportBootstrapCoordinator {
        TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: MockTeleportKeyRing(),
            safariPresenter: MockWebAuthenticationSessionPresenter(),
            logging: DefaultTeleportLogging(),
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            tlsKeyPairGenerator: try! TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
    }

    private func driveFailure(_ error: Error) async -> TeleportBootstrapCoordinator {
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessError = error
        let coordinator = makeCoordinator(http: http)
        await coordinator.begin(cluster: makeCluster())
        XCTAssertEqual(http.headlessLoginCallCount, 1)
        return coordinator
    }

    func testTransportTimeout_mapsToFailedTimeout() async {
        let coordinator = await driveFailure(
            HeadlessError.transport("The request timed out.")
        )
        XCTAssertEqual(coordinator.state, .failed(.timeout))
    }

    func testTransportTimeout_isCaseInsensitive() async {
        // URLSession's localizedDescription casing varies by platform/locale
        // (e.g. "…Timed Out…"); the mapping lowercases before matching.
        let coordinator = await driveFailure(
            HeadlessError.transport("The request TIMED OUT while waiting")
        )
        XCTAssertEqual(coordinator.state, .failed(.timeout))
    }

    func testTransportNetworkLoss_mapsToNetworkLost() async {
        let coordinator = await driveFailure(
            HeadlessError.transport("The Internet connection appears to be offline.")
        )
        XCTAssertEqual(coordinator.state, .failed(.networkLost))
    }

    func testHTTPError_mapsToServerWithTheBodyVerbatim() async {
        let coordinator = await driveFailure(
            HeadlessError.http(status: 403, body: "access denied")
        )
        XCTAssertEqual(coordinator.state, .failed(.server("HTTP 403: access denied")))
    }

    func testDecodeError_mapsToUnknown() async {
        let coordinator = await driveFailure(HeadlessError.decode("bad json"))
        XCTAssertEqual(coordinator.state, .failed(.unknown("decode: bad json")))
    }

    func testNoCert_mapsToUnknown() async {
        let coordinator = await driveFailure(HeadlessError.noCert)
        XCTAssertEqual(coordinator.state, .failed(.unknown("no cert in response")))
    }

    func testUnwrappedURLErrorTimedOut_mapsToTimeout() async {
        let coordinator = await driveFailure(URLError(.timedOut))
        XCTAssertEqual(coordinator.state, .failed(.timeout))
    }

    func testUnwrappedURLErrorOffline_mapsToNetworkLost() async {
        let coordinator = await driveFailure(URLError(.notConnectedToInternet))
        XCTAssertEqual(coordinator.state, .failed(.networkLost))
    }

    func testUnwrappedURLErrorCancelled_mapsToUserCancelled() async {
        let coordinator = await driveFailure(URLError(.cancelled))
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
    }
}
#endif
