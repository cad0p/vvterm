import XCTest

final class NoticePresentationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testConnectionFailureUsesBottomSheetWithLargePrimaryAction() throws {
        let app = launchNoticeHarness()
        selectScenario("connectionFailure", in: app)
        let title = app.staticTexts["Connection Failed"]
        let retry = app.buttons["Retry"]
        let close = app.buttons["vvterm.connectionStatus.close"]

        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(title.frame.minY, app.frame.midY)
        XCTAssertLessThanOrEqual(retry.frame.maxY, app.frame.maxY)
        XCTAssertGreaterThan(retry.frame.width, app.frame.width * 0.75)
    }

    @MainActor
    func testConnectionFailureCloseExposesNavigationWithoutRetrying() throws {
        // Resurrected via single-launch harness (see #43 #125 #138 #143)
        let app = launchNoticeHarness()
        selectScenario("connectionFailure", in: app)
        let title = app.staticTexts["Connection Failed"]
        let close = app.buttons["vvterm.connectionStatus.close"]

        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))

        let back = app.buttons["vvterm.noticeTest.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.noticeTest.serverList"]
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testDismissedFailureDoesNotImmediatelyReopen() throws {
        // #119: recurring flake on host-degraded xcode-27 runners — the
        // "Connection Failed" title is never served by the degraded AX stack
        // within 20s even though the harness presents .failed synchronously
        // (failed 3/5 recent runs, always on a shard that wedged once first;
        // passed every healthy run). Same root cause as
        // testPrivacyModeBackgroundResumeRestoresResponsiveTerminal — see #119.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Host-degraded notice presentation flake — quarantined (#119)")
        }
        let app = launchNoticeHarness()
        selectScenario("connectionFailure", in: app)
        let title = app.staticTexts["Connection Failed"]
        let close = app.buttons["vvterm.connectionStatus.close"]

        XCTAssertTrue(title.waitForExistence(timeout: 20))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))

        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(close.exists)
        XCTAssertTrue(app.buttons["Retry"].exists)
    }

    @MainActor
    func testRetryFromDismissedBannerCanPresentANewFailure() throws {
        let app = launchNoticeHarness()
        selectScenario("connectionFailure", in: app)
        let title = app.staticTexts["Connection Failed"]
        let close = app.buttons["vvterm.connectionStatus.close"]

        XCTAssertTrue(title.waitForExistence(timeout: 20))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))

        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 20))
    }

    @MainActor
    func testDisconnectedSheetSupportsSwipeDismissalAndKeepsReconnect() throws {
        let app = launchNoticeHarness()
        selectScenario("disconnected", in: app)
        let title = app.staticTexts["Disconnected"]
        let close = app.buttons["vvterm.connectionStatus.close"]

        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Reconnect"].waitForExistence(timeout: 5))
        close.swipeDown()

        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Reconnect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vvterm.noticeTest.back"].exists)
    }

    @MainActor
    func testHostKeyFailureRetainsCloseAndTrustActions() throws {
        let app = launchNoticeHarness()
        selectScenario("hostKeyFailure", in: app)

        XCTAssertTrue(app.staticTexts["Connection Failed"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["vvterm.connectionStatus.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Trust New Host Key"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testInitialConnectionUsesNonBlockingTopBanner() throws {
        let app = launchNoticeHarness()
        selectScenario("connecting", in: app)
        let title = app.staticTexts["Connecting to production..."]
        let close = app.buttons["vvterm.connectionStatus.close"]
        let terminal = app.staticTexts["$ ssh production"]
        let banner = app.descendants(matching: .any)
            .matching(identifier: "vvterm.notice.banner")
            .firstMatch

        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertFalse(close.waitForExistence(timeout: 1))
        XCTAssertLessThan(banner.frame.maxY, app.frame.midY)
    }

    @MainActor
    func testInitialConnectionBannerYieldsToTmuxSelectionSheet() throws {
        // Resurrected via single-launch harness (see #43 #125 #138 #143)
        let app = launchNoticeHarness()
        selectScenario("bannerHandoff", in: app)
        let connecting = app.staticTexts["Connecting to production..."]
        let tmuxTitle = app.navigationBars["Choose tmux session"]

        XCTAssertTrue(connecting.waitForExistence(timeout: 20))
        XCTAssertTrue(tmuxTitle.waitForExistence(timeout: 20))
        XCTAssertFalse(connecting.exists)
    }

    @MainActor
    func testInactiveSplitPaneCannotPresentConnectionBanner() throws {
        let app = launchNoticeHarness()
        selectScenario("inactiveBanner", in: app)
        let terminal = app.staticTexts["$ ssh production"]
        let inactiveConnecting = app.staticTexts["Connecting to inactive split..."]

        XCTAssertTrue(terminal.waitForExistence(timeout: 20))
        XCTAssertFalse(inactiveConnecting.waitForExistence(timeout: 2))
    }

    @MainActor
    func testFilesOperationNoticeRemainsVisibleOnPushedPreview() throws {
        // Resurrected via single-launch harness (see #43 #125 #138 #143)
        let app = launchNoticeHarness()
        selectScenario("filesPreview", in: app)
        let previewNavigationBar = app.navigationBars["report.pdf"]
        let operationTitle = app.staticTexts["Downloading"]

        XCTAssertTrue(previewNavigationBar.waitForExistence(timeout: 20))
        XCTAssertTrue(operationTitle.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(operationTitle.frame.minY, app.frame.midY)
    }

    @MainActor
    func testConcurrentOperationsStackAboveBottomToolbar() throws {
        // Resurrected via single-launch harness (see #43 #125 #138 #143)
        let app = launchNoticeHarness()
        selectScenario("operationStack", in: app)
        let first = app.staticTexts["Upload 1"]
        let second = app.staticTexts["Upload 2"]
        let third = app.staticTexts["Upload 3"]
        let stackCount = app.otherElements["vvterm.notice.operationStackCount"]
        let toolbarButton = app.buttons["vvterm.noticeTest.bottomToolbar"]

        XCTAssertTrue(first.waitForExistence(timeout: 20))
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
        // Resurrected via single-launch harness (see #43 #125 #138 #143)
        let app = launchNoticeHarness()
        selectScenario("diagnostics", in: app)
        let details = app.descendants(matching: .any)
            .matching(identifier: "vvterm.notice.details")
            .firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 20))
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
    private func selectScenario(_ name: String, in app: XCUIApplication) {
        // Single-launch cleanup: the connection-status bottom sheet (and the
        // diagnostics detail sheet) can outlive their test. Dismiss any
        // presented sheet before opening the scenario menu, or the tap lands
        // on the sheet scrim and the menu never opens (deterministic cascade
        // with the single-launch harness). Both sheets support interactive
        // dismissal (no interactiveDismissDisabled; the connection-status
        // sheet sits at its .height detent, the detail sheet at .large).
        let sheet = app.sheets.firstMatch
        if sheet.exists {
            if sheet.isHittable { sheet.swipeDown() }
            XCTAssertTrue(
                sheet.waitForNonExistence(timeout: 5),
                "Leftover sheet did not dismiss before scenario switch"
            )
        }
        let menu = app.buttons["vvterm.noticeTest.scenarioMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let item = app.descendants(matching: .any)["vvterm.noticeTest.scenarioMenu.\(name)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let current = app.staticTexts["vvterm.noticeTest.scenario.current"]
        let predicate = NSPredicate(format: "label == %@", name)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: current)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 5), .completed)
    }

    private static var app: XCUIApplication?

    @MainActor
    private func launchNoticeHarness() -> XCUIApplication {
        if let app = Self.app { return app }
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-notice-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        _ = launchForTest(app)
        Self.app = app
        return app
    }
}
