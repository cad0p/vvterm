// SPDX-License-Identifier: AGPL-3.0-or-later
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
//    2. The mock bootstrap coordinator immediately succeeds (happyPath).
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
                keyRing: keyRing
            )
            .padding()

            Divider()

            // A status marker that reflects the current readiness so the
            // test can assert the chain progressed (not just dismissed).
            Text("readiness: \(readinessLabel)")
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
            PhaseChainBootstrapSheet(cluster: cluster) { result in
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
                PhaseChainBootstrapSheet(cluster: cluster) { result in
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
// Each phase's coordinator is held in `@StateObject` so SwiftUI creates it
// once and preserves it across body re-evaluations (mirrors the pattern in
// TeleportUITestHarness+iOS.swift).

private struct PhaseChainBootstrapSheet: View {
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
        // happyPath → immediate success (cert + TLS keypair in hand).
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
            onSuccess: onSuccess,
            onCancel: onCancel
        )
    }
}
#endif
