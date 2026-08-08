//
//  VVTermUITests.swift
//  VVTermUITests
//
//  Created by Uladzislau Yakauleu on 6.01.26.
//

import XCTest

final class VVTermUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // #45: template test — it only launches the app (launchForTest's own
        // XCTFail is a launch-wedge canary, not a functional assertion) and
        // provides no regression value, while failing whenever the simulator
        // launch wedges on CI (observed 5× on shard-3). Skip in CI like
        // VVTermUITestsLaunchTests; keep it for local template parity.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Template test with no assertions — skipped in CI (#45)")
        }
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        _ = launchForTest(app)

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
