import XCTest

final class TerminalReconnectUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testProductionSSHForegroundReconnectRestoresTyping() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-reconnect-harness",
            "--vvterm-debug-log", "keyboard",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-sshAutoReconnect", "YES",
            "-terminalTmuxEnabledDefault", "NO",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()

        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        if !diagnostics.waitForExistence(timeout: 5),
           app.state == .runningForeground {
            // Installing the app can cause ActivityKit to launch it once to
            // finish a stale Live Activity before XCUITest supplies our launch
            // arguments. Relaunch after installation so the harness owns the
            // process from its first scene.
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45), "Production reconnect harness did not mount")
        wait(
            for: diagnostics,
            containing: "setup=ready state=connected",
            timeout: 45,
            app: app
        )
        wait(for: diagnostics, containing: "shell=true", timeout: 10, app: app)
        wait(for: diagnostics, containing: "title=DEV199_READY_1", timeout: 10, app: app)

        let terminal = app.descendants(matching: .any)
            .matching(identifier: "vvterm.reconnectTest.terminalSurface")
            .firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        terminal.tap()
        assertKeyboardAndAccessoryVisible(diagnostics: diagnostics, app: app)

        guard let initialTerminalId = diagnosticValue("terminalId", in: diagnostics) else {
            XCTFail("Missing terminal identity. \(diagnosticText(in: app))")
            return
        }
        guard var shellId = diagnosticValue("shellId", in: diagnostics), shellId != "none" else {
            XCTFail("Missing initial SSH shell identity. \(diagnosticText(in: app))")
            return
        }
        guard let initialInputRebuilds = diagnosticIntegerValue(
            "inputRebuilds",
            in: diagnostics
        ) else {
            XCTFail("Missing initial input-rebuild count. \(diagnosticText(in: app))")
            return
        }

        let initialKey = app.keys["x"]
        XCTAssertTrue(initialKey.waitForExistence(timeout: 5), diagnosticText(in: app))
        tapPromptly(initialKey, diagnostics: diagnostics, app: app)
        wait(for: diagnostics, containing: "cwd=/tmp/DEV199_INPUT_X_1", timeout: 8, app: app)

        for connectionNumber in 2...4 {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(
                waitForBackgroundState(of: app, timeout: 8),
                "VVTerm did not enter the background. \(diagnosticText(in: app))"
            )
            let backgroundDuration: TimeInterval = connectionNumber == 2 ? 5 : 0.5
            RunLoop.current.run(until: Date().addingTimeInterval(backgroundDuration))

            app.activate()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 8),
                "VVTerm did not return to the foreground. \(diagnosticText(in: app))"
            )
            wait(
                for: diagnostics,
                containing: "setup=ready state=connected",
                timeout: 30,
                app: app
            )
            wait(for: diagnostics, containing: "shell=true", timeout: 8, app: app)
            guard let reconnectedShellId = waitForChangedDiagnosticValue(
                "shellId",
                previousValue: shellId,
                in: diagnostics,
                timeout: 8,
                app: app
            ) else { return }
            shellId = reconnectedShellId
            wait(for: diagnostics, containing: "windowAttached=true", timeout: 8, app: app)
            wait(for: diagnostics, containing: "renderingPaused=false", timeout: 8, app: app)
            wait(for: diagnostics, containing: "surfaceFocused=true", timeout: 8, app: app)
            XCTAssertEqual(
                diagnosticValue("terminalId", in: diagnostics),
                initialTerminalId,
                "Foreground reconnect replaced the preserved Ghostty terminal. \(diagnosticText(in: app))"
            )
            assertKeyboardAndAccessoryVisible(diagnostics: diagnostics, app: app)
            XCTAssertEqual(
                diagnosticIntegerValue("inputRebuilds", in: diagnostics),
                initialInputRebuilds,
                "Normal foreground reconnect rebuilt the terminal input session. \(diagnosticText(in: app))"
            )

            let key = app.keys["x"]
            XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticText(in: app))
            tapPromptly(key, diagnostics: diagnostics, app: app)
            wait(
                for: diagnostics,
                containing: "cwd=/tmp/DEV199_INPUT_X_\(connectionNumber)",
                timeout: 8,
                app: app
            )
        }

        // Let the production background path disconnect the final shell and
        // end its Live Activity. Otherwise ActivityKit can prelaunch VVTerm
        // while the next XCUITest installation is still supplying arguments.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            waitForBackgroundState(of: app, timeout: 8),
            "VVTerm did not enter the background during cleanup. \(diagnosticText(in: app))"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor
    private func tapPromptly(
        _ key: XCUIElement,
        diagnostics: XCUIElement,
        app: XCUIApplication
    ) {
        let startedAt = Date()
        key.tap()
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            10,
            "Software-keyboard input stalled. \(diagnosticText(in: app))"
        )
    }

    @MainActor
    private func assertKeyboardAndAccessoryVisible(
        diagnostics: XCUIElement,
        app: XCUIApplication
    ) {
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 8, app: app)
        wait(for: diagnostics, containing: "softwareInputActive=true", timeout: 8, app: app)
        wait(for: diagnostics, containing: "accessoryAttached=true", timeout: 8, app: app)
        wait(for: diagnostics, containing: "hardware=false", timeout: 8, app: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.keyboard.accessory.hide"]
                .waitForExistence(timeout: 5),
            diagnosticText(in: app)
        )
    }

    @MainActor
    private func wait(
        for element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval,
        app: XCUIApplication
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(expected) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Expected diagnostics to contain '\(expected)'. \(diagnosticText(in: app))")
    }

    @MainActor
    private func diagnosticValue(_ name: String, in diagnostics: XCUIElement) -> String? {
        diagnostics.label
            .split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix("\(name)=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }

    @MainActor
    private func diagnosticIntegerValue(_ name: String, in diagnostics: XCUIElement) -> Int? {
        diagnosticValue(name, in: diagnostics).flatMap(Int.init)
    }

    @MainActor
    private func waitForBackgroundState(of app: XCUIApplication, timeout: TimeInterval) -> Bool {
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
    private func waitForChangedDiagnosticValue(
        _ name: String,
        previousValue: String,
        in diagnostics: XCUIElement,
        timeout: TimeInterval,
        app: XCUIApplication
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = diagnosticValue(name, in: diagnostics),
               value != "none",
               value != previousValue {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Expected \(name) to change from \(previousValue). \(diagnosticText(in: app))")
        return nil
    }

    @MainActor
    private func diagnosticText(in app: XCUIApplication) -> String {
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        return diagnostics.exists ? diagnostics.label : "diagnostics unavailable; app state=\(app.state.rawValue)"
    }
}
