// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportReadinessUITests.swift
//  VVTermUITests
//
//  Real XCUITests for the Teleport "prompt-on-connect" flow (mockup B in the
//  2.2 UI design doc) — the server-list → tap → sheet path that the existing
//  18 TeleportUITests bypass by presenting sheets directly.
//
//  Each test launches the app with the TeleportServerListUITestHarness +
//  a readiness arg, taps the server row, and asserts which sheet (or terminal
//  connect) appears. The harness renders the real `ServerRow` + replicates
//  `ServerSidebarView`'s `teleportSetupSheet` routing so the tap → sheet path
//  is exercised end-to-end against a mock `TeleportKeyRing`.
//
//  Launch-arg contract (parsed by TeleportServerListUITestHarness+iOS.swift):
//    --vvterm-ui-test-teleport-serverlist                enables the harness
//    --vvterm-ui-test-teleport-readiness=ready|needsLogin|needsRegistration|needsBootstrap|crossDevice
//
//  See:
//    - VVTerm/App/iOS/TeleportServerListUITestHarness+iOS.swift (the harness)
//    - VVTerm/Core/UI/SidebarComponents.swift (ServerRow + readiness badge)
//    - VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift
//      (teleportSetupSheet routing — replicated by the harness)
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup B)
//

import XCTest

@MainActor
final class TeleportReadinessUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch helper

    /// Launch the app with the server-list harness + the given readiness.
    private func launch(readiness: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-teleport-serverlist",
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

    // MARK: - The server row

    /// The harness renders a single `ServerRow` with a fixed cluster ID.
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

    // MARK: - Tests (mockup B — 5 readiness scenarios)

    // 1. needsBootstrap — empty keychain → amber "Setup" pill → tap → bootstrap sheet
    func testReadiness_needsBootstrap_tapShowsBootstrapSheet() {
        let app = launch(readiness: "needsBootstrap")

        // The amber "Setup" pill should be visible.
        let setupPill = app.descendants(matching: .any)["vvterm.serverRow.readinessPill.setup"]
        if !setupPill.waitForExistence(timeout: 5) {
            // DEBUG: dump the full accessibility tree so CI logs reveal
            // whether ServerRow rendered, whether the pill Text exists, and
            // what identifier/type it has. The previous accessibility fixes
            // (1c848fd, 7bc8434, dcbe78b, 20c5164) all guessed without
            // seeing the tree; this stops the guessing.
            let tree = app.debugDescription
            let attachment = XCTAttachment(string: tree)
            attachment.name = "element-tree-needsBootstrap"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("DEBUG_ELEMENT_TREE_needsBootstrap:\n\(tree)")
        }
        XCTAssertTrue(setupPill.waitForExistence(timeout: 5), "amber 'Setup' pill should be visible for needsBootstrap")

        // Tap the row → the bootstrap sheet should appear.
        tapServerRow(in: app)
        let bootstrapHeader = app.staticTexts["vvterm.teleport.bootstrap.header"]
        XCTAssertTrue(bootstrapHeader.waitForExistence(timeout: 10), "bootstrap sheet header should appear after tapping a needsBootstrap row")
        XCTAssertEqual(bootstrapHeader.label, "Approve in Safari")
        attachScreenshot(app, named: "readiness-needsBootstrap-bootstrap-sheet")
    }

    // 2. needsRegistration — cert but no SEP key → amber "Setup" pill → tap →
    //    bootstrap sheet (NOT registration). When a needsRegistration state is
    //    reached fresh (no in-memory BootstrapResult from a just-completed
    //    Phase 1), production falls back to re-bootstrapping because the
    //    Phase-1 TLS keypair is ephemeral and not persisted to the keychain
    //    (see ServerSidebarView.swift teleportSetupSheet, needsRegistration
    //    case — the `else` fallback). The design doc (mockup B) says this
    //    should open the registration sheet directly; the in-memory phase-
    //    chaining fix only covers the just-bootstrapped case. This test
    //    asserts the ACTUAL behavior for a fresh needsRegistration state and
    //    flags the discrepancy with the design doc.
    func testReadiness_needsRegistration_tapShowsBootstrapSheetNotRegistration() {
        let app = launch(readiness: "needsRegistration")

        let setupPill = app.descendants(matching: .any)["vvterm.serverRow.readinessPill.setup"]
        XCTAssertTrue(setupPill.waitForExistence(timeout: 5), "amber 'Setup' pill should be visible for needsRegistration")

        tapServerRow(in: app)
        // The harness seeds needsRegistration with NO in-memory BootstrapResult
        // (simulating a fresh needsRegistration state, e.g. cert present but SEP
        // key absent on first tap). Production's fallback re-bootstraps to
        // regenerate the TLS keypair. Assert the ACTUAL behavior.
        let bootstrapHeader = app.staticTexts["vvterm.teleport.bootstrap.header"]
        XCTAssertTrue(bootstrapHeader.waitForExistence(timeout: 10), "needsRegistration with no in-memory result routes to bootstrap (production fallback)")
        XCTAssertEqual(bootstrapHeader.label, "Approve in Safari")

        // And the registration sheet should NOT appear (no BootstrapResult to
        // construct it from).
        let registrationContinue = app.buttons["vvterm.teleport.registration.continueButton"]
        XCTAssertFalse(registrationContinue.exists, "registration sheet should NOT appear for a fresh needsRegistration state")

        attachScreenshot(app, named: "readiness-needsRegistration-bootstrap-fallback")
    }

    // 3. needsLogin — SEP key + expired cert → blue "Sign in" pill → tap → login sheet
    func testReadiness_needsLogin_tapShowsLoginSheet() {
        let app = launch(readiness: "needsLogin")

        let signInPill = app.descendants(matching: .any)["vvterm.serverRow.readinessPill.signIn"]
        XCTAssertTrue(signInPill.waitForExistence(timeout: 5), "blue 'Sign in' pill should be visible for needsLogin")

        tapServerRow(in: app)
        let loginHeader = app.staticTexts["vvterm.teleport.login.header"]
        XCTAssertTrue(loginHeader.waitForExistence(timeout: 10), "login sheet header should appear after tapping a needsLogin row")
        XCTAssertEqual(loginHeader.label, "Sign in with Face ID")
        attachScreenshot(app, named: "readiness-needsLogin-login-sheet")
    }

    // 4. ready — SEP key + valid cert → no badge → tap → connects directly
    //    (no Teleport sheet should appear).
    func testReadiness_ready_tapConnectsDirectly() {
        let app = launch(readiness: "ready")

        // No readiness pill should be visible for a ready server.
        XCTAssertFalse(app.descendants(matching: .any)["vvterm.serverRow.readinessPill.setup"].exists, "no 'Setup' pill for ready server")
        XCTAssertFalse(app.descendants(matching: .any)["vvterm.serverRow.readinessPill.signIn"].exists, "no 'Sign in' pill for ready server")

        // Tap the row → the connect marker should appear (the harness wires
        // onConnect/onSelect to a visible "Connected" marker).
        tapServerRow(in: app)
        let connected = app.staticTexts["vvterm.teleport.serverlistHarness.connected"]
        XCTAssertTrue(connected.waitForExistence(timeout: 10), "ready server should connect directly (no Teleport sheet)")

        // And NO Teleport sheet header should appear.
        XCTAssertFalse(app.staticTexts["vvterm.teleport.bootstrap.header"].exists, "no bootstrap sheet for ready server")
        XCTAssertFalse(app.staticTexts["vvterm.teleport.login.header"].exists, "no login sheet for ready server")

        attachScreenshot(app, named: "readiness-ready-connects-directly")
    }

    // 5. crossDevice (iCloud sync) — server record arrives via iCloud with an
    //    empty keychain → needsBootstrap → prompt-on-connect offers setup.
    func testReadiness_crossDevice_iCloudSync_showsNeedsBootstrap() {
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
        attachScreenshot(app, named: "readiness-crossDevice-needsBootstrap")
    }
}
