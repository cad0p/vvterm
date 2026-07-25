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
import Combine

/// The Phase 3 login sheet. Presented when a Teleport server's readiness is
/// `needsLogin` (SEP key present, cert missing or expired).
///
/// The coordinator is injected (protocol `TeleportLoginCoordinating`) so UI
/// tests can script the Face ID success/cancel/unavailable outcomes via a
/// `MockSEPKeySigner` without a real Secure Enclave. Production callers pass
/// a `TeleportLoginCoordinator` (the `Live` impl).
struct TeleportLoginView<Coordinator: TeleportLoginCoordinating>: View {
    @ObservedObject var coordinator: Coordinator

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
                    .accessibilityIdentifier("vvterm.teleport.login.cancelButton")
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
                .foregroundStyle(Color.accentColor)

            Text(String(localized: "Sign in with Face ID"))
                .font(.title2.bold())
                .accessibilityIdentifier("vvterm.teleport.login.header")
        }
    }

    // MARK: - Cluster info

    private var clusterInfo: some View {
        VStack(spacing: 4) {
            Text(cluster.host)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("vvterm.teleport.login.clusterHost")
            Text(String(format: String(localized: "user: %@"), cluster.username))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("vvterm.teleport.login.clusterUser")
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
                .accessibilityIdentifier("vvterm.teleport.login.inFlight")
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
            .accessibilityIdentifier("vvterm.teleport.login.signInButton")
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
                .accessibilityIdentifier("vvterm.teleport.login.successTitle")

            Text(certificateValidityText(certValidUntil: certValidUntil))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("vvterm.teleport.login.successMessage")
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
                .accessibilityIdentifier("vvterm.teleport.login.errorTitle")

            Text(errorMessage(error))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("vvterm.teleport.login.errorMessage")

            Button {
                Task { await coordinator.begin(cluster: cluster) }
            } label: {
                Label(String(localized: "Try Again"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("vvterm.teleport.login.retryButton")
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
                .accessibilityIdentifier("vvterm.teleport.login.footer")
        }
    }

    // MARK: - Certificate validity text

    /// "Signed in. Certificate valid in <relative time> (until <absolute time>)."
    /// Computed from `certValidBefore` — never hardcoded.
    ///
    /// `RelativeDateTimeFormatter` includes the leading preposition "in" in
    /// its output (e.g. "in 12 hours"), so the format string omits "for" to
    /// avoid the duplicated "valid for in 12 hours".
    private func certificateValidityText(certValidUntil: Date) -> String {
        TeleportValidityCopy.certificateValidityText(
            certValidUntil: certValidUntil,
            relativeTo: Date()
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

// MARK: - Certificate validity copy formatting

/// Formats the relative-time portion of the "Certificate valid for …" copy
/// shown in the login sheet's success state.
///
/// `RelativeDateTimeFormatter` floors the remaining interval to the largest
/// whole unit (e.g. 11h 59m 59s → "in 11 hours", 59m 59s → "in 59 minutes").
/// Because the cert's `validBefore` is captured when the coordinator issues
/// it but the copy is formatted a moment later when SwiftUI re-renders, a
/// cert issued with an exact N-hour TTL can display as "N-1 hours" purely
/// due to sub-second render drift.
///
/// To avoid that misleading off-by-one, the remaining interval is rounded to
/// the nearest whole minute before formatting. A 12h TTL that has drifted by
/// a few seconds (11h 59m 59s) rounds up to 12h 00m and renders as
/// "in 12 hours"; a 1h TTL (59m 59s) rounds up to 1h 00m and renders as
/// "in 1 hour". Genuine elapsed time (>= 30s past a minute boundary) still
/// rounds down as expected.
enum TeleportValidityCopy {
    /// The rounding granularity in seconds. Sub-minute drift from UI render
    /// latency is absorbed by rounding to the nearest minute.
    private static let roundingGranularity: TimeInterval = 60

    /// Returns a localized relative-time string for `certValidUntil` relative
    /// to `referenceDate`, with the remaining interval rounded to the nearest
    /// minute to avoid off-by-one flooring.
    ///
    /// - Parameters:
    ///   - certValidUntil: the cert's `validBefore` date.
    ///   - referenceDate: the "now" to compute the remaining interval against
    ///     (defaults to `Date()` at call time in production).
    /// - Returns: a localized string such as "in 12 hours" or "in 1 hour".
    static func relativeValidityString(
        for certValidUntil: Date,
        relativeTo referenceDate: Date
    ) -> String {
        let remaining = certValidUntil.timeIntervalSince(referenceDate)
        // Round to the nearest minute to absorb sub-minute render drift
        // (the cert's `validBefore` is captured when the coordinator issues
        // it, but the copy is formatted a moment later when SwiftUI
        // re-renders). Without this, a 12h TTL that drifted to 11h59m59s
        // would floor to "in 11 hours".
        //
        // Uses the default `.toNearestOrEven` (banker's) rounding; for the
        // realistic TTL range (>= 1 minute) this is equivalent to schoolbook
        // rounding because the sub-minute remainder is never exactly 0.5.
        let roundedRemaining = (remaining / roundingGranularity).rounded() * roundingGranularity
        let roundedExpiry = referenceDate.addingTimeInterval(roundedRemaining)

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: roundedExpiry, relativeTo: referenceDate)
    }

    /// Builds the full success-copy string shown in the login sheet's success
    /// state: "Certificate valid in <relative> (until <absolute>)."
    ///
    /// `relativeValidityString(for:relativeTo:)` returns a string that already
    /// includes the leading preposition "in" (e.g. "in 12 hours"), so the
    /// format string MUST NOT prepend "for" — that would produce the
    /// ungrammatical "Certificate valid for in 12 hours".
    ///
    /// - Parameters:
    ///   - certValidUntil: the cert's `validBefore` date.
    ///   - referenceDate: the "now" to compute the relative interval against.
    ///   - absoluteFormatter: the formatter for the absolute timestamp portion.
    ///     Defaults to a short date + short time formatter.
    /// - Returns: the localized success copy.
    static func certificateValidityText(
        certValidUntil: Date,
        relativeTo referenceDate: Date,
        absoluteFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            return f
        }()
    ) -> String {
        let relativeString = relativeValidityString(
            for: certValidUntil,
            relativeTo: referenceDate
        )
        let absoluteString = absoluteFormatter.string(from: certValidUntil)
        return String(
            format: String(localized: "Certificate valid %@ (until %@)."),
            relativeString,
            absoluteString
        )
    }
}
