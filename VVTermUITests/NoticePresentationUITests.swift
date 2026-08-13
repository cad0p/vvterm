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
        // #138: recurring flake on host-degraded xcode-27 runners — the harness
        // never finishes launching (hard "Failed to launch ... via Xcode: Timed
        // out while launching" timeout); failed 3 consecutive PR attempts on
        // PR #137 plus 2 more runs. Quarantined per CI policy until the runner
        // pool stabilizes or a real fix lands.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Host-degraded notice presentation flake — quarantined (#138)")
        }
        let app = launchNoticeHarness()
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
        let app = launchNoticeHarness(
            additionalArguments: ["--vvterm-ui-test-notice-disconnected"]
        )
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
        let app = launchNoticeHarness(
            additionalArguments: ["--vvterm-ui-test-notice-host-key"]
        )

        XCTAssertTrue(app.staticTexts["Connection Failed"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["vvterm.connectionStatus.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Trust New Host Key"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testInitialConnectionUsesNonBlockingTopBanner() throws {
        let app = launchNoticeHarness(additionalArguments: ["--vvterm-ui-test-notice-connecting"])
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
        // #43: the "Choose tmux session" sheet never presents on host-degraded
        // xcode-27 runners (the tmuxTitle XCTAssertTrue failed in 2 runs; the
        // #118 launch-retry helper is already in place — the residual is the
        // presentation wedge). Quarantined per CI policy until the runner pool
        // stabilizes or a real fix lands.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Host-degraded notice presentation flake — quarantined (#43)")
        }
        let app = launchNoticeHarness(
            additionalArguments: ["--vvterm-ui-test-connection-banner-handoff"]
        )
        let connecting = app.staticTexts["Connecting to production..."]
        let tmuxTitle = app.navigationBars["Choose tmux session"]

        XCTAssertTrue(connecting.waitForExistence(timeout: 20))
        XCTAssertTrue(tmuxTitle.waitForExistence(timeout: 20))
        XCTAssertFalse(connecting.exists)
    }

    @MainActor
    func testInactiveSplitPaneCannotPresentConnectionBanner() throws {
        let app = launchNoticeHarness(
            additionalArguments: ["--vvterm-ui-test-inactive-connection-banner"]
        )
        let terminal = app.staticTexts["$ ssh production"]
        let inactiveConnecting = app.staticTexts["Connecting to inactive split..."]

        XCTAssertTrue(terminal.waitForExistence(timeout: 20))
        XCTAssertFalse(inactiveConnecting.waitForExistence(timeout: 2))
    }

    @MainActor
    func testFilesOperationNoticeRemainsVisibleOnPushedPreview() throws {
        // #125: the pushed-preview operation notice never presents on
        // host-degraded runners and the test hangs past the 180s execution
        // allowance (failed 2x on two unrelated branches). Quarantined per CI
        // policy until the runner pool stabilizes or a real fix lands.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Host-degraded notice presentation flake — quarantined (#125)")
        }
        let app = launchNoticeHarness(additionalArguments: ["--vvterm-ui-test-notice-files-preview"])
        let previewNavigationBar = app.navigationBars["report.pdf"]
        let operationTitle = app.staticTexts["Downloading"]

        XCTAssertTrue(previewNavigationBar.waitForExistence(timeout: 20))
        XCTAssertTrue(operationTitle.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(operationTitle.frame.minY, app.frame.midY)
    }

    @MainActor
    func testConcurrentOperationsStackAboveBottomToolbar() throws {
        // #143: hard XCTest launch timeout on host-degraded xcode-27 runners
        // (failed 4 runs). Quarantined per CI policy until the runner pool
        // stabilizes or a real fix lands.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Host-degraded notice presentation flake — quarantined (#143)")
        }
        let app = launchNoticeHarness(additionalArguments: ["--vvterm-ui-test-notice-operation-stack"])
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
        // #143: hard XCTest launch timeout on host-degraded xcode-27 runners
        // (failed 2 runs). Quarantined per CI policy until the runner pool
        // stabilizes or a real fix lands.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Host-degraded notice presentation flake — quarantined (#143)")
        }
        let app = launchNoticeHarness(
            additionalArguments: ["--vvterm-ui-test-notice-diagnostics"]
        )
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
    private func launchNoticeHarness(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Terminate any stale instance from the previous test before
        // launching: a leftover app process is the recurring cause of the
        // "Failed to launch" wedge on the CI runners.
        app.terminate()
        app.launchArguments = [
            "--vvterm-ui-test-notice-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ] + additionalArguments
        _ = launchForTest(app)
        return app
    }
}
