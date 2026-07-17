import XCTest

final class StatsStorageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-stats-storage-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO"
        ]
        app.launch()
        XCTAssertTrue(app.otherElements["vvterm.stats.storage.details"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app = nil
    }

    @MainActor
    func testVolumeVisibilityBulkActionsAndHealthStates() throws {
        let rootVisibility = app.buttons[volumeIdentifier(
            "stable|linux|root-uuid|/",
            suffix: "visibility"
        )]
        XCTAssertTrue(rootVisibility.waitForExistence(timeout: 5))
        XCTAssertEqual(rootVisibility.label, "Hide Volume")

        rootVisibility.tap()
        XCTAssertEqual(rootVisibility.label, "Show Volume")

        openActions()
        let showAll = app.buttons["Show All Volumes"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 3))
        showAll.tap()
        XCTAssertEqual(rootVisibility.label, "Hide Volume")

        app.buttons["vvterm.stats.storage.selectionMode"].tap()
        app.buttons[volumeIdentifier("stable|linux|root-uuid|/", suffix: "selection")].tap()
        app.buttons[volumeIdentifier(
            "stable|linux|share-uuid|/mnt/share",
            suffix: "selection"
        )].tap()
        openActions()
        let hideSelected = app.buttons["Hide Selected"]
        XCTAssertTrue(hideSelected.waitForExistence(timeout: 3))
        hideSelected.tap()
        XCTAssertEqual(rootVisibility.label, "Show Volume")

        app.buttons["Storage health for /"].tap()
        XCTAssertTrue(app.staticTexts["Healthy"].waitForExistence(timeout: 5))
        closePresentedHealth()

        app.buttons["Storage health for /mnt/share"].tap()
        XCTAssertTrue(app.staticTexts["Network Volume"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openActions() {
        let actions = app.buttons["vvterm.stats.storage.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
    }

    @MainActor
    private func closePresentedHealth() {
        let close = app.navigationBars["Storage Health"].buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(app.otherElements["vvterm.stats.storage.details"].waitForExistence(timeout: 3))
    }

    private func volumeIdentifier(_ identity: String, suffix: String) -> String {
        let token = Data(identity.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "vvterm.stats.storage.volume.\(token).\(suffix)"
    }
}
