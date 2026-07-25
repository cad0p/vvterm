// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportUITestHarness+iOS.swift
//  VVTerm
//
//  A DEBUG-only iOS harness that presents the real Teleport SwiftUI sheets
//  (Phase 1 bootstrap, Phase 2 registration, Phase 3 login) against the
//  mock coordinators so XCUITests can script every failure/recovery case
//  in the design doc's mockup C/D/E matrices without a real Teleport
//  server, real Safari, or real Face ID.
//
//  Launch-arg contract (read by this harness + by VVTermApp.swift):
//    --vvterm-ui-test-teleport-harness                enables the harness
//    --vvterm-ui-test-teleport-phase=bootstrap|registration|login
//    --vvterm-ui-test-teleport-scenario=<phase-specific>
//
//  The view's `.task` modifier calls `coordinator.begin(...)` automatically
//  for bootstrap and login. The registration sheet requires a Continue tap
//  (the form waits for the user to confirm the device name) — the tests
//  tap the Continue button via its accessibility identifier.
//
//  See:
//    - VVTerm/App/iOS/NoticePresentationUITestHarness+iOS.swift (harness pattern)
//    - VVTermUITests/Features/Teleport/TeleportUITests.swift (the XCUITests)
//

#if os(iOS) && DEBUG
import SwiftUI

struct TeleportUITestHarness: View {
    /// The cluster config the harness presents. The values are fixtures —
    /// the mock coordinators don't reach a real server, but the views read
    /// `cluster.host` and `cluster.username` for display copy.
    private let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")

    /// The Phase-2 registration sheet needs a Phase-1 result to construct.
    /// Build a minimal fixture (the registration mock ignores the contents).
    private let bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult = {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error)!
        return TeleportBootstrapCoordinator.BootstrapResult(
            sshCertPEM: "harness-cert-pem",
            tlsCertPEM: "harness-tls-cert-pem",
            tlsKeyPairPrivateKey: secKey,
            clusterName: "teleport.pcad.it",
            clusterCAPEMs: [],
            certValidBefore: Date().addingTimeInterval(3600)
        )
    }()

    var body: some View {
        Group {
            switch phase {
            case .bootstrap:
                bootstrapSheet
            case .registration:
                registrationSheet
            case .login:
                loginSheet
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Phase 1: bootstrap

    @ViewBuilder
    private var bootstrapSheet: some View {
        let coordinator = MockTeleportBootstrapCoordinator(scenario: bootstrapScenario)
        TeleportBootstrapView(
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: { _ in },
            onCancel: {}
        )
    }

    // MARK: - Phase 2: registration

    @ViewBuilder
    private var registrationSheet: some View {
        let coordinator = MockTeleportRegistrationCoordinator(scenario: registrationScenario)
        TeleportRegistrationView(
            coordinator: coordinator,
            cluster: cluster,
            bootstrapResult: bootstrapResult,
            onSuccess: {},
            onCancel: {}
        )
    }

    // MARK: - Phase 3: login

    @ViewBuilder
    private var loginSheet: some View {
        let coordinator = MockTeleportLoginCoordinator(scenario: loginScenario)
        TeleportLoginView(
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: {},
            onCancel: {}
        )
    }

    // MARK: - Launch-arg parsing

    /// Which phase's sheet to present. Driven by
    /// `--vvterm-ui-test-teleport-phase=bootstrap|registration|login`.
    private var phase: Phase {
        guard let raw = launchArgValue(for: "--vvterm-ui-test-teleport-phase"),
              let parsed = Phase(rawValue: raw) else {
            return .bootstrap
        }
        return parsed
    }

    private var bootstrapScenario: MockTeleportBootstrapCoordinator.Scenario {
        guard let raw = launchArgValue(for: "--vvterm-ui-test-teleport-scenario"),
              let parsed = BootstrapScenario(rawValue: raw) else {
            return .happyPath
        }
        switch parsed {
        case .happyPath:
            return .happyPath
        case .alreadyLoggedIn:
            return .alreadyLoggedIn
        case .userCancelled:
            return .userCancelsInSafari
        case .timeout:
            return .timeout
        case .networkLost:
            return .networkLost
        case .suspended:
            return .suspended
        case .safariUnavailable:
            return .safariUnavailable
        case .serverError:
            return .serverError("cluster not found")
        }
    }

    private var registrationScenario: MockTeleportRegistrationCoordinator.Scenario {
        guard let raw = launchArgValue(for: "--vvterm-ui-test-teleport-scenario"),
              let parsed = RegistrationScenario(rawValue: raw) else {
            return .happyPath
        }
        switch parsed {
        case .happyPath:
            return .happyPath
        case .alreadyExists:
            return .deviceNameAlreadyExists("vvterm-pier-iphone")
        case .cancelBetweenSafariTrips:
            return .cancelBetweenSafariTrips
        case .emptyDeviceName:
            // Empty name is a client-side validation (the Continue button
            // stays disabled). We present the happyPath coordinator so the
            // test can assert the Continue button is disabled without a
            // server error firing.
            return .happyPath
        case .invalidChars:
            // Same as emptyDeviceName — sanitization is client-side.
            return .happyPath
        }
    }

    private var loginScenario: MockTeleportLoginCoordinator.Scenario {
        guard let raw = launchArgValue(for: "--vvterm-ui-test-teleport-scenario"),
              let parsed = LoginScenario(rawValue: raw) else {
            return .happyPath(certTTL: 12 * 3600)
        }
        switch parsed {
        case .happyPath12h:
            return .happyPath(certTTL: 12 * 3600)
        case .happyPath1h:
            return .happyPath(certTTL: 3600)
        case .certExpiredOnTap:
            return .certExpiredOnTap(certTTL: 4 * 3600)
        case .faceIDCancelled:
            return .faceIDCancelled
        case .faceIDUnavailable:
            return .faceIDUnavailable("Face ID isn't available. Set up Face ID in iOS Settings.")
        case .serverUnreachable:
            return .serverUnreachable
        }
    }

    /// Parse `--arg=value` from `ProcessInfo.arguments`. Returns nil if the
    /// arg is absent or has no `=` value.
    private func launchArgValue(for prefix: String) -> String? {
        for arg in Foundation.ProcessInfo.processInfo.arguments {
            guard arg.hasPrefix(prefix) else { continue }
            let remainder = arg.dropFirst(prefix.count)
            if remainder == "" {
                // The arg was present as a bare flag (e.g.
                // `--vvterm-ui-test-teleport-harness`). The scenario/phase
                // args always carry `=value`, so return nil here.
                return nil
            }
            // Strip a leading `=`.
            if remainder.hasPrefix("=") {
                return String(remainder.dropFirst())
            }
        }
        return nil
    }

    private enum Phase: String {
        case bootstrap, registration, login
    }

    private enum BootstrapScenario: String {
        case happyPath, alreadyLoggedIn, userCancelled, timeout
        case networkLost, suspended, safariUnavailable, serverError
    }

    private enum RegistrationScenario: String {
        case happyPath, alreadyExists, cancelBetweenSafariTrips
        case emptyDeviceName, invalidChars
    }

    private enum LoginScenario: String {
        case happyPath12h, happyPath1h, certExpiredOnTap
        case faceIDCancelled, faceIDUnavailable, serverUnreachable
    }
}
#endif
