// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  sepbiometryApp.swift
//  sepbiometry
//
//  Session 1.6b Option A — iOS app that runs the SEP+biometry WebAuthn
//  flow against teleport.pcad.it. The user pastes an invite token, taps
//  Run, and gets two Face ID prompts (steps 5 and 7). If a cert is
//  returned, the SEP biometry path is confirmed on iOS/Face ID.
//

import SwiftUI

@main
struct sepbiometryApp: App {
    var body: some Scene {
        WindowGroup {
            SEPBiometryView()
        }
    }
}
