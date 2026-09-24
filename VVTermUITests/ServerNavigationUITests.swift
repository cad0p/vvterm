import XCTest

final class ServerNavigationUITests: XCTestCase {
    /// One app instance per test-class run (all tests share identical
    /// harness launch args). Saves a full app launch + fixture reconnect
    /// per shard run; the reset guard below returns each test to the
    /// server list regardless of the previous test's end state.
    @MainActor
    private static var sharedApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        // These tests boot the TerminalReconnectUITestHarness against a real
        // loopback SSH server (127.0.0.1:22229) whose username + private key
        // must be seeded into the app's `app.vivy.vvterm.dev199-ui-test`
        // UserDefaults suite by the developer before running. CI does not
        // provision that fixture, so the harness reports
        // `setup=failed error=Missing loopback SSH username` and every test in
        // this suite times out waiting for `setup=ready`. Skip in CI so the
        // suite reports a clean result; developers still run them locally
        // with the loopback fixture.
        try skipUnlessLoopbackFixtureAvailable()
    }

    /// List-position half of the old combined push/pop test (#227): after
    /// each pop the active connection row must still be visible in the
    /// server list. Split out so no single test dominates the shard bin
    /// (the two halves stay in the same class so they share `sharedApp`).
    @MainActor
    func testActiveTerminalPushPopPreservesListPosition() throws {
        let context = prepareNavigationContext(verifyMetadataReload: true)
        let app = context.app
        let diagnostics = context.diagnostics
        let activeRow = context.activeRow
        let list = context.list

        // Cycle 1: a plain push/pop keeps the active row visible.
        let cycle1BaselineMidY = activeRow.frame.midY
        tapVisible(activeRow)
        let terminal = productionTerminal(in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        wait(for: diagnostics, containing: "setup=ready state=connected", timeout: 45, app: app)
        popTerminal(in: app)
        assertActiveRowVisibleAfterPop(
            activeRow: activeRow,
            list: list,
            app: app,
            baselineMidY: cycle1BaselineMidY
        )

        // Cycle 2: the keyboard-shown-then-pop path (#129) keeps it visible
        // too. The terminal is tapped first so the pop is exercised with the
        // software keyboard presented, not merely observed.
        let cycle2BaselineMidY = activeRow.frame.midY
        tapVisible(activeRow)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        wait(for: diagnostics, containing: "setup=ready state=connected", timeout: 45, app: app)
        terminal.tap()
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 8, app: app)
        popTerminal(in: app)
        assertActiveRowVisibleAfterPop(
            activeRow: activeRow,
            list: list,
            app: app,
            baselineMidY: cycle2BaselineMidY
        )

        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 8)
    }

    /// Session half of the old combined push/pop test (#227): the same
    /// terminal + shell ids survive a pop and re-push.
    @MainActor
    func testActiveTerminalPushPopPreservesSession() throws {
        let context = prepareNavigationContext(verifyMetadataReload: false)
        let app = context.app
        let diagnostics = context.diagnostics
        let activeRow = context.activeRow

        // Push 1: mount + connect, then capture the session identity.
        tapVisible(activeRow)
        let terminal = productionTerminal(in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        wait(for: diagnostics, containing: "setup=ready state=connected", timeout: 45, app: app)
        wait(for: diagnostics, containing: "shell=true", app: app)
        let terminalID = try XCTUnwrap(diagnosticValue("terminalId", in: diagnostics))
        let shellID = try XCTUnwrap(diagnosticValue("shellId", in: diagnostics))

        popTerminal(in: app)

        // Push 2: the same session survives the pop and re-push.
        tapVisible(activeRow)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        assertSession(
            terminalID: terminalID,
            shellID: shellID,
            diagnostics: diagnostics,
            app: app
        )

        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 8)
    }

    @MainActor
    func testBackgroundReturnPreservesSessionKeyboardAndBackResponsiveness() throws {
        let app = resetToServerList(in: launchNavigationHarness())
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45))
        wait(for: diagnostics, containing: "setup=ready", app: app)

        let activeRow = app.descendants(matching: .any)
            .matching(
                identifier: "vvterm.serverList.activeConnection.D3A03FD5-453E-43AC-8BB5-838E5D5D1990"
            )
            .firstMatch
        let list = app.descendants(matching: .any)
            .matching(identifier: "vvterm.serverList.list")
            .firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        scrollToVisible(activeRow, in: list, app: app)
        tapVisible(activeRow)
        wait(for: diagnostics, containing: "state=connected", timeout: 45, app: app)

        let terminal = productionTerminal(in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        terminal.tap()
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 8, app: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), diagnosticText(in: app))

        let terminalId = try XCTUnwrap(diagnosticValue("terminalId", in: diagnostics))
        let shellId = try XCTUnwrap(diagnosticValue("shellId", in: diagnostics))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))

        wait(for: diagnostics, containing: "state=connected", timeout: 10, app: app)
        XCTAssertEqual(diagnosticValue("terminalId", in: diagnostics), terminalId)
        XCTAssertEqual(diagnosticValue("shellId", in: diagnostics), shellId)
        XCTAssertFalse(
            app.staticTexts["Reconnecting…"].exists,
            "Backgrounding unnecessarily disconnected the live terminal. \(diagnosticText(in: app))"
        )
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 8, app: app)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 8),
            "The native software keyboard session was not preserved. \(diagnosticText(in: app))"
        )

        popTerminal(in: app)
        XCTAssertEqual(app.state, .runningForeground)

        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 8)
    }

    @MainActor
    private func launchNavigationHarness() -> XCUIApplication {
        // Early return: XCUIApplication.launch() on an already-running app
        // would silently relaunch it, so the whole seed+launch+retry block
        // is gated on the shared instance.
        if let app = Self.sharedApp {
            return app
        }
        let app = XCUIApplication()
        seedLoopbackFixtureEnv(into: app)
        app.launchArguments = [
            "--vvterm-ui-test-terminal-reconnect-harness",
            "--vvterm-ui-test-server-navigation",
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
        _ = launchForTest(app)

        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        if !diagnostics.waitForExistence(timeout: 5),
           app.state == .runningForeground {
            app.terminate()
            _ = launchForTest(app)
        }
        Self.sharedApp = app
        return app
    }

    /// Prepared server-list state shared by the split push/pop tests: the
    /// harness is up, the loopback fixture reports ready, and the active
    /// connection row is on screen.
    @MainActor
    private struct NavigationContext {
        let app: XCUIApplication
        let diagnostics: XCUIElement
        let activeRow: XCUIElement
        let list: XCUIElement
    }

    /// Resets the shared app to the server list and resolves the elements
    /// the split tests need. `verifyMetadataReload` runs the mount-time
    /// metadata reload check (a list behaviour) once, in the list-position
    /// method; the session method skips it so the split does not pay for it
    /// twice while keeping the coverage.
    @MainActor
    private func prepareNavigationContext(
        verifyMetadataReload: Bool
    ) -> NavigationContext {
        let app = resetToServerList(in: launchNavigationHarness())
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45))
        wait(for: diagnostics, containing: "setup=ready", app: app)

        let serverRow = app.descendants(matching: .any)
            .matching(
                identifier: "vvterm.serverList.server.D3A03FD5-453E-43AC-8BB5-838E5D5D1990"
            )
            .firstMatch
        let activeRow = app.descendants(matching: .any)
            .matching(
                identifier: "vvterm.serverList.activeConnection.D3A03FD5-453E-43AC-8BB5-838E5D5D1990"
            )
            .firstMatch
        let list = app.descendants(matching: .any)
            .matching(identifier: "vvterm.serverList.list")
            .firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(serverRow.waitForExistence(timeout: 10))
        if verifyMetadataReload {
            assertPostMountServerMetadataReload(serverRow: serverRow, app: app)
        }
        scrollToVisible(activeRow, in: list, app: app)
        return NavigationContext(
            app: app,
            diagnostics: diagnostics,
            activeRow: activeRow,
            list: list
        )
    }

    /// Returns the shared app to a known state (server list, foreground)
    /// regardless of the previous test's end state: the list-position test
    /// ends at the list (popped), the session and background tests end
    /// backgrounded (the session test with the terminal pushed), and a
    /// failed test can leave the terminal pushed. Tapping the harness back
    /// button pops to the list; a wedged app is relaunched once (the shared
    /// instance is cleared first so the relaunch reuses the seed/args path).
    @discardableResult
    @MainActor
    private func resetToServerList(in app: XCUIApplication) -> XCUIApplication {
        // A crashed app cannot be activated back into the harness; relaunch
        // through the shared path (clearing the gate first so the seed/args
        // block re-runs) instead of activate()'s arg-less fresh launch.
        if app.state == .notRunning {
            Self.sharedApp = nil
            return launchNavigationHarness()
        }
        if app.state != .runningForeground {
            app.activate()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 8),
                diagnosticText(in: app)
            )
        }
        let back = app.buttons["vvterm.terminal.back"]
        if back.waitForExistence(timeout: 3) {
            // Production pop budget (8s wait + 15s settle + 5s final) — pops
            // can exceed 8s under runner load (#129 family).
            popTerminal(in: app)
        }
        // Wedged fallback: the shared instance cannot be restored -> relaunch
        // once and keep using the new instance.
        if !app.descendants(matching: .any)
            .matching(identifier: "vvterm.serverList.list")
            .firstMatch
            .waitForExistence(timeout: 3) {
            app.terminate()
            Self.sharedApp = nil
            return launchNavigationHarness()
        }
        return app
    }

    @MainActor
    private func scrollToVisible(
        _ element: XCUIElement,
        in list: XCUIElement,
        app: XCUIApplication
    ) {
        for _ in 0..<12 where !isVisible(element, in: list) {
            list.swipeUp()
        }
        XCTAssertTrue(isVisible(element, in: list), diagnosticText(in: app))
    }

    @MainActor
    private func assertPostMountServerMetadataReload(
        serverRow: XCUIElement,
        app: XCUIApplication
    ) {
        let toggle = app.buttons["vvterm.navigationTest.toggleServerMetadata"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), diagnosticText(in: app))
        toggle.tap()
        XCTAssertTrue(serverRow.waitForNonExistence(timeout: 8), diagnosticText(in: app))
        XCTAssertEqual(app.state, .runningForeground)

        toggle.tap()
        XCTAssertTrue(serverRow.waitForExistence(timeout: 8), diagnosticText(in: app))
    }

    /// Asserts the active connection row is still visible in the server list
    /// after a pop, and records the settled frames for triage. There is no
    /// drift assertion: the old strict branch was never observed to run — all
    /// 10 measured CI cycles took the loose path with drift 0 — because the
    /// pop hides the keyboard, so its `keyboardVisible == true` precondition
    /// was never satisfied. That is weaker than "unreachable by construction",
    /// so the branch was deleted rather than "fixed" (rewriting the condition
    /// would risk manufacturing a vacuous assert); drift is still printed
    /// against the pre-push baseline as a triage signal, but nothing asserts
    /// it (#227). The visible-cell enumeration runs only on the failure path;
    /// as an unconditional diagnostic dump it cost ~43 s per run.
    @MainActor
    private func assertActiveRowVisibleAfterPop(
        activeRow: XCUIElement,
        list: XCUIElement,
        app: XCUIApplication,
        baselineMidY: CGFloat
    ) {
        // The pop transition restores the list scroll asynchronously; under
        // runner load the active row can still be mid-animation (or the AX
        // snapshot stale) right after the pop — the known scroll-restoration
        // race (#129). Settle-wait for the row to become visible, bounded,
        // before asserting.
        let visibilityDeadline = Date().addingTimeInterval(8)
        var activeRowVisible = isVisible(activeRow, in: list)
        while !activeRowVisible, Date() < visibilityDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            activeRowVisible = isVisible(activeRow, in: list)
        }
        if !activeRowVisible {
            XCTFail("Active row left the visible list after pop. \(visibleListDescription(in: app))")
        }
        let actualFrame = activeRow.frame
        let actualListFrame = list.frame
        print("NAV-FRAMES post active=(\(Int(actualFrame.midY)),\(Int(actualFrame.height))) "
            + "drift=\(Int(actualFrame.midY - baselineMidY)) "
            + "activeLabel=\(activeRow.label.replacingOccurrences(of: " ", with: "_")) "
            + "list=(\(Int(actualListFrame.minY)),\(Int(actualListFrame.height))) "
            + "servers=\(diagnosticValue("servers", in: app.staticTexts["vvterm.reconnectTest.diagnostics"]) ?? "?")")
    }

    @MainActor
    private func popTerminal(in app: XCUIApplication) {
        let back = app.buttons["vvterm.terminal.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 8), diagnosticText(in: app))
        back.tap()
        // The pop transition can take >8s under runner load (observed:
        // #129 family, ServerNavigationUITests.swift:300). Settle-wait
        // bounded to 15s so the precondition absorbs load without
        // masking a genuinely stuck pop.
        let popDeadline = Date().addingTimeInterval(15)
        while Date() < popDeadline,
              !app.navigationBars["Servers"].exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(
            app.navigationBars["Servers"].waitForExistence(timeout: 5),
            diagnosticText(in: app)
        )
    }

    /// Diagnostic-only visible-row dump, built on the failure path so the
    /// happy path pays no AX enumeration (#227).
    @MainActor
    private func visibleListDescription(in app: XCUIApplication) -> String {
        let serverCells = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'vvterm.serverList.server.'"))
        let visibleCells = (0..<min(serverCells.count, 40)).compactMap { index -> String? in
            let cell = serverCells.element(boundBy: index)
            guard cell.exists else { return nil }
            let frame = cell.frame
            guard !frame.isEmpty, frame.maxY > 0, frame.minY < app.frame.height else { return nil }
            let cellID = cell.identifier
                .replacingOccurrences(of: "vvterm.serverList.server.", with: "")
            return "\(Int(frame.minY)):\(cellID.prefix(8))"
        }
        let activeCells = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'vvterm.serverList.activeConnection.'"))
        let visibleActive = (0..<min(activeCells.count, 8)).compactMap { index -> String? in
            let cell = activeCells.element(boundBy: index)
            guard cell.exists else { return nil }
            let frame = cell.frame
            guard !frame.isEmpty, frame.maxY > 0, frame.minY < app.frame.height else { return nil }
            return "\(Int(frame.minY))"
        }
        return "\(diagnosticText(in: app)) "
            + "visibleServerRows=[\(visibleCells.joined(separator: ","))] "
            + "visibleActiveRows=[\(visibleActive.joined(separator: ","))]"
    }

    @MainActor
    private func isVisible(_ element: XCUIElement, in container: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return !frame.isEmpty && frame.intersects(container.frame)
    }

    @MainActor
    private func tapVisible(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func productionTerminal(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "vvterm.reconnectTest.terminalSurface")
            .firstMatch
    }

    @MainActor
    private func assertSession(
        terminalID: String,
        shellID: String,
        diagnostics: XCUIElement,
        app: XCUIApplication
    ) {
        wait(for: diagnostics, containing: "setup=ready state=connected", app: app)
        XCTAssertEqual(diagnosticValue("terminalId", in: diagnostics), terminalID)
        XCTAssertEqual(diagnosticValue("shellId", in: diagnostics), shellID)
    }

    @MainActor
    private func wait(
        for element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval = 10,
        app: XCUIApplication
    ) {
        let predicate = NSPredicate(format: "label CONTAINS %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Timed out waiting for \(expected). \(diagnosticText(in: app))"
        )
    }

    @MainActor
    private func diagnosticValue(_ key: String, in diagnostics: XCUIElement) -> String? {
        diagnostics.label
            .split(separator: " ")
            .first { $0.hasPrefix("\(key)=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    @MainActor
    private func diagnosticText(in app: XCUIApplication) -> String {
        app.staticTexts["vvterm.reconnectTest.diagnostics"].label
    }
}
