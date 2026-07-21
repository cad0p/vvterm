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

import SwiftUI

@main
struct iotestApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeView()
        }
    }
}
