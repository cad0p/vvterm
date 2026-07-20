#if os(iOS) && DEBUG
import SwiftUI

struct NoticePresentationUITestHarness: View {
    private var showsFilesPreviewScenario: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-notice-files-preview")
    }

    private var showsConnectingScenario: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-notice-connecting")
    }

    private var showsReconnectBannerScenario: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-notice-reconnect-banner")
    }

    private var showsOperationStackScenario: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-notice-operation-stack")
    }

    private var showsDiagnosticDetailScenario: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-notice-diagnostics")
    }

    private var showsConnectionSheetHandoffScenario: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-connection-sheet-handoff")
    }

    private var showsInactiveConnectionSheetScenario: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-inactive-connection-sheet")
    }

    @ViewBuilder
    var body: some View {
        if showsFilesPreviewScenario {
            NoticeFilesPreviewHarness()
        } else if showsDiagnosticDetailScenario {
            NoticeDiagnosticDetailHarness()
        } else if showsConnectingScenario {
            NoticeConnectingHarness()
        } else if showsReconnectBannerScenario {
            NoticeReconnectBannerHarness()
        } else if showsOperationStackScenario {
            NoticeOperationStackHarness()
        } else if showsConnectionSheetHandoffScenario {
            ConnectionSheetHandoffHarness()
        } else if showsInactiveConnectionSheetScenario {
            InactiveConnectionSheetHarness()
        } else {
            NoticeConnectionFailureHarness()
        }
    }
}

private struct NoticeDiagnosticDetailHarness: View {
    @State private var isVisible = true

    private var diagnosticNotice: NoticeItem? {
        guard isVisible else { return nil }
        return NoticeItem(
            id: "notice-mosh-diagnostic-preview",
            lane: .topBanner,
            level: .warning,
            leading: .icon("arrow.trianglehead.2.clockwise"),
            message: "Using SSH fallback for this session (the Mosh UDP connection timed out).",
            detail: (0..<24).map { index in
                "stage_\(index)=privacy-safe diagnostic detail for a long localized layout"
            }.joined(separator: "\n"),
            dismissAction: { isVisible = false }
        )
    }

    var body: some View {
        NoticeHost(topBanner: diagnosticNotice) {
            terminalBackdrop { EmptyView() }
        }
        .preferredColorScheme(.dark)
    }
}

private struct InactiveConnectionSheetHarness: View {
    var body: some View {
        terminalBackdrop {
            ZStack {
                TerminalConnectionStatusView(
                    presentation: .connecting(serverName: "inactive split"),
                    surfaceStyle: terminalSurfaceStyle,
                    isActive: false,
                    onRetry: {},
                    onTrustNewHostKey: {}
                )

                TerminalConnectionStatusView(
                    presentation: .hidden,
                    surfaceStyle: terminalSurfaceStyle,
                    isActive: true,
                    onRetry: {},
                    onTrustNewHostKey: {}
                )
            }
        }
        .accessibilityIdentifier("vvterm.noticeTest.inactiveConnectionSheet")
        .preferredColorScheme(.dark)
    }
}

private struct ConnectionSheetHandoffHarness: View {
    @State private var tmuxPrompt: TmuxAttachPrompt?

    private let paneId = UUID()

    var body: some View {
        terminalBackdrop {
            TerminalConnectionStatusView(
                presentation: tmuxPrompt == nil
                    ? .connecting(serverName: "production")
                    : .hidden,
                surfaceStyle: terminalSurfaceStyle,
                isActive: true,
                onRetry: {},
                onTrustNewHostKey: {}
            )
        }
        .sheet(item: $tmuxPrompt) { prompt in
            NavigationStack {
                Text("Choose how to continue the connection.")
                    .navigationTitle("Choose tmux session")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            tmuxPrompt = TmuxAttachPrompt(
                id: UUID(),
                paneId: paneId,
                serverId: UUID(),
                serverName: "production",
                existingSessions: []
            )
        }
        .preferredColorScheme(.dark)
    }
}

private struct NoticeOperationStackHarness: View {
    @StateObject private var noticeHost = NoticeHostModel()

    var body: some View {
        NoticeHost(
            bottomOperations: noticeHost.bottomOperations,
            bottomInsetBehavior: .contentBottom
        ) {
            NavigationStack {
                List(0..<14, id: \.self) { index in
                    Label("Remote item \(index + 1)", systemImage: "folder.fill")
                }
                .navigationTitle("Files")
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Upload", systemImage: "arrow.up.doc") {}
                            .accessibilityIdentifier("vvterm.noticeTest.bottomToolbar")
                    }
                }
            }
        }
        .task {
            for index in 1...3 {
                noticeHost.show(
                    NoticeItem(
                        id: "notice-operation-stack-\(index)",
                        lane: .bottomOperation,
                        level: .info,
                        leading: .activity,
                        title: "Upload \(index)",
                        message: "Preparing files for upload.",
                        lifetime: .persistent
                    )
                )
            }
        }
    }
}

private struct NoticeConnectingHarness: View {
    var body: some View {
        terminalBackdrop {
            TerminalConnectionStatusView(
                presentation: .connecting(serverName: "production"),
                surfaceStyle: terminalSurfaceStyle,
                isActive: true,
                onRetry: {},
                onTrustNewHostKey: {}
            )
        }
        .preferredColorScheme(.dark)
    }
}

private struct NoticeReconnectBannerHarness: View {
    private let reconnectNotice = NoticeItem(
        id: "notice-reconnect-preview",
        lane: .topBanner,
        level: .warning,
        leading: .activity,
        message: "Reconnecting (attempt 2)...",
        lifetime: .persistent
    )

    var body: some View {
        NoticeHost(
            topBanner: reconnectNotice,
            bannerSurfaceStyle: terminalSurfaceStyle
        ) {
            terminalBackdrop { EmptyView() }
        }
        .accessibilityIdentifier("vvterm.noticeTest.reconnectBanner")
        .preferredColorScheme(.dark)
    }
}

private let terminalSurfaceStyle = NoticeSurfaceStyle.terminal(
    backgroundColor: Color(red: 0.035, green: 0.045, blue: 0.055),
    foregroundColor: .white
)

private func terminalBackdrop<Overlay: View>(
    @ViewBuilder overlay: () -> Overlay = { EmptyView() }
) -> some View {
    ZStack {
        Color(red: 0.035, green: 0.045, blue: 0.055)
            .ignoresSafeArea()

        VStack(alignment: .leading, spacing: 8) {
            Text("$ ssh production")
            Text("Waiting for session...")
        }
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)

        overlay()
    }
}

private struct NoticeConnectionFailureHarness: View {
    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.045, blue: 0.055)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                Text("$ ssh production")
                Text("Connecting to production...")
                Text("Connection timed out.")
            }
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)

            TerminalConnectionStatusView(
                presentation: .failed(
                    message: "Connection timed out. Please retry.",
                    allowsHostKeyReplacement: false
                ),
                surfaceStyle: .terminal(
                    backgroundColor: Color(red: 0.035, green: 0.045, blue: 0.055),
                    foregroundColor: .white
                ),
                isActive: true,
                onRetry: {},
                onTrustNewHostKey: {}
            )
        }
        .accessibilityIdentifier("vvterm.noticeTest.connectionFailure")
        .preferredColorScheme(.dark)
    }
}

private struct NoticeFilesPreviewHarness: View {
    @State private var showsPreview = false
    @StateObject private var noticeHost = NoticeHostModel()

    var body: some View {
        NavigationStack {
            List {
                Label("report.pdf", systemImage: "doc.richtext")
            }
            .navigationTitle("Files")
            .navigationDestination(isPresented: $showsPreview) {
                NoticeHost(bottomOperation: noticeHost.bottomOperation) {
                    ZStack {
                        Color(uiColor: .systemGroupedBackground)
                            .ignoresSafeArea()

                        VStack(spacing: 12) {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 42))
                            Text("report.pdf")
                                .font(.title3.weight(.semibold))
                            Text("Preview")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("vvterm.noticeTest.filesPreview")
                }
                .navigationTitle("report.pdf")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            noticeHost.show(
                NoticeItem(
                    id: "notice-files-preview-download",
                    lane: .bottomOperation,
                    level: .info,
                    leading: .activity,
                    title: "Downloading",
                    message: "Preparing remote file.",
                    lifetime: .persistent
                )
            )
            showsPreview = true
        }
    }
}
#endif
