// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  MockTeleportLoginCoordinator.swift
//  VVTermUITests
//
//  A mock `TeleportLoginCoordinating` implementation for UI tests.
//
//  Scripts the Phase-3 login state machine for the 5-row matrix in mockup E,
//  including the Face ID outcomes (which are also assertable via the injected
//  `MockSEPKeySigner`):
//    - happyPath(certTTL:) → .success(certValidUntil:) → "Certificate valid for …"
//    - certExpiredOnTap → flows through login, shows new TTL
//    - faceIDCancelled → .failed(.faceIDCancelled) → "Face ID cancelled."
//    - faceIDUnavailable(reason) → .failed(.faceIDUnavailable(msg)) → "Face ID
//      isn't available. Set up Face ID in iOS Settings."
//    - serverUnreachable → .failed(.networkLost) → "Couldn't reach Teleport."
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup E —
//      the login matrix incl. Face ID outcomes)
//    - VVTerm/Features/Teleport/Application/TeleportLoginCoordinator.swift
//      (the protocol + real coordinator)
//

import Foundation
@testable import VVTerm

/// A mock Phase-3 login coordinator that scripts state transitions based on
/// a `Scenario`. Used by `TeleportLoginUITests` to assert the recovery UX
/// for every case in mockup E, including the Face ID outcomes.
@MainActor
final class MockTeleportLoginCoordinator: ObservableObject, TeleportLoginCoordinating {
    /// The scripted login scenario.
    enum Scenario: Equatable {
        /// Happy path: Face ID succeeds, cert issued. The `certValidUntil`
        /// drives the "Certificate valid for …" copy.
        /// - Parameter certTTL: the cert TTL in seconds (12h = 43200, 1h = 3600).
        ///   Proves the TTL is dynamic (read from the cert, not hardcoded).
        case happyPath(certTTL: TimeInterval)
        /// The cert was already expired when the user tapped → flows through
        /// login, shows the new TTL (same as happyPath after refresh).
        case certExpiredOnTap(certTTL: TimeInterval)
        /// The user cancelled the Face ID prompt (LAError.userCancel).
        /// → .failed(.faceIDCancelled) → "Face ID cancelled. Tap to try again."
        case faceIDCancelled
        /// Face ID isn't available (not enrolled / locked out).
        /// → .failed(.faceIDUnavailable(reason)) → "Face ID isn't available…"
        case faceIDUnavailable(String)
        /// The Teleport server was unreachable on /begin.
        /// → .failed(.networkLost) → "Couldn't reach Teleport. Tap to retry."
        case serverUnreachable
    }

    /// The number of times `begin` was called.
    private(set) var beginCallCount = 0

    /// The number of times `cancel` was called.
    private(set) var cancelCallCount = 0

    /// The last cluster passed to `begin`.
    private(set) var lastCluster: TeleportCluster?

    /// The `certValidUntil` from the most recent `.success` state. Used by
    /// UI tests to assert the dynamic TTL (12h vs 1h).
    private(set) var lastCertValidUntil: Date?

    @Published private(set) var state: TeleportLoginState = .idle

    private let scenario: Scenario
    private let delay: TimeInterval

    init(scenario: Scenario, delay: TimeInterval = 0.05) {
        self.scenario = scenario
        self.delay = delay
    }

    func begin(cluster: TeleportCluster) async {
        beginCallCount += 1
        lastCluster = cluster
        state = .idle
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        switch scenario {
        case .happyPath(let ttl), .certExpiredOnTap(let ttl):
            state = .awaitingFaceID
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            state = .fetchingCert
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let validUntil = Date().addingTimeInterval(ttl)
            lastCertValidUntil = validUntil
            state = .success(certValidUntil: validUntil)
        case .faceIDCancelled:
            state = .awaitingFaceID
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            state = .failed(.faceIDCancelled)
        case .faceIDUnavailable(let reason):
            state = .awaitingFaceID
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            state = .failed(.faceIDUnavailable(reason))
        case .serverUnreachable:
            state = .fetchingCert
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            state = .failed(.networkLost)
        }
    }

    func cancel() async {
        cancelCallCount += 1
        state = .failed(.faceIDCancelled)
    }
}
