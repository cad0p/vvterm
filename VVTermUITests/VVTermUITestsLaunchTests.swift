//
//  VVTermUITestsLaunchTests.swift
//  VVTermUITests
//
//  Created by Uladzislau Yakauleu on 6.01.26.
//

import XCTest

final class VVTermUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // #45: this template launch test ran once per UI configuration
        // (77× per CI run) and failed every variant with "Lost connection to
        // the application" under simulator load, burning ~38m of CI time.
        // It provides no functional regression value — keep it for local
        // launch-performance measurement, but skip it in CI so it can never
        // re-enter the hot path (e.g. if re-added to a shard list).
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Launch tests are for local performance measurement, not CI (#45)")
        }
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
