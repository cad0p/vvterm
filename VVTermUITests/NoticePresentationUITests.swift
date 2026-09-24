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
    func testFirstUseHostKeyShowsTrustAffordance() throws {
        // First contact with an unknown host must offer the trust action
        // instead of silently pinning the key (W4c).
        let app = launchNoticeHarness()
        selectScenario("hostKeyUnknown", in: app)

        XCTAssertTrue(app.staticTexts["Connection Failed"].waitForExistence(timeout: 20))
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

        // The connecting banner stays up until the harness trigger yields it
        // (the original 3s auto-handoff made the banner transient — the stale
        // AX tree could miss its brief life under runner load). Every assert
        // below targets a persistent state.
        XCTAssertTrue(connecting.waitForExistence(timeout: 20))
        let present = app.buttons["vvterm.noticeTest.bannerHandoff.present"]
        XCTAssertTrue(present.waitForExistence(timeout: 5))
        present.tap()
        XCTAssertTrue(tmuxTitle.waitForExistence(timeout: 20))
        XCTAssertTrue(connecting.waitForNonExistence(timeout: 5))
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

    /// Selects a scenario from the notice harness's scenario menu.
    ///
    /// #243: under runner load the AX stack can drop the menu presentation or
    /// the item tap entirely (the shard-3 cascade failed at the menu wait 6×),
    /// and a fixed waiter cannot recover a lost tap. Re-drive the menu/item a
    /// bounded number of times and gate on the resulting scenario label; the
    /// label assert is the real check, and a scenario that never switches
    /// still fails with the observed label.
    ///
    /// Two bounds matter here. The loop also requires that a menu item was
    /// **actually tapped**: the label can already equal `name` because a
    /// previous test in the shared app selected the same scenario, and a
    /// label-only assert would then pass without the menu ever presenting —
    /// the exact failure this loop exists to catch, made vacuous. And the
    /// whole loop is wall-clock capped, because each attempt can burn its
    /// per-wait timeouts and a failing attempt must stay cheap enough for the
    /// shard's cost-based retry budget.
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
            // The sheet can exist in AX while still animating in (tests may
            // end mid-presentation); wait for it to be hittable first, then
            // swipe to dismiss. Bounded, fall-through.
            let sheetDeadline = Date().addingTimeInterval(5)
            while Date() < sheetDeadline, !sheet.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if sheet.isHittable { sheet.swipeDown() }
            XCTAssertTrue(
                sheet.waitForNonExistence(timeout: 5),
                "Leftover sheet did not dismiss before scenario switch"
            )
        }
        let menu = app.buttons["vvterm.noticeTest.scenarioMenu"]
        let item = app.descendants(matching: .any)["vvterm.noticeTest.scenarioMenu.\(name)"]
        let current = app.staticTexts["vvterm.noticeTest.scenario.current"]

        var didTapItem = false
        let loopDeadline = Date().addingTimeInterval(40)
        for _ in 0..<3 {
            guard Date() < loopDeadline else { break }
            if !menu.exists {
                guard menu.waitForExistence(timeout: 5) else { continue }
            }
            if !item.exists {
                // A sheet dismissal animation can still intercept hits for a
                // moment after the sheet leaves the AX tree; wait for the
                // menu to be hittable before tapping (bounded, fall-through).
                let menuDeadline = Date().addingTimeInterval(5)
                while Date() < menuDeadline, !menu.isHittable {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
                menu.tap()
                if !item.waitForExistence(timeout: 5), menu.isHittable {
                    // Context-menu presentation can be dropped under runner
                    // load (the tap lands but no items appear). A second tap
                    // re-presents the menu — but only when the menu is not
                    // covered by its own open popover (isHittable false = the
                    // popover is up and items may still be coming).
                    menu.tap()
                }
            }
            guard item.waitForExistence(timeout: 5) else { continue }
            item.tap()
            didTapItem = true
            if waitForLabel(current, equalTo: name, timeout: 5) {
                return
            }
        }
        // Require a real interaction: without this the assert below can pass
        // on a label a previous test already set, with the menu never opened.
        XCTAssertTrue(
            didTapItem,
            "The '\(name)' scenario menu item never presented to be tapped. "
                + "Menu exists: \(menu.exists); item exists: \(item.exists)."
        )
        let observedLabel = current.exists ? current.label : "<missing>"
        XCTAssertEqual(
            observedLabel,
            name,
            "Scenario did not switch to '\(name)' after the bounded menu/item taps. "
                + "Menu exists: \(menu.exists); item exists: \(item.exists)."
        )
    }

    /// Non-asserting label wait used by `selectScenario`'s bounded re-tap
    /// loop; the loop's final `XCTAssertEqual` is the only failure gate.
    @MainActor
    private func waitForLabel(
        _ element: XCUIElement,
        equalTo expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
