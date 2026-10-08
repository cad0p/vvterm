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
        wait(for: diagnostics, containing: "shell=true", timeout: Self.diagnosticsWaitBudget, app: app)
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
        wait(for: diagnostics, containing: "setup=ready", timeout: Self.diagnosticsWaitBudget, app: app)

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
        // #232: this pre-background connect wait carries the worst measured
        // host-state AX stall: 45 s budget against slippages of ~64.4 / ~54.0 /
        // 82.661 / ~75.8 s across four CI instances (max 82.661 s, which
        // reproduces exactly; the other three are wall-clock deltas within
        // 0.5 s). 90 s is the largest defensible budget — ~7.3 s above that
        // tail. Allowance arithmetic (enumerated scopes, pre-#387): the 12
        // in-body waits before `popTerminal` budget 300 s (#400 routed `:111`
        // 10→30, +20 s), + the final 8 s discard = 308 s, + `popTerminal`'s
        // 8+15+5 = 336 s; #387's pair calibration (8→30 twice) adds exactly
        // +44 s → 344/352/380 s. Worst single expiry at the pair, composed
        // from measured extrema: 122.85 s max observed pre-background wait
        // start + 20 s (#400's `:111` budget delta, ahead of the recorded
        // start) + 90 s + ≤26 s (terminal 10 + keyboard label 8 + keyboard
        // element 8) + 30 s + the 22.56 s failure-path `current=` read + ~1 s
        // ≈ 312 s; margin ~8 s. That read is unbounded by design, so this is
        // an estimate, not a bound; a later-calibrated-wait expiry after
        // several near-deadline successes can exceed 300 s — the stop rule's
        // `elapsed=` ≥250 s trigger is the catch. `continueAfterFailure =
        // false` keeps it to one expiry per run.
        // Stacked-success can reach ~326-396 s: that residual predates #387
        // (~262-332 s) and is accepted. Stop rule (home: this comment, plus
        // #387/#400 while open; owner: the next agent touching this method;
        // shrink target: 15-20 s waits or a fail-fast guard): any shard-3 run
        // of this method >250 s, any `elapsed=` ≥250 s, or an allowance kill →
        // reopen #387/#400 and shrink; record runtimes on #248 and reds on
        // #257. A stall beyond a budget can still red here and stays on #257.
        wait(for: diagnostics, containing: "state=connected", timeout: 90, app: app)

        let terminal = productionTerminal(in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        terminal.tap()
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 8, app: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), diagnosticText(in: app))

        let terminalId = try XCTUnwrap(diagnosticValue("terminalId", in: diagnostics))
        let shellId = try XCTUnwrap(diagnosticValue("shellId", in: diagnostics))

        XCUIDevice.shared.press(.home)
        waitForAppState(.runningBackground, timeout: Self.appStateWaitBudget, app: app)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.activate()
        waitForAppState(.runningForeground, timeout: Self.appStateWaitBudget, app: app)

        // #232: measured slippage for the post-background wait is ~22.2 s
        // (n=1, job 111071659829) against the old 10 s budget; 45 s leaves
        // ~22.7 s above that sample. The stacked-success allowance arithmetic
        // (~326-396 s after #387 and #400) is documented at the pre-background
        // site above; the residual is accepted there via the stop rule.
        wait(for: diagnostics, containing: "state=connected", timeout: 45, app: app)
        XCTAssertEqual(diagnosticValue("terminalId", in: diagnostics), terminalId)
        XCTAssertEqual(diagnosticValue("shellId", in: diagnostics), shellId)
        XCTAssertFalse(
            app.staticTexts["Reconnecting…"].exists,
            "Backgrounding unnecessarily disconnected the live terminal. \(diagnosticText(in: app))"
        )
        // #232: measured slippage here is ~8.7 s (n=1, job 108860967255)
        // against the old 8 s budget; 30 s leaves ~21 s of room. Same-trip
        // rule (the `runningBackground`/`runningForeground` pair left this set
        // when #387 calibrated it via `appStateWaitBudget`; #400 calibrated
        // the shared helper's four 10 s defaults via `diagnosticsWaitBudget`):
        // the uncalibrated 8 s waits near the keyboard labels — the
        // pre-background `keyboardVisible=true` label wait and the two
        // `app.keyboards.firstMatch.waitForExistence` waits — are left alone;
        // if any of them reds, calibrate it on its own measured evidence in
        // the same trip.
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 30, app: app)
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
        // #400: this shared wait (both #227 methods) moved from the helper's
        // 10 s default to `diagnosticsWaitBudget` (30 s). Shard-0 exposure:
        // the #227 pair's 41-run maxima are 244.008 s (session) and 274.228 s
        // (list-position) against the 300 s allowance; this change's
        // worst-case budget-inventory deltas are +60 s (session: `:86` + this
        // wait + `assertSession`) and +20 s (list-position: this wait). Stop
        // rule (home: this comment; owner: the next agent touching the #227
        // pair; shrink target: per-site 15-20 s waits or a fail-fast guard):
        // any shard-0 run of either #227 method >250 s, or an allowance kill →
        // reopen #400 and shrink/cap; record runtimes on #248 and reds on #257.
        wait(for: diagnostics, containing: "setup=ready", timeout: Self.diagnosticsWaitBudget, app: app)

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
        revealListTop(list, until: serverRow)
        // Carry the visible-row dump on the failure path: this assertion is the
        // one that failed in run 36067947194 shard-0, and a bare
        // `XCTAssertTrue failed` was the artifact that made the lazy-list
        // diagnosis expensive (#227).
        XCTAssertTrue(
            serverRow.waitForExistence(timeout: 10),
            "server row never appeared after revealListTop; visible list: \(visibleListDescription(in: app))"
        )
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

    /// The server list is lazy: a row outside the render window is absent from
    /// the AX tree entirely, so `waitForExistence` cannot see it. Both split
    /// halves share `prepareNavigationContext`, and the list-position half ends
    /// by scrolling to the active row (`scrollToVisible`), which leaves the list
    /// scrolled for whichever half runs next — that hid the seeded server row
    /// from the session half and failed it at the `serverRow` assertion
    /// (measured on run 36067947194 shard-0: two `Swipe up "vvterm.serverList.list"`
    /// at t=29.62s and t=33.65s, then the next test failed at 22.5s). Scroll
    /// back toward the top, bounded, until the row is realized. The list is not
    /// `.refreshable`, so a downward swipe cannot trigger a reload.
    @MainActor
    private func revealListTop(_ list: XCUIElement, until row: XCUIElement) {
        guard !row.exists else { return }
        for _ in 0..<12 where !row.exists {
            list.swipeDown()
        }
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
        wait(for: diagnostics, containing: "setup=ready state=connected", timeout: Self.diagnosticsWaitBudget, app: app)
        XCTAssertEqual(diagnosticValue("terminalId", in: diagnostics), terminalID)
        XCTAssertEqual(diagnosticValue("shellId", in: diagnostics), shellID)
    }

    /// The app-state wait budget (issue #387): 30 s is the #232 device-state
    /// family budget (90/45/30) and ~6.9× the widest non-stalled completion
    /// upper bound in the extended census (4.35 s, n=15; the plan's n=8 seed
    /// had the same max). The red that prompted this was right-censored at
    /// 8.016 s; the same run measured a 22.557 s AX observation stall (22.56 s
    /// rounded), so a 20 s budget could still red. Stacked exposure and the
    /// stop rule are documented at the pre-background wait site above.
    private static let appStateWaitBudget: TimeInterval = 30

    /// Waits for an `XCUIApplication.State`; on failure reports the wait-clock
    /// evidence only (`budget=`/`elapsed=`/`current=`). The dropped diagnostics
    /// payload is the AX label read (`diagnosticText`): this failure path is
    /// the degraded-host path, where that read is unbounded (22.557 s measured
    /// in the #387 red run) and the label may be stale/empty while
    /// backgrounded. `current=` is a cheap `app.state` query, not an AX tree
    /// read.
    @MainActor
    private func waitForAppState(
        _ expected: XCUIApplication.State,
        timeout: TimeInterval,
        app: XCUIApplication
    ) {
        let started = Date()
        let reached = app.wait(for: expected, timeout: timeout)
        // Measured before any payload, so `elapsed` is the wait clock alone.
        let waited = Date().timeIntervalSince(started)
        XCTAssertTrue(
            reached,
            "Timed out waiting for app state \(String(describing: expected))."
                + " budget=\(String(format: "%.0f", timeout))s"
                + " elapsed=\(String(format: "%.2f", waited))s"
                + " current=\(String(describing: app.state))"
        )
    }

    /// The diagnostics-label wait budget (issue #400): 30 s is the #387-calibrated
    /// host-stall floor — the same host measured a 22.557 s AX observation stall,
    /// so a 20 s budget can still red — and the issue's own first suggestion was
    /// `appStateWaitBudget` (= 30), kept as a separate constant because that one is
    /// scoped to `XCUIApplication.State` waits. The red that prompted this was
    /// right-censored at 10.34 s (`budget=10s elapsed=10.34s`, the token already
    /// present in the post-wait dump) — a lower bound, not a completion. 45 s (the
    /// `:85`/`:42`/`:57`/`:171` sibling budget) was rejected: no measured stall
    /// lands in the 30-45 s band, and shard-0's #227 maxima (244.008 / 274.228 s
    /// against the 300 s allowance) make the +15 s per site a pure exposure cost.
    /// 30 s is also below the 54.0-82.661 s worst-stall tail, so a worse-stall
    /// episode can still red and stays on #257. The wait still fails on a genuine
    /// absence: the token is the session identity.
    private static let diagnosticsWaitBudget: TimeInterval = 30

    @MainActor
    private func wait(
        for element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval,
        app: XCUIApplication
    ) {
        let predicate = NSPredicate(format: "label CONTAINS %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let started = Date()
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        // #232: measured before the diagnostic payload is collected, so
        // `elapsed` is the wait clock alone (the census's wait-start →
        // failure-print convention minus the payload cost); `budget` makes a
        // future red self-contained.
        let waited = Date().timeIntervalSince(started)
        XCTAssertEqual(
            result,
            .completed,
            "Timed out waiting for \(expected). budget=\(String(format: "%.0f", timeout))s"
                + " elapsed=\(String(format: "%.2f", waited))s"
                + " \(diagnosticText(in: app))"
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
