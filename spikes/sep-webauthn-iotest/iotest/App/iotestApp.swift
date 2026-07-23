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
//  Session 1.9 — added the "Headless" tab.
//  Session 1.10 — added the "Full Flow" tab (cert → gRPC → SEP-key → login).
//
//  The app now has three screens:
//    - Probe:     the 1.6a scaffolding probe.
//    - Headless:  the 1.9 headless bootstrap (standalone).
//    - Full Flow: the 1.10 full chain (Phase 1 reuses Headless, Phase 2 is
//                 the gRPC SEP-key registration, Phase 3 is passwordless
//                 login with the registered key).
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
                FullFlowView()
                    .tabItem { Label("Full Flow", systemImage: "link.badge.plus") }
            }
            .onAppear {
                // Run the headless ID self-check on launch so CI can grep
                // for the headless_id_fixture_match marker.
                _ = HeadlessID.selfCheck()
            }
        }
    }
}
