import XCTest

final class TerminalZenModeUITests: XCTestCase {
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
        app.launch()

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
        app.launch()

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
        app.launch()

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
