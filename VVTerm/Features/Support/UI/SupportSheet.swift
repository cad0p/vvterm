import SwiftUI
import os.log

// MARK: - Support Sheet

struct SupportSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Diagnostics export state — available in every build so users can
    /// attach recent logs when reporting a bug.
    @State private var diagnosticsShareItem: FileShareItem?
    @State private var isExportingDiagnostics = false

    private struct ContactOption: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let icon: String
        let iconImage: String?
        let iconText: String?
        let color: Color
        let url: String
    }

    private let contactOptions: [ContactOption] = [
        ContactOption(title: String(localized: "Developer"), subtitle: "@wiedymi", icon: "", iconImage: nil, iconText: "𝕏", color: .primary, url: "https://x.com/wiedymi"),
        ContactOption(title: String(localized: "Discord"), subtitle: String(localized: "Join Community"), icon: "", iconImage: "DiscordLogo", iconText: nil, color: Color(red: 0.345, green: 0.396, blue: 0.949), url: "https://discord.gg/zemMZtrkSb"),
        ContactOption(title: String(localized: "Email"), subtitle: "vvterm@vivy.company", icon: "envelope.fill", iconImage: nil, iconText: nil, color: .orange, url: "mailto:vvterm@vivy.company"),
        ContactOption(title: String(localized: "GitHub"), subtitle: String(localized: "Report Issue"), icon: "exclamationmark.triangle.fill", iconImage: nil, iconText: nil, color: .red, url: "https://github.com/vivy-company/vvterm/issues"),
        ContactOption(title: String(localized: "Rate VVTerm"), subtitle: String(localized: "Leave a review on the App Store"), icon: "star.fill", iconImage: nil, iconText: nil, color: .yellow, url: "https://apps.apple.com/app/id6757482822?action=write-review")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)

                    Text("Get in Touch")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Questions, feedback, or issues?\nReach out anytime.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .padding(.bottom, 20)

                DetailCloseButton { dismiss() }
                    .padding(12)
            }

            Divider()

            // Diagnostics export
            Button {
                exportDiagnostics()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "ladybug.fill")
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.indigo)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Share Diagnostics"))
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Text(String(localized: "Attach recent logs to your bug report"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isExportingDiagnostics {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isExportingDiagnostics)
            .accessibilityIdentifier("vvterm.support.shareDiagnostics")

            Divider()
                .padding(.leading, 58)

            // Options
            VStack(spacing: 0) {
                ForEach(contactOptions) { option in
                    Button {
                        openURL(option.url)
                    } label: {
                        HStack(spacing: 14) {
                            Group {
                                if let imageName = option.iconImage {
                                    Image(imageName)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else if let text = option.iconText {
                                    Text(text)
                                        .font(.system(size: 18, weight: .bold))
                                } else {
                                    Image(systemName: option.icon)
                                }
                            }
                            .frame(width: 24, height: 24)
                            .foregroundStyle(option.color)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.primary)

                                Text(option.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if option.id != contactOptions.last?.id {
                        Divider()
                            .padding(.leading, 58)
                    }
                }
            }

            // Company footer
            Button {
                openURL("https://x.com/vivytech")
            } label: {
                HStack(spacing: 6) {
                    Text("Vivy Technologies Co., Limited")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 340)
        .adaptiveSoftScrollEdges()
        .diagnosticsSharePresentation(item: $diagnosticsShareItem)
    }

    private func exportDiagnostics() {
        guard !isExportingDiagnostics else { return }
        isExportingDiagnostics = true
        Task {
            let item = await SupportDiagnostics.exportReport()
            isExportingDiagnostics = false
            if let item {
                diagnosticsShareItem = item
            }
        }
    }
}

/// Shared export helper for the support surfaces (sheet + settings list).
enum SupportDiagnostics {
    static func exportReport() async -> FileShareItem? {
        do {
            let url = try await DiagnosticsExporter.export()
            return FileShareItem(fileURL: url)
        } catch {
            Logger.forCategory("Diagnostics").error(
                "diagnostics export failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}

// MARK: - Preview

#Preview {
    SupportSheet()
}
