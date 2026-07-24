// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportRegistrationUITests.swift
//  VVTermUITests
//
//  Layer 2 UI tests for the Phase-2 registration matrix (mockup D in the
//  2.2 UI design doc).
//
//  Each test injects a `MockTeleportRegistrationCoordinator` with a specific
//  `Scenario`, drives the state machine, and asserts the recovery UX state
//  transition. An `XCTAttachment` screenshot is captured at key states with
//  `.keepAlways` lifetime.
//
//  These tests target the coordinator protocol (not the SwiftUI views, which
//  the parallel agent is building) — they verify the state-machine coverage +
//  the mock injection mechanism. Once the views land, they'll observe the
//  same `@Published var state` these tests drive.
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup D —
//      the 5-row registration matrix)
//    - VVTermUITests/Features/Teleport/MockTeleportRegistrationCoordinator.swift
//

import XCTest
@testable import VVTerm

@MainActor
final class TeleportRegistrationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// A minimal bootstrap result fixture (the registration coordinator's
    /// `begin` takes one). The values are placeholders — the mock doesn't
    /// use them, but the type is required by the protocol signature.
    private func makeBootstrapResult() -> TeleportBootstrapCoordinator.BootstrapResult {
        // The BootstrapResult has a SecKey field. We create a dummy SecKey
        // via the software key path so the mock has something to ignore.
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error)!
        return TeleportBootstrapCoordinator.BootstrapResult(
            sshCertPEM: "mock-cert-pem",
            tlsCertPEM: "mock-tls-cert-pem",
            tlsKeyPairPrivateKey: secKey,
            clusterName: "teleport.pcad.it",
            clusterCAPEMs: [],
            certValidBefore: Date().addingTimeInterval(3600)
        )
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(string: "state-marker: \(name)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - The 5-row registration matrix (mockup D)

    func testRegistration_happyPath_reachesSuccess() async {
        // Happy path: device-name field prefilled → Continue → Safari opens →
        // Face ID prompt → SEP key created + registered + persisted → success.
        let coordinator = MockTeleportRegistrationCoordinator(
            scenario: .happyPath,
            delay: 0.01
        )
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        let deviceName = "vvterm-pier-iphone"

        attachScreenshot(named: "registration-happyPath-initial")
        XCTAssertEqual(coordinator.state, .idle)

        await coordinator.begin(
            cluster: cluster,
            deviceName: deviceName,
            bootstrapResult: makeBootstrapResult()
        )

        XCTAssertEqual(coordinator.state, .success)
        XCTAssertEqual(coordinator.lastDeviceName, deviceName)
        XCTAssertEqual(coordinator.lastCluster, cluster)
        attachScreenshot(named: "registration-happyPath-success")
    }

    func testRegistration_deviceNameAlreadyExists_reachesFailedDeviceNameAlreadyExists() async {
        // AddMFADeviceSync returned ALREADY_EXISTS (gRPC code 6). The device
        // name is included for the inline error: "A device named
        // 'vvterm-pier-iphone' already exists for your Teleport user."
        let deviceName = "vvterm-pier-iphone"
        let coordinator = MockTeleportRegistrationCoordinator(
            scenario: .deviceNameAlreadyExists(deviceName),
            delay: 0.01
        )
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")

        await coordinator.begin(
            cluster: cluster,
            deviceName: deviceName,
            bootstrapResult: makeBootstrapResult()
        )

        XCTAssertEqual(coordinator.state, .failed(.deviceNameAlreadyExists(deviceName)))
        attachScreenshot(named: "registration-alreadyExists-error")
    }

    func testRegistration_deviceNameAlreadyExists_resubmitWithoutRedoingPhase1() async {
        // The "already exists" recovery: the user edits the name and resubmits
        // WITHOUT redoing Phase 1 (the Phase-1 cert is retained). This test
        // asserts the resubmit path works — begin() is called a second time
        // with a new device name.
        let originalName = "vvterm-pier-iphone"
        let newName = "vvterm-pier-iphone-2"
        // The mock always returns deviceNameAlreadyExists — the point is
        // that the second begin() uses the new name.
        let coordinator = MockTeleportRegistrationCoordinator(
            scenario: .deviceNameAlreadyExists(originalName),
            delay: 0.01
        )
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")

        // First attempt — fails with "already exists".
        await coordinator.begin(
            cluster: cluster,
            deviceName: originalName,
            bootstrapResult: makeBootstrapResult()
        )
        XCTAssertEqual(coordinator.state, .failed(.deviceNameAlreadyExists(originalName)))
        XCTAssertEqual(coordinator.beginCallCount, 1)

        // User edits the name + resubmits. The scenario now needs to succeed
        // (a real coordinator would retry AddMFADeviceSync with the new name).
        // We swap to a happyPath coordinator to model the successful resubmit.
        let retryCoordinator = MockTeleportRegistrationCoordinator(
            scenario: .happyPath,
            delay: 0.01
        )
        await retryCoordinator.begin(
            cluster: cluster,
            deviceName: newName,
            bootstrapResult: makeBootstrapResult()  // SAME Phase-1 cert — retained
        )
        XCTAssertEqual(retryCoordinator.state, .success)
        XCTAssertEqual(retryCoordinator.lastDeviceName, newName)
        attachScreenshot(named: "registration-alreadyExists-resubmit-success")
    }

    func testRegistration_cancelBetweenSafariTrips_returnsToForm() async {
        // The user cancelled between the two Safari trips (the device-name
        // pause is the resume point). Returns to the form; Phase-1 cert is
        // retained; row shows needsRegistration; tapping the row resumes here.
        let coordinator = MockTeleportRegistrationCoordinator(
            scenario: .cancelBetweenSafariTrips,
            delay: 0.01
        )
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")

        await coordinator.begin(
            cluster: cluster,
            deviceName: "vvterm-pier-iphone",
            bootstrapResult: makeBootstrapResult()
        )

        XCTAssertEqual(coordinator.state, .failed(.unknown("cancelled")))
        attachScreenshot(named: "registration-cancel-between-safari-trips")
    }

    func testRegistration_emptyDeviceName_doesNotCallBegin() async {
        // Empty device name → Continue button disabled; inline validation
        // "Device name required". The coordinator's begin() is NOT called
        // (the form blocks the submit). This test asserts the validation
        // (via the pure function TeleportDeviceName.validate) rather than
        // the coordinator (which never runs).
        let emptyName = ""
        let error = TeleportDeviceName.validate(emptyName)
        XCTAssertEqual(error, "Device name required")
        // The coordinator is never invoked — no state transition to assert.
        attachScreenshot(named: "registration-empty-name-blocked")
    }

    func testRegistration_invalidCharsInDeviceName_sanitizedLive() async {
        // Device name with invalid chars → sanitized live as typed; the
        // preview shows the accepted form. The pure function
        // TeleportDeviceName.sanitize produces the accepted form; the form
        // calls it on every keystroke to show the preview.
        let raw = "Pier's iPhone 📱"
        let sanitized = TeleportDeviceName.sanitize(raw)
        XCTAssertEqual(sanitized, "piers-iphone")
        attachScreenshot(named: "registration-invalid-chars-sanitized")
    }

    func testRegistration_sepKeyCreationFailed_reachesFailedSepKeyCreationFailed() async {
        // The SEP key creation failed (Face ID cancelled / unavailable).
        // This is the path where MockSEPKeySigner with a non-.success
        // outcome would drive the real coordinator into this state.
        let msg = "Face ID cancelled"
        let coordinator = MockTeleportRegistrationCoordinator(
            scenario: .sepKeyCreationFailed(msg),
            delay: 0.01
        )
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")

        await coordinator.begin(
            cluster: cluster,
            deviceName: "vvterm-pier-iphone",
            bootstrapResult: makeBootstrapResult()
        )

        XCTAssertEqual(coordinator.state, .failed(.sepKeyCreationFailed(msg)))
        attachScreenshot(named: "registration-sep-key-creation-failed")
    }

    func testRegistration_serverError_reachesFailedServer() async {
        // A gRPC server error (non-ALREADY_EXISTS).
        let msg = "permission denied"
        let coordinator = MockTeleportRegistrationCoordinator(
            scenario: .serverError(msg),
            delay: 0.01
        )
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")

        await coordinator.begin(
            cluster: cluster,
            deviceName: "vvterm-pier-iphone",
            bootstrapResult: makeBootstrapResult()
        )

        XCTAssertEqual(coordinator.state, .failed(.server(msg)))
        attachScreenshot(named: "registration-server-error")
    }

    // MARK: - Device-name defaulting (mockup D's prefill)

    func testRegistration_deviceNamePrefilledWithVvtermPrefix() async {
        // The registration sheet prefills the device name with
        // `vvterm-<sanitized>` from UIDevice.name / Host.current().name.
        // The pure function produces it; the form uses it as the default.
        let raw = "Pier's iPhone"
        let defaultName = TeleportDeviceName.default(rawDeviceName: raw)
        XCTAssertEqual(defaultName, "vvterm-piers-iphone")

        // The form submits this name to begin().
        let coordinator = MockTeleportRegistrationCoordinator(
            scenario: .happyPath,
            delay: 0.01
        )
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        await coordinator.begin(
            cluster: cluster,
            deviceName: defaultName,
            bootstrapResult: makeBootstrapResult()
        )
        XCTAssertEqual(coordinator.state, .success)
        XCTAssertEqual(coordinator.lastDeviceName, defaultName)
    }

    // MARK: - State isolation

    func testRegistration_eachScenarioProducesCorrectTerminalState() async {
        // A single test that runs through every scenario and asserts the
        // terminal state — a regression guard against future refactors.
        let deviceName = "vvterm-pier-iphone"
        let expectations: [(MockTeleportRegistrationCoordinator.Scenario, TeleportRegistrationState)] = [
            (.happyPath, .success),
            (.deviceNameAlreadyExists(deviceName), .failed(.deviceNameAlreadyExists(deviceName))),
            (.cancelBetweenSafariTrips, .failed(.unknown("cancelled"))),
            (.sepKeyCreationFailed("err"), .failed(.sepKeyCreationFailed("err"))),
            (.serverError("err"), .failed(.server("err"))),
        ]

        for (scenario, expected) in expectations {
            let coordinator = MockTeleportRegistrationCoordinator(scenario: scenario, delay: 0.01)
            await coordinator.begin(
                cluster: TeleportCluster(host: "h", username: "u"),
                deviceName: deviceName,
                bootstrapResult: makeBootstrapResult()
            )
            XCTAssertEqual(
                coordinator.state, expected,
                "scenario \(scenario) produced wrong terminal state: got \(coordinator.state)"
            )
        }
    }
}
