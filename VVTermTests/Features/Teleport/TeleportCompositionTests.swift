// SPDX-License-Identifier: MIT
//
//  TeleportCompositionTests.swift
//  VVTermTests
//
//  Seam-contract coverage for the composition root: the per-presentation
//  factories must mint fresh instances (stateful gRPC clients must never be
//  shared across sheet presentations), and the composition must resolve the
//  single host keyring.
//

#if DEBUG
import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TeleportCompositionTests {

    private func makeComposition() -> TeleportComposition {
        let defaults = UserDefaults(suiteName: "TeleportCompositionTests-\(UUID().uuidString)") ?? .standard
        let keyRing = TeleportKeyRing(
            signer: MockSEPKeySigner(outcome: .success),
            logging: DefaultTeleportLogging(),
            config: TeleportKeychainConfig(
                keychainService: "app.vivy.vvterm.tests",
                defaults: defaults
            )
        )
        return TeleportComposition(
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            browserMFAPresenter: RecordingBrowserMFAPresenter()
        )
    }

    @Test
    func factoriesMintFreshPerPresentationInstances() {
        let composition = makeComposition()
        // Each sheet presentation gets its own coordinator/client graph; the
        // gRPC client's init sweeps stale keychain identities and its deinit
        // deletes the per-connect identity, so sharing one would be a bug.
        #expect(composition.makeBootstrapCoordinator() !== composition.makeBootstrapCoordinator())
        #expect(composition.makeRegistrationCoordinator() !== composition.makeRegistrationCoordinator())
        #expect(composition.makeLoginCoordinator() !== composition.makeLoginCoordinator())
        #expect(composition.makeBrowserMFACeremony() !== composition.makeBrowserMFACeremony())
    }

    @Test
    func sharedCompositionSharesStatelessSeamsAndMintsFreshClients() {
        // The shared composition must keep the stateless seams shared (one
        // credential store = the single host keyring) while minting a fresh
        // stateful client graph per presentation (the gRPC client sweeps +
        // deletes keychain identities).
        let composition = TeleportComposition.shared
        #expect(composition.credentialStore as? TeleportKeyRing === TeleportKeyRingHost.shared)
        #expect(composition.makeRegistrationCoordinator() !== composition.makeRegistrationCoordinator())
        #expect(composition.makeBootstrapCoordinator() !== composition.makeBootstrapCoordinator())
    }
}
#endif
