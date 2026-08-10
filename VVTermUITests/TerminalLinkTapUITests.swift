import XCTest

/// Regression coverage for #111/#112: an OSC 8 link tap on iOS must present
/// the confirmation alert (exact URL, Cancel dismisses), and a plain-word
/// double-tap must keep routing as a normal tap — never presenting the
/// link confirmation.
///
/// The harness (`--vvterm-ui-test-terminal-keyboard-harness`) clears the
/// screen, homes the cursor, and feeds the link line `VVTERM-LINK`
/// (https://example.com) at grid (10,0) plus a plain word `SOMEWORD` on
/// row 11 once the surface is ready — comfortably inside the visible
/// terminal area, away from the top screen edge (status bar / Dynamic
/// Island region) where synthetic UI-test taps may not reach the app.
///
/// Core word/line selection from the injected presses is not observable in
/// the harness: iPhone word selection runs through the native
/// UITextInteraction path an in-process harness cannot drive, and the core
/// left-press selection path itself is tracked in issue #114.
final class TerminalLinkTapUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testOSC8LinkTapPresentsConfirmationAlert() throws {
        // Disable keyboard avoidance so the link at row 10 stays at a
        // predictable grid position (no keyboard-avoidance resize).
        let app = launchLinkHarness(feedsOSC8Link: true, preserveTerminalSize: true)
        let terminal = waitForTerminal(in: app)
        let (cols, rows) = try requiredGridSize(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "nativeSelection=false",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )
        // The OSC 8 feed only lands once the core surface exists (feedData
        // drops silently before that); tap only after delivery is confirmed.
        wait(
            for: diagnostics,
            labelContaining: "linkFeed=delivered",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )

        // The link sits at grid (10,0); tap its center via window-relative
        // coordinates (element-relative AX frames can be stale/offset, and
        // the top screen edge is unreliable for synthetic taps). The OSC8
        // feed leaves the caret at the bottom of the grid, which engages the
        // keyboard-avoidance lift and pushes row 10 off-screen — move the
        // caret home first so the grid stays at its natural position.
        let cursorTopButton = app.buttons["vvterm.keyboardTest.cursor.top"]
        XCTAssertTrue(cursorTopButton.waitForExistence(timeout: 5), diagnosticsText(in: app))
        cursorTopButton.tap()
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["terminalTop"] ?? -1) == 0
        }
        let terminalHeight = terminalHeight(in: app)
        tapGridCell(row: 10, col: 0, cols: cols, rows: rows, terminalHeight: terminalHeight, in: app).tap()
        wait(
            for: diagnostics,
            labelContaining: "tapFires=1",
            timeout: 3,
            diagnostics: diagnosticsText(in: app)
        )

        // The confirmation must show the exact URL that would open. The
        // title is "Open Link"; the URL is the alert message, exposed as a
        // static text child of the alert element.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 8), diagnosticsText(in: app))
        let urlInMessage = alert.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "https://example.com")
        ).firstMatch
        XCTAssertTrue(
            alert.label.contains("https://example.com") || urlInMessage.waitForExistence(timeout: 2),
            "Confirmation must show the exact URL; alert label was: \(alert.label)"
        )
        let cancel = alert.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2), diagnosticsText(in: app))
        cancel.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), diagnosticsText(in: app))
    }

    @MainActor
    func testDoubleTapStillSelectsWord() throws {
        // Disable keyboard avoidance so the grid stays at 52 rows and the
        // core's getTopLeft(.active) pin lookup finds a full page.
        let app = launchLinkHarness(
            feedsOSC8Link: true,
            feedsOSC8DoubleClick: true,
            preserveTerminalSize: true
        )
        let terminal = waitForTerminal(in: app)
        let (cols, rows) = try requiredGridSize(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "nativeSelection=false",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )
        // Tap only after the feed is confirmed delivered (see above).
        wait(
            for: diagnostics,
            labelContaining: "linkFeed=delivered",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )

        // The harness drives an in-process double-click at grid (11,0) —
        // SOMEWORD, NOT the OSC 8 link on row 10 — mirroring the app's own
        // handleDoubleTap exactly (one pos event + two immediate press/
        // release pairs, no modifiers). The regression asserted here is the
        // #111 routing-safety property: a plain-word double-click must NOT
        // present the link confirmation alert. (Core word selection from
        // injected presses is not observable in the simulator harness —
        // iPhone word selection runs through the native UITextInteraction
        // path the harness cannot drive; see issue #114.)
        wait(
            for: diagnostics,
            labelContaining: "harness double-click sent",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )
        // The plain word must not trigger the confirmation alert.
        XCTAssertFalse(
            app.alerts.firstMatch.waitForExistence(timeout: 2),
            "Plain-word double-click must not present the link confirmation"
        )
    }

    // MARK: - Launch helpers

    @MainActor
    private func launchLinkHarness(
        feedsOSC8Link: Bool,
        feedsOSC8DoubleClick: Bool = false,
        preserveTerminalSize: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-keyboard-harness",
            "--vvterm-debug-log", "keyboard",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-security.privacyModeEnabled", "NO"
        ]
        if feedsOSC8Link {
            app.launchArguments.append("--vvterm-ui-test-osc8-link")
        }
        if feedsOSC8DoubleClick {
            app.launchArguments.append("--vvterm-ui-test-osc8-double-click")
        }
        if preserveTerminalSize {
            app.launchArguments.append("--vvterm-ui-test-preserve-terminal-size")
        }
        _ = launchForTest(app)

        let ready = app.staticTexts["vvterm.keyboardTest.ready"]
        let readinessTimeout: TimeInterval = 45
        XCTAssertTrue(
            ready.waitForExistence(timeout: readinessTimeout),
            "Keyboard harness did not mount"
        )
        wait(
            for: ready,
            labelContaining: "ready=true",
            timeout: readinessTimeout,
            diagnostics: diagnosticsText(in: app)
        )
        return app
    }

    @MainActor
    private func waitForTerminal(in app: XCUIApplication) -> XCUIElement {
        let terminal = app.descendants(matching: .any)
            .matching(identifier: "vvterm.keyboardTest.terminalSurface")
            .firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticsText(in: app))
        return terminal
    }

    /// Waits for the grid metrics to appear and returns (cols, rows). The
    /// harness feed is injected when the surface becomes ready, so once the
    /// grid is up a short settle lets the OSC 8 line land in the core.
    @MainActor
    private func requiredGridSize(in app: XCUIApplication) throws -> (cols: Double, rows: Double) {
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["gridCols"] ?? 0) > 0 && (metrics["gridRows"] ?? 0) > 0
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let metrics = diagnosticMetrics(in: app)
        guard let cols = metrics["gridCols"], let rows = metrics["gridRows"] else {
            XCTFail("Missing grid metrics. \(diagnosticsText(in: app))")
            throw DiagnosticMetricError.missing("gridCols/gridRows")
        }
        return (cols, rows)
    }

    // MARK: - Grid tap helpers

    /// Grid cell center as a window-relative coordinate. The terminal view
    /// spans the full window width and `terminalHeight` points (parsed from
    /// the harness diagnostics); cells are (width/cols) x (height/rows).
    private func tapGridCell(
        row: Double,
        col: Double,
        cols: Double,
        rows: Double,
        terminalHeight: Double,
        in app: XCUIApplication
    ) -> XCUICoordinate {
        let window = app.windows.firstMatch
        let frame = window.frame
        let cellWidth = frame.width / cols
        let cellHeight = terminalHeight / rows
        let x = (col + 0.5) * cellWidth
        let y = (row + 0.5) * cellHeight
        return app.coordinate(
            withNormalizedOffset: CGVector(dx: x / frame.width, dy: y / frame.height)
        )
    }

    private func terminalHeight(in app: XCUIApplication) -> Double {
        diagnosticMetrics(in: app)["terminalHeight"] ?? 0
    }

    // MARK: - Diagnostics helpers

    private func diagnosticMetrics(in app: XCUIApplication) -> [String: Double] {
        let label = app.staticTexts["vvterm.keyboardTest.diagnostics"].label
        return label.split(separator: " ").reduce(into: [:]) { result, token in
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { return }
            result[String(parts[0])] = value
        }
    }

    private func diagnosticsText(in app: XCUIApplication) -> String {
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        guard diagnostics.exists else { return "diagnostics=<missing>" }
        return "diagnostics=\(diagnostics.label)"
    }

    private func waitForDiagnosticMetrics(
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: ([String: Double]) -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(diagnosticMetrics(in: app)) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Timed out waiting for terminal geometry. \(diagnosticsText(in: app))", file: file, line: line)
    }

    private func wait(
        for element: XCUIElement,
        labelContaining expectedText: String,
        timeout: TimeInterval,
        diagnostics: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label.contains(expectedText) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail(
            """
            Timed out waiting for \(expectedText).
            \(diagnostics())
            """,
            file: file,
            line: line
        )
    }

    private enum DiagnosticMetricError: Error {
        case missing(String)
    }
}
