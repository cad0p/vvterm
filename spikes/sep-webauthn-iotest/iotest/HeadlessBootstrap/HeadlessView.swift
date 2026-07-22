// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  HeadlessView.swift
//  iotest
//
//  SwiftUI view for the 1.9 Headless Bootstrap screen. Shows:
//    - the 6-step checklist (keypair, ID, POST, Safari, approve, cert)
//    - a username field + method toggle (ASWebAuthenticationSession vs
//      UIApplication.open)
//    - a "Start bootstrap" button
//    - the cert preview (on success)
//    - the POST duration + error (the device-only signals)
//    - a log panel mirroring the os_log lines
//

import SwiftUI

struct HeadlessView: View {
    @StateObject private var runner = HeadlessRunner()
    @State private var username: String = ""
    @State private var useASWebAuth: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Target + config banner
            HStack {
                Text("Target:")
                    .font(.caption).foregroundStyle(.secondary)
                Text(runner.baseURL.absoluteString)
                    .font(.caption).monospaced()
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))

            // Config: username + method
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("User:")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("teleport username", text: $username)
                        .font(.caption).monospaced()
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }
                Toggle(isOn: $useASWebAuth) {
                    Text("Use ASWebAuthenticationSession")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                Text(useASWebAuth
                     ? "ASWebAuthenticationSession (in-app Safari, may keep VVTerm active)"
                     : "UIApplication.open (full app switch to Safari)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))

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
                    Task { await runner.runBootstrap(user: username, useASWebAuth: useASWebAuth) }
                }) {
                    Label("Start bootstrap", systemImage: "play.fill")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(runner.overallStatus == "running" || username.isEmpty)

                if runner.overallStatus == "running" {
                    ProgressView().scaleEffect(0.8)
                }
                Spacer()
                statusBadge(runner.overallStatus)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            // POST duration + error (the device-only signals)
            if runner.postDuration > 0 || !runner.postError.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if runner.postDuration > 0 {
                        HStack {
                            Text("POST duration:")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1f s", runner.postDuration))
                                .font(.caption).monospaced()
                        }
                    }
                    if !runner.postError.isEmpty {
                        HStack(alignment: .top) {
                            Text("POST error:")
                                .font(.caption).foregroundStyle(.red)
                            Spacer()
                            Text(runner.postError)
                                .font(.caption2).monospaced()
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(8)
                .background(runner.postError.isEmpty
                            ? Color.green.opacity(0.08)
                            : Color.red.opacity(0.08))
            }

            // Cert preview (on success)
            if !runner.certBase64.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Cert (PEM):")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(runner.certBase64.count) chars")
                            .font(.caption2).monospaced().foregroundStyle(.secondary)
                    }
                    Text(String(runner.certBase64.prefix(120)) + "…")
                        .font(.caption2).monospaced()
                        .lineLimit(3)
                        .textSelection(.enabled)
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
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func statusIcon(_ status: HeadlessStepStatus) -> some View {
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
}

#Preview {
    HeadlessView()
}
