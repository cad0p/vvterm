// SPDX-License-Identifier: MIT
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
//  tap → sheet path is exercised end-to-end. It does NOT phase-chain
//  (bootstrap → registration → login): the readiness tests only assert
//  which sheet a tap opens, and auto-advancing on bootstrap success raced
//  the test's `waitForExistence` on the bootstrap header.
//
//  Launch-arg contract (read by this harness + by VVTermApp.swift):
//    --vvterm-ui-test-teleport-ios-serverlist   enables this harness
//    --vvterm-ui-test-teleport-readiness=bootstrap|registration|login|ready|crossDevice
//         the readiness state to seed the mock key ring with
//    --vvterm-ui-test-teleport-readiness=swipeDismiss (#272)
//         presents the bootstrap sheet with a parent-owned suspended
//         coordinator and renders its begin/cancel/retry counters outside
//         the sheet, so the swipe-dismissal XCUITest can read them after the
//         sheet is gone
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

    /// The parent-owned coordinator for the #272 swipe-dismissal harness mode:
    /// `.suspended` fails the first `begin` with a retryable error (so the
    /// Reopen Safari button appears). The 30s delay keeps each of the mock's
    /// three sleeps long, so the retry's `begin` is still non-terminal when the
    /// test swipes the sheet down. Note the mock's `try? await Task.sleep`
    /// swallows cancellation, so after the swipe it fast-forwards to a terminal
    /// state; the test asserts the dismissal's `cancel` counter, not the mock's
    /// post-dismissal state.
    @StateObject private var dismissalCoordinator: MockTeleportBootstrapCoordinator

    @MainActor
    init() {
        _keyRing = StateObject(wrappedValue: MockTeleportKeyRing())
        // The coordinator is created unconditionally (a `@StateObject` cannot be
        // created lazily per mode), but it is only used by `.swipeDismiss`: the
        // sheet kind and the counters label are both gated on that readiness.
        _dismissalCoordinator = StateObject(
            wrappedValue: MockTeleportBootstrapCoordinator(scenario: .suspended, delay: 30)
        )
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

            // #272: the dismissal coordinator's call counters live OUTSIDE the
            // sheet so the XCUITest can read them after the swipe-down
            // dismissal has removed the sheet from the accessibility tree.
            if readiness == .swipeDismiss {
                Text(dismissalCounterSummary)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("vvterm.teleport.bootstrapDismissal.counters")
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
        case .needsBootstrap, .crossDevice, .swipeDismiss:
            // Empty keychain — no seed needed (swipeDismiss probes as
            // needsBootstrap and drives its own parent-owned coordinator).
            break
        }
    }

    // MARK: - Sheet routing (replicates ServerListScreen.teleportSetupSheet)

    /// Maps a readiness state to the sheet the production router presents.
    /// NOTE: a fresh `needsRegistration` with no in-memory result routes to
    /// bootstrap (the TLS keypair isn't persisted between Phase 1 and Phase 2).
    /// This harness has no in-memory result, so it replicates that path.
    private func sheetKind(for readiness: TeleportDeviceReadiness) -> SheetKind {
        // The #272 dismissal mode drives the bootstrap sheet (the empty mock
        // key ring probes as needsBootstrap) with the parent-owned suspended
        // coordinator instead of the happyPath one.
        if self.readiness == .swipeDismiss {
            return .bootstrapDismissal
        }
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
        case .bootstrapDismissal:
            // #272: the coordinator is owned by the harness (the parent), so
            // its counters survive the sheet's dismissal and can be rendered
            // outside it. `onSuccess`/`onCancel` are no-ops; the test only
            // asserts the counters and the dismissal itself.
            TeleportBootstrapView(
                coordinator: dismissalCoordinator,
                cluster: makeCluster(),
                onSuccess: { _ in },
                onCancel: {}
            )
        case .bootstrap:
            // Use the mock bootstrap coordinator (happyPath) so the sheet
            // renders its header without reaching a real server.
            //
            // `onSuccess` is a true no-op (matching `TeleportServerListUITestHarness`):
            // the harness does NOT phase-chain bootstrap → registration → login
            // and does NOT dismiss the sheet on success. The readiness tests only
            // assert which sheet a tap opens, not the phase transitions. Auto-
            // advancing (or dismissing) on success raced the test's
            // `waitForExistence` on the bootstrap header: the mock happyPath
            // reaches `.success` in ~150ms, so the header vanished before the
            // assertion could see it, and needsBootstrap / crossDevice /
            // needsRegistration all failed. Advancing also contradicted
            // `testReadinessIOS_needsRegistration`, which asserts the
            // registration sheet must NOT appear.
            ReadinessBootstrapSheet(cluster: makeCluster())
        case .login:
            ReadinessLoginSheet(cluster: makeCluster())
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

    /// The dismissal coordinator's begin/cancel/retry counters, formatted for
    /// the test to parse from one accessibility label.
    private var dismissalCounterSummary: String {
        "begin=\(dismissalCoordinator.beginCallCount) "
            + "cancel=\(dismissalCoordinator.cancelCallCount) "
            + "retry=\(dismissalCoordinator.retryCallCount)"
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
        /// #272 dismissal harness mode (parent-owned suspended coordinator).
        case swipeDismiss
    }

    private enum SheetKind: Identifiable {
        case bootstrap, bootstrapDismissal, login, none
        var id: String {
            switch self {
            case .bootstrap: return "bootstrap"
            case .bootstrapDismissal: return "bootstrapDismissal"
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

    @StateObject private var coordinator: MockTeleportBootstrapCoordinator

    @MainActor
    init(cluster: TeleportCluster) {
        self.cluster = cluster
        _coordinator = StateObject(wrappedValue: MockTeleportBootstrapCoordinator(scenario: .happyPath))
    }

    var body: some View {
        // `onSuccess` / `onCancel` are no-ops: the harness only needs the sheet
        // to render its header so the readiness test can assert it exists. See
        // `sheetContent` for why phase-chaining is intentionally NOT replicated.
        TeleportBootstrapView(
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: { _ in },
            onCancel: { }
        )
    }
}

private struct ReadinessLoginSheet: View {
    let cluster: TeleportCluster

    @StateObject private var coordinator: MockTeleportLoginCoordinator

    @MainActor
    init(cluster: TeleportCluster) {
        self.cluster = cluster
        _coordinator = StateObject(wrappedValue: MockTeleportLoginCoordinator(scenario: .happyPath(certTTL: 12 * 3600)))
    }

    var body: some View {
        // `onSuccess` / `onCancel` are no-ops: the harness only needs the sheet
        // to render its header so the readiness test can assert it exists.
        TeleportLoginView(
            coordinator: coordinator,
            cluster: cluster,
            storedHostLogin: nil,
            onSuccess: { _ in },
            onCancel: { }
        )
    }
}
#endif
