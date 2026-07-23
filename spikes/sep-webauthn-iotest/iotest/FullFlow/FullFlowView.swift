// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  FullFlowView.swift
//  iotest
//
//  Session 1.10 — the "Full Flow" tab that chains Phase 1 (headless
//  bootstrap) → Phase 2 (gRPC register SEP key) → Phase 3 (passwordless
//  login with the SEP key).
//

import SwiftUI
import UIKit

struct FullFlowView: View {
    @StateObject private var runner = FullFlowRunner()
    @State private var username: String = ""
    @State private var host: String = "teleport.pcad.it"
    @State private var deviceName: String = "vvterm-spike"

    var body: some View {
        VStack(spacing: 0) {
            // Config banner
            HStack {
                Text("Target:")
                    .font(.caption).foregroundStyle(.secondary)
                Text("https://\(host)")
                    .font(.caption).monospaced()
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))

            // Config: username + host
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
                HStack {
                    Text("Host:")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("teleport proxy host", text: $host)
                        .font(.caption).monospaced()
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Device:")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("MFA device name", text: $deviceName)
                        .font(.caption).monospaced()
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }
                Text("Device name must be unique per Teleport user. If a run fails with “already exists”, delete the old device in the Teleport web portal (Settings → Management → Devices / Add MFA Device) and retry, or pick a new name.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))

            // Phases
            VStack(alignment: .leading, spacing: 6) {
                ForEach(runner.phases) { phase in
                    HStack(alignment: .top, spacing: 8) {
                        phaseIcon(phase.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(phase.phase.rawValue)
                                .font(.subheadline.weight(.medium))
                            if !phase.detail.isEmpty {
                                Text(phase.detail)
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
                    Task { await runner.run(user: username, host: host, deviceName: deviceName) }
                }) {
                    Label("Run full chain", systemImage: "play.fill")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(runner.overallStatus == "running" || username.isEmpty || deviceName.isEmpty)

                if runner.overallStatus == "running" {
                    ProgressView().scaleEffect(0.8)
                }
                Spacer()
                Button(action: {
                    UIPasteboard.general.string = runner.fullLogDump()
                }) {
                    Label("Copy logs", systemImage: "doc.on.doc")
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(runner.log.isEmpty)
                statusBadge(runner.overallStatus)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            // Phase results
            if runner.phase1CertLength > 0 || !runner.error.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if runner.phase1CertLength > 0 {
                        resultRow("Phase 1 cert:", "\(runner.phase1CertLength) chars (\(String(format: "%.1f", runner.phase1Duration))s)")
                        resultRow("Phase 1 TLS cert:", "\(runner.phase1TLSCertLength) chars")
                    }
                    if !runner.phase2CredentialID.isEmpty {
                        resultRow("Phase 2 SEP credID:", String(runner.phase2CredentialID.prefix(32)) + "…")
                    }
                    if runner.phase3CertLength > 0 {
                        resultRow("Phase 3 login cert:", "\(runner.phase3CertLength) chars")
                    }
                    if !runner.error.isEmpty {
                        HStack(alignment: .top) {
                            Text("Error:")
                                .font(.caption).foregroundStyle(.red)
                            Spacer()
                            Text(runner.error)
                                .font(.caption2).monospaced()
                                .foregroundStyle(.red)
                                .lineLimit(4)
                        }
                    }
                }
                .padding(8)
                .background(runner.error.isEmpty
                            ? Color.green.opacity(0.08)
                            : Color.red.opacity(0.08))
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
            runner.resetPhases()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func phaseIcon(_ status: String) -> some View {
        switch status {
        case "pending":
            Image(systemName: "circle").foregroundStyle(.secondary)
        case "running":
            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
        case "passed":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "failed":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        default:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption2).monospaced()
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
    FullFlowView()
}
