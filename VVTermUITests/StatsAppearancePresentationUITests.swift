import XCTest

final class StatsAppearancePresentationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    #if os(macOS)
    @MainActor
    func testStatsAppearanceCanBeClosedFromGeneralSettings() throws {
        let app = XCUIApplication()
        app.launch()

        app.typeKey(",", modifierFlags: .command)

        let general = app.staticTexts["General"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        general.click()

        let statsAppearance = app.staticTexts["Stats Appearance"]
        XCTAssertTrue(statsAppearance.waitForExistence(timeout: 5))
        statsAppearance.click()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()

        XCTAssertTrue(statsAppearance.waitForExistence(timeout: 5))
    }
    #endif
}
