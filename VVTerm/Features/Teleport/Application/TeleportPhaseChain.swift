// SPDX-License-Identifier: MIT
//
//  TeleportPhaseChain.swift
//  VVTerm
//
//  The single-source Teleport phase-chain decision (issue #369).
//
//  The prompt-on-connect setup flow chains three phases:
//
//      bootstrap → registration → login → ready
//
//  This value type owns the readiness + the in-memory Phase-1
//  `BootstrapResult` and derives which phase view to render. It is the ONE
//  place the chain decision lives: the production setup sheet renders
//  `chain.phase`, and the UI-test harness presents that same sheet, so a
//  routing regression can no longer stay green behind a mirrored switch.
//
//  Cancel is a dismissal, not a phase transition — the sheet calls its
//  `onFinish` directly; this type only models the success transitions.
//
//  See:
//    - VVTerm/Features/Teleport/UI/TeleportSetupSheet.swift (the renderer)
//    - VVTermTests/Features/Teleport/TeleportPhaseChainTests.swift
//

import Foundation
import TeleportCore
import TeleportAuth

/// The phase view the setup sheet renders.
enum TeleportPhaseChainPhase {
    /// Phase 1: no in-memory result is available and readiness does not
    /// carry one.
    case bootstrap
    /// Phase 2: Phase 1 succeeded and its result is available.
    case registration(TeleportBootstrapCoordinator.BootstrapResult)
    /// Phase 3: the SEP key is registered; a fresh cert is needed.
    case login
    /// Complete: nothing left to render (the sheet dismisses).
    case ready
}

/// readiness + the in-memory Phase-1 result → the phase to render.
///
/// `.needsRegistration` with no result falls back to `.bootstrap`: the TLS
/// keypair is ephemeral and not persisted, so a device that reaches
/// `.needsRegistration` without the in-memory result (e.g. the app was
/// killed between phases) must re-bootstrap to regenerate it.
struct TeleportPhaseChain {
    private(set) var readiness: TeleportDeviceReadiness
    private(set) var bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult?

    init(readiness: TeleportDeviceReadiness) {
        self.readiness = readiness
        self.bootstrapResult = nil
    }

    /// The phase view to render for the current readiness + result.
    var phase: TeleportPhaseChainPhase {
        switch readiness {
        case .needsBootstrap:
            return .bootstrap
        case .needsRegistration:
            if let bootstrapResult {
                return .registration(bootstrapResult)
            }
            // No in-memory result — re-bootstrap to regenerate the TLS
            // keypair, then chain to registration on success.
            return .bootstrap
        case .needsLogin:
            return .login
        case .ready:
            return .ready
        }
    }

    /// Phase 1 succeeded: hold the result (TLS keypair) in memory and advance
    /// to `.needsRegistration`. Must NOT dismiss or reach `.ready` — the user
    /// flows straight into Phase 2 (the #272 regression).
    mutating func bootstrapSucceeded(_ result: TeleportBootstrapCoordinator.BootstrapResult) {
        bootstrapResult = result
        readiness = .needsRegistration
    }

    /// Phase 2 succeeded: advance to `.needsLogin`.
    mutating func registrationSucceeded() {
        readiness = .needsLogin
    }

    /// Phase 3 succeeded: the chain is complete and the ephemeral Phase-1
    /// result is released.
    mutating func loginSucceeded() {
        readiness = .ready
        bootstrapResult = nil
    }
}
