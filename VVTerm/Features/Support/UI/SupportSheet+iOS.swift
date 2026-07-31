#if os(iOS)
import SwiftUI
import UIKit

extension SupportSheet {
    func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

extension View {
    /// Presents the diagnostics file via the iOS share sheet.
    func diagnosticsSharePresentation(item: Binding<FileShareItem?>) -> some View {
        sheet(item: item) { shareItem in
            FileShareSheet(item: shareItem) {
                DiagnosticsExporter.cleanup(reportAt: shareItem.fileURL)
                item.wrappedValue = nil
            }
        }
    }
}

// MARK: - Support Settings View (iOS)

struct SupportSettingsView: View {
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
        List {
            Section {
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
                }
                .disabled(isExportingDiagnostics)
                .accessibilityIdentifier("vvterm.support.shareDiagnostics")
            }

            Section {
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
                    }
                }
            } header: {
                Text("Questions, feedback, or issues? Reach out anytime.")
                    .textCase(nil)
            }

            Section {
                Button {
                    openURL("https://x.com/vivytech")
                } label: {
                    HStack {
                        Text("Vivy Technologies Co., Limited")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
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

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}
#endif
