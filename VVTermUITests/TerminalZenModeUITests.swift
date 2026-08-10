import XCTest

final class TerminalZenModeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let zenHarnessArguments = [
        "--vvterm-ui-test-terminal-reconnect-harness",
        "--vvterm-ui-test-enable-startup-zen",
        "--vvterm-ui-test-keyboard-toggle-controls",
        "-AppleLanguages", "(en)",
        "-AppleLocale", "en_US",
        "-hasSeenWelcome", "YES",
        "-iCloudSyncEnabled", "NO",
        "-sshAutoReconnect", "NO",
        "-terminalTmuxEnabledDefault", "NO",
        "-terminalUsePerAppearanceTheme", "NO",
        "-terminalThemeName", "Aizen Dark",
        "-security.privacyModeEnabled", "NO",
        "-security.fullAppLockEnabled", "NO",
        "-security.lockOnBackground", "NO",
    ]

    /// Boots the production server route against the loopback SSH fixture
    /// (skipped in CI, like the reconnect suite) and returns the terminal
    /// surface element.
    @MainActor
    private func launchZenRouteHarness(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        app.launchArguments = Self.zenHarnessArguments
        _ = launchForTest(app, file: file, line: line)
        let terminal = app.descendants(matching: .any)["vvterm.terminal.surface"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 45), "Terminal surface never appeared", file: file, line: line)
        // The loopback shell takes focus on connect; hide the software keyboard
        // so geometry assertions see the unobstructed terminal frame.
        let hideKeyboard = app.buttons["vvterm.reconnectTest.keyboard.hide"]
        if hideKeyboard.waitForExistence(timeout: 5) {
            hideKeyboard.tap()
        }
        return terminal
    }

    @MainActor
    private func overscrollShift(of terminal: XCUIElement) -> Int? {
        guard let value = terminal.value as? String,
              value.hasPrefix("overscroll="),
              let raw = value.split(separator: "=").last else {
            return nil
        }
        return Int(raw)
    }

    /// With "Open in Zen mode by default" on (the default), the production
    /// route must enter zen automatically once the terminal is active — no
    /// menu tap — and the full-screen terminal must span the whole screen
    /// (behind the notch and home indicator).
    @MainActor
    func testDefaultToZenEntersZenAutomaticallyAndTerminalCoversScreen() throws {
        try skipUnlessLoopbackFixtureAvailable()
        let app = XCUIApplication()
        defer { app.terminate() }

        let terminal = launchZenRouteHarness(app)

        let launcher = app.buttons["vvterm.zen.controls"]
        XCTAssertTrue(
            launcher.waitForExistence(timeout: 10),
            "Startup zen should enter zen mode automatically without user action"
        )

        let screenFrame = app.frame
        let terminalFrame = terminal.frame
        XCTAssertEqual(
            terminalFrame.minY, screenFrame.minY, accuracy: 1,
            "Full-screen zen terminal should start at the top of the screen"
        )
        XCTAssertEqual(
            terminalFrame.maxY, screenFrame.maxY, accuracy: 1,
            "Full-screen zen terminal should reach the bottom of the screen"
        )
    }

    /// The full-screen terminal hides rows behind the notch; scrolling past
    /// the top edge must shift the rendered content (overscroll) so those
    /// rows become visible, and scrolling back must return to normal.
    @MainActor
    func testFullScreenZenOverscrollShiftsContentPastTopEdgeAndResets() throws {
        try skipUnlessLoopbackFixtureAvailable()
        let app = XCUIApplication()
        defer { app.terminate() }

        let terminal = launchZenRouteHarness(app)
        XCTAssertTrue(
            app.buttons["vvterm.zen.controls"].waitForExistence(timeout: 10)
        )

        // Swipe down (toward older content) until the top edge is reached and
        // the overscroll shift engages.
        var shift: Int?
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            terminal.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if let value = overscrollShift(of: terminal), value > 0 {
                shift = value
                break
            }
        }
        let engagedShift = try XCTUnwrap(
            shift,
            "Overscroll shift never engaged while swiping past the top edge"
        )
        XCTAssertGreaterThan(engagedShift, 0)

        // Swipe up (toward newer content): the shift must be consumed and
        // return to zero before normal scrolling resumes.
        let resetDeadline = Date().addingTimeInterval(20)
        while Date() < resetDeadline {
            terminal.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if let value = overscrollShift(of: terminal), value == 0 {
                return
            }
        }
        XCTFail("Overscroll shift did not reset after scrolling back from the top edge")
    }

    @MainActor
    func testRealTerminalLauncherOpensZenPanel() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        _ = launchForTest(app)

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.zenTest.terminalSurface"]
                .waitForExistence(timeout: 15)
        )
        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        let launcher = app.buttons["vvterm.zen.controls"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(launcher.isHittable)
        XCTAssertEqual(launcher.frame.width, launcher.frame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(launcher.frame.width, 48)
        launcher.tap()

        XCTAssertTrue(
            app.buttons["vvterm.terminal.zen.view.terminal"].waitForExistence(timeout: 5),
            "Zen launcher remained visible but did not open the control panel"
        )
    }

    @MainActor
    func testMenuEntryHidesChromeAndFloatingControlRestoresIt() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        _ = launchForTest(app)

        let chrome = app.buttons["vvterm.zenTest.chrome"]
        XCTAssertTrue(chrome.waitForExistence(timeout: 5))

        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        XCTAssertTrue(
            app.buttons["vvterm.zen.controls"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(chrome.waitForNonExistence(timeout: 5))

        app.buttons["vvterm.zen.controls"].tap()
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.view.terminal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.view.files"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.newTab"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.settings"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.editServer"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.back"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.disconnect"].exists)

        app.buttons["vvterm.terminal.zen.view.files"].tap()
        XCTAssertTrue(app.buttons["vvterm.zen.controls"].exists)

        let exitZenMode = app.buttons["vvterm.terminal.exitZenMode"]
        XCTAssertTrue(exitZenMode.waitForExistence(timeout: 5))
        if !exitZenMode.isHittable {
            app.scrollViews["vvterm.terminal.zenPanel"].swipeUp()
        }
        XCTAssertTrue(exitZenMode.isHittable)
        exitZenMode.tap()

        XCTAssertTrue(chrome.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["vvterm.zen.controls"].waitForNonExistence(timeout: 5)
        )
    }

    /// The zen tray exposes an ungated "Share Diagnostics" button so users
    /// can attach recent logs to bug reports (see GitHub issue #74).
    @MainActor
    func testZenPanelShareDiagnosticsButtonTriggersHandler() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        _ = launchForTest(app)

        XCTAssertTrue(app.buttons["vvterm.zenTest.chrome"].waitForExistence(timeout: 5))

        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        app.buttons["vvterm.zen.controls"].tap()
        let shareDiagnostics = app.buttons["vvterm.terminal.zen.shareDiagnostics"]
        XCTAssertTrue(shareDiagnostics.waitForExistence(timeout: 5))
        var scrollAttempts = 0
        while !shareDiagnostics.isHittable && scrollAttempts < 3 {
            app.scrollViews["vvterm.terminal.zenPanel"].swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(shareDiagnostics.isHittable)
        shareDiagnostics.tap()

        XCTAssertTrue(
            app.staticTexts["vvterm.zenTest.diagnosticsTapped"].waitForExistence(timeout: 5)
        )
    }

    /// The zen launcher is a glass circle with a thin SF Symbol inside.
    /// Without a `.contentShape`, only the symbol's opaque strokes were
    /// tappable, so tapping the visible glass circle (the obvious target)
    /// did nothing — leaving users stuck in zen mode. This test taps an
    /// off-center point inside the glass circle (not on the symbol) to
    /// verify the whole circle is tappable.
    @MainActor
    func testZenLauncherCircleIsFullyTappable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        _ = launchForTest(app)

        XCTAssertTrue(app.buttons["vvterm.zenTest.chrome"].waitForExistence(timeout: 5))

        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        let launcher = app.buttons["vvterm.zen.controls"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))

        // Tap near the bottom edge of the launcher circle — well outside the
        // thin slider.symbol but inside the visible glass circle.
        let coordinate = launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        coordinate.tap()

        // The panel should open (proving the off-center tap registered).
        XCTAssertTrue(
            app.buttons["vvterm.terminal.zen.view.terminal"].waitForExistence(timeout: 5)
        )
    }
}
