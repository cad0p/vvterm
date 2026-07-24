// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  MockTeleportRegistrationCoordinator.swift
//  VVTermUITests
//
//  A mock `TeleportRegistrationCoordinating` implementation for UI tests.
//
//  Scripts the Phase-2 registration state machine for the 5-row matrix in
//  mockup D:
//    - happyPath → success (SEP key created + registered + persisted)
//    - deviceNameAlreadyExists → .failed(.deviceNameAlreadyExists(name)) →
//      inline error, name re-focusable, resubmit without redoing Phase 1
//    - cancelBetweenSafariTrips → .failed(.unknown("cancelled")) → returns
//      to form, Phase-1 cert retained, row shows needsRegistration
//    - sepKeyCreationFailed → .failed(.sepKeyCreationFailed(msg)) → Face ID
//      failure surfaces (used in conjunction with MockSEPKeySigner)
//    - serverError → .failed(.server(msg)) → server message verbatim
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup D —
//      the registration matrix)
//    - VVTerm/Features/Teleport/Application/TeleportRegistrationCoordinator.swift
//      (the protocol + real coordinator)
//

import Foundation
@testable import VVTerm

/// A mock Phase-2 registration coordinator that scripts state transitions
/// based on a `Scenario`. Used by `TeleportRegistrationUITests` to assert
/// the recovery UX for every case in mockup D.
@MainActor
final class MockTeleportRegistrationCoordinator: ObservableObject, TeleportRegistrationCoordinating {
    /// The scripted registration scenario.
    enum Scenario: Equatable {
        /// The SEP key is created + registered + persisted → success.
        case happyPath
        /// AddMFADeviceSync returned ALREADY_EXISTS (gRPC code 6). The device
        /// name is included for the inline error.
        /// → .failed(.deviceNameAlreadyExists(name)) → inline error,
        ///   name re-focusable, resubmit without redoing Phase 1.
        case deviceNameAlreadyExists(String)
        /// The user cancelled between the two Safari trips (the device-name
        /// pause is the resume point).
        /// → .failed(.unknown("cancelled")) → returns to form.
        case cancelBetweenSafariTrips
        /// The SEP key creation failed (Face ID cancelled / unavailable).
        /// → .failed(.sepKeyCreationFailed(msg)).
        case sepKeyCreationFailed(String)
        /// A gRPC server error (non-ALREADY_EXISTS).
        /// → .failed(.server(msg)).
        case serverError(String)
    }

    /// The number of times `begin` was called.
    private(set) var beginCallCount = 0

    /// The number of times `cancel` was called.
    private(set) var cancelCallCount = 0

    /// The last device name passed to `begin`. Used to assert the form
    /// submitted the sanitized name.
    private(set) var lastDeviceName: String?

    /// The last cluster passed to `begin`.
    private(set) var lastCluster: TeleportCluster?

    @Published private(set) var state: TeleportRegistrationState = .idle

    private let scenario: Scenario
    private let delay: TimeInterval

    init(scenario: Scenario, delay: TimeInterval = 0.05) {
        self.scenario = scenario
        self.delay = delay
    }

    func begin(
        cluster: TeleportCluster,
        deviceName: String,
        bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult
    ) async {
        beginCallCount += 1
        lastCluster = cluster
        lastDeviceName = deviceName
        state = .connectingGRPC
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        state = .awaitingExistingAssertion
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        state = .creatingSEPKey
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        state = .registeringWithServer
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        switch scenario {
        case .happyPath:
            state = .success
        case .deviceNameAlreadyExists(let name):
            state = .failed(.deviceNameAlreadyExists(name))
        case .cancelBetweenSafariTrips:
            state = .failed(.unknown("cancelled"))
        case .sepKeyCreationFailed(let msg):
            state = .failed(.sepKeyCreationFailed(msg))
        case .serverError(let msg):
            state = .failed(.server(msg))
        }
    }

    func cancel() async {
        cancelCallCount += 1
        state = .failed(.unknown("cancelled"))
    }
}
