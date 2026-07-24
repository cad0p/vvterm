// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  CeremonyView.swift
//  iotest
//
//  SwiftUI view for the 1.7 Ceremony screen. Shows:
//    - the 4-step checklist (Face ID prompt, login, privilege re-auth, extraction)
//    - a "Start ceremony" button
//    - the privilege token preview (on success)
//    - a log panel mirroring the os_log lines
//
//  The webview is shared with ProbeView via the WebAuthnProbeModel — the
//  ceremony JS runs in the same page context (https://teleport.pcad.it/web/login)
//  that the probe already loaded. This avoids a second webview + a second
//  page load, and means the ceremony sees the same JS state the probe saw.
//

import SwiftUI
import WebKit

struct CeremonyView: View {
    @ObservedObject var model: WebAuthnProbeModel
    @StateObject private var runner = CeremonyRunner()

    var body: some View {
        VStack(spacing: 0) {
            // Target + load-state banner (shared with probe).
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

            // Checklist
            VStack(alignment: .leading, spacing: 6) {
                ForEach(runner.steps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        statusIcon(step.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(step.id). \(step.title)")
                                .font(.subheadline.weight(.medium))
                            if !step.detail.isEmpty {
                                Text(step.detail)
                                    .font(.caption2).monospaced()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))

            // Start button + overall status
            HStack {
                Button(action: {
                    Task { await runner.runCeremony() }
                }) {
                    Label("Start ceremony", systemImage: "play.fill")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(runner.overallStatus == "running" || model.state.loadState != "loaded")

                if runner.overallStatus == "running" {
                    ProgressView().scaleEffect(0.8)
                }
                Spacer()
                statusBadge(runner.overallStatus)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            // Token previews (on success)
            if !runner.sessionTokenPreview.isEmpty || !runner.privilegeToken.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !runner.sessionTokenPreview.isEmpty {
                        tokenRow("Session token", runner.sessionTokenPreview)
                    }
                    if !runner.privilegeToken.isEmpty {
                        tokenRow("Privilege token", String(runner.privilegeToken.prefix(24)) + "…")
                    }
                }
                .padding(8)
                .background(Color.green.opacity(0.08))
            }

            Divider()

            // Log panel
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(runner.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.05))
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            runner.resetSteps()
            // Attach the shared webview so the runner can inject JS into it.
            if let webView = model.webView {
                runner.attach(webView: webView)
            }
            // Trigger the load if the probe tab hasn't been visited yet.
            if model.state.loadState == "idle" {
                model.load(url: model.targetURL)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func statusIcon(_ status: CeremonyStepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .inProgress:
            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case "idle":    return ("idle", .secondary)
            case "running": return ("running", .blue)
            case "passed":  return ("PASSED", .green)
            case "failed":  return ("FAILED", .red)
            default:        return (status, .secondary)
            }
        }()
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func tokenRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).monospaced()
        }
    }
}

#Preview {
    CeremonyView(model: WebAuthnProbeModel())
}
