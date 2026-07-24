// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  ProbeView.swift
//  iotest
//
//  SwiftUI view hosting the WKWebView + a log panel. The log panel mirrors
//  the structured os_log lines so a human can read them in the simulator
//  and the CI workflow can grep the unified log.
//

import SwiftUI
import WebKit

struct ProbeView: View {
    @ObservedObject var model: WebAuthnProbeModel

    var body: some View {
        VStack(spacing: 0) {
            // Target URL banner
            HStack {
                Text("Target:")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.targetURL.absoluteString)
                    .font(.caption).monospaced()
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(model.state.loadState)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))

            // Probe summary
            VStack(alignment: .leading, spacing: 4) {
                summaryRow("PublicKeyCredential exists",
                           value: model.state.publicKeyCredentialExists.map { $0 ? "✓ yes" : "✗ no" } ?? "—")
                summaryRow("Platform authenticator available",
                           value: model.state.platformAuthenticatorAvailable.map { $0 ? "✓ yes" : "✗ no" } ?? "—")
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))

            // WKWebView
            WebViewRepresentable(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Log panel
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.state.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: 180)
            .background(Color.black.opacity(0.05))
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            ProbeLog.appLaunched()
            // Only load if not already loaded (the Ceremony tab may have
            // triggered it, or we may be re-appearing after a tab switch).
            if model.state.loadState == "idle" {
                model.load(url: model.targetURL)
            }
        }
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).monospaced()
        }
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let model: WebAuthnProbeModel

    func makeUIView(context: Context) -> WKWebView {
        model.makeWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No-op; the model loads on appear.
    }
}

#Preview {
    ProbeView(model: WebAuthnProbeModel())
}
