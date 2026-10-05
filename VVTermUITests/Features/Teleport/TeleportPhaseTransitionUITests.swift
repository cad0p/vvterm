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

    // MARK: - Helpers

    /// The harness renders a single `ServerRow` with a fixed cluster ID.
    private func serverRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["vvterm.serverRow.00000000-0000-0000-0000-000000000001"]
    }

    /// Bounded hittability wait, so a mounted-but-untappable control during
    /// the sheet presentation cannot false-red the assertion (the
    /// NoticePresentationUITests / ServerNavigationUITests idiom).
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Bounded poll for a counters/readiness label substring. The label
    /// re-renders on the parent-owned coordinator's `@Published` state, so
    /// this is a signal wait whose timeout only bounds a genuine failure.
    private func waitForLabel(
        _ needle: String,
        in element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", needle),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
        // already carries, 85421b53).
        let setupPill = app.descendants(matching: .any)["vvterm.serverRow.readinessPill.setup"]
        XCTAssertTrue(setupPill.waitForExistence(timeout: 5), "amber 'Setup' pill should be visible for needsBootstrap")

        // Tap the row → the bootstrap sheet should appear.
        serverRow(app).tap()

        // The harness's mock holds `.awaitingApproval` until the release
        // control is tapped (issue #277) — the control's existence is the
        // gate-engaged signal, so the header below is a stable state, not a
        // ~100 ms transient.
        let releaseControl = app.buttons["vvterm.teleport.phaseChainHarness.releaseBootstrapApproval"]
        XCTAssertTrue(
            releaseControl.waitForExistence(timeout: 5),
            "bootstrap gate's release control should appear in .awaitingApproval"
        )
        XCTAssertTrue(waitForHittable(releaseControl), "release control must be hittable")

        let bootstrapHeader = app.staticTexts["vvterm.teleport.bootstrap.header"]
        XCTAssertTrue(bootstrapHeader.waitForExistence(timeout: 5), "bootstrap sheet header should appear after tapping a needsBootstrap row")
        XCTAssertEqual(bootstrapHeader.label, "Approve in Safari")
        attachScreenshot(app, named: "phaseChain-1-bootstrap-sheet")

        // Persistence proof: after the header read the gate is still held, so
        // the header was not caught by luck.
        XCTAssertTrue(
            releaseControl.exists && waitForHittable(releaseControl),
            "the gate must still hold after the header read"
        )

        tapWhenHittable(releaseControl)

        // The mock bootstrap coordinator (happyPath) succeeds once released.
        // The bootstrap sheet's `onSuccess` stores the result and flips
        // readiness to `.needsRegistration`, which re-renders the sheet as
        // `TeleportRegistrationView`. Wait for the registration form's
        // Continue button to appear — that's the phase-2 marker.
        let registrationContinue = app.buttons["vvterm.teleport.registration.continueButton"]
        XCTAssertTrue(
            registrationContinue.waitForExistence(timeout: 8),
            "registration sheet (Continue button) should appear after bootstrap succeeds — this is the phase 1→2 transition that was broken"
        )

        // The bootstrap sheet should be GONE (the success copy must not
        // linger — the sheet re-rendered as registration, not stacked).
        XCTAssertFalse(
            app.staticTexts["vvterm.teleport.bootstrap.success"].exists,
            "bootstrap success copy should not persist — the sheet should have transitioned to registration"
        )

        // The "Signed in to Teleport" row (phase-1-complete section of the
        // registration sheet) confirms we're on phase 2.
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

        serverRow(app).tap()

        // Gate-held bootstrap phase: the release control exists exactly while
        // the mock is parked in `.awaitingApproval` (issue #277).
        let releaseControl = app.buttons["vvterm.teleport.phaseChainHarness.releaseBootstrapApproval"]
        XCTAssertTrue(releaseControl.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(releaseControl))

        let bootstrapHeader = app.staticTexts["vvterm.teleport.bootstrap.header"]
        XCTAssertTrue(bootstrapHeader.waitForExistence(timeout: 5))

        // Persistence proof: the gate is still holding after the header read.
        XCTAssertTrue(releaseControl.exists && waitForHittable(releaseControl))

        tapWhenHittable(releaseControl)

        // Wait for the registration sheet.
        let registrationContinue = app.buttons["vvterm.teleport.registration.continueButton"]
        XCTAssertTrue(registrationContinue.waitForExistence(timeout: 8))

        // The bootstrap header must be gone (not re-presented).
        XCTAssertFalse(
            bootstrapHeader.exists,
            "bootstrap header should NOT reappear — the needsRegistration path must present registration, not re-run bootstrap"
        )
        // The namesake no-re-run property: the parent-owned coordinator counts
        // `begin` calls and the harness renders the count outside the sheet, so
        // it survives the bootstrap → registration swap. A second (fallback)
        // bootstrap would increment it to 2.
        let bootstrapBeginsLabel = app.staticTexts["vvterm.teleport.phaseChainHarness.bootstrapBegins"]
        XCTAssertTrue(
            bootstrapBeginsLabel.waitForExistence(timeout: 5),
            "the harness bootstrapBegins label should be visible after the transition"
        )
        XCTAssertTrue(
            waitForLabel("bootstrapBegins: 1", in: bootstrapBeginsLabel),
            "bootstrap must run exactly once — a second (fallback) bootstrap would increment the count; label was \(bootstrapBeginsLabel.label)"
        )

        attachScreenshot(app, named: "phaseChain-no-bootstrap-rerun")
    }

    // MARK: - Phase 2 → Phase 3 transition

    /// After registration succeeds (Continue tapped, mock returns success),
    /// the login sheet (phase 3) appears. This verifies the full chain.
    func testPhase2RegistrationSuccess_transitionsToLoginSheet() {
        let app = launch()

        serverRow(app).tap()

        // Wait for the release control (the mock parks in `.awaitingApproval`)
        // — its presence is this test's bootstrap-phase proof.
        let releaseControl = app.buttons["vvterm.teleport.phaseChainHarness.releaseBootstrapApproval"]
        XCTAssertTrue(releaseControl.waitForExistence(timeout: 5), "bootstrap gate's release control should appear")
        XCTAssertTrue(waitForHittable(releaseControl))
        tapWhenHittable(releaseControl)

        // Wait for the registration sheet (phase 1 succeeds after release).
        let registrationContinue = app.buttons["vvterm.teleport.registration.continueButton"]
        XCTAssertTrue(registrationContinue.waitForExistence(timeout: 8))

        // Tap Continue → the mock registration coordinator (happyPath)
        // succeeds, firing `onSuccess` which flips readiness to
        // `.needsLogin` → the login sheet appears.
        registrationContinue.tap()

        // The login sheet's "Sign in with Face ID" button is the phase-3
        // marker (the login sheet starts in .idle and requires a tap).
        let signInButton = app.buttons["vvterm.teleport.login.signInButton"]
        XCTAssertTrue(
            signInButton.waitForExistence(timeout: 8),
            "login sheet (Sign in button) should appear after registration succeeds — this is the phase 2→3 transition"
        )

        // The registration Continue button must be gone.
        XCTAssertFalse(
            registrationContinue.exists,
            "registration sheet should NOT persist — it should have transitioned to login"
        )

        // Tap Sign in → the mock login coordinator (happyPath) succeeds and
        // the host-login step appears with a Continue button.
        XCTAssertTrue(waitForHittable(signInButton), "Sign in button must be hittable")
        signInButton.tap()
        let loginContinue = app.buttons["vvterm.teleport.login.continueButton"]
        XCTAssertTrue(
            loginContinue.waitForExistence(timeout: 8),
            "the host-login step (Continue button) should appear after Face ID succeeds"
        )
        attachScreenshot(app, named: "phaseChain-3-login-hostLogin")

        // Continue persists the host login (no-op in the harness) and the
        // shared sheet's login success calls `onFinish`, dismissing the sheet.
        //
        // `signInButton` renders only in login `.idle` and disappears as soon
        // as the coordinator leaves it, so its absence is NOT a dismissal
        // signal. Assert the host-login step is gone AND the harness row is
        // interactive again: the sheet must actually dismiss.
        XCTAssertTrue(waitForHittable(loginContinue), "host-login Continue must be hittable")
        loginContinue.tap()

        XCTAssertTrue(
            loginContinue.waitForNonExistence(timeout: 8),
            "the host-login step should be gone after Continue — login success must finish the chain"
        )
        XCTAssertTrue(
            waitForHittable(serverRow(app)),
            "the harness row must be hittable again — the setup sheet must have dismissed"
        )
    }
}
