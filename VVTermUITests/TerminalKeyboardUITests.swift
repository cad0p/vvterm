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
    private func launchKeyboardHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-keyboard-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
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
}
