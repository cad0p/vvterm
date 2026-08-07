import XCTest

/// Regression coverage for #111/#112: an OSC 8 link tap on iOS must present
/// the confirmation alert (exact URL, Cancel dismisses), and double-tap
/// word selection must keep working alongside the link-tap routing.
///
/// The harness (`--vvterm-ui-test-terminal-keyboard-harness`) feeds the
/// link line `VVTERM-LINK` (https://example.com) at grid (0,0) once the
/// surface is ready, mirroring the mouseCaptureSequence timing pattern.
final class TerminalLinkTapUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testOSC8LinkTapPresentsConfirmationAlert() throws {
        let app = launchLinkHarness(feedsOSC8Link: true)
        let terminal = waitForTerminal(in: app)
        let (cols, rows) = try requiredGridSize(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "nativeSelection=false",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )

        // The link starts at grid (0,0); a cell is ~(1/cols, 1/rows) of the
        // terminal, so its center sits at (0.5/cols, 0.5/rows).
        let linkCell = terminal.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5 / cols, dy: 0.5 / rows)
        )
        linkCell.tap()

        // The confirmation must show the exact URL that would open.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 8), diagnosticsText(in: app))
        XCTAssertTrue(
            alert.label.contains("https://example.com"),
            "Confirmation must show the exact URL; alert label was: \(alert.label)"
        )
        let cancel = alert.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2), diagnosticsText(in: app))
        cancel.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), diagnosticsText(in: app))
    }

    @MainActor
    func testDoubleTapStillSelectsWord() throws {
        let app = launchLinkHarness(feedsOSC8Link: true)
        let terminal = waitForTerminal(in: app)
        let (cols, rows) = try requiredGridSize(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "nativeSelection=false",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )

        // Double-tap the word at grid (0,0): a plain double-tap (no super
        // modifier) must select the word, not activate the hyperlink.
        let wordCell = terminal.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5 / cols, dy: 0.5 / rows)
        )
        wordCell.doubleTap()

        wait(
            for: diagnostics,
            labelContaining: "nativeSelection=true",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )
    }

    // MARK: - Launch helpers

    @MainActor
    private func launchLinkHarness(feedsOSC8Link: Bool) -> XCUIApplication {
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
