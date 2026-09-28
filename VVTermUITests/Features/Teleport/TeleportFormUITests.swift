// SPDX-License-Identifier: MIT
//
//  TeleportFormUITests.swift
//  VVTermUITests
//
//  XCUITests for the Teleport copy in the production `ServerFormSheet`,
//  presented by the DEBUG-only `TeleportFormUITestHarness` (add / edit mode).
//
//  Two launches cover every direction of the #265 gate:
//    - add mode starts on `.password`, so the pre-switch state IS the
//      non-Teleport case; after switching the Method picker to
//      Face ID (Teleport) the node-name caption appears and the
//      "re-runs Teleport setup" reminder must not (#265);
//    - edit mode on a seeded `.faceIDTeleport` row shows the reminder.
//
//  Launch-arg contract (parsed by TeleportFormUITestHarness+iOS.swift):
//    --vvterm-ui-test-teleport-form=add|edit
//
//  See:
//    - VVTerm/App/iOS/TeleportFormUITestHarness+iOS.swift (the harness)
//    - VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift (the form)
//

import XCTest

@MainActor
final class TeleportFormUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Form copy identifiers

    private static let authMethodPicker = "vvterm.teleport.form.authMethodPicker"
    private static let userHint = "vvterm.teleport.form.userHint"
    private static let userCaption = "vvterm.teleport.form.userCaption"
    private static let nodeNameCaption = "vvterm.teleport.form.nodeNameCaption"

    // MARK: - Launch

    /// Launch the app with the form harness in `mode` (`add` or `edit`). The
    /// standard args mirror `TeleportUITests.launch`: force English copy,
    /// skip the welcome sheet, and disable app lock + iCloud sync (the latter
    /// keeps the harness's `ServerManager` on local data only).
    private func launch(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-teleport-form=\(mode)",
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

    /// Waits for the harness root + the presented sheet and returns the form's
    /// scroll container. The root marker makes a mis-routed launch fail fast
    /// with a readable identifier instead of a navigation-bar timeout.
    private func waitForForm(in app: XCUIApplication, title: String) -> XCUIElement {
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.teleportFormHarness.root"].waitForExistence(timeout: 15),
            "the teleport-form harness root should appear (check the --vvterm-ui-test-teleport-form routing)"
        )
        XCTAssertTrue(
            app.navigationBars[title].waitForExistence(timeout: 10),
            "the '\(title)' sheet should be presented"
        )
        let collection = app.collectionViews.firstMatch
        if collection.waitForExistence(timeout: 10) {
            return collection
        }
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5), "the form's scroll container should exist")
        return table
    }

    // MARK: - Add mode (#265 gate + Teleport copy)

    /// Add mode starts on `.password` (`ServerFormSheet`'s default auth
    /// method), so the pre-switch assertions cover the non-Teleport case. After
    /// switching to Face ID (Teleport) the Teleport captions must appear and
    /// the "Changing the Teleport user or host re-runs Teleport setup on this
    /// device." reminder must NOT: a new server has no setup to re-run (#265).
    func testAddMode_faceIDTeleport_showsTeleportFieldCopy() {
        let app = launch(mode: "add")
        let form = waitForForm(in: app, title: "Add Server")

        // Non-Teleport (`.password`) form: the Method picker shows Password and
        // no Teleport copy exists yet.
        let picker = methodPicker(in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the Method picker should exist")
        assertSelectedAuthMethod("Password", picker: picker)
        XCTAssertFalse(
            app.descendants(matching: .any)[Self.userCaption].exists,
            "the setup reminder must not exist before Face ID (Teleport) is selected"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[Self.userHint].exists,
            "the Teleport-user hint must not exist on a non-Teleport form (#266)"
        )

        selectAuthMethod("Face ID (Teleport)", in: app, form: form)

        // Presence first, then absence: the node-name caption and the
        // reminder live in the same (first) section, so a lazily realized row
        // cannot make the absence assertion pass by accident.
        assertSelectedAuthMethod("Face ID (Teleport)", picker: picker)
        XCTAssertTrue(
            app.descendants(matching: .any)[Self.nodeNameCaption].waitForExistence(timeout: 5),
            "the node-name caption should appear for Face ID (Teleport)"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[Self.userHint].waitForExistence(timeout: 5),
            "the Teleport-user hint should appear for Face ID (Teleport) (#266)"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[Self.userCaption].exists,
            "the setup reminder must not show on first setup (#265)"
        )
    }

    // MARK: - Edit mode (#265 gate)

    /// Editing an existing `.faceIDTeleport` row keeps the reminder: this is
    /// the only case where changing the Teleport user or host really does
    /// re-run setup on this device. The Teleport-user hint shows in both modes
    /// (#266 acceptance: Add/Edit).
    func testEditMode_teleportServer_showsTeleportCaptions() {
        let app = launch(mode: "edit")
        let form = waitForForm(in: app, title: "Edit Server")

        let reminder = app.descendants(matching: .any)[Self.userCaption]
        scrollToVisible(reminder, in: form)
        XCTAssertTrue(reminder.exists, "the setup reminder should show when editing a Teleport server (#265)")
        XCTAssertTrue(
            app.descendants(matching: .any)[Self.userHint].exists,
            "the Teleport-user hint should show when editing a Teleport server (#266)"
        )

        XCTAssertTrue(
            app.descendants(matching: .any)[Self.nodeNameCaption].exists,
            "the node-name caption should show for a Teleport server"
        )
    }

    // MARK: - Auth-method picker

    private func methodPicker(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: Self.authMethodPicker).firstMatch
    }

    /// Asserts the picker's current value (its child static text —
    /// `AuthMethod.displayName`). Waits, because the row re-renders after a
    /// selection pops back.
    private func assertSelectedAuthMethod(
        _ expected: String,
        picker: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let value = picker.staticTexts.matching(NSPredicate(format: "label == %@", expected)).firstMatch
        XCTAssertTrue(
            value.waitForExistence(timeout: timeout),
            "the Method picker should show '\(expected)' (shows '\(picker.staticTexts.firstMatch.label)')",
            file: file,
            line: line
        )
    }

    /// Drives the Method picker (in the Authentication section, below the
    /// fold) to `displayName` (`AuthMethod.displayName`).
    private func selectAuthMethod(_ displayName: String, in app: XCUIApplication, form: XCUIElement) {
        let picker = methodPicker(in: app)
        scrollToVisible(picker, in: form)
        tapWhenHittable(picker)

        let option = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", displayName))
            .firstMatch
        XCTAssertTrue(
            option.waitForExistence(timeout: 5),
            "the '\(displayName)' option should appear after tapping the Method picker"
        )
        tapWhenHittable(option)
    }
}
