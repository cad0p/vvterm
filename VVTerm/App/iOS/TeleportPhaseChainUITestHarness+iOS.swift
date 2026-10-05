// SPDX-License-Identifier: MIT
//
//  TeleportPhaseChainUITestHarness+iOS.swift
//  VVTerm
//
//  A DEBUG-only iOS harness that verifies the Teleport phase-chaining fix
//  in the prompt-on-connect flow (bootstrap → registration → login).
//
//  `TeleportServerListUITestHarness` replicates the OLD routing where
//  `needsRegistration` routes BACK to bootstrap (the pre-fix behavior).
//  After the fix, `ServerSidebarView.teleportSetupSheet` chains phases:
//  bootstrap `onSuccess` stores the `BootstrapResult` and flips readiness
//  to `needsRegistration`, which presents `TeleportRegistrationView` with
//  the in-memory result (no keychain persistence of the TLS keypair).
//
//  This harness replicates that FIXED chaining so an XCUITest can assert:
//    1. Tap a `needsBootstrap` server row → bootstrap sheet appears.
//    2. The mock bootstrap coordinator parks in `.awaitingApproval` until the
//       release control is tapped, then succeeds (happyPath).
//    3. The registration sheet appears (NOT dismissal, NOT a second bootstrap).
//
//  Launch-arg contract (read by this harness + by VVTermApp.swift):
//    --vvterm-ui-test-teleport-phase-chain   enables this harness
//
//  See:
//    - VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift
//      (teleportSetupSheet — the production routing this mirrors)
//    - VVTermUITests/Features/Teleport/TeleportPhaseTransitionUITests.swift
//      (the XCUITest that asserts the chain)
//

#if os(iOS) && DEBUG
import SwiftUI

struct TeleportPhaseChainUITestHarness: View {
    /// The fixed cluster ID. Reused as both `server.id` and the key-ring
    /// cluster ID so the readiness probe hits the seeded fixture.
    private let clusterId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @StateObject private var keyRing = MockTeleportKeyRing()
    @State private var presentingSheet: Bool = false
    @State private var readiness: TeleportDeviceReadiness = .needsBootstrap
    @State private var bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult?

    /// Parent-owned bootstrap coordinator (issue #277): the harness owns the
    /// single instance so its `beginCallCount` survives the phase-1 → phase-2
    /// sheet swap and the no-re-run assertion can read it. Mirrors the
    /// parent-owned pattern in `TeleportIOSServerListUITestHarness+iOS.swift`.
    @StateObject private var bootstrapCoordinator: MockTeleportBootstrapCoordinator

    @MainActor
    init() {
        _bootstrapCoordinator = StateObject(
            wrappedValue: MockTeleportBootstrapCoordinator(scenario: .happyPath, holdsForApproval: true)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ServerRow(
                server: makeServer(),
                isSelected: false,
                onSelect: { },
                onEdit: { _ in },
                onMove: nil,
                onConnect: { _ in },
                onLockedTap: nil,
                onTeleportSetup: { _, read in
                    readiness = read
                    presentingSheet = true
                },
                keyRing: keyRing,
                isLockedOverride: false
            )
            .padding()

            Divider()

            // A status marker that reflects the current readiness so the
            // test can assert the chain progressed (not just dismissed).
            // The parent-owned coordinator's begin count is included so the
            // no-re-run assertion survives the sheet swap (issue #277).
            Text("readiness: \(readinessLabel) bootstrapBegins: \(bootstrapCoordinator.beginCallCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("vvterm.teleport.phaseChainHarness.readiness")
                .padding()

            Spacer()
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $presentingSheet) {
            sheetContent
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
            name: "Teleport Phase Chain Server",
            host: "teleport.example.com",
            port: 22,
            username: "tester",
            authMethod: .faceIDTeleport
        )
    }

    private func makeCluster() -> TeleportCluster {
        TeleportCluster(
            id: clusterId,
            host: "teleport.example.com",
            port: 22,
            username: "tester"
        )
    }

    // MARK: - Key-ring seeding

    /// Seed an empty keychain (needsBootstrap) so the row taps into the
    /// bootstrap sheet. The chain then drives readiness forward.
    private func seedKeyRing() {
        // Empty keychain — needsBootstrap.
    }

    // MARK: - Sheet routing (mirrors the FIXED ServerSidebarView.teleportSetupSheet)

    @ViewBuilder
    private var sheetContent: some View {
        let cluster = makeCluster()
        switch readiness {
        case .needsBootstrap:
            PhaseChainBootstrapSheet(
                cluster: cluster,
                coordinator: bootstrapCoordinator
            ) { result in
                // Phase 1 → Phase 2: hold the result, flip readiness.
                bootstrapResult = result
                readiness = .needsRegistration
            } onCancel: {
                presentingSheet = false
                bootstrapResult = nil
            }
        case .needsRegistration:
            if let bootstrapResult {
                PhaseChainRegistrationSheet(
                    cluster: cluster,
                    bootstrapResult: bootstrapResult
                ) {
                    // Phase 2 → Phase 3: flip to login.
                    readiness = .needsLogin
                } onCancel: {
                    presentingSheet = false
                    self.bootstrapResult = nil
                }
            } else {
                // No in-memory result — re-bootstrap (matches production fallback).
                PhaseChainBootstrapSheet(
                    cluster: cluster,
                    coordinator: bootstrapCoordinator
                ) { result in
                    bootstrapResult = result
                    readiness = .needsRegistration
                } onCancel: {
                    presentingSheet = false
                    bootstrapResult = nil
                }
            }
        case .needsLogin:
            PhaseChainLoginSheet(cluster: cluster) {
                // Phase 3 complete — dismiss.
                presentingSheet = false
                bootstrapResult = nil
            } onCancel: {
                presentingSheet = false
                bootstrapResult = nil
            }
        case .ready:
            EmptyView()
        }
    }

    // MARK: - Helpers

    private var readinessLabel: String {
        switch readiness {
        case .needsBootstrap: return "needsBootstrap"
        case .needsRegistration: return "needsRegistration"
        case .needsLogin: return "needsLogin"
        case .ready: return "ready"
        }
    }
}

// MARK: - Phase wrapper sheets
//
// The registration/login coordinators are held in `@StateObject` so SwiftUI
// creates them once and preserves them across body re-evaluations (mirrors
// the pattern in TeleportUITestHarness+iOS.swift). The bootstrap coordinator
// is instead owned by the harness (the parent) so its `beginCallCount`
// survives the phase-1 → phase-2 sheet swap and the no-re-run assertion can
// read it (issue #277).

private struct PhaseChainBootstrapSheet: View {
    let cluster: TeleportCluster
    let onSuccess: (TeleportBootstrapCoordinator.BootstrapResult) -> Void
    let onCancel: () -> Void

    /// Parent-owned (not `@StateObject`): the harness owns the single
    /// instance so `beginCallCount` survives the sheet swap (issue #277).
    @ObservedObject var coordinator: MockTeleportBootstrapCoordinator

    @MainActor
    init(
        cluster: TeleportCluster,
        coordinator: MockTeleportBootstrapCoordinator,
        onSuccess: @escaping (TeleportBootstrapCoordinator.BootstrapResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.cluster = cluster
        self.coordinator = coordinator
        self.onSuccess = onSuccess
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TeleportBootstrapView(
                coordinator: coordinator,
                cluster: cluster,
                onSuccess: onSuccess,
                onCancel: onCancel
            )

            // The deterministic gate release. Rendered only while the mock is
            // actually parked in `.awaitingApproval`, so the control's own
            // existence is the gate-engaged signal (issue #277). The wrapper is
            // intentionally container-free: the element must surface as a
            // hittable Button in the AX tree.
            if coordinator.state == .awaitingApproval {
                Button("Release Bootstrap Approval") {
                    coordinator.releaseApproval()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("vvterm.teleport.phaseChainHarness.releaseBootstrapApproval")
                .padding(.bottom, 24)
            }
        }
    }
}

private struct PhaseChainRegistrationSheet: View {
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
        // happyPath → success (SEP key created + registered + persisted).
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

private struct PhaseChainLoginSheet: View {
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
            storedHostLogin: nil,
            onSuccess: { _ in onSuccess() },
            onCancel: onCancel
        )
    }
}
#endif
