// SPDX-License-Identifier: MIT
//
//  TeleportPhaseChainUITestHarness+iOS.swift
//  VVTerm
//
//  A DEBUG-only iOS harness that drives the Teleport phase-chaining flow
//  (bootstrap → registration → login) through the SHARED production
//  `TeleportSetupSheet` with mock coordinators.
//
//  Before #369 this harness re-implemented the production routing switch
//  (`ServerSidebarView.teleportSetupSheet`) and its three phase wrappers, so
//  the XCUITest asserted a mirror rather than the production view. It now
//  presents the shared sheet directly, so a drift in the shared routing view
//  reds the scheduled `TeleportPhaseTransitionUITests`. The host call-site
//  composition (readiness capture + presentation binding) is pinned by
//  `TeleportSetupSheetPinsTests`, not exercised end-to-end here.
//
//  The XCUITest asserts:
//    1. Tap a `needsBootstrap` server row → bootstrap sheet appears.
//    2. The mock bootstrap coordinator parks in `.awaitingApproval` until the
//       release control is tapped, then succeeds (happyPath).
//    3. The registration sheet appears (NOT dismissal, NOT a second bootstrap).
//    4. Continue → login sheet; Sign in → Continue → the sheet dismisses.
//
//  Launch-arg contract (read by this harness + by VVTermApp.swift):
//    --vvterm-ui-test-teleport-phase-chain   enables this harness
//
//  See:
//    - VVTerm/Features/Teleport/UI/TeleportSetupSheet.swift
//      (the shared production routing this presents)
//    - VVTermUITests/Features/Teleport/TeleportPhaseTransitionUITests.swift
//      (the XCUITest that asserts the chain)
//

#if os(iOS) && DEBUG
import SwiftUI
import TeleportTesting

struct TeleportPhaseChainUITestHarness: View {
    /// The fixed cluster ID. Reused as both `server.id` and the key-ring
    /// cluster ID so the readiness probe hits the seeded fixture.
    private let clusterId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @StateObject private var keyRing = MockTeleportKeyRing()
    @State private var presentingSheet: Bool = false

    /// Parent-owned bootstrap coordinator (issue #277): the harness owns the
    /// single instance so its `beginCallCount` survives the phase-1 → phase-2
    /// sheet swap and the no-re-run assertion can read it. It is handed to the
    /// shared sheet's `makeBootstrapCoordinator` factory, so the chain runs on
    /// this same instance. Mirrors the parent-owned pattern in
    /// `TeleportIOSServerListUITestHarness+iOS.swift`.
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
                onTeleportSetup: { _, _ in
                    presentingSheet = true
                },
                keyRing: keyRing,
                isLockedOverride: false
            )
            .padding()

            Divider()

            // The parent-owned coordinator's begin count so the no-re-run
            // assertion survives the sheet swap (issue #277). The chain now
            // lives in the shared sheet, so this label no longer mirrors
            // readiness — only the live counter remains.
            Text("bootstrapBegins: \(bootstrapCoordinator.beginCallCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("vvterm.teleport.phaseChainHarness.bootstrapBegins")
                .padding()

            Spacer()
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $presentingSheet) {
            ZStack(alignment: .bottom) {
                // The shared production routing view, driven by mock
                // coordinators. The bootstrap factory returns the harness-owned
                // instance so `beginCallCount` survives the phase swap.
                TeleportSetupSheet(
                    server: makeServer(),
                    initialReadiness: .needsBootstrap,
                    makeBootstrapCoordinator: { bootstrapCoordinator },
                    makeRegistrationCoordinator: {
                        MockTeleportRegistrationCoordinator(scenario: .happyPath)
                    },
                    makeLoginCoordinator: {
                        MockTeleportLoginCoordinator(scenario: .happyPath(certTTL: 12 * 3600))
                    },
                    persistHostLogin: { _ in },
                    onFinish: { presentingSheet = false }
                )

                // The #277 deterministic gate: a sibling of the shared sheet
                // that observes the harness-owned coordinator. Its own
                // existence is the gate-engaged signal.
                PhaseChainGateOverlay(coordinator: bootstrapCoordinator)
            }
        }
        .preferredColorScheme(.dark)
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
}

// MARK: - Deterministic gate overlay (issue #277)
//
// Rendered only while the mock is actually parked in `.awaitingApproval`, so
// the control's own existence is the gate-engaged signal. The body is
// intentionally container-free (no layout container, no
// `.accessibilityElement(children:)`): the element must surface as a hittable
// Button in the AX tree, and a disengaged overlay must leave no hit area.

private struct PhaseChainGateOverlay: View {
    @ObservedObject var coordinator: MockTeleportBootstrapCoordinator

    var body: some View {
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
#endif
