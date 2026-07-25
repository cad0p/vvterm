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
//  Each phase's coordinator is held by a dedicated wrapper view via
//  `@StateObject` so SwiftUI does NOT recreate it on body re-evaluation
//  (recreating it would reset the `@Published state` and break the
//  `.task` lifecycle that drives `begin()`).
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

    var body: some View {
        Group {
            switch phase {
            case .bootstrap:
                BootstrapHarnessSheet(scenario: bootstrapScenario, cluster: cluster)
            case .registration:
                RegistrationHarnessSheet(
                    scenario: registrationScenario,
                    cluster: cluster,
                    bootstrapResult: bootstrapResult
                )
            case .login:
                LoginHarnessSheet(scenario: loginScenario, cluster: cluster)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Phase 2 bootstrap result fixture

    /// The Phase-2 registration sheet needs a Phase-1 result to construct.
    /// Build a minimal fixture on demand (computed so it's only evaluated
    /// when the registration phase is active). The registration mock ignores
    /// the result's contents — only the type is required to satisfy
    /// `TeleportRegistrationView`'s initializer.
    private var bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        var secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error)
        if secKey == nil {
            var retryError: Unmanaged<CFError>?
            secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &retryError)
        }
        guard let key = secKey else {
            // SecKeyCreateRandomKey failed twice — this shouldn't happen in
            // the simulator, but if it does the registration sheet can't be
            // constructed. Crash with a clear message so the test surfaces
            // the real cause instead of a nil-force-unwrap.
            fatalError("TeleportUITestHarness: SecKeyCreateRandomKey failed for bootstrap result fixture")
        }
        return TeleportBootstrapCoordinator.BootstrapResult(
            sshCertPEM: "harness-cert-pem",
            tlsCertPEM: "harness-tls-cert-pem",
            tlsKeyPairPrivateKey: key,
            clusterName: "teleport.pcad.it",
            clusterCAPEMs: [],
            certValidBefore: Date().addingTimeInterval(3600)
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

// MARK: - Phase wrapper sheets
//
// Each phase's coordinator is held in `@StateObject` so SwiftUI creates it
// once and preserves it across body re-evaluations. If the coordinator were
// created in a `@ViewBuilder` computed property, SwiftUI would recreate it
// on every re-evaluation, resetting `@Published state` and breaking the
// `.task` lifecycle that drives `begin()`.

private struct BootstrapHarnessSheet: View {
    let scenario: MockTeleportBootstrapCoordinator.Scenario
    let cluster: TeleportCluster

    @StateObject private var coordinator: MockTeleportBootstrapCoordinator

    init(scenario: MockTeleportBootstrapCoordinator.Scenario, cluster: TeleportCluster) {
        self.scenario = scenario
        self.cluster = cluster
        _coordinator = StateObject(wrappedValue: MockTeleportBootstrapCoordinator(scenario: scenario))
    }

    var body: some View {
        TeleportBootstrapView(
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: { _ in },
            onCancel: {}
        )
    }
}

private struct RegistrationHarnessSheet: View {
    let scenario: MockTeleportRegistrationCoordinator.Scenario
    let cluster: TeleportCluster
    let bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult

    @StateObject private var coordinator: MockTeleportRegistrationCoordinator

    init(
        scenario: MockTeleportRegistrationCoordinator.Scenario,
        cluster: TeleportCluster,
        bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult
    ) {
        self.scenario = scenario
        self.cluster = cluster
        self.bootstrapResult = bootstrapResult
        _coordinator = StateObject(wrappedValue: MockTeleportRegistrationCoordinator(scenario: scenario))
    }

    var body: some View {
        TeleportRegistrationView(
            coordinator: coordinator,
            cluster: cluster,
            bootstrapResult: bootstrapResult,
            onSuccess: {},
            onCancel: {}
        )
    }
}

private struct LoginHarnessSheet: View {
    let scenario: MockTeleportLoginCoordinator.Scenario
    let cluster: TeleportCluster

    @StateObject private var coordinator: MockTeleportLoginCoordinator

    init(scenario: MockTeleportLoginCoordinator.Scenario, cluster: TeleportCluster) {
        self.scenario = scenario
        self.cluster = cluster
        _coordinator = StateObject(wrappedValue: MockTeleportLoginCoordinator(scenario: scenario))
    }

    var body: some View {
        TeleportLoginView(
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: {},
            onCancel: {}
        )
    }
}
#endif
