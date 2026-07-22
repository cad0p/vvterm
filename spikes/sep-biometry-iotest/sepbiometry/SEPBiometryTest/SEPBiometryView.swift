// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  SEPBiometryView.swift
//  sepbiometry
//
//  SwiftUI view for the 1.6b Option A test. Shows:
//    - a token input field (paste the invite token's last path segment)
//    - a "Register + Login" button
//    - the 7 steps with status + detail
//    - the returned cert (base64) on success
//    - an error panel on failure
//

import SwiftUI

struct SEPBiometryView: View {
    @StateObject private var runner = SEPBiometryTestRunner()
    @State private var token: String = ""
    @State private var host: String = "teleport.pcad.it"

    private let stepIcons: [SEPBiometryStepStatus: String] = [
        .pending: "○", .inProgress: "⏳", .done: "✓", .failed: "✗",
    ]
    private let stepColors: [SEPBiometryStepStatus: Color] = [
        .pending: .secondary, .inProgress: .orange, .done: .green, .failed: .red,
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Input panel
                VStack(alignment: .leading, spacing: 8) {
                    Text("1.6b Option A — SEP + biometry on iOS")
                        .font(.headline)
                    Text("Mint a fresh invite token on pcad-it, paste it below, tap Run. Two Face ID prompts should appear (steps 5 and 7).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Host") {
                        TextField("teleport.pcad.it", text: $host)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    LabeledContent("Invite token") {
                        TextField("paste token here", text: $token, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .lineLimit(2...4)
                    }

                    Button {
                        Task { await runner.run(token: token.trimmingCharacters(in: .whitespacesAndNewlines), host: host) }
                    } label: {
                        Label(runner.overallStatus == "running" ? "Running…" : "Run register + login", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(runner.overallStatus == "running" || token.isEmpty)
                }
                .padding()
                .background(Color.secondary.opacity(0.05))

                Divider()

                // Steps list
                if runner.steps.isEmpty {
                    // ContentUnavailableView is iOS 17+; our deployment
                    // target is 16.1. Use a plain fallback so the app builds
                    // on iOS 16 (and the 1.6b test isn't gated on iOS 17).
                    VStack(spacing: 8) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No run yet")
                            .font(.headline)
                        Text("Paste an invite token and tap Run")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section("Steps") {
                            ForEach(runner.steps.filter { $0.id > 0 }) { step in
                                stepRow(step)
                            }
                        }
                        if !runner.certBase64.isEmpty {
                            Section("Cert (base64, first 200 chars)") {
                                Text(String(runner.certBase64.prefix(200)))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        if let err = runner.error {
                            Section("Error") {
                                Text(err)
                                    .foregroundStyle(.red)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        // Log panel (step id == -1)
                        if let logStep = runner.steps.first(where: { $0.id == -1 }), !logStep.detail.isEmpty {
                            Section("Log") {
                                Text(logStep.detail)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("SEP + biometry")
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 500)
            #endif
        }
    }

    private func stepRow(_ step: SEPBiometryStep) -> some View {
        HStack(alignment: .top) {
            Text(stepIcons[step.status] ?? "?")
                .foregroundStyle(stepColors[step.status] ?? .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(step.id)/7] \(step.title)")
                    .font(.callout)
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
