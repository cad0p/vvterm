import XCTest

final class NoticePresentationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testConnectionFailureUsesBottomSheetWithLargePrimaryAction() throws {
        let app = launchNoticeHarness()
        let title = app.staticTexts["Connection Failed"]
        let retry = app.buttons["Retry"]

        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(title.frame.minY, app.frame.midY)
        XCTAssertLessThanOrEqual(retry.frame.maxY, app.frame.maxY)
        XCTAssertGreaterThan(retry.frame.width, app.frame.width * 0.75)
    }

    @MainActor
    func testInitialConnectionUsesBottomSheet() throws {
        let app = launchNoticeHarness(additionalArguments: ["--vvterm-ui-test-notice-connecting"])
        let title = app.staticTexts["Connecting to production..."]

        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(title.frame.minY, app.frame.midY)
    }

    @MainActor
    func testInitialConnectionSheetYieldsToTmuxSelectionSheet() throws {
        let app = launchNoticeHarness(
            additionalArguments: ["--vvterm-ui-test-connection-sheet-handoff"]
        )
        let connecting = app.staticTexts["Connecting to production..."]
        let tmuxTitle = app.navigationBars["Choose tmux session"]

        XCTAssertTrue(connecting.waitForExistence(timeout: 10))
        XCTAssertTrue(tmuxTitle.waitForExistence(timeout: 10))
        XCTAssertFalse(connecting.exists)
    }

    @MainActor
    func testInactiveSplitPaneCannotPresentConnectionSheet() throws {
        let app = launchNoticeHarness(
            additionalArguments: ["--vvterm-ui-test-inactive-connection-sheet"]
        )
        let terminal = app.staticTexts["$ ssh production"]
        let inactiveConnecting = app.staticTexts["Connecting to inactive split..."]

        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertFalse(inactiveConnecting.waitForExistence(timeout: 2))
    }

    @MainActor
    func testFilesOperationNoticeRemainsVisibleOnPushedPreview() throws {
        let app = launchNoticeHarness(additionalArguments: ["--vvterm-ui-test-notice-files-preview"])
        let previewNavigationBar = app.navigationBars["report.pdf"]
        let operationTitle = app.staticTexts["Downloading"]

        XCTAssertTrue(previewNavigationBar.waitForExistence(timeout: 10))
        XCTAssertTrue(operationTitle.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(operationTitle.frame.minY, app.frame.midY)
    }

    @MainActor
    func testConcurrentOperationsStackAboveBottomToolbar() throws {
        let app = launchNoticeHarness(additionalArguments: ["--vvterm-ui-test-notice-operation-stack"])
        let first = app.staticTexts["Upload 1"]
        let second = app.staticTexts["Upload 2"]
        let third = app.staticTexts["Upload 3"]
        let stackCount = app.otherElements["vvterm.notice.operationStackCount"]
        let toolbarButton = app.buttons["vvterm.noticeTest.bottomToolbar"]

        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        XCTAssertTrue(stackCount.waitForExistence(timeout: 5))
        XCTAssertTrue(toolbarButton.waitForExistence(timeout: 5))
        XCTAssertEqual(stackCount.label, "3")
        XCTAssertLessThan(first.frame.maxY, second.frame.minY)
        XCTAssertLessThan(second.frame.maxY, third.frame.minY)
        XCTAssertLessThan(third.frame.maxY, toolbarButton.frame.minY)
    }

    @MainActor
    func testDiagnosticBannerExpandsCopiesScrollsAndDismisses() throws {
        let app = launchNoticeHarness(
            additionalArguments: ["--vvterm-ui-test-notice-diagnostics"]
        )
        let details = app.descendants(matching: .any)
            .matching(identifier: "vvterm.notice.details")
            .firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()

        let detailText = app.descendants(matching: .any)
            .matching(identifier: "vvterm.notice.detailText")
            .firstMatch
        let copy = app.descendants(matching: .any)
            .matching(identifier: "vvterm.notice.copyDiagnostics")
            .firstMatch
        XCTAssertTrue(detailText.waitForExistence(timeout: 5))
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        detailText.swipeUp()
        copy.tap()
        XCTAssertEqual(copy.label, "Copied")

        let close = app.descendants(matching: .any)
            .matching(identifier: "vvterm.notice.detailClose")
            .firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        let dismiss = app.descendants(matching: .any)
            .matching(identifier: "vvterm.notice.dismiss")
            .firstMatch
        let banner = app.descendants(matching: .any)
            .matching(identifier: "vvterm.notice.banner")
            .firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(dismiss.exists)
        dismiss.tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func launchNoticeHarness(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-notice-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ] + additionalArguments
        app.launch()
        return app
    }
}
