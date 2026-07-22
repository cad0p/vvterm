// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  iotestApp.swift
//  iotest
//
//  Session 1.6a — minimal iOS app that loads a WKWebView against
//  https://teleport.pcad.it/web/login and probes the WebAuthn JS surface.
//  Built for the iOS Simulator smoke test (CI); the device run proves the
//  ceremony.
//
//  Session 1.9 — added the "Headless" tab. The app now has two screens:
//    - Probe:    the 1.6a scaffolding probe (PublicKeyCredential exists,
//                platform authenticator available, JS round-trip).
//    - Headless: the 1.9 headless bootstrap (ephemeral keypair →
//                headlessAuthenticationID → blocking POST → Safari approval
//                → cert). Device-only; CI asserts the plumbing compiles +
//                the ID derivation matches a Go fixture.
//

import SwiftUI

@main
struct iotestApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ProbeView()
                    .tabItem { Label("Probe", systemImage: "stethoscope") }
                HeadlessView()
                    .tabItem { Label("Headless", systemImage: "key.fill") }
            }
            .onAppear {
                // Run the headless ID self-check on launch so CI can grep
                // for the headless_id_fixture_match marker.
                _ = HeadlessID.selfCheck()
            }
        }
    }
}
