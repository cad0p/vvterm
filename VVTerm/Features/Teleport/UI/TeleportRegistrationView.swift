// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportRegistrationView.swift
//  VVTerm
//
//  Phase 2 UI: the registration / device-name sheet (design doc mockup D).
//
//  Sits between the two Safari trips. Shows "✓ Signed in to Teleport"
//  (Phase 1 complete), explains the second Safari trip + Face ID, lets the
//  user name the MFA device, and provides a clean resume point if the user
//  cancels (the Phase-1 cert is retained, so they can resume later without
//  redoing Phase 1).
//
//  The view observes `coordinator.state` (protocol-backed for testability)
//  and forwards user actions (begin / cancel) to the coordinator. The
//  "already exists" error is surfaced inline so the user can rename + resubmit
//  without redoing Phase 1.
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup D)
//

import SwiftUI
import Security
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Phase 2 registration sheet. Presented when a Teleport server's
/// readiness is `needsRegistration` (Phase-1 cert present, no SEP key yet).
///
/// The coordinator is injected (protocol `TeleportRegistrationCoordinating`)
/// so UI tests can script the "already exists" error + the SEP-key-creation
/// failure cases without a real gRPC client or real Face ID. Production
/// callers pass a `TeleportRegistrationCoordinator` (the `Live` impl).
struct TeleportRegistrationView: View {
    @ObservedObject var coordinator: any TeleportRegistrationCoordinating

    /// The cluster being registered against.
    let cluster: TeleportCluster

    /// The Phase-1 result (cert + TLS keypair for the gRPC mTLS dial).
    let bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult

    /// Called when Phase 2 succeeds (SEP key registered + persisted). The
    /// caller advances to the login sheet (or auto-connects).
    var onSuccess: () -> Void

    /// Called when the user cancels. The caller dismisses the sheet; the
    /// Phase-1 cert is retained so the user can resume here later.
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// The MFA device name. Prefilled with `vvterm-<device-name>` (sanitized).
    @State private var deviceName: String

    /// Inline validation error (empty name, or "already exists" from the server).
    @State private var nameError: String?

    init(
        coordinator: any TeleportRegistrationCoordinating,
        cluster: TeleportCluster,
        bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult,
        onSuccess: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.cluster = cluster
        self.bootstrapResult = bootstrapResult
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        // Prefill with the sanitized default via the Domain helper
        // (`TeleportDeviceName.default`). Using an initializer here
        // (rather than @State's initialValue) so the default is computed
        // once at view construction, not on every re-render.
        _deviceName = State(initialValue: TeleportDeviceName.default(rawDeviceName: Self.currentDeviceName()))
    }

    var body: some View {
        NavigationStack {
            Form {
                phaseOneCompleteSection
                explanationSection
                deviceNameSection
                errorSection
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Register Device Key"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        Task { await coordinator.cancel() }
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        beginRegistration()
                    } label: {
                        if isRegistering {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(String(localized: "Continue"))
                        }
                    }
                    .disabled(!isNameValid || isRegistering)
                }
            }
            .onChange(of: coordinator.state) { newValue in
                handleStateChange(newValue)
            }
        }
    }

    // MARK: - Sections

    private var phaseOneCompleteSection: some View {
        Section {
            Label {
                Text(String(localized: "Signed in to Teleport"))
                    .foregroundStyle(.green)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var explanationSection: some View {
        Section {
            Text(String(localized: "Now register this device's Secure Enclave key so future logins are seamless Face ID. Safari will open once more for you to approve, then you'll be prompted for Face ID here to save the key."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deviceNameSection: some View {
        Section {
            TextField(String(localized: "Device name"), text: $deviceName)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: deviceName) { _ in
                    // Clear the inline error as soon as the user edits.
                    if nameError != nil {
                        nameError = nil
                    }
                }

            Text(String(localized: "Used to identify this device in Teleport's admin panel. You can rename it freely."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(String(localized: "Device Name"))
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let nameError {
            Section {
                Label {
                    Text(nameError)
                        .foregroundStyle(.red)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Actions

    private func beginRegistration() {
        guard isNameValid else { return }
        nameError = nil
        Task {
            await coordinator.begin(
                cluster: cluster,
                deviceName: deviceName.trimmingCharacters(in: .whitespacesAndNewlines),
                bootstrapResult: bootstrapResult
            )
        }
    }

    private func handleStateChange(_ newValue: TeleportRegistrationState) {
        switch newValue {
        case .success:
            onSuccess()
        case .failed(let error):
            switch error {
            case .deviceNameAlreadyExists(let name):
                nameError = String(
                    format: String(localized: "A device named '%@' already exists for your Teleport user. Rename it, or delete the old device in Teleport's admin panel and retry."),
                    name
                )
            case .browserMFAFailed(let message):
                nameError = message
            case .sepKeyCreationFailed(let message):
                nameError = message
            case .server(let message):
                nameError = message
            case .unknown(let message):
                nameError = message
            }
        default:
            break
        }
    }

    // MARK: - Validation

    private var isNameValid: Bool {
        !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isRegistering: Bool {
        switch coordinator.state {
        case .connectingGRPC, .awaitingExistingAssertion, .creatingSEPKey, .registeringWithServer:
            return true
        case .idle, .success, .failed:
            return false
        }
    }

    // MARK: - Device-name defaulting

    /// The raw device name from the platform. Passed to
    /// `TeleportDeviceName.default(rawDeviceName:)` for sanitization.
    private static func currentDeviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Device"
        #endif
    }
}

// MARK: - Preview

#Preview("Registration — idle") {
    TeleportRegistrationView(
        coordinator: PreviewRegistrationCoordinator(state: .idle),
        cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"),
        bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult(
            sshCertPEM: "",
            tlsCertPEM: "",
            tlsKeyPairPrivateKey: SecKeyCreateRandomKey(
                [
                    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                    kSecAttrKeySizeInBits as String: 256
                ] as CFDictionary,
                nil
            )!,
            clusterName: "teleport.pcad.it",
            clusterCAPEMs: [],
            certValidBefore: Date(timeIntervalSinceNow: 3600)
        ),
        onSuccess: {},
        onCancel: {}
    )
}

#Preview("Registration — already exists") {
    TeleportRegistrationView(
        coordinator: PreviewRegistrationCoordinator(
            state: .failed(.deviceNameAlreadyExists("vvterm-pier-iphone"))
        ),
        cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"),
        bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult(
            sshCertPEM: "",
            tlsCertPEM: "",
            tlsKeyPairPrivateKey: SecKeyCreateRandomKey(
                [
                    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                    kSecAttrKeySizeInBits as String: 256
                ] as CFDictionary,
                nil
            )!,
            clusterName: "teleport.pcad.it",
            clusterCAPEMs: [],
            certValidBefore: Date(timeIntervalSinceNow: 3600)
        ),
        onSuccess: {},
        onCancel: {}
    )
}

// MARK: - Preview support

@MainActor
private final class PreviewRegistrationCoordinator: ObservableObject, TeleportRegistrationCoordinating {
    @Published var state: TeleportRegistrationState

    init(state: TeleportRegistrationState) {
        self.state = state
    }

    func begin(
        cluster: TeleportCluster,
        deviceName: String,
        bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult
    ) async {}

    func cancel() async {}
}
