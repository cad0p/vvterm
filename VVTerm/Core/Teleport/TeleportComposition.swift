// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportComposition.swift
//  VVTerm
//
//  The app-level Teleport composition root.
//
//  One place that owns the host-side seam set — the single keyring
//  (`TeleportKeyRingHost.shared`, configured with `TeleportKeychainConfig`
//  + `AppTeleportLogging`), the logging seam, and the browser-MFA presenter
//  — and mints **fresh per-presentation** coordinators/clients exactly as
//  the three previous inline factories did.
//
//  Stateful clients stay per-presentation: `LiveTeleportGRPCClient` sweeps
//  stale keychain identities in `init` and deletes its per-connect identity
//  in `deinit`, so it must never be shared across sheet presentations. Only
//  stateless seams (logging, config, presenter, store) are shared.
//
//  `VVTermApp` references the single instance at construction; the leaf
//  screens use the same instance (`TeleportComposition.shared`). The init
//  takes every seam so tests/harnesses can build an isolated composition.
//

import Foundation
import SwiftUI

@MainActor
final class TeleportComposition {
    /// The single app composition. Constructed when `VVTermApp` initializes.
    static let shared = TeleportComposition()

    /// The single credential owner (never construct a second keyring).
    private let keyRing: TeleportKeyRing
    private let logging: any TeleportLogging
    private let browserMFAPresenter: any BrowserMFAPresenting

    init(
        keyRing: TeleportKeyRing = TeleportKeyRingHost.shared,
        logging: any TeleportLogging = AppTeleportLogging.shared,
        browserMFAPresenter: (any BrowserMFAPresenting)? = nil
    ) {
        self.keyRing = keyRing
        self.logging = logging
        self.browserMFAPresenter = browserMFAPresenter ?? LiveBrowserMFAPresenter()
    }

    // MARK: - Per-presentation factories

    /// A fresh Phase-1 bootstrap coordinator (per sheet presentation).
    func makeBootstrapCoordinator() -> TeleportBootstrapCoordinator {
        TeleportBootstrapCoordinator(
            httpClient: LiveTeleportHTTPClient(),
            keyRing: keyRing,
            safariPresenter: WebAuthenticationSessionPresenter.shared,
            logging: logging,
            signer: SecureEnclaveSigner()
        )
    }

    /// A fresh Phase-2 registration coordinator (per sheet presentation).
    /// Mints its own gRPC client + ceremony: the client sweeps stale
    /// identities in `init`, so it is never shared.
    func makeRegistrationCoordinator() -> TeleportRegistrationCoordinator {
        TeleportRegistrationCoordinator(
            grpcClient: LiveTeleportGRPCClient(logging: logging),
            browserMFACeremony: makeBrowserMFACeremony(),
            keyRing: keyRing,
            logging: logging,
            signer: SecureEnclaveSigner(),
            webAuthnBuilder: TeleportWebAuthnBuilder()
        )
    }

    /// A fresh Phase-3 login coordinator (per sheet presentation).
    func makeLoginCoordinator() -> TeleportLoginCoordinator {
        TeleportLoginCoordinator(
            httpClient: LiveTeleportHTTPClient(),
            keyRing: keyRing,
            logging: logging,
            signer: SecureEnclaveSigner(),
            webAuthnBuilder: TeleportWebAuthnBuilder()
        )
    }

    /// A fresh Browser-MFA ceremony runner (per registration presentation)
    /// over the shared presenter seam.
    func makeBrowserMFACeremony() -> LiveBrowserMFACeremony {
        LiveBrowserMFACeremony(logging: logging, presenter: browserMFAPresenter)
    }
}

// MARK: - Environment injection

/// The composition injected at the app root. `nil` outside the app tree
/// (previews / UI-test harnesses), where call sites fall back to
/// `TeleportComposition.shared`.
private struct TeleportCompositionKey: EnvironmentKey {
    static let defaultValue: TeleportComposition? = nil
}

extension EnvironmentValues {
    var teleportComposition: TeleportComposition? {
        get { self[TeleportCompositionKey.self] }
        set { self[TeleportCompositionKey.self] = newValue }
    }
}
