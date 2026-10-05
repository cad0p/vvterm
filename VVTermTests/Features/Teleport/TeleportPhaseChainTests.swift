// SPDX-License-Identifier: MIT
//
//  TeleportPhaseChainTests.swift
//  VVTermTests
//
//  Unit tests for the single-source Teleport phase-chain state machine
//  (issue #369). `BootstrapResult` is not `Equatable` (it holds a `SecKey`),
//  so phase assertions pattern-match and the carried result is compared
//  field-wise (`sshCertPEM`) plus by private-key identity.
//
//  See:
//    - VVTerm/Features/Teleport/Application/TeleportPhaseChain.swift
//    - VVTermTests/Features/Teleport/TeleportSetupSheetPinsTests.swift (the
//      source pin that keeps the chain single-source)
//

import Foundation
import Testing
@testable import VVTerm

@Suite
@MainActor
struct TeleportPhaseChainTests {

    // MARK: - Helpers

    private func isBootstrap(_ phase: TeleportPhaseChainPhase) -> Bool {
        if case .bootstrap = phase { return true }
        return false
    }

    private func isLogin(_ phase: TeleportPhaseChainPhase) -> Bool {
        if case .login = phase { return true }
        return false
    }

    private func isReady(_ phase: TeleportPhaseChainPhase) -> Bool {
        if case .ready = phase { return true }
        return false
    }

    private func registrationResult(
        _ phase: TeleportPhaseChainPhase
    ) -> TeleportBootstrapCoordinator.BootstrapResult? {
        if case .registration(let result) = phase { return result }
        return nil
    }

    // MARK: - 1. Initial phase matrix

    @Test
    func initialPhaseMatrix() throws {
        // .needsBootstrap → .bootstrap
        #expect(isBootstrap(TeleportPhaseChain(readiness: .needsBootstrap).phase))
        // .needsRegistration with no in-memory result → .bootstrap (fallback:
        // the ephemeral TLS keypair was lost, e.g. the app was killed).
        #expect(isBootstrap(TeleportPhaseChain(readiness: .needsRegistration).phase))
        // .needsLogin → .login
        #expect(isLogin(TeleportPhaseChain(readiness: .needsLogin).phase))
        // .ready → .ready
        #expect(isReady(TeleportPhaseChain(readiness: .ready).phase))

        // .needsRegistration with a stored result → .registration, carrying
        // the SAME result (not a reconstructed one).
        let result = try TeleportFixtureSupport.makeBootstrapResult()
        var withResult = TeleportPhaseChain(readiness: .needsBootstrap)
        withResult.bootstrapSucceeded(result)
        let stored = try #require(registrationResult(withResult.phase))
        #expect(stored.sshCertPEM == result.sshCertPEM)
        #expect(stored.tlsKeyPairPrivateKey === result.tlsKeyPairPrivateKey)
    }

    // MARK: - 2. bootstrapSucceeded (the #272 transition)

    @Test
    func bootstrapSucceededAdvancesToRegistrationAndKeepsResult() throws {
        let result = try TeleportFixtureSupport.makeBootstrapResult()
        var chain = TeleportPhaseChain(readiness: .needsBootstrap)

        chain.bootstrapSucceeded(result)

        // The #272 regression: bootstrap success must advance to
        // registration, NOT dismiss / reach `.ready`.
        #expect(chain.readiness == .needsRegistration)
        let stored = try #require(registrationResult(chain.phase))
        #expect(stored.sshCertPEM == result.sshCertPEM)
        #expect(stored.tlsKeyPairPrivateKey === result.tlsKeyPairPrivateKey)
        #expect(chain.bootstrapResult?.sshCertPEM == result.sshCertPEM)
        #expect(chain.bootstrapResult?.tlsKeyPairPrivateKey === result.tlsKeyPairPrivateKey)
    }

    // MARK: - 3. registrationSucceeded

    @Test
    func registrationSucceededAdvancesToLogin() throws {
        var chain = TeleportPhaseChain(readiness: .needsBootstrap)
        chain.bootstrapSucceeded(try TeleportFixtureSupport.makeBootstrapResult())

        chain.registrationSucceeded()

        #expect(chain.readiness == .needsLogin)
        #expect(isLogin(chain.phase))
    }

    // MARK: - 4. loginSucceeded

    @Test
    func loginSucceededReachesReadyAndClearsResult() throws {
        var chain = TeleportPhaseChain(readiness: .needsLogin)

        chain.loginSucceeded()

        #expect(chain.readiness == .ready)
        #expect(isReady(chain.phase))
        #expect(chain.bootstrapResult == nil)
    }

    // MARK: - 5. A second bootstrapSucceeded replaces the stored result

    @Test
    func secondBootstrapSucceededReplacesStoredResult() throws {
        let first = try TeleportFixtureSupport.makeBootstrapResult()
        let second = try TeleportFixtureSupport.makeBootstrapResult()
        var chain = TeleportPhaseChain(readiness: .needsBootstrap)

        chain.bootstrapSucceeded(first)
        chain.bootstrapSucceeded(second)

        let stored = try #require(registrationResult(chain.phase))
        #expect(stored.sshCertPEM == second.sshCertPEM)
        #expect(stored.tlsKeyPairPrivateKey === second.tlsKeyPairPrivateKey)
        #expect(stored.tlsKeyPairPrivateKey !== first.tlsKeyPairPrivateKey)
    }
}
