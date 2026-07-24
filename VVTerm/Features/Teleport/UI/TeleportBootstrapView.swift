// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportBootstrapView.swift
//  VVTerm
//
//  Phase 1 UI: the headless bootstrap sheet (design doc mockup C).
//
//  Auto-opens Safari on appear, shows "Approve in Safari" + spinner while the
//  blocking POST is in flight, and surfaces the 7-row error-recovery matrix
//  (user cancels, timeout, network loss, suspended, safari unavailable,
//  server error, already-logged-in).
//
//  The view observes `coordinator.state` (protocol-backed for testability)
//  and forwards user actions (cancel / retry) to the coordinator. No
//  business logic lives here — the coordinator owns the POST + Safari race.
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup C)
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Phase 1 bootstrap sheet. Presented when a Teleport server's readiness
/// is `needsBootstrap` (no Phase-1 cert in the keychain).
///
/// The coordinator is injected (protocol `TeleportBootstrapCoordinating`) so
/// UI tests can script every failure case in the recovery matrix without a
/// real Safari or Teleport server. Production callers pass a
/// `TeleportBootstrapCoordinator` (the `Live` impl).
struct TeleportBootstrapView: View {
    @ObservedObject var coordinator: any TeleportBootstrapCoordinating

    /// The cluster being bootstrapped. Held by the view so `retry()` can
    /// re-invoke `begin()` with the same config.
    let cluster: TeleportCluster

    /// Called when Phase 1 succeeds (cert in hand). The caller advances to
    /// the registration sheet. The bootstrap result is passed so the caller
    /// can hand it to the registration coordinator.
    var onSuccess: (TeleportBootstrapCoordinator.BootstrapResult) -> Void

    /// Called when the user cancels. The caller dismisses the sheet; the
    /// Phase-1 cert (if any) is retained for resume.
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                header

                statusBlock

                Spacer()

                actionButtons
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .navigationTitle(String(localized: "Teleport Setup"))
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
        .task {
            await coordinator.begin(cluster: cluster)
        }
        .onChange(of: coordinator.state) { newValue in
            if case .success = newValue, let result = coordinator.lastBootstrapResult {
                onSuccess(result)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari")
                .font(.system(size: 48))
                .foregroundStyle(.accentColor)

            Text(String(localized: "Approve in Safari"))
                .font(.title2.bold())
        }
    }

    // MARK: - Status block

    @ViewBuilder
    private var statusBlock: some View {
        switch coordinator.state {
        case .idle, .preparing, .openingSafari, .awaitingApproval:
            waitingBlock
        case .success:
            successBlock
        case .failed(let error):
            errorBlock(error)
        }
    }

    private var waitingBlock: some View {
        VStack(spacing: 12) {
            Text(String(localized: "Safari will open to \(cluster.host). Sign in with your iCloud passkey and approve the VVTerm login request."))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                Text(String(localized: "Waiting for Safari approval…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var successBlock: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text(String(localized: "Approved. Continuing…"))
                .font(.headline)
        }
    }

    @ViewBuilder
    private func errorBlock(_ error: TeleportBootstrapError) -> some View {
        VStack(spacing: 14) {
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

            if case .safariUnavailable = error {
                manualSafariLink
            }
        }
    }

    /// The "Open Safari manually" recovery: a tappable URL that copies to
    /// the clipboard. Shown when `ASWebAuthenticationSession.start()` failed
    /// (Safari disabled / unavailable).
    private var manualSafariLink: some View {
        let approvalURL = "https://\(cluster.host)/web/headless/"
        return VStack(spacing: 6) {
            Text(String(localized: "Open Safari manually:"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                #if os(iOS)
                UIPasteboard.general.string = approvalURL
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(approvalURL, forType: .string)
                #endif
            } label: {
                Text(approvalURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.accentColor)
                    .underline()
            }
            .buttonStyle(.plain)
            Text(String(localized: "Copied to clipboard."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        switch coordinator.state {
        case .failed(let error) where isRetryable(error):
            Button {
                Task { await coordinator.retry() }
            } label: {
                Label(String(localized: "Reopen Safari"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        default:
            EmptyView()
        }
    }

    // MARK: - Error presentation helpers

    private func errorIcon(_ error: TeleportBootstrapError) -> String {
        switch error {
        case .userCancelled:
            return "xmark.circle"
        case .timeout:
            return "clock.badge.exclamationmark"
        case .networkLost:
            return "wifi.slash"
        case .suspended:
            return "arrow.clockwise"
        case .safariUnavailable:
            return "safari"
        case .server:
            return "exclamationmark.triangle"
        case .unknown:
            return "exclamationmark.triangle"
        }
    }

    private func errorColor(_ error: TeleportBootstrapError) -> Color {
        switch error {
        case .userCancelled:
            return .secondary
        case .timeout, .networkLost, .suspended, .safariUnavailable, .server, .unknown:
            return .orange
        }
    }

    private func errorTitle(_ error: TeleportBootstrapError) -> String {
        switch error {
        case .userCancelled:
            return String(localized: "Setup Cancelled")
        case .timeout:
            return String(localized: "Approval Timed Out")
        case .networkLost:
            return String(localized: "Network Connection Lost")
        case .suspended:
            return String(localized: "Reconnecting…")
        case .safariUnavailable:
            return String(localized: "Safari Unavailable")
        case .server:
            return String(localized: "Teleport Server Error")
        case .unknown:
            return String(localized: "Setup Failed")
        }
    }

    private func errorMessage(_ error: TeleportBootstrapError) -> String {
        switch error {
        case .userCancelled:
            return String(localized: "Setup cancelled. Tap retry to start again.")
        case .timeout:
            return String(localized: "Safari approval timed out. Tap retry.")
        case .networkLost:
            return String(localized: "Network connection lost. Tap retry.")
        case .suspended:
            return String(localized: "Reconnecting…")
        case .safariUnavailable:
            return String(localized: "Safari couldn't open automatically. Open the URL below in Safari to approve.")
        case .server(let message):
            return message
        case .unknown(let message):
            return message
        }
    }

    /// Whether the error state offers a "Reopen Safari" retry button.
    /// `safariUnavailable` shows the manual-link recovery instead.
    private func isRetryable(_ error: TeleportBootstrapError) -> Bool {
        switch error {
        case .safariUnavailable:
            return false
        default:
            return true
        }
    }
}

// MARK: - Preview

#Preview("Bootstrap — waiting") {
    TeleportBootstrapView(
        coordinator: PreviewBootstrapCoordinator(state: .awaitingApproval),
        cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"),
        onSuccess: { _ in },
        onCancel: {}
    )
}

#Preview("Bootstrap — cancelled") {
    TeleportBootstrapView(
        coordinator: PreviewBootstrapCoordinator(state: .failed(.userCancelled)),
        cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"),
        onSuccess: { _ in },
        onCancel: {}
    )
}

// MARK: - Preview support

@MainActor
private final class PreviewBootstrapCoordinator: ObservableObject, TeleportBootstrapCoordinating {
    @Published var state: TeleportBootstrapState
    var lastBootstrapResult: TeleportBootstrapCoordinator.BootstrapResult?

    init(state: TeleportBootstrapState) {
        self.state = state
    }

    func begin(cluster: TeleportCluster) async {}
    func cancel() async {}
    func retry() async {}
}
