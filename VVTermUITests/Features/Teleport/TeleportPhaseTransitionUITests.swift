// SPDX-License-Identifier: MIT
//
//  TeleportPhaseTransitionUITests.swift
//  VVTermUITests
//
//  Regression tests for the Teleport phase-chaining fix in the
//  prompt-on-connect (sidebar) flow.
//
//  Bug (fixed by #272): the setup sheet's `onSuccess` callbacks for
//  `.needsBootstrap` and `.needsRegistration` just dismissed the sheet
//  (or re-ran bootstrap) instead of chaining to the next phase. The user
//  saw "bootstrap succeeded" but no registration sheet appeared.
//
//  The chain is now single-source (issue #369): `TeleportPhaseChain` decides
//  the phase and the shared `TeleportSetupSheet` renders it. Bootstrap
//  success stores the `BootstrapResult` and advances to registration, which
//  re-renders the same sheet as `TeleportRegistrationView` using the
//  in-memory TLS keypair — no keychain persistence, no Phase-1 redo.
//
//  These tests verify the chain end-to-end via the
//  `TeleportPhaseChainUITestHarness`, which presents the SHARED production
//  `TeleportSetupSheet` (the production routing view) with mock coordinators.
//  The host call-site composition (readiness capture + presentation binding)
//  is pinned by `TeleportSetupSheetPinsTests`, not exercised here.
//
//  Wait/tap contract (issue #444; source-pinned by
//  `VVTermTests/Features/Teleport/TeleportPhaseTransitionWaitBudgetPinsTests`):
//    - `waitForElement` / `waitForLabel` are bounded re-query polls: the
//      query is constructed fresh inside the loop, `exists` guards every
//      read, the pause is a `RunLoop` run (never a fixed sleep), and the
//      deadline is derived from `budget`. They assert internally with a
//      diagnostic payload (one failure owner), so a timeout names the site.
//    - `tapControl` is the ONLY tap path: existence wait -> bounded
//      best-effort frame settle (3 s; `exists` re-checked immediately before
//      every `.frame` read, and a vanished element returns without tapping or
//      asserting) -> `coordinate(withNormalizedOffset:)` tap. No
//      `.isHittable` read and no bare element `.tap()` can record the #444
//      "Failed to determine hittability" / "Activation point invalid" abort,
//      and `XCTNSPredicateExpectation` is not used (its predicate and a direct
//      `isHittable` read are the same recorded `hitPoint:` path).
//    - Budget scope (the A1 corrected scope rule): only the phase-transition
//      carriers take `axWaitBudget` (30 s, the #387/#400 calibrated floor) —
//      each `tapControl` existence wait plus the `registrationContinue`
//      marker wait. The non-carrier probes keep their pre-existing short
//      values because they do not gate a chain step, and lifting them to
//      30 s pushes the per-method ceiling past the 300 s allowance (#444 plan
//      §7). The exempt list:
//        * `setupPill` existence                               5 s
//        * bootstrap header existence                           5 s
//        * "Approve in Safari" header label                     5 s
//        * `gateReleases` label read                            5 s
//        * `bootstrapBegins` label                              5 s
//        * "Signed in to Teleport" existence                    5 s
//        * `loginContinue` non-existence (negative check)       8 s
//        * terminal dismissal proofs                            3 s
//    - The A3 gate-release counter
//      (`vvterm.teleport.phaseChainHarness.gateReleases`) is asserted right
//      after each gate tap, bounded at 5 s. `waitForLabel` compares the full
//      label, so `gateReleases: 10` cannot satisfy `gateReleases: 1`
//      (CL-13). The pinned mock self-releases its 30 s hold, so without this
//      counter a missed gate tap would pass green.
//
//  Launch-arg contract (parsed by TeleportPhaseChainUITestHarness+iOS.swift):
//    --vvterm-ui-test-teleport-phase-chain   enables the harness
//
//  See:
//    - VVTerm/Features/Teleport/UI/TeleportSetupSheet.swift (the shared routing)
//    - VVTerm/Features/Teleport/Application/TeleportPhaseChain.swift (the rule)
//    - VVTerm/App/iOS/TeleportPhaseChainUITestHarness+iOS.swift (the harness)
//

import XCTest

@MainActor
final class TeleportPhaseTransitionUITests: XCTestCase {

    // MARK: - Identifiers

    private static let serverRowIdentifier = "vvterm.serverRow.00000000-0000-0000-0000-000000000001"
    private static let setupPillIdentifier = "vvterm.serverRow.readinessPill.setup"
    private static let releaseControlIdentifier = "vvterm.teleport.phaseChainHarness.releaseBootstrapApproval"
    private static let gateReleasesIdentifier = "vvterm.teleport.phaseChainHarness.gateReleases"
    private static let bootstrapHeaderIdentifier = "vvterm.teleport.bootstrap.header"
    private static let registrationContinueIdentifier = "vvterm.teleport.registration.continueButton"
    private static let loginHeaderIdentifier = "vvterm.teleport.login.header"
    private static let signInButtonIdentifier = "vvterm.teleport.login.signInButton"
    private static let loginContinueIdentifier = "vvterm.teleport.login.continueButton"
    private static let bootstrapBeginsIdentifier = "vvterm.teleport.phaseChainHarness.bootstrapBegins"

    /// The calibrated stall floor for the phase-transition carriers (#387's
    /// 22.557 s stall; 20 s was rejected in #400). Declared exactly once: the
    /// pin suite reds a second `TimeInterval` constant and a call-site
    /// override.
    private static let axWaitBudget: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch helper

    /// Launch the app with the phase-chain harness.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-teleport-phase-chain",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
            "-iCloudSyncEnabled", "NO",
        ]
        _ = launchForTest(app)
        return app
    }

    /// Capture a screenshot and persist it (loose file + XCTAttachment).
    /// Mirrors the helper in TeleportUITests.swift.
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let png = app.screenshot().pngRepresentation

        let env = ProcessInfo.processInfo.environment
        let candidateDirs: [String] = [
            env["SCREENSHOT_DIR"] ?? "",
            env["CI_SCREENSHOT_DIR"] ?? "",
            "\(NSTemporaryDirectory())screenshots",
            "\(NSHomeDirectory())/screenshots"
        ]
        for dir in candidateDirs where !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dir),
                withIntermediateDirectories: true
            )
            do {
                try png.write(to: url)
                break
            } catch {
                continue
            }
        }

        let attachment = XCTAttachment(
            uniformTypeIdentifier: "public.png",
            name: "\(name).png",
            payload: png,
            userInfo: nil
        )
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Wait/tap helpers (issue #444)

    /// Bounded re-query existence poll. The query is constructed fresh inside
    /// the loop (a captured element would go stale behind the presentation
    /// animation) and the failure payload is owned by this single assertion.
    @discardableResult
    private func waitForElement(
        _ identifier: String,
        in app: XCUIApplication,
        reason: String,
        budget: TimeInterval = TeleportPhaseTransitionUITests.axWaitBudget,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(budget)
        let start = Date()
        var attempts = 0
        var lastExists = false
        while Date() < deadline {
            attempts += 1
            let candidate = app.descendants(matching: .any)[identifier]
            lastExists = candidate.exists
            if lastExists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        XCTFail(
            "\(reason) — attempts=\(attempts) elapsed=\(elapsedMs)ms budget=\(budget)s identifier=\(identifier) lastExists=\(lastExists) app state=\(app.state.rawValue)",
            file: file,
            line: line
        )
        return false
    }

    /// Bounded re-query label poll. `needle` is compared with `==` — the full
    /// label — so a longer label (`gateReleases: 10`) cannot satisfy a shorter
    /// needle (`gateReleases: 1`) (CL-13).
    @discardableResult
    private func waitForLabel(
        _ needle: String,
        _ identifier: String,
        in app: XCUIApplication,
        reason: String,
        budget: TimeInterval = TeleportPhaseTransitionUITests.axWaitBudget,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(budget)
        let start = Date()
        var attempts = 0
        var lastExists = false
        var lastLabel = "<unread>"
        var lastLabelReadMs = 0
        while Date() < deadline {
            attempts += 1
            let candidate = app.staticTexts[identifier]
            lastExists = candidate.exists
            if lastExists {
                let readStart = Date()
                lastLabel = candidate.label
                lastLabelReadMs = Int(Date().timeIntervalSince(readStart) * 1000)
                if lastLabel == needle {
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        XCTFail(
            "\(reason) — attempts=\(attempts) elapsed=\(elapsedMs)ms budget=\(budget)s identifier=\(identifier) needle=\(needle) lastExists=\(lastExists) label=\(lastLabel) labelReadMs=\(lastLabelReadMs) app state=\(app.state.rawValue)",
            file: file,
            line: line
        )
        return false
    }

    /// The only tap path (issue #444): existence wait -> bounded best-effort
    /// frame settle -> coordinate tap. The settle timeout does not assert and
    /// a vanished element returns without tapping, so the caller's next-state
    /// wait (or the A3 counter) is the verdict.
    private func tapControl(
        _ identifier: String,
        in app: XCUIApplication,
        reason: String,
        budget: TimeInterval = TeleportPhaseTransitionUITests.axWaitBudget,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard waitForElement(identifier, in: app, reason: reason, budget: budget, file: file, line: line) else {
            return
        }

        // Frame settle: the I1 record was an element-tappability condition, so
        // give a mounted-but-unmeasured frame a bounded window to settle. The
        // `.frame` read is guarded by `exists` immediately before it.
        let settleDeadline = Date().addingTimeInterval(3)
        while Date() < settleDeadline {
            let candidate = app.descendants(matching: .any)[identifier]
            guard candidate.exists else { return }
            if candidate.frame.width > 0, candidate.frame.height > 0 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        // Coordinate tap: no `hitPoint:`/scroll-to-visible record path. The
        // event builder still resolves the element's frame at dispatch (a
        // vanished element records and aborts — an accepted residual), so the
        // element is re-queried and `exists`-guarded once more.
        let element = app.descendants(matching: .any)[identifier]
        guard element.exists else { return }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // MARK: - Phase 1 → Phase 2 transition (the bug)

    /// Tapping a `needsBootstrap` server row opens the bootstrap sheet; the
    /// mock coordinator parks in `.awaitingApproval` until the release control
    /// is tapped, then succeeds and the registration sheet (phase 2) appears —
    /// NOT dismissal, NOT a second bootstrap.
    ///
    /// This is the core regression test for the sidebar phase-chaining bug.
    func testPhase1BootstrapSuccess_transitionsToRegistrationSheet() {
        let app = launch()

        // The amber "Setup" pill should be visible for needsBootstrap.
        // PillBadge applies `.accessibilityElement(children: .ignore)`, which
        // surfaces the element as `Other`, not `StaticText` — query
        // type-agnostically (the migration every sibling readiness suite
        // already carries, 85421b53). Non-carrier probe: 5 s.
        let setupPill = app.descendants(matching: .any)[Self.setupPillIdentifier]
        XCTAssertTrue(setupPill.waitForExistence(timeout: 5), "amber 'Setup' pill should be visible for needsBootstrap")

        // Tap the row → the bootstrap sheet should appear. The tap path's own
        // existence wait is the carrier; the old standalone pre-tap
        // `releaseControl.waitForExistence`/`waitForHittable` pair and its
        // "persistence proof" are dropped (subsumed by the tap path and the
        // A3 counter).
        tapControl(
            Self.serverRowIdentifier,
            in: app,
            reason: "tapping the needsBootstrap row must present the bootstrap sheet"
        )

        // Non-carrier probe: the header is a stable state, not a ~100 ms
        // transient (the gate holds), so it keeps its 5 s.
        let bootstrapHeader = app.staticTexts[Self.bootstrapHeaderIdentifier]
        XCTAssertTrue(
            bootstrapHeader.waitForExistence(timeout: 5),
            "bootstrap sheet header should appear after tapping a needsBootstrap row"
        )
        waitForLabel(
            "Approve in Safari",
            Self.bootstrapHeaderIdentifier,
            in: app,
            reason: "bootstrap header must read 'Approve in Safari'",
            budget: 5
        )
        attachScreenshot(app, named: "phaseChain-1-bootstrap-sheet")

        tapControl(
            Self.releaseControlIdentifier,
            in: app,
            reason: "the bootstrap gate's release control must be present in .awaitingApproval"
        )

        // #444 A3: the mock self-releases its 30 s hold, so a missed gate tap
        // would complete the chain anyway; the counter is the tap-specific
        // observable. Non-carrier probe: 5 s.
        waitForLabel(
            "gateReleases: 1",
            Self.gateReleasesIdentifier,
            in: app,
            reason: "the gate-release counter must be exactly 1 after the gate tap (#444 A3)",
            budget: 5
        )

        // The mock bootstrap coordinator (happyPath) succeeds once released.
        // The bootstrap sheet's `onSuccess` stores the result and flips
        // readiness to `.needsRegistration`, which re-renders the sheet as
        // `TeleportRegistrationView`. The Continue button's appearance is the
        // phase-2 marker — a phase-transition carrier, 30 s.
        waitForElement(
            Self.registrationContinueIdentifier,
            in: app,
            reason: "registration sheet (Continue button) should appear after bootstrap succeeds — the phase 1→2 transition that was broken (#272)"
        )

        // The bootstrap sheet should be GONE (the success copy must not
        // linger — the sheet re-rendered as registration, not stacked).
        XCTAssertFalse(
            app.staticTexts["vvterm.teleport.bootstrap.success"].exists,
            "bootstrap success copy should not persist — the sheet should have transitioned to registration"
        )

        // The "Signed in to Teleport" row (phase-1-complete section of the
        // registration sheet) confirms we're on phase 2. Non-carrier probe: 5 s.
        let signedIn = app.staticTexts["Signed in to Teleport"]
        XCTAssertTrue(
            signedIn.waitForExistence(timeout: 5),
            "registration sheet should show the 'Signed in to Teleport' phase-1-complete row"
        )

        attachScreenshot(app, named: "phaseChain-2-registration-sheet")
    }

    /// The phase 1→2 transition must NOT re-run bootstrap. Before the fix,
    /// the sidebar's `needsRegistration` case routed BACK to
    /// `TeleportBootstrapView` (redoing phase 1). This test asserts the
    /// registration sheet appears WITHOUT a second bootstrap sheet
    /// header flash.
    func testPhase1BootstrapSuccess_doesNotReRunBootstrap() {
        let app = launch()

        tapControl(
            Self.serverRowIdentifier,
            in: app,
            reason: "tapping the needsBootstrap row must present the bootstrap sheet"
        )

        // Gate-held bootstrap phase. Non-carrier probe: 5 s.
        let bootstrapHeader = app.staticTexts[Self.bootstrapHeaderIdentifier]
        XCTAssertTrue(bootstrapHeader.waitForExistence(timeout: 5))

        tapControl(
            Self.releaseControlIdentifier,
            in: app,
            reason: "the bootstrap gate's release control must be present in .awaitingApproval"
        )

        // #444 A3: the tap-specific gate-release observable. Non-carrier
        // probe: 5 s.
        waitForLabel(
            "gateReleases: 1",
            Self.gateReleasesIdentifier,
            in: app,
            reason: "the gate-release counter must be exactly 1 after the gate tap (#444 A3)",
            budget: 5
        )

        // Wait for the registration sheet — a phase-transition carrier, 30 s.
        waitForElement(
            Self.registrationContinueIdentifier,
            in: app,
            reason: "registration sheet (Continue button) should appear after bootstrap succeeds"
        )

        // The bootstrap header must be gone (not re-presented).
        XCTAssertFalse(
            bootstrapHeader.exists,
            "bootstrap header should NOT reappear — the needsRegistration path must present registration, not re-run bootstrap"
        )
        // The namesake no-re-run property: the parent-owned coordinator counts
        // `begin` calls and the harness renders the count outside the sheet, so
        // it survives the bootstrap → registration swap. A second (fallback)
        // bootstrap would increment it to 2. Non-carrier probe: 5 s.
        waitForLabel(
            "bootstrapBegins: 1",
            Self.bootstrapBeginsIdentifier,
            in: app,
            reason: "bootstrap must run exactly once — a second (fallback) bootstrap would increment the count",
            budget: 5
        )

        attachScreenshot(app, named: "phaseChain-no-bootstrap-rerun")
    }

    // MARK: - Phase 2 → Phase 3 transition

    /// After registration succeeds (Continue tapped, mock returns success),
    /// the login sheet (phase 3) appears. This verifies the full chain.
    func testPhase2RegistrationSuccess_transitionsToLoginSheet() {
        let app = launch()

        tapControl(
            Self.serverRowIdentifier,
            in: app,
            reason: "tapping the needsBootstrap row must present the bootstrap sheet"
        )

        tapControl(
            Self.releaseControlIdentifier,
            in: app,
            reason: "the bootstrap gate's release control must be present in .awaitingApproval"
        )

        // #444 A3: the tap-specific gate-release observable. Non-carrier
        // probe: 5 s.
        waitForLabel(
            "gateReleases: 1",
            Self.gateReleasesIdentifier,
            in: app,
            reason: "the gate-release counter must be exactly 1 after the gate tap (#444 A3)",
            budget: 5
        )

        // Tap Continue → the mock registration coordinator (happyPath)
        // succeeds, firing `onSuccess` which flips readiness to
        // `.needsLogin` → the login sheet appears. The tap path's existence
        // wait is the phase-1→2 carrier (30 s).
        tapControl(
            Self.registrationContinueIdentifier,
            in: app,
            reason: "registration sheet (Continue button) should appear after bootstrap succeeds — the phase 1→2 transition"
        )

        // The login sheet's "Sign in with Face ID" button is the phase-3
        // marker (the login sheet starts in .idle and requires a tap); the tap
        // path's existence wait is the phase-2→3 carrier (30 s).
        tapControl(
            Self.signInButtonIdentifier,
            in: app,
            reason: "login sheet (Sign in button) should appear after registration succeeds — the phase 2→3 transition"
        )

        // The registration Continue button must be gone.
        XCTAssertFalse(
            app.buttons[Self.registrationContinueIdentifier].exists,
            "registration sheet should NOT persist — it should have transitioned to login"
        )

        // Tap Sign in → the mock login coordinator (happyPath) succeeds and
        // the host-login step appears with a Continue button. The tap path's
        // existence wait is the Face-ID-success carrier (30 s).
        tapControl(
            Self.loginContinueIdentifier,
            in: app,
            reason: "the host-login step (Continue button) should appear after Face ID succeeds"
        )
        attachScreenshot(app, named: "phaseChain-3-login-hostLogin")

        // Continue persists the host login (no-op in the harness) and the
        // shared sheet's login success calls `onFinish`, dismissing the sheet.
        //
        // `signInButton` renders only in login `.idle` and disappears as soon
        // as the coordinator leaves it, so its absence is NOT a dismissal
        // signal. Assert the host-login step is gone AND the presented
        // surface's own live marker is gone: the sheet must actually dismiss.
        // Negative check keeps its pre-existing 8 s.
        XCTAssertTrue(
            app.buttons[Self.loginContinueIdentifier].waitForNonExistence(timeout: 8),
            "the host-login step should be gone after Continue — login success must finish the chain"
        )
        // Terminal dismissal proof: the harness row's `exists` is true behind a
        // presented sheet, so the pre-#444 `waitForHittable(serverRow)` cannot
        // become a row-existence check. The login sheet's header is the marker
        // that is live while the sheet is up at this point (it renders in every
        // login state, including the host-login step); the bootstrap header is
        // kept as the #444 plan's explicit check, but it is already absent from
        // phase 2 onward, so the login header is the non-vacuous verdict. Both
        // are the `TeleportReadinessIOSUITests.swift:283` absence idiom, 3 s.
        XCTAssertTrue(
            app.staticTexts[Self.loginHeaderIdentifier].waitForNonExistence(timeout: 3),
            "the login sheet's header must be gone — the setup sheet must have dismissed"
        )
        XCTAssertTrue(
            app.staticTexts[Self.bootstrapHeaderIdentifier].waitForNonExistence(timeout: 3),
            "the setup sheet must have dismissed (its bootstrap header must be gone)"
        )
    }
}
