// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportLoginView.swift
//  VVTerm
//
//  Phase 3 UI: the native passwordless login sheet (design doc mockup E).
//
//  One-tap Face ID. The coordinator does `loginBegin` → `WebAuthn.login`
//  (SEP signature, Face ID prompt fires automatically) → `loginFinish` →
//  cert lands in `TeleportKeyRing` → sheet dismisses → row badge flips to
//  green → auto-connect.
//
//  The cert TTL is dynamic — read from `cert.ValidBefore`, never hardcoded.
//  Before login: generic copy ("Your SSH certificate will be issued by
//  Teleport. Its validity depends on the cluster's role policy."). After
//  login: "Signed in. Certificate valid for <relative time> (until
//  <absolute time>)." computed from the success state's `certValidUntil`.
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup E)
//

import SwiftUI

/// The Phase 3 login sheet. Presented when a Teleport server's readiness is
/// `needsLogin` (SEP key present, cert missing or expired).
///
/// The coordinator is injected (protocol `TeleportLoginCoordinating`) so UI
/// tests can script the Face ID success/cancel/unavailable outcomes via a
/// `MockSEPKeySigner` without a real Secure Enclave. Production callers pass
/// a `TeleportLoginCoordinator` (the `Live` impl).
struct TeleportLoginView: View {
    @ObservedObject var coordinator: any TeleportLoginCoordinating

    /// The cluster being logged in to.
    let cluster: TeleportCluster

    /// Called when Phase 3 succeeds (cert issued + stored). The caller
    /// dismisses the sheet and auto-connects.
    var onSuccess: () -> Void

    /// Called when the user cancels. The caller dismisses the sheet.
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                header

                clusterInfo

                signInButton

                footerCopy

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .navigationTitle(String(localized: "Sign in to Teleport"))
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
            }
        }
        .onChange(of: coordinator.state) { newValue in
            if case .success = newValue {
                onSuccess()
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundStyle(.accentColor)

            Text(String(localized: "Sign in with Face ID"))
                .font(.title2.bold())
        }
    }

    // MARK: - Cluster info

    private var clusterInfo: some View {
        VStack(spacing: 4) {
            Text(cluster.host)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(String(format: String(localized: "user: %@"), cluster.username))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sign-in button

    @ViewBuilder
    private var signInButton: some View {
        switch coordinator.state {
        case .awaitingFaceID, .fetchingCert:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
        case .success(let certValidUntil):
            successView(certValidUntil: certValidUntil)
        case .failed(let error):
            errorView(error)
        case .idle:
            Button {
                Task { await coordinator.begin(cluster: cluster) }
            } label: {
                Text(String(localized: "Sign in with Face ID"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Success

    private func successView(certValidUntil: Date) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)

            Text(String(localized: "Signed in"))
                .font(.headline)

            Text(certificateValidityText(certValidUntil: certValidUntil))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Error

    private func errorView(_ error: TeleportLoginError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: errorIcon(error))
                .font(.system(size: 36))
                .foregroundStyle(errorColor(error))

            Text(errorTitle(error))
                .font(.headline)

            Text(errorMessage(error))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await coordinator.begin(cluster: cluster) }
            } label: {
                Label(String(localized: "Try Again"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Footer copy

    @ViewBuilder
    private var footerCopy: some View {
        switch coordinator.state {
        case .success:
            EmptyView()
        default:
            Text(String(localized: "Your SSH certificate will be issued by Teleport. Its validity depends on the cluster's role policy."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Certificate validity text

    /// "Signed in. Certificate valid for <relative time> (until <absolute time>)."
    /// Computed from `certValidBefore` — never hardcoded.
    private func certificateValidityText(certValidUntil: Date) -> String {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        let relativeString = relative.localizedString(for: certValidUntil, relativeTo: Date())

        let absoluteFormatter = DateFormatter()
        absoluteFormatter.dateStyle = .short
        absoluteFormatter.timeStyle = .short
        let absoluteString = absoluteFormatter.string(from: certValidUntil)

        return String(
            format: String(localized: "Certificate valid for %@ (until %@)."),
            relativeString,
            absoluteString
        )
    }

    // MARK: - Error presentation helpers

    private func errorIcon(_ error: TeleportLoginError) -> String {
        switch error {
        case .faceIDCancelled:
            return "xmark.circle"
        case .faceIDUnavailable:
            return "faceid"
        case .server:
            return "exclamationmark.triangle"
        case .networkLost:
            return "wifi.slash"
        case .noRegisteredKey:
            return "key.slash"
        case .unknown:
            return "exclamationmark.triangle"
        }
    }

    private func errorColor(_ error: TeleportLoginError) -> Color {
        switch error {
        case .faceIDCancelled:
            return .secondary
        case .faceIDUnavailable, .noRegisteredKey:
            return .orange
        case .server, .networkLost, .unknown:
            return .orange
        }
    }

    private func errorTitle(_ error: TeleportLoginError) -> String {
        switch error {
        case .faceIDCancelled:
            return String(localized: "Face ID Cancelled")
        case .faceIDUnavailable:
            return String(localized: "Face ID Unavailable")
        case .server:
            return String(localized: "Teleport Server Error")
        case .networkLost:
            return String(localized: "Network Connection Lost")
        case .noRegisteredKey:
            return String(localized: "No Registered Key")
        case .unknown:
            return String(localized: "Sign In Failed")
        }
    }

    private func errorMessage(_ error: TeleportLoginError) -> String {
        switch error {
        case .faceIDCancelled:
            return String(localized: "Face ID cancelled. Tap to try again.")
        case .faceIDUnavailable(let message):
            return message
        case .server(let message):
            return message
        case .networkLost:
            return String(localized: "Couldn't reach Teleport. Tap to retry.")
        case .noRegisteredKey:
            return String(localized: "No Secure Enclave key is registered for this cluster. Complete setup first.")
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Preview

#Preview("Login — idle") {
    TeleportLoginView(
        coordinator: PreviewLoginCoordinator(state: .idle),
        cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"),
        onSuccess: {},
        onCancel: {}
    )
}

#Preview("Login — success") {
    TeleportLoginView(
        coordinator: PreviewLoginCoordinator(
            state: .success(certValidUntil: Date(timeIntervalSinceNow: 12 * 3600))
        ),
        cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"),
        onSuccess: {},
        onCancel: {}
    )
}

#Preview("Login — face ID cancelled") {
    TeleportLoginView(
        coordinator: PreviewLoginCoordinator(state: .failed(.faceIDCancelled)),
        cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"),
        onSuccess: {},
        onCancel: {}
    )
}

// MARK: - Preview support

@MainActor
private final class PreviewLoginCoordinator: ObservableObject, TeleportLoginCoordinating {
    @Published var state: TeleportLoginState

    init(state: TeleportLoginState) {
        self.state = state
    }

    func begin(cluster: TeleportCluster) async {}
    func cancel() async {}
}
