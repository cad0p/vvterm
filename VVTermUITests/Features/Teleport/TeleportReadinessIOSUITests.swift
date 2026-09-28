// SPDX-License-Identifier: MIT
//
//  TeleportReadinessIOSUITests.swift
//  VVTermUITests
//
//  Real XCUITests for the iOS Teleport "prompt-on-connect" flow (mockup B in
//  the 2.2 UI design doc) — the iOS server-list row → tap → sheet path.
//
//  Unlike `TeleportReadinessUITests` (which renders the macOS `ServerRow`
//  component on iOS), these tests render the REAL iOS `ServerListRow` via
//  the `TeleportIOSServerListUITestHarness`. This catches iOS-specific
//  regressions where the iOS row is missing the `onTeleportSetup` hook, the
//  readiness badge, or the tap routing.
//
//  Each test launches the app with the iOS server-list harness + a readiness
//  arg, taps the server row, and asserts which sheet (or terminal connect)
//  appears. The harness renders the real `ServerListRow` + replicates
//  `ServerListScreen`'s `teleportSetupSheet` routing so the tap → sheet path
//  is exercised end-to-end against a mock `TeleportKeyRing`.
//
//  Launch-arg contract (parsed by TeleportIOSServerListUITestHarness+iOS.swift):
//    --vvterm-ui-test-teleport-ios-serverlist          enables the harness
//    --vvterm-ui-test-teleport-readiness=ready|needsLogin|needsRegistration|needsBootstrap|crossDevice|swipeDismiss
//
//  See:
//    - VVTerm/App/iOS/TeleportIOSServerListUITestHarness+iOS.swift (the harness)
//    - VVTerm/App/iOS/ServerComponents+iOS.swift (ServerListRow + readiness badge)
//    - VVTerm/App/iOS/ServerListScreen+iOS.swift (teleportSetupSheet routing)
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup B)
//

import XCTest

@MainActor
final class TeleportReadinessIOSUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch helper

    /// Launch the app with the iOS server-list harness + the given readiness.
    private func launch(readiness: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-teleport-ios-serverlist",
            "--vvterm-ui-test-teleport-readiness=\(readiness)",
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
    /// Mirrors the helper in TeleportReadinessUITests.swift.
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

    // MARK: - The server row

    /// The harness renders a single `ServerListRow` with a fixed cluster ID.
    /// Its accessibility identifier is `vvterm.serverRow.<uuid>`.
    private func serverRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["vvterm.serverRow.00000000-0000-0000-0000-000000000001"]
    }

    /// Taps the server row once it is hittable (issue #47 — the row can
    /// exist in the AX tree before it finishes mounting; a tap that lands
    /// early misses it and no sheet appears). See tapWhenHittable.
    private func tapServerRow(in app: XCUIApplication) {
        tapWhenHittable(serverRow(app))
    }

    // MARK: - Tests (mockup B — 5 readiness scenarios, iOS row)

    // 1. needsBootstrap — empty keychain → amber "Setup" pill → tap → bootstrap sheet
    func testReadinessIOS_needsBootstrap_tapShowsBootstrapSheet() {
        let app = launch(readiness: "needsBootstrap")

        // The amber "Setup" pill should be visible.
        let setupPill = app.descendants(matching: .any)["vvterm.serverRow.readinessPill.setup"]
        if !setupPill.waitForExistence(timeout: 5) {
            // DEBUG: dump the full accessibility tree so CI logs reveal
            // whether ServerListRow rendered, whether the pill Text exists,
            // and what identifier/type it has.
            let tree = app.debugDescription
            let attachment = XCTAttachment(string: tree)
            attachment.name = "element-tree-ios-needsBootstrap"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("DEBUG_ELEMENT_TREE_ios_needsBootstrap:\n\(tree)")
        }
        XCTAssertTrue(setupPill.waitForExistence(timeout: 5), "amber 'Setup' pill should be visible for needsBootstrap")

        // Tap the row → the bootstrap sheet should appear.
        tapServerRow(in: app)
        let bootstrapHeader = app.staticTexts["vvterm.teleport.bootstrap.header"]
        XCTAssertTrue(bootstrapHeader.waitForExistence(timeout: 10), "bootstrap sheet header should appear after tapping a needsBootstrap row")
        XCTAssertEqual(bootstrapHeader.label, "Approve in Safari")
        attachScreenshot(app, named: "readiness-ios-needsBootstrap-bootstrap-sheet")
    }

    // 2. needsRegistration — cert but no SEP key → amber "Setup" pill → tap →
    //    bootstrap sheet (NOT registration). When a needsRegistration state is
    //    reached fresh (no in-memory BootstrapResult from a just-completed
    //    Phase 1), production falls back to re-bootstrapping because the
    //    Phase-1 TLS keypair is ephemeral and not persisted to the keychain.
    //    This test asserts the ACTUAL behavior for a fresh needsRegistration state.
    func testReadinessIOS_needsRegistration_tapShowsBootstrapSheetNotRegistration() {
        let app = launch(readiness: "needsRegistration")

        let setupPill = app.descendants(matching: .any)["vvterm.serverRow.readinessPill.setup"]
        XCTAssertTrue(setupPill.waitForExistence(timeout: 5), "amber 'Setup' pill should be visible for needsRegistration")

        tapServerRow(in: app)
        // The harness seeds needsRegistration with NO in-memory BootstrapResult
        // (simulating a fresh needsRegistration state). Production's fallback
        // re-bootstraps to regenerate the TLS keypair. Assert the ACTUAL behavior.
        let bootstrapHeader = app.staticTexts["vvterm.teleport.bootstrap.header"]
        XCTAssertTrue(bootstrapHeader.waitForExistence(timeout: 10), "needsRegistration with no in-memory result routes to bootstrap (production fallback)")
        XCTAssertEqual(bootstrapHeader.label, "Approve in Safari")

        // And the registration sheet should NOT appear (no BootstrapResult to
        // construct it from).
        let registrationContinue = app.buttons["vvterm.teleport.registration.continueButton"]
        XCTAssertFalse(registrationContinue.exists, "registration sheet should NOT appear for a fresh needsRegistration state")

        attachScreenshot(app, named: "readiness-ios-needsRegistration-bootstrap-fallback")
    }

    // 3. needsLogin — SEP key + expired cert → blue "Sign in" pill → tap → login sheet
    func testReadinessIOS_needsLogin_tapShowsLoginSheet() {
        let app = launch(readiness: "needsLogin")

        let signInPill = app.descendants(matching: .any)["vvterm.serverRow.readinessPill.signIn"]
        XCTAssertTrue(signInPill.waitForExistence(timeout: 5), "blue 'Sign in' pill should be visible for needsLogin")

        tapServerRow(in: app)
        let loginHeader = app.staticTexts["vvterm.teleport.login.header"]
        XCTAssertTrue(loginHeader.waitForExistence(timeout: 10), "login sheet header should appear after tapping a needsLogin row")
        XCTAssertEqual(loginHeader.label, "Sign in with Face ID")
        attachScreenshot(app, named: "readiness-ios-needsLogin-login-sheet")
    }

    // 4. ready — SEP key + valid cert → no badge → tap → connects directly
    //    (no Teleport sheet should appear).
    func testReadinessIOS_ready_tapConnectsDirectly() {
        let app = launch(readiness: "ready")

        // No readiness pill should be visible for a ready server.
        XCTAssertFalse(app.descendants(matching: .any)["vvterm.serverRow.readinessPill.setup"].exists, "no 'Setup' pill for ready server")
        XCTAssertFalse(app.descendants(matching: .any)["vvterm.serverRow.readinessPill.signIn"].exists, "no 'Sign in' pill for ready server")

        // Tap the row → the connect marker should appear (the harness wires
        // onTap to a visible "Connected" marker).
        tapServerRow(in: app)
        let connected = app.staticTexts["vvterm.teleport.serverlistHarness.connected"]
        XCTAssertTrue(connected.waitForExistence(timeout: 10), "ready server should connect directly (no Teleport sheet)")

        // And NO Teleport sheet header should appear.
        XCTAssertFalse(app.staticTexts["vvterm.teleport.bootstrap.header"].exists, "no bootstrap sheet for ready server")
        XCTAssertFalse(app.staticTexts["vvterm.teleport.login.header"].exists, "no login sheet for ready server")

        attachScreenshot(app, named: "readiness-ios-ready-connects-directly")
    }

    // 5. crossDevice (iCloud sync) — server record arrives via iCloud with an
    //    empty keychain → needsBootstrap → prompt-on-connect offers setup.
    func testReadinessIOS_crossDevice_iCloudSync_showsNeedsBootstrap() {
        let app = launch(readiness: "crossDevice")

        // An empty keychain (simulating a server record arriving via iCloud
        // on a fresh device) should resolve to needsBootstrap.
        let setupPill = app.descendants(matching: .any)["vvterm.serverRow.readinessPill.setup"]
        XCTAssertTrue(setupPill.waitForExistence(timeout: 5), "amber 'Setup' pill should be visible for crossDevice (empty keychain → needsBootstrap)")

        // Tapping should offer setup (bootstrap sheet).
        tapServerRow(in: app)
        let bootstrapHeader = app.staticTexts["vvterm.teleport.bootstrap.header"]
        XCTAssertTrue(bootstrapHeader.waitForExistence(timeout: 10), "bootstrap sheet should appear after tapping a crossDevice (needsBootstrap) row")
        XCTAssertEqual(bootstrapHeader.label, "Approve in Safari")
        attachScreenshot(app, named: "readiness-ios-crossDevice-needsBootstrap")
    }

    // MARK: - #272: swipe-down dismissal mid-retry tears the flow down

    /// A swipe-down dismissal of the bootstrap sheet must tear the in-flight
    /// retry down. The harness (`readiness=swipeDismiss`) owns the `.suspended`
    /// coordinator (30s delay) and renders its begin/cancel/retry counters
    /// OUTSIDE the sheet; before the fix `.onDisappear` only cancelled the
    /// retry task cooperatively, so `cancel` stayed 0 and the retry could keep
    /// driving the flow after the sheet was gone.
    func testBootstrap_swipeDismissDuringRetry_cancelsTheFlow() {
        let app = launch(readiness: "swipeDismiss")

        // The empty key ring must probe to needsBootstrap before the tap so
        // the row routes to setup rather than to connect.
        let setupPill = app.descendants(matching: .any)["vvterm.serverRow.readinessPill.setup"]
        XCTAssertTrue(setupPill.waitForExistence(timeout: 5), "empty keychain should show the Setup pill")

        // Tap the row → the bootstrap sheet appears with the mocked
        // `.suspended` coordinator (its first begin fails after 30s).
        tapServerRow(in: app)
        let bootstrapHeader = app.staticTexts["vvterm.teleport.bootstrap.header"]
        XCTAssertTrue(bootstrapHeader.waitForExistence(timeout: 10), "bootstrap sheet header should appear")

        let retryButton = app.buttons["vvterm.teleport.bootstrap.retryButton"]
        XCTAssertTrue(
            retryButton.waitForExistence(timeout: 40),
            "the suspended scenario should surface the Reopen Safari button"
        )

        let counters = app.staticTexts["vvterm.teleport.bootstrapDismissal.counters"]
        XCTAssertTrue(counters.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForCounter("begin=1", in: counters),
            "the first begin should be counted; counters=\(counters.label)"
        )

        // Start the retry, then swipe the sheet away while the retry's begin is
        // still inside its 30s delay.
        tapWhenHittable(retryButton)
        XCTAssertTrue(
            waitForCounter("retry=1", in: counters),
            "the retry should be counted; counters=\(counters.label)"
        )
        XCTAssertTrue(
            waitForCounter("begin=2", in: counters),
            "the retry's begin should be counted; counters=\(counters.label)"
        )

        // Dismiss the sheet interactively with a press-and-drag from its
        // content down to the bottom of the screen. This harness's presented
        // sheet is not exposed as a `Sheet` accessibility element on the iOS 26
        // runner (`app.sheets.firstMatch` stays empty while the sheet is on
        // screen), and a `swipeDown()` on a small element's frame is too short
        // to cross the interactive-dismissal threshold. A single synthesized
        // drag is occasionally not picked up by the presentation controller,
        // so attempt a bounded number of real drags, gated on the sheet
        // actually leaving; a sheet that never dismisses still fails.
        var dismissed = false
        for _ in 0..<3 where !dismissed {
            let dragStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
            dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
            dismissed = bootstrapHeader.waitForNonExistence(timeout: 3)
        }
        if !dismissed {
            // Dump the tree so CI logs reveal what still owns the screen.
            let tree = app.debugDescription
            let treeAttachment = XCTAttachment(string: tree)
            treeAttachment.name = "element-tree-swipeDismiss"
            treeAttachment.lifetime = .keepAlways
            add(treeAttachment)
            print("DEBUG_ELEMENT_TREE_swipeDismiss:\n\(tree)")
            attachScreenshot(app, named: "swipeDismiss-after-drag")
        }
        XCTAssertTrue(dismissed, "swipe-down should dismiss the bootstrap sheet")
        XCTAssertTrue(
            waitForCounter("cancel=1", in: counters),
            "the dismissal must tear the flow down (coordinator.cancel); counters=\(counters.label)"
        )

        // Bounded settle, then re-read the counters. This is a can't-fail
        // guard by construction — nothing in the mock can re-enter `begin`
        // after the swipe, and the mock's `try? await Task.sleep` swallows
        // cancellation, so it fast-forwards to a terminal state rather than
        // stopping. Its value is diagnostic: a counters line captured after
        // the settle shows whether the dismissal raced anything. The
        // discriminating assertion is `cancel=1` above, which only the
        // production `.onDisappear` can produce.
        let settleDeadline = Date().addingTimeInterval(2)
        while Date() < settleDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(
            counters.label.contains("begin=2"),
            "the mock must not re-enter begin after the dismissal; counters=\(counters.label)"
        )
        XCTAssertTrue(
            counters.label.contains("cancel=1"),
            "the dismissal cancel count should remain stable; counters=\(counters.label)"
        )

        attachScreenshot(app, named: "readiness-ios-swipeDismiss-counters")
    }

    /// Bounded poll for a counters-label substring. The label updates on the
    /// coordinator's `@Published` state, so this is a signal wait with a
    /// timeout that only bounds a genuine failure.
    private func waitForCounter(
        _ needle: String,
        in element: XCUIElement,
        timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(needle) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.label.contains(needle)
    }
}
