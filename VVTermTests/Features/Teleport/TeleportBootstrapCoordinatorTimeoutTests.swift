// SPDX-License-Identifier: MIT
//
//  TeleportBootstrapCoordinatorTimeoutTests.swift
//  VVTermTests
//
//  Pins `TeleportBootstrapCoordinator.handlePostFailure` — the load-bearing
//  error mapping from the Phase-1 blocking POST to the bootstrap sheet's
//  recovery UX. In particular `HeadlessError.transport(_, code: .timedOut)`
//  must become `.failed(.timeout)` (the mapping classifies on the carried
//  `URLError.Code`, not on the OS-localized message).
//
//  The login coordinator collapses every transport failure to `.networkLost`
//  (it has no timeout branch); the bootstrap coordinator is the one that runs
//  for the headless POST, so this suite drives the real coordinator end-to-end
//  with a scripted HTTP client.

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
            HeadlessError.transport("The request timed out.", code: .timedOut)
        )
        XCTAssertEqual(coordinator.state, .failed(.timeout))
    }

    /// The classification must not read the OS-localized message: a German
    /// timeout description still maps to `.timeout`, and a foreign-language
    /// non-timeout still maps to `.networkLost`.
    func testTransportTimeout_isLocaleIndependent() async {
        let timedOut = await driveFailure(
            HeadlessError.transport(
                "Der Vorgang hat das Zeitlimit überschritten.",
                code: .timedOut
            )
        )
        XCTAssertEqual(timedOut.state, .failed(.timeout))

        let networkLost = await driveFailure(
            HeadlessError.transport(
                "Die Verbindung zum Server ist fehlgeschlagen.",
                code: .cannotConnectToHost
            )
        )
        XCTAssertEqual(networkLost.state, .failed(.networkLost))
    }

    func testTransportNetworkLoss_mapsToNetworkLost() async {
        let coordinator = await driveFailure(
            HeadlessError.transport(
                "The Internet connection appears to be offline.",
                code: .notConnectedToInternet
            )
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
