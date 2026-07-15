import XCTest

final class TerminalKeyboardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testKeyboardButtonRestoresAfterUserHideButTerminalTapDoesNot() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)

        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        let hideButton = app.descendants(matching: .any)
            .matching(identifier: "vvterm.keyboard.accessory.hide")
            .firstMatch
        XCTAssertTrue(
            hideButton.waitForExistence(timeout: 5),
            """
            Accessory hide button did not attach above the software keyboard.
            \(diagnosticsText(in: app))
            """
        )
        let harnessHideButton = app.buttons["vvterm.keyboardTest.hideViaToolbar"]
        XCTAssertTrue(
            harnessHideButton.waitForExistence(timeout: 5),
            """
            Harness hide control did not mount.
            \(diagnosticsText(in: app))
            """
        )

        harnessHideButton.tap()
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "hideRequests=1", timeout: 3, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeProxyFirstResponder=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "browse=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryHidden(in: app)

        terminal.tap()
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "browse=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryRemainHidden(in: app)

        app.buttons["vvterm.keyboardTest.showKeyboard"].tap()
        assertKeyboardAndAccessoryVisible(in: app)
    }

    @MainActor
    func testKeyboardIsScopedToTerminalSurface() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.mode.other"].tap()
        XCTAssertTrue(
            app.buttons["vvterm.keyboardTest.nonTerminalSurface"].waitForExistence(timeout: 5),
            diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryHidden(in: app)

        app.buttons["vvterm.keyboardTest.mode.terminal"].tap()
        _ = waitForTerminal(in: app)
        assertKeyboardAndAccessoryVisible(in: app)
    }

    @MainActor
    func testForegroundReconnectRestoresTerminalTyping() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            waitForBackgroundState(of: app, timeout: 8),
            "VVTerm did not enter the background. \(diagnosticsText(in: app))"
        )

        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 8),
            "VVTerm did not return to the foreground. \(diagnosticsText(in: app))"
        )

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "reconnect=connected",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryVisible(in: app)

        let key = app.keys["x"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticsText(in: app))
        key.tap()
        wait(
            for: diagnostics,
            labelContaining: "inputHex=78",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testPrivacyModeBackgroundResumeRestoresResponsiveTerminal() throws {
        let app = launchKeyboardHarness(privacyModeEnabled: true)
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            waitForBackgroundState(of: app, timeout: 8),
            "VVTerm did not enter the background. \(diagnosticsText(in: app))"
        )

        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 8),
            "VVTerm did not return to the foreground. \(diagnosticsText(in: app))"
        )

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "reconnect=connected",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryVisible(in: app)

        let key = app.keys["p"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticsText(in: app))
        key.tap()
        wait(
            for: diagnostics,
            labelContaining: "inputHex=70",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testPrivacyShieldHidesAccessoryAndRestoresResponsiveTerminal() throws {
        let app = launchKeyboardHarness(privacyModeEnabled: true)
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.privacy.shield"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.keyboardTest.privacyShield"]
                .waitForExistence(timeout: 5),
            diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryHidden(in: app)

        app.buttons["vvterm.keyboardTest.privacy.resume"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.keyboardTest.privacyShield"]
                .waitForNonExistence(timeout: 5),
            diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryVisible(in: app)

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        let key = app.keys["s"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticsText(in: app))
        key.tap()
        wait(
            for: diagnostics,
            labelContaining: "inputHex=73",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testTemporarySystemOverlayPreservesVisibleKeyboardAndTyping() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        app.buttons["vvterm.keyboardTest.scene.inactive"].tap()
        wait(
            for: diagnostics,
            labelContaining: "reconnect=inactive",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.scene.active"].tap()
        wait(
            for: diagnostics,
            labelContaining: "reconnect=connected",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryVisible(in: app)

        let key = app.keys["x"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticsText(in: app))
        key.tap()
        wait(
            for: diagnostics,
            labelContaining: "inputHex=78",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testTemporarySystemOverlayPreservesUserHiddenKeyboardIntent() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.hideViaToolbar"].tap()
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryHidden(in: app)

        app.buttons["vvterm.keyboardTest.scene.inactive"].tap()
        wait(
            for: diagnostics,
            labelContaining: "reconnect=inactive",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryRemainHidden(in: app)

        app.buttons["vvterm.keyboardTest.scene.active"].tap()
        wait(
            for: diagnostics,
            labelContaining: "reconnect=connected",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryRemainHidden(in: app)
    }

    @MainActor
    func testRepeatedTerminalReconstructionKeepsRenderingAndInputResponsive() throws {
        let app = launchKeyboardHarness()
        var terminal = waitForTerminal(in: app)
        terminal.tap()
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        for _ in 0..<12 {
            app.buttons["vvterm.keyboardTest.mode.other"].tap()
            XCTAssertTrue(
                app.buttons["vvterm.keyboardTest.nonTerminalSurface"].waitForExistence(timeout: 3),
                diagnosticsText(in: app)
            )

            app.buttons["vvterm.keyboardTest.mode.terminal"].tap()
            terminal = waitForTerminal(in: app)
        }

        terminal.tap()
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        terminal.typeText("x")
        wait(
            for: diagnostics,
            labelContaining: "inputHex=78",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    private func waitForBackgroundState(
        of app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state == .runningBackground || app.state == .runningBackgroundSuspended {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor
    func testIMEProxyMarkedTextDeleteAndCommitPath() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)

        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        app.buttons["vvterm.keyboardTest.ime.mark"].tap()
        wait(for: diagnostics, labelContaining: "imeComposing=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeMarkedText=nihon", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeModelText=nihon", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.buttons["vvterm.keyboardTest.ime.delete"].tap()
        wait(for: diagnostics, labelContaining: "imeComposing=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeMarkedText=niho", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeModelText=niho", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.buttons["vvterm.keyboardTest.ime.commit"].tap()
        wait(for: diagnostics, labelContaining: "imeComposing=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeMarkedText=empty", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeModelText=niho", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryVisible(in: app)
    }

    @MainActor
    func testHardwareKeyboardFocusSuppressesAccessoryBar() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)

        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.hardwareFocus"].tap()
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessorySuppressed=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryHidden=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=false", timeout: 5, diagnostics: diagnosticsText(in: app))
    }

    @MainActor
    func testHardwareKeyboardAttachmentHidesAccessoryFromExistingSoftwareSession() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)

        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "hardware=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryHidden=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=false", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.buttons["vvterm.keyboardTest.hardware.detach"].tap()
        wait(for: diagnostics, labelContaining: "hardware=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryVisible(in: app)
    }

    @MainActor
    func testDefaultKeyboardAvoidanceResizesTerminalGrid() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.hideViaToolbar"].tap()
        assertKeyboardAndAccessoryHidden(in: app)
        let expandedRows = try requiredDiagnosticMetric("gridRows", in: app)

        app.buttons["vvterm.keyboardTest.showKeyboard"].tap()
        assertKeyboardAndAccessoryVisible(in: app)
        waitForDiagnosticMetrics(in: app) { metrics in
            guard let rows = metrics["gridRows"] else { return false }
            return rows < expandedRows
        }
    }

    @MainActor
    func testPreservedTerminalGridMovesCursorAboveKeyboard() throws {
        let app = launchKeyboardHarness(preservesTerminalSize: true)
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.hideViaToolbar"].tap()
        assertKeyboardAndAccessoryHidden(in: app)
        let expandedRows = try requiredDiagnosticMetric("gridRows", in: app)
        let restingTerminalTop = try requiredDiagnosticMetric("terminalTop", in: app)

        app.buttons["vvterm.keyboardTest.showKeyboard"].tap()
        assertKeyboardAndAccessoryVisible(in: app)
        app.buttons["vvterm.keyboardTest.cursor.bottom"].tap()

        waitForDiagnosticMetrics(in: app) { metrics in
            guard let rows = metrics["gridRows"],
                  let terminalTop = metrics["terminalTop"],
                  let cursorBottom = metrics["cursorBottom"],
                  let keyboardTop = metrics["keyboardTop"]
            else {
                return false
            }
            return rows == expandedRows
                && terminalTop < restingTerminalTop
                && cursorBottom <= keyboardTop
        }
    }

    @MainActor
    private func launchKeyboardHarness(
        preservesTerminalSize: Bool = false,
        privacyModeEnabled: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-keyboard-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-security.privacyModeEnabled", privacyModeEnabled ? "YES" : "NO"
        ]
        if preservesTerminalSize {
            app.launchArguments.append("--vvterm-ui-test-preserve-terminal-size")
        }
        app.launch()

        let ready = app.staticTexts["vvterm.keyboardTest.ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "Keyboard harness did not mount")
        wait(for: ready, labelContaining: "ready=true", timeout: 20, diagnostics: diagnosticsText(in: app))
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

    private func assertKeyboardAndAccessoryVisible(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)
        wait(for: diagnostics, labelContaining: "imeProxyFirstResponder=true", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)

        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 8),
            """
            Software keyboard did not appear.
            \(diagnosticsText(in: app))
            """,
            file: file,
            line: line
        )
        wait(for: diagnostics, labelContaining: "keyboardVisible=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=true", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)
    }

    private func assertKeyboardAndAccessoryHidden(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 8),
            """
            Software keyboard did not hide with the accessory.
            \(diagnosticsText(in: app))
            """,
            file: file,
            line: line
        )
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "keyboardVisible=false", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)
        wait(for: diagnostics, labelContaining: "accessoryAttached=false", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)
    }

    private func assertKeyboardAndAccessoryRemainHidden(
        in app: XCUIApplication,
        duration: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertKeyboardAndAccessoryHidden(in: app, file: file, line: line)

        let deadline = Date().addingTimeInterval(duration)
        let keyboard = app.keyboards.firstMatch
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        while Date() < deadline {
            if keyboard.exists || diagnostics.label.contains("keyboardVisible=true") || diagnostics.label.contains("accessoryAttached=true") {
                XCTFail(
                    """
                    Software keyboard or accessory reappeared after terminal tap.
                    \(diagnosticsText(in: app))
                    """,
                    file: file,
                    line: line
                )
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func wait(
        for element: XCUIElement,
        labelContaining expectedText: String,
        timeout: TimeInterval,
        diagnostics: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "label CONTAINS %@", expectedText)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            XCTFail(
                """
                Timed out waiting for \(expectedText).
                \(diagnostics())
                """,
                file: file,
                line: line
            )
        }
    }

    private func diagnosticsText(in app: XCUIApplication) -> String {
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        guard diagnostics.exists else { return "diagnostics=<missing>" }
        return "diagnostics=\(diagnostics.label)"
    }

    private func requiredDiagnosticMetric(
        _ name: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Double {
        let metrics = diagnosticMetrics(in: app)
        guard let value = metrics[name] else {
            XCTFail("Missing diagnostic metric \(name). \(diagnosticsText(in: app))", file: file, line: line)
            throw DiagnosticMetricError.missing(name)
        }
        return value
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

    private func diagnosticMetrics(in app: XCUIApplication) -> [String: Double] {
        let label = app.staticTexts["vvterm.keyboardTest.diagnostics"].label
        return label.split(separator: " ").reduce(into: [:]) { result, token in
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { return }
            result[String(parts[0])] = value
        }
    }

    private enum DiagnosticMetricError: Error {
        case missing(String)
    }
}
