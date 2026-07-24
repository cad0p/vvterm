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
//  Session 1.7 — added the "Ceremony" tab. The app now has two screens:
//    - Probe:    the 1.6a scaffolding probe (PublicKeyCredential exists,
//                platform authenticator available, JS round-trip).
//    - Ceremony: the 1.7 end-to-end ceremony (Face ID → login → privilege
//                token → extraction). Device-only.
//
//  Both tabs share the same WebAuthnProbeModel (and thus the same WKWebView),
//  so the ceremony JS runs in the page context the probe already loaded.
//

import SwiftUI

@main
struct iotestApp: App {
    @StateObject private var model = WebAuthnProbeModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                ProbeView(model: model)
                    .tabItem { Label("Probe", systemImage: "stethoscope") }
                CeremonyView(model: model)
                    .tabItem { Label("Ceremony", systemImage: "lock.shield") }
            }
        }
    }
}
