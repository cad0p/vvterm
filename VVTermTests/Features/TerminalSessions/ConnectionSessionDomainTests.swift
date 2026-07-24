import XCTest
@testable import VVTerm

final class ConnectionSessionDomainTests: XCTestCase {
    func testConnectionStateFlagsReflectConnectedAndConnectingStates() {
        XCTAssertTrue(ConnectionState.connected.isConnected)
        XCTAssertFalse(ConnectionState.disconnected.isConnected)
        XCTAssertTrue(ConnectionState.connecting.isConnecting)
        XCTAssertTrue(ConnectionState.reconnecting(attempt: 2).isConnecting)
        XCTAssertFalse(ConnectionState.failed("boom").isConnecting)
    }

    func testConnectionSessionDefaultsToRootTabSession() {
        let session = ConnectionSession(serverId: UUID(), title: "Prod")

        XCTAssertTrue(session.isTabRoot)
        XCTAssertEqual(session.activeTransport, .ssh)
        XCTAssertEqual(session.tmuxStatus, .unknown)
    }
}
