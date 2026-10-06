import XCTest

// #264 (scoped fix: #389) — `TerminalScreenAwakeUITests`.
//
// Two measured failure signatures for this single method:
//
// * Signature A (hang, 300 s allowance kill): run 36295905453 job
//   108556200643 — `t=0.00 Start → 60.21 Set Up → 60.21 Open it.pcad.vvterm →
//   91.00 Launch`, then no further step for five minutes. The wedge is inside
//   `XCUIApplication.launch()` itself (no `Setting up automation session` /
//   `Running Foreground` step appears), so no test-side change can fix it.
//   It is the #257 launch/terminate host-state class; #264 stays open as its
//   per-test instance (reopen/act on any further allowance kill of this
//   method).
//
// * Signature B (this fix, scoped as #389): the tap is synthesized on the
//   `Switch` but the preference never flips. Three identical instances in
//   three days (2026-10-04 run 37220378280 job 111491153350; 2026-10-05 run
//   37359185798 job 111930968225; 2026-10-06 run 37468729499 job
//   112291096304), each red at the `:92` read-back with `Expected
//   diagnostics to contain 'preference=false idleTimerDisabled=false'; got
//   'preference=true idleTimerDisabled=true backgroundReleased=false'; app
//   state=4`. The start state is true
//   (`TerminalDefaults.defaultKeepScreenAwake`), so the first toggle-off is
//   lost — the #126/#47 dropped-input class. The fix is the bounded,
//   state-verified re-tap in `setKeepScreenAwake`: per-attempt preference
//   re-read, bounded hittability wait (#47), 8 s read-back, one confirmation
//   read. A `Toggle` is stateful, unlike #126's idempotent `rotate()`
//   (hardened in #349): if the first tap landed but the label lagged, a blind
//   re-tap would cancel it.
//
// The DEBUG-only harness (`TerminalScreenAwakeUITestHarness+iOS.swift`)
// carries the reproducing fault mode used by the counterfactual runs
// (`--vvterm-ui-test-screen-awake-drop-toggle-writes N`; never in the CI
// path).
//
// Allowance arithmetic (documented, not a bound): launch 15–90 s (observed)
// + 3 activations × ≤3 attempts × (existence ≤5 s + tap + 8 s read-back +
// one confirmation query-pair) + the post-background single-shot 8 s label
// wait + 2 app-state waits × 30 s (#387 family budget) can approach ~4 min on
// a maximally degraded host; `continueAfterFailure = false` keeps it to one
// expiry per run. Stop
// rule: any run of this method > 250 s, or an allowance kill → reopen #264
// and shrink the budgets; a post-fix red at the read-back with `attempts=3`
// is a different mechanism (reopen). Record runtimes on #248, reds on #257.
// Related: #387 (app-state family budget), #349 (query-bounded re-assert),
// #126 (`rotate()` re-assert precedent).

final class TerminalScreenAwakeUITests: XCTestCase {
    /// The app-state wait budget (issue #387): 30 s is the #232 device-state
    /// family budget (90/45/30), and the #387 red measured a 22.557 s AX
    /// observation stall — the old 8 s waits were right-censored by that
    /// stall tail alone. Stacked exposure and the stop rule live in the
    /// header.
    private static let appStateWaitBudget: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTerminalSettingControlsIdleTimerAndRestoresAfterBackground() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-screen-awake-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        _ = launchForTest(app)
        defer { app.terminate() }

        let diagnostics = app.staticTexts["vvterm.screenAwakeTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))

        // Sequence true → false → true. The first call no-ops exactly when
        // the old `if diagnostics.label.contains("preference=false")` branch
        // did: the per-attempt re-read gates on the preference token, so a
        // start state of `true` (the harness default) still performs only the
        // two transitions the old test performed.
        let enableAttempt = setKeepScreenAwake(true, in: app, diagnostics: diagnostics)
        let disableAttempt = setKeepScreenAwake(false, in: app, diagnostics: diagnostics)
        let reenableAttempt = setKeepScreenAwake(true, in: app, diagnostics: diagnostics)
        // Out-of-band dormancy control (CF-C): a healthy host reports attempt
        // 1 for all three calls. Deliberately not asserted — an assertion
        // would red a loaded-but-recovered run; the counterfactual run reads
        // these from the test log.
        print("screenAwake attempts: enable=\(enableAttempt) disable=\(disableAttempt) reenable=\(reenableAttempt)")

        XCUIDevice.shared.press(.home)
        waitForBackgroundState(of: app, timeout: Self.appStateWaitBudget)

        app.activate()
        waitForAppState(.runningForeground, timeout: Self.appStateWaitBudget, app: app)

        assertDiagnostics(
            diagnostics,
            containing: "idleTimerDisabled=true backgroundReleased=true",
            app: app
        )
    }

    /// Flips the screen-awake toggle to `target` with a bounded,
    /// state-verified re-tap (max 3 attempts) and returns the attempt index
    /// that reached the target (1 on a healthy host). Per attempt:
    ///
    /// 1. re-read the diagnostics label; already at the target preference →
    ///    return immediately (the old branch's gate);
    /// 2. bounded hittability wait, then a fresh query and the trailing-switch
    ///    coordinate tap (the #47 remedy);
    /// 3. bounded (8 s), non-failing read-back of the full preference +
    ///    idle-timer expectation;
    /// 4. one confirmation read after a short settle before the attempt is
    ///    counted lost. A `Toggle` is stateful, unlike #126's idempotent
    ///    `rotate()`: a delayed first tap must not be answered with a blind
    ///    re-tap that would cancel it.
    ///
    /// Exhausting all three attempts is a hard failure with the full payload
    /// (`target=`/`attempts=`/`elapsed=`/`labelReadMs=`/label/`app state=`) so
    /// a systematic product failure is not masked.
    @discardableResult
    @MainActor
    private func setKeepScreenAwake(
        _ target: Bool,
        in app: XCUIApplication,
        diagnostics: XCUIElement
    ) -> Int {
        let started = Date()
        let targetToken = target ? "preference=true" : "preference=false"
        let expected = target
            ? "preference=true idleTimerDisabled=true"
            : "preference=false idleTimerDisabled=false"

        for attempt in 1...3 {
            var reachedTarget = false
            XCTContext.runActivity(named: "keepScreenAwake=\(target) attempt \(attempt)/3") { _ in
                // 1. Re-read: never re-tap a `Toggle` that is already at the
                //    target preference (also covers launch, where the
                //    preference renders before the idle pair catches up).
                if diagnostics.exists, diagnostics.label.contains(targetToken) {
                    reachedTarget = true
                    return
                }

                // 2. Bounded hittability wait (#47), then a fresh query and
                //    the trailing-switch coordinate tap.
                waitForHittableToggle(in: app)
                let toggle = keepScreenAwakeToggle(in: app, diagnostics: diagnostics)
                tapTrailingSwitch(in: toggle)

                // 3. Bounded read-back of the full expectation.
                if waitForDiagnostics(diagnostics, containing: expected, app: app) {
                    reachedTarget = true
                    return
                }

                // 4. One confirmation read after a short settle before the
                //    attempt is counted lost.
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                if diagnostics.exists, diagnostics.label.contains(expected) {
                    reachedTarget = true
                }
            }
            if reachedTarget {
                return attempt
            }
        }

        let labelReadStarted = Date()
        let observedLabel = diagnostics.exists ? diagnostics.label : "<missing>"
        let labelReadMs = Date().timeIntervalSince(labelReadStarted) * 1000
        XCTFail(
            "keepScreenAwake target=\(target) attempts=3"
                + " elapsed=\(String(format: "%.2f", Date().timeIntervalSince(started)))s"
                + " labelReadMs=\(String(format: "%.0f", labelReadMs))"
                + " label='\(observedLabel)' app state=\(app.state.rawValue)"
        )
        return 3
    }

    /// The screen-awake toggle, re-queried per attempt: a captured
    /// `XCUIElement` can serve a stale AX snapshot across re-renders.
    @MainActor
    private func keepScreenAwakeToggle(
        in app: XCUIApplication,
        diagnostics: XCUIElement
    ) -> XCUIElement {
        let toggle = app.descendants(matching: .any)
            .matching(identifier: "vvterm.settings.terminal.keepScreenAwake")
            .firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), diagnostics.label)
        return toggle
    }

    /// Bounded hittability wait for the toggle (the #47 remedy, same idiom as
    /// the shared `UITestLaunchSupport.tapWhenHittable`). Best-effort: on
    /// timeout the caller's tap still runs and the read-back reports the real
    /// state.
    @MainActor
    private func waitForHittableToggle(
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let toggle = app.descendants(matching: .any)
                .matching(identifier: "vvterm.settings.terminal.keepScreenAwake")
                .firstMatch
            if toggle.exists, toggle.isHittable {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    @MainActor
    private func tapTrailingSwitch(in toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
    }

    /// Bounded `RunLoop` poll for the diagnostics label; never fails. The
    /// label is read only when the element exists; the label read is the one
    /// that can stall behind an AX rebuild on a degraded host (the #387 red
    /// measured a 22.557 s observation). `app` is accepted for symmetry with
    /// `assertDiagnostics`, the payload-carrying wrapper.
    @MainActor
    private func waitForDiagnostics(
        _ diagnostics: XCUIElement,
        containing expected: String,
        timeout: TimeInterval = 8,
        app: XCUIApplication
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if diagnostics.exists, diagnostics.label.contains(expected) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// `waitForDiagnostics` plus the single-shot failure payload
    /// (`budget=`/`elapsed=` and the app state) for the waits that are not
    /// part of the bounded re-tap.
    @MainActor
    private func assertDiagnostics(
        _ diagnostics: XCUIElement,
        containing expected: String,
        timeout: TimeInterval = 8,
        app: XCUIApplication
    ) {
        let started = Date()
        let matched = waitForDiagnostics(
            diagnostics,
            containing: expected,
            timeout: timeout,
            app: app
        )
        guard !matched else { return }
        let waited = Date().timeIntervalSince(started)
        let observedLabel = diagnostics.exists ? diagnostics.label : "<missing>"
        XCTFail(
            "Expected diagnostics to contain '\(expected)'; got '\(observedLabel)';"
                + " budget=\(String(format: "%.0f", timeout))s"
                + " elapsed=\(String(format: "%.2f", waited))s"
                + " app state=\(app.state.rawValue)"
        )
    }

    /// Waits for the two-state background condition (`.runningBackground` or
    /// `.runningBackgroundSuspended`); kept local to this class (the #387
    /// helper is single-state). Failure payload is wait-clock evidence only
    /// (`budget=`/`elapsed=`/`current=`): the diagnostics label read is
    /// unbounded on a degraded host (22.557 s measured in the #387 red) and
    /// is not needed here — `current=` is a cheap `app.state` query.
    @MainActor
    private func waitForBackgroundState(
        of app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        var reached = false
        while Date() < deadline {
            if app.state == .runningBackground || app.state == .runningBackgroundSuspended {
                reached = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        // Measured before any payload, so `elapsed` is the wait clock alone.
        let waited = Date().timeIntervalSince(started)
        XCTAssertTrue(
            reached,
            "Timed out waiting for an app background state."
                + " budget=\(String(format: "%.0f", timeout))s"
                + " elapsed=\(String(format: "%.2f", waited))s"
                + " current=\(String(describing: app.state))"
        )
    }

    /// Waits for one `XCUIApplication.State` (the #387 shape, a second local
    /// copy; extract on the third). Failure payload is wait-clock evidence
    /// only (`budget=`/`elapsed=`/`current=`).
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
}
