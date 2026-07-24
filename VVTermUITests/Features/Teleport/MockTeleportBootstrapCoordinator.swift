// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  MockTeleportBootstrapCoordinator.swift
//  VVTermUITests
//
//  A mock `TeleportBootstrapCoordinating` implementation for UI tests.
//
//  This is the key enabler for the bootstrap error-recovery matrix (mockup C
//  in the 2.2 UI design doc). Each `Scenario` produces a deterministic state
//  transition — no real Safari, no real Teleport server, no real blocking POST.
//
//  The mock drives the same state machine as the real
//  `TeleportBootstrapCoordinator` (idle → preparing → openingSafari →
//  awaitingApproval → success/failed), so UI tests can assert the recovery UX
//  for every failure case:
//    - userCancelsInSafari → .failed(.userCancelled) → "Setup cancelled. Tap retry."
//    - timeout → .failed(.timeout) → "Safari approval timed out."
//    - networkLost → .failed(.networkLost) → "Network connection lost."
//    - suspended → .failed(.suspended) → "Reconnecting…" then success on retry
//    - safariUnavailable → .failed(.safariUnavailable) → "Open Safari manually:" + URL
//    - serverError → .failed(.server(msg)) → server message verbatim
//    - happyPath / alreadyLoggedIn → .success → advances to registration
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup C —
//      the 7-row bootstrap matrix)
//    - VVTerm/Features/Teleport/Application/TeleportBootstrapCoordinator.swift
//      (the protocol + real coordinator)
//

import Foundation
@testable import VVTerm

/// A mock Phase-1 bootstrap coordinator that scripts state transitions
/// based on a `Scenario`. Used by `TeleportBootstrapUITests` to assert the
/// recovery UX for every failure case in mockup C.
@MainActor
final class MockTeleportBootstrapCoordinator: ObservableObject, TeleportBootstrapCoordinating {
    /// The scripted bootstrap scenario. Each maps to a specific recovery UX.
    enum Scenario: Equatable {
        /// The user approves in Safari → POST returns with a cert → success.
        /// Advances to the registration sheet.
        case happyPath
        /// The user was already logged in elsewhere → POST returns immediately
        /// with a cert → silent success (same UX as happyPath).
        case alreadyLoggedIn
        /// The user cancelled in Safari (ASWebAuthenticationSessionError).
        /// → .failed(.userCancelled) → "Setup cancelled. Tap retry."
        case userCancelsInSafari
        /// The 180s server-side timeout fired (POST returned with no cert).
        /// → .failed(.timeout) → "Safari approval timed out. Tap retry."
        case timeout
        /// The URLSession failed (no connection / timeout / DNS).
        /// → .failed(.networkLost) → "Network connection lost. Tap retry."
        case networkLost
        /// The app was backgrounded mid-POST → suspended. On retry → success.
        /// → .failed(.suspended) → "Reconnecting…" then .success on retry.
        case suspended
        /// ASWebAuthenticationSession.start() returned false (Safari disabled).
        /// → .failed(.safariUnavailable) → "Open Safari manually:" + URL.
        case safariUnavailable
        /// The Teleport server returned a non-2xx status. The message is
        /// surfaced verbatim.
        /// → .failed(.server(msg)) → server message + Retry.
        case serverError(String)
    }

    /// The number of times `begin` was called. Used to assert retry behavior
    /// (e.g. the suspended scenario succeeds on the second call).
    private(set) var beginCallCount = 0

    /// The number of times `cancel` was called.
    private(set) var cancelCallCount = 0

    /// The number of times `retry` was called.
    private(set) var retryCallCount = 0

    /// The last cluster passed to `begin`. Used to assert the coordinator
    /// received the right cluster config.
    private(set) var lastCluster: TeleportCluster?

    @Published private(set) var state: TeleportBootstrapState = .idle

    /// The Phase-1 result, set when the scenario reaches `.success`. The
    /// protocol exposes this so the bootstrap view can pass it to the
    /// registration view without casting to the concrete type. `nil` for
    /// all non-success scenarios.
    private(set) var lastBootstrapResult: TeleportBootstrapCoordinator.BootstrapResult?

    private let scenario: Scenario
    private let delay: TimeInterval

    init(scenario: Scenario, delay: TimeInterval = 0.05) {
        self.scenario = scenario
        self.delay = delay
    }

    func begin(cluster: TeleportCluster) async {
        beginCallCount += 1
        lastCluster = cluster
        state = .preparing
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        // The suspended scenario succeeds on the second begin() (retry).
        if scenario == .suspended && beginCallCount == 1 {
            state = .failed(.suspended)
            return
        }

        state = .openingSafari
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        state = .awaitingApproval
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        switch scenario {
        case .happyPath, .alreadyLoggedIn:
            // Build a minimal bootstrap result so the view's `onSuccess`
            // callback has something to pass to the registration view.
            // The values are placeholders — the registration mock ignores
            // them (it only asserts state transitions).
            lastBootstrapResult = makeMockBootstrapResult()
            state = .success
        case .userCancelsInSafari:
            state = .failed(.userCancelled)
        case .timeout:
            state = .failed(.timeout)
        case .networkLost:
            state = .failed(.networkLost)
        case .suspended:
            // Second call (after retry) → success.
            lastBootstrapResult = makeMockBootstrapResult()
            state = .success
        case .safariUnavailable:
            state = .failed(.safariUnavailable)
        case .serverError(let msg):
            state = .failed(.server(msg))
        }
    }

    func cancel() async {
        cancelCallCount += 1
        state = .failed(.userCancelled)
    }

    func retry() async {
        retryCallCount += 1
        state = .idle
        // The caller (the bootstrap sheet) re-invokes begin() with the same
        // cluster. We don't capture it here to avoid stale state.
    }

    /// Build a minimal `BootstrapResult` for the success scenarios. The
    /// registration mock ignores the contents (it only asserts state
    /// transitions), but the type is required by the protocol + the view's
    /// `onSuccess` callback.
    private func makeMockBootstrapResult() -> TeleportBootstrapCoordinator.BootstrapResult {
        // The BootstrapResult has a SecKey field. Create a dummy software
        // EC P-256 key so the type is constructible without a real SEP.
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error)!
        return TeleportBootstrapCoordinator.BootstrapResult(
            sshCertPEM: "mock-bootstrap-cert-pem",
            tlsCertPEM: "mock-tls-cert-pem",
            tlsKeyPairPrivateKey: secKey,
            clusterName: "teleport.pcad.it",
            clusterCAPEMs: [],
            certValidBefore: Date().addingTimeInterval(3600)
        )
    }
}
