// SPDX-License-Identifier: MIT
//
//  TeleportLoginView.swift
//  VVTerm
//
//  Phase 3 UI: the native passwordless login sheet (design doc mockup E).
//
//  One-tap Face ID. The coordinator does `loginBegin` → `WebAuthn.login`
//  (SEP signature, Face ID prompt fires automatically) → `loginFinish` →
//  cert lands in `TeleportKeyRing` → sheet dismisses → row badge flips to
//  green (the user connects from the row).
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
import TeleportCore
import TeleportAuth

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

    /// The host login already stored on the server row, if any. When it is
    /// still a principal of the fresh certificate the step renders it
    /// read-only (the choice is frozen per row); the picker only appears
    /// when no stored login applies.
    let storedHostLogin: String?

    /// Called when the user continues past the host-login step (cert issued +
    /// stored). The argument is the chosen certificate principal; the caller
    /// persists it on the server row and dismisses the sheet when the persist
    /// succeeds. No caller auto-connects.
    var onSuccess: (String) -> Void

    /// Called when the user cancels. The caller dismisses the sheet.
    var onCancel: () -> Void

    /// An optional notice shown above the host-login step (e.g. the reuse
    /// notice when the credential came from a duplicate server's setup).
    var reuseNotice: String? = nil

    /// The host login chosen in the Phase-3 step. Initialized from the stored
    /// login / the certificate's single principal when the coordinator
    /// reaches `.success`.
    @State private var selectedHostLogin: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                header

                clusterInfo

                if let reuseNotice {
                    // Shown before the cert is issued too, so the user knows
                    // the registration came from another row while Face ID
                    // runs.
                    Text(reuseNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("vvterm.teleport.login.reuseNotice")
                }

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
                        // Latch before the scheduled teardown: the latch's
                        // generation bump lands in this MainActor turn, so a
                        // continuation that has not yet passed its next re-take
                        // cannot start a keyring write or a terminal .success
                        // after the user cancelled. `cancel()` still runs the
                        // teardown.
                        coordinator.latchDismissal()
                        Task { await coordinator.cancel() }
                        onCancel()
                    }
                    .accessibilityIdentifier("vvterm.teleport.login.cancelButton")
                }
            }
        }
        .onChange(of: coordinator.state) { newValue in
            guard case .success(_, let logins) = newValue else {
                selectedHostLogin = nil
                return
            }
            // Prefer the stored login only while it is still a principal of
            // the fresh cert; single-principal certs auto-select, and several
            // principals with no stored login start with no selection.
            if selectedHostLogin == nil || !logins.contains(selectedHostLogin ?? "") {
                selectedHostLogin = TeleportHostLogin.initialSelection(
                    logins: logins,
                    stored: storedHostLogin
                )
            }
        }
        .onDisappear {
            // A swipe-down dismissal (iOS) / close (macOS) runs no toolbar
            // action; if the flow still has live work, latch the dismissal
            // synchronously (so a continuation that has not yet passed its
            // next re-take cannot start a keyring write or a terminal
            // .success) before the scheduled teardown. Terminal states are
            // left alone: `.success` is the host-login hand-off, and a
            // terminal `.failed` is the user's exit.
            guard coordinator.state.dismissalRequiresTeardown else { return }
            coordinator.latchDismissal()
            Task { await coordinator.cancel() }
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
        case .success(let certValidUntil, let logins):
            successView(certValidUntil: certValidUntil, logins: logins)
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

    private func successView(certValidUntil: Date, logins: [String]) -> some View {
        VStack(spacing: 14) {
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

            hostLoginStep(logins: logins)
        }
    }

    // MARK: - Host login step

    /// The Phase-3 "Host login" step, appended below the success copy (which
    /// stays visible). A stored login that is still a principal of the fresh
    /// certificate is shown read-only — no re-login picker, the choice is
    /// frozen per server row. Otherwise: with a single principal it is
    /// auto-selected and shown read-only (never silent); with several
    /// principals the user must pick one explicitly before Continue.
    @ViewBuilder
    private func hostLoginStep(logins: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Host login"))
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("vvterm.teleport.login.hostLoginTitle")

            if logins.isEmpty {
                // Defensive: the issued-cert validator rejects a cert with no
                // **non-internal** principals before `.success`, so this is a
                // setup error, not a retry loop.
                Text(String(localized: "The certificate carries no login for this host. Ask an administrator to grant a login for this host on the Teleport role, then run setup again."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("vvterm.teleport.login.hostLoginError")
            } else if let frozenLogin = frozenHostLogin(logins: logins) {
                // The row already has a frozen login and it is still a
                // principal: show it read-only, never the picker. The section
                // header above already names the field.
                Text(frozenLogin)
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("vvterm.teleport.login.hostLoginValue")
            } else if logins.count == 1 {
                // The section header above already names the field.
                Text(effectiveHostLogin(logins: logins) ?? "")
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("vvterm.teleport.login.hostLoginValue")
            } else {
                Text(String(localized: "This certificate carries several logins. Pick the one to use for this server."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(logins, id: \.self) { login in
                    Button {
                        selectedHostLogin = login
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: effectiveHostLogin(logins: logins) == login ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(effectiveHostLogin(logins: logins) == login ? Color.accentColor : Color.secondary)
                            Text(login)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("vvterm.teleport.login.hostLoginOption.\(login)")
                    .accessibilityAddTraits(effectiveHostLogin(logins: logins) == login ? .isSelected : [])
                    .accessibilityHint(String(localized: "Use this login for the server"))
                }
            }

            if !logins.isEmpty {
                Button {
                    guard let login = effectiveHostLogin(logins: logins) else { return }
                    onSuccess(login)
                } label: {
                    Text(String(localized: "Continue"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(effectiveHostLogin(logins: logins) == nil)
                .accessibilityIdentifier("vvterm.teleport.login.continueButton")
            }
        }
        .padding(.top, 4)
    }

    /// The row's stored login while it is still a principal of the fresh
    /// certificate. Present ⇒ the step renders read-only (no re-login picker).
    private func frozenHostLogin(logins: [String]) -> String? {
        guard let stored = Server.normalizedTeleportHostLogin(storedHostLogin),
              logins.contains(stored) else {
            return nil
        }
        return stored
    }

    /// The selection shown: the user's explicit pick when it is still a
    /// principal, otherwise the pure selection policy. Also keeps the step
    /// usable when the `.onChange` initialization did not run (e.g. the
    /// coordinator was already in `.success` when the view appeared).
    private func effectiveHostLogin(logins: [String]) -> String? {
        if let selectedHostLogin, logins.contains(selectedHostLogin) {
            return selectedHostLogin
        }
        return TeleportHostLogin.initialSelection(logins: logins, stored: storedHostLogin)
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
        storedHostLogin: nil,
        onSuccess: { _ in },
        onCancel: {}
    )
}

#Preview("Login — success") {
    TeleportLoginView(
        coordinator: PreviewLoginCoordinator(
            state: .success(certValidUntil: Date(timeIntervalSinceNow: 12 * 3600), logins: ["deploy", "root"])
        ),
        cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"),
        storedHostLogin: "deploy",
        onSuccess: { _ in },
        onCancel: {}
    )
}

#Preview("Login — face ID cancelled") {
    TeleportLoginView(
        coordinator: PreviewLoginCoordinator(state: .failed(.faceIDCancelled)),
        cluster: TeleportCluster(host: "teleport.pcad.it", username: "pier"),
        storedHostLogin: nil,
        onSuccess: { _ in },
        onCancel: {}
    )
}

// MARK: - Preview support

@MainActor
private final class PreviewLoginCoordinator: ObservableObject, TeleportLoginCoordinating {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    @Published var state: TeleportLoginState

    init(state: TeleportLoginState) {
        self.state = state
    }

    func begin(cluster: TeleportCluster) async {}
    func cancel() async {}
    func latchDismissal() {}
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
