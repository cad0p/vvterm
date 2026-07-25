// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportIOSServerListUITestHarness+iOS.swift
//  VVTerm
//
//  A DEBUG-only iOS harness that presents the REAL iOS server-list row
//  (`ServerListRow`) → tap → sheet prompt-on-connect flow (mockup B in the
//  2.2 UI design doc) against a mock TeleportKeyRing, so XCUITests can
//  assert which sheet (or terminal connect) appears for each readiness
//  state on the iOS row component.
//
//  Unlike `TeleportServerListUITestHarness` (which renders the macOS
//  `ServerRow` component directly on iOS), this harness renders the
//  production iOS `ServerListRow` so the test drives the REAL iOS UI —
//  the same row `ServerListScreen` renders in production. This catches
//  iOS-specific regressions (e.g. the row missing the `onTeleportSetup`
//  hook, the readiness badge, or the tap routing).
//
//  The harness replicates `ServerListScreen`'s `teleportSetupSheet`
//  routing (which mirrors `ServerSidebarView`'s routing) so the
//  tap → sheet path is exercised end-to-end, including the phase-
//  chaining fix (bootstrap → registration → login).
//
//  Launch-arg contract (read by this harness + by VVTermApp.swift):
//    --vvterm-ui-test-teleport-ios-serverlist   enables this harness
//    --vvterm-ui-test-teleport-readiness=bootstrap|registration|login|ready|crossDevice
//         the readiness state to seed the mock key ring with
//
//  See:
//    - VVTerm/App/iOS/ServerComponents+iOS.swift (ServerListRow + readiness badge)
//    - VVTerm/App/iOS/ServerListScreen+iOS.swift (teleportSetupSheet routing)
//    - VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift (macOS reference)
//    - VVTermUITests/Features/Teleport/TeleportReadinessIOSUITests.swift (tests)
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup B)
//

#if os(iOS) && DEBUG
import SwiftUI

struct TeleportIOSServerListUITestHarness: View {
    /// The fixed cluster ID the harness seeds. The `Server` fixture reuses
    /// this ID as both `server.id` and the key-ring cluster ID so the
    /// readiness probe hits the seeded fixture.
    private let clusterId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @StateObject private var keyRing: MockTeleportKeyRing
    @State private var presentingSheet: SheetKind?
    @State private var didConnect = false
    /// Held in memory so the registration sheet can resume (phase chaining).
    @State private var bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult?

    @MainActor
    init() {
        _keyRing = StateObject(wrappedValue: MockTeleportKeyRing())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Render the REAL iOS ServerListRow with the injected mock
            // keyRing. The row's Button action routes to onTeleportSetup
            // (non-ready) or onTap (ready). We map onTap → connect for the
            // ready case.
            ServerListRow(
                server: makeServer(),
                onTap: { connect() },
                onEdit: { },
                onMove: nil,
                onLockedTap: nil,
                onTeleportSetup: { _, readiness in
                    presentingSheet = sheetKind(for: readiness)
                },
                keyRing: keyRing,
                isLockedOverride: false
            )
            .padding()

            Divider()

            // A connect marker that appears when onTap fires for a ready
            // server. The ready test asserts this is visible (and NO
            // Teleport sheet header is present).
            if didConnect {
                Text("Connected")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("vvterm.teleport.serverlistHarness.connected")
                    .padding()
            }

            Spacer()
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(item: $presentingSheet) { kind in
            sheetContent(for: kind)
        }
        .preferredColorScheme(.dark)
        .onAppear { seedKeyRing() }
    }

    // MARK: - Server fixture

    private func makeServer() -> Server {
        Server(
            id: clusterId,
            workspaceId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            environment: .production,
            name: "Teleport Test Server",
            host: "teleport.example.com",
            port: 22,
            username: "tester",
            authMethod: .faceIDTeleport
        )
    }

    // MARK: - Key-ring seeding

    /// Seed the mock key ring based on `--vvterm-ui-test-teleport-readiness`.
    /// Mirrors the mockup B matrix:
    ///   ready            → SEP key + valid cert
    ///   needsLogin       → SEP key + expired cert
    ///   needsRegistration → cert, no SEP key
    ///   needsBootstrap   → nothing
    ///   crossDevice      → nothing (same as needsBootstrap; simulates a server
    ///                       record arriving via iCloud with an empty keychain)
    private func seedKeyRing() {
        let now = Date()
        switch readiness {
        case .ready:
            keyRing.seed(clusterId: clusterId, fixture: .init(
                hasBootstrapCert: true,
                hasSEPKey: true,
                certValidBefore: now.addingTimeInterval(12 * 3600),
                credentialID: Data([0x01]),
                userHandle: Data([0x02]),
                deviceName: "vvterm-test"
            ))
        case .needsLogin:
            keyRing.seed(clusterId: clusterId, fixture: .init(
                hasBootstrapCert: true,
                hasSEPKey: true,
                certValidBefore: now.addingTimeInterval(-3600),  // expired
                credentialID: Data([0x01]),
                userHandle: Data([0x02]),
                deviceName: "vvterm-test"
            ))
        case .needsRegistration:
            keyRing.seed(clusterId: clusterId, fixture: .init(
                hasBootstrapCert: true,
                hasSEPKey: false,
                certValidBefore: now.addingTimeInterval(3600),
                credentialID: Data(),
                userHandle: Data(),
                deviceName: ""
            ))
        case .needsBootstrap, .crossDevice:
            // Empty keychain — no seed needed.
            break
        }
    }

    // MARK: - Sheet routing (replicates ServerListScreen.teleportSetupSheet)

    /// Maps a readiness state to the sheet the production router presents.
    /// NOTE: production routes `needsRegistration` BACK to bootstrap (the TLS
    /// keypair isn't persisted between Phase 1 and Phase 2). We replicate
    /// that exact behavior here so the test asserts what the code ACTUALLY does.
    private func sheetKind(for readiness: TeleportDeviceReadiness) -> SheetKind {
        switch readiness {
        case .needsBootstrap, .needsRegistration:
            return .bootstrap
        case .needsLogin:
            return .login
        case .ready:
            return .none
        }
    }

    @ViewBuilder
    private func sheetContent(for kind: SheetKind) -> some View {
        switch kind {
        case .bootstrap:
            // Use the mock bootstrap coordinator (happyPath) so the sheet
            // renders its header without reaching a real server.
            ReadinessBootstrapSheet(cluster: makeCluster()) { result in
                // Phase 1 → Phase 2: hold the result, advance to registration.
                bootstrapResult = result
                presentingSheet = .registration
            } onCancel: {
                presentingSheet = nil
                bootstrapResult = nil
            }
        case .registration:
            if let bootstrapResult {
                ReadinessRegistrationSheet(
                    cluster: makeCluster(),
                    bootstrapResult: bootstrapResult
                ) {
                    // Phase 2 → Phase 3: advance to login.
                    presentingSheet = .login
                } onCancel: {
                    presentingSheet = nil
                    self.bootstrapResult = nil
                }
            } else {
                // No in-memory result — re-bootstrap (matches production fallback).
                ReadinessBootstrapSheet(cluster: makeCluster()) { result in
                    bootstrapResult = result
                    presentingSheet = .registration
                } onCancel: {
                    presentingSheet = nil
                    bootstrapResult = nil
                }
            }
        case .login:
            ReadinessLoginSheet(cluster: makeCluster()) {
                // Phase 3 complete — dismiss.
                presentingSheet = nil
                bootstrapResult = nil
            } onCancel: {
                presentingSheet = nil
                bootstrapResult = nil
            }
        case .none:
            EmptyView()
        }
    }

    private func makeCluster() -> TeleportCluster {
        TeleportCluster(
            id: clusterId,
            host: "teleport.example.com",
            port: 22,
            username: "tester"
        )
    }

    private func connect() {
        didConnect = true
    }

    // MARK: - Launch-arg parsing

    private var readiness: Readiness {
        guard let raw = launchArgValue(for: "--vvterm-ui-test-teleport-readiness"),
              let parsed = Readiness(rawValue: raw) else {
            return .needsBootstrap
        }
        return parsed
    }

    /// Parse `--arg=value` from `ProcessInfo.arguments`.
    private func launchArgValue(for prefix: String) -> String? {
        for arg in Foundation.ProcessInfo.processInfo.arguments {
            guard arg.hasPrefix(prefix) else { continue }
            let remainder = arg.dropFirst(prefix.count)
            if remainder == "" { return nil }
            if remainder.hasPrefix("=") {
                return String(remainder.dropFirst())
            }
        }
        return nil
    }

    private enum Readiness: String {
        case ready, needsLogin, needsRegistration, needsBootstrap, crossDevice
    }

    private enum SheetKind: Identifiable {
        case bootstrap, registration, login, none
        var id: String {
            switch self {
            case .bootstrap: return "bootstrap"
            case .registration: return "registration"
            case .login: return "login"
            case .none: return "none"
            }
        }
    }
}

// MARK: - Sheet wrappers
//
// Each phase's coordinator is held in `@StateObject` so SwiftUI creates it
// once and preserves it across body re-evaluations (mirrors the pattern in
// TeleportServerListUITestHarness+iOS.swift). The sheet itself just needs
// to render the real view so the test can assert its accessibility-identified
// header.

private struct ReadinessBootstrapSheet: View {
    let cluster: TeleportCluster
    let onSuccess: (TeleportBootstrapCoordinator.BootstrapResult) -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator: MockTeleportBootstrapCoordinator

    @MainActor
    init(
        cluster: TeleportCluster,
        onSuccess: @escaping (TeleportBootstrapCoordinator.BootstrapResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.cluster = cluster
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        _coordinator = StateObject(wrappedValue: MockTeleportBootstrapCoordinator(scenario: .happyPath))
    }

    var body: some View {
        TeleportBootstrapView(
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: onSuccess,
            onCancel: onCancel
        )
    }
}

private struct ReadinessRegistrationSheet: View {
    let cluster: TeleportCluster
    let bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator: MockTeleportRegistrationCoordinator

    @MainActor
    init(
        cluster: TeleportCluster,
        bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult,
        onSuccess: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.cluster = cluster
        self.bootstrapResult = bootstrapResult
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        _coordinator = StateObject(wrappedValue: MockTeleportRegistrationCoordinator(scenario: .happyPath))
    }

    var body: some View {
        TeleportRegistrationView(
            coordinator: coordinator,
            cluster: cluster,
            bootstrapResult: bootstrapResult,
            onSuccess: onSuccess,
            onCancel: onCancel
        )
    }
}

private struct ReadinessLoginSheet: View {
    let cluster: TeleportCluster
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator: MockTeleportLoginCoordinator

    @MainActor
    init(
        cluster: TeleportCluster,
        onSuccess: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.cluster = cluster
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        _coordinator = StateObject(wrappedValue: MockTeleportLoginCoordinator(scenario: .happyPath(certTTL: 12 * 3600)))
    }

    var body: some View {
        TeleportLoginView(
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: onSuccess,
            onCancel: onCancel
        )
    }
}
#endif
