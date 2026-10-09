// SPDX-License-Identifier: MIT
//
//  TeleportSetupSheetTests.swift
//  VVTermTests
//
//  Hosted-view test for the shared Teleport setup sheet's defensive `.ready`
//  branch (issue #369): a caller that presents the sheet with a ready
//  readiness must be dismissed immediately instead of being stranded on an
//  empty phase view.
//
//  The branch is unreachable from the two production hosts (they gate the
//  sheet on `needsSetup`) and from the phase-chain harness (`.needsBootstrap`),
//  so this test is its only regression guard. The mock coordinator factories
//  are never invoked for `.ready`; they exist only to satisfy the generic
//  parameters.
//
//  See:
//    - VVTerm/Features/Teleport/UI/TeleportSetupSheet.swift
//    - VVTermTests/Features/Teleport/TeleportPhaseChainTests.swift (the rule)
//

import SwiftUI
import XCTest
import TeleportCore
import TeleportTesting
@testable import VVTerm

@MainActor
final class TeleportSetupSheetTests: XCTestCase {

    func testReadyInitialReadinessFinishesImmediately() {
        let finished = expectation(description: "onFinish fired for a ready sheet")

        let sheet = TeleportSetupSheet(
            server: makeServer(),
            initialReadiness: .ready,
            makeBootstrapCoordinator: { MockTeleportBootstrapCoordinator(scenario: .happyPath) },
            makeRegistrationCoordinator: { MockTeleportRegistrationCoordinator(scenario: .happyPath) },
            makeLoginCoordinator: { MockTeleportLoginCoordinator(scenario: .happyPath(certTTL: 3_600)) },
            persistHostLogin: { _ in },
            onFinish: { finished.fulfill() }
        )

        let host = UIHostingController(rootView: sheet)
        installInWindow(host)

        wait(for: [finished], timeout: 5)
    }

    private func makeServer() -> Server {
        Server(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            workspaceId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            environment: .production,
            name: "Teleport Ready Sheet",
            host: "teleport.example.com",
            port: 22,
            username: "tester",
            authMethod: .faceIDTeleport
        )
    }

    private func installInWindow(_ host: UIHostingController<some View>) {
        #if canImport(UIKit)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        // Retain the window for the test's lifetime.
        objc_setAssociatedObject(
            host,
            &TeleportSetupSheetTests.windowKey,
            window,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        #endif
    }

    nonisolated(unsafe) private static var windowKey: UInt8 = 0
}

#if canImport(UIKit)
import UIKit
import ObjectiveC
#endif
