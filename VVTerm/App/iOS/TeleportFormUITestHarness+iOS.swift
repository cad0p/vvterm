// SPDX-License-Identifier: MIT
//
//  TeleportFormUITestHarness+iOS.swift
//  VVTerm
//
//  A DEBUG-only iOS harness that presents the PRODUCTION `ServerFormSheet` in
//  Add or Edit mode, so XCUITests can assert the Teleport form copy:
//    - the "Changing the Teleport user or host re-runs Teleport setup…"
//      reminder is edit-only (#265);
//    - the Teleport-user field hint (#266);
//    - the node-name caption (#268).
//
//  The sheet is presented inside a `NavigationStack` (as every production iOS
//  caller does: `ServerListScreen`, `ServerTerminalRoute`, …) and under the
//  app root's environment, which supplies `AppLockManager` +
//  `\.teleportComposition` — the two environment inputs `ServerFormSheet`
//  requires. The harness does NOT set `StoreManager.shared.isPro` (the
//  singleton's entitlement check lands asynchronously and would move the form
//  geometry mid-test); the tests scroll instead of relying on Pro layout.
//
//  The edit fixture is a plain `Server` value passed to the form — never
//  inserted into `ServerManager.servers`, so nothing is persisted. Its fixed
//  cluster id is unique so the keychain readiness probe cannot collide with
//  another fixture, and the tests never tap the setup button.
//
//  Launch-arg contract (read by this harness + by VVTermApp.swift):
//    --vvterm-ui-test-teleport-form=add|edit   enables this harness
//
//  See:
//    - VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift (the form)
//    - VVTermUITests/Features/Teleport/TeleportFormUITests.swift (the tests)
//

#if os(iOS) && DEBUG
import SwiftUI

struct TeleportFormUITestHarness: View {
    /// Which form the harness presents: `add` (a new server, `server: nil`)
    /// or `edit` (the seeded `.faceIDTeleport` row).
    enum Mode: String {
        case add
        case edit
    }

    /// The seeded edit row. Fixed IDs: the cluster id must not collide with
    /// another UI-test fixture (the readiness probe reads the real keychain).
    private static let editServerId = UUID(uuidString: "00000000-0000-0000-0000-0000000265AB")!
    private static let editWorkspaceId = UUID(uuidString: "00000000-0000-0000-0000-0000000265AC")!

    private static var editServer: Server {
        Server(
            id: editServerId,
            workspaceId: editWorkspaceId,
            environment: .production,
            name: "teleport-node",
            host: "teleport.example.com",
            port: 22,
            username: "alice",
            authMethod: .faceIDTeleport
        )
    }

    private let mode: Mode

    /// A fresh manager that never persists the edit fixture:
    /// `ServerManager()` still reads (and does its own bookkeeping writes to)
    /// `UserDefaults.standard` — there is no dedicated suite — but the fixture
    /// is a plain `Server` value passed to the form, never inserted into
    /// `ServerManager.servers`; the `--vvterm-ui-test-*` arg skips the CloudKit
    /// container and `-iCloudSyncEnabled NO` disables sync, so the harness never
    /// touches `ServerManager.shared`.
    @StateObject private var serverManager = ServerManager()
    @State private var presentingSheet = true

    @MainActor
    init() {
        mode = Mode(rawValue: Self.launchArgValue(for: "--vvterm-ui-test-teleport-form") ?? "") ?? .add
        _serverManager = StateObject(wrappedValue: ServerManager())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Routing marker: the tests wait on this first so a mis-routed
            // launch fails fast with a readable identifier instead of a
            // navigation-bar timeout.
            Text("teleport-form-harness")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("vvterm.teleportFormHarness.root")
                .padding()

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $presentingSheet) {
            NavigationStack {
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: nil,
                    server: mode == .edit ? Self.editServer : nil,
                    onSave: { _ in }
                )
            }
        }
    }

    /// Parse `--arg=value` from `ProcessInfo.arguments` (same shape as
    /// `TeleportUITestHarness`). Returns nil when the arg is absent or bare.
    private static func launchArgValue(for prefix: String) -> String? {
        for arg in Foundation.ProcessInfo.processInfo.arguments {
            guard arg.hasPrefix(prefix) else { continue }
            let remainder = arg.dropFirst(prefix.count)
            if remainder == "" {
                return nil
            }
            if remainder.hasPrefix("=") {
                return String(remainder.dropFirst())
            }
        }
        return nil
    }
}
#endif
