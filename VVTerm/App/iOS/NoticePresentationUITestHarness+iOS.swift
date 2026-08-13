#if os(iOS) && DEBUG
import SwiftUI

/// Notice presentation scenarios that UI tests can switch between at runtime.
/// The raw value doubles as the scenario-menu item id suffix and the
/// current-scenario label value.
enum HarnessScenario: String, CaseIterable {
    case idle
    case connectionFailure
    case disconnected
    case hostKeyFailure
    case connecting
    case reconnectBanner
    case operationStack
    case diagnostics
    case filesPreview
    case bannerHandoff
    case inactiveBanner
}

struct NoticePresentationUITestHarness: View {
    /// Initial scenario derived from launch arguments (launch-arg compatibility
    /// kept so nothing outside this file changes); no scenario args → .idle so
    /// the harness launches WITHOUT the connection-status sheet (a launch-time
    /// sheet racing the first test's scenario-menu tap was the M2 CI failure:
    /// the tap landed on the sheet scrim instead of the menu).
    private static var initialScenario: HarnessScenario {
        let arguments = Foundation.ProcessInfo.processInfo.arguments
        if arguments.contains("--vvterm-ui-test-notice-files-preview") {
            return .filesPreview
        }
        if arguments.contains("--vvterm-ui-test-notice-diagnostics") {
            return .diagnostics
        }
        if arguments.contains("--vvterm-ui-test-notice-connecting") {
            return .connecting
        }
        if arguments.contains("--vvterm-ui-test-notice-reconnect-banner") {
            return .reconnectBanner
        }
        if arguments.contains("--vvterm-ui-test-notice-operation-stack") {
            return .operationStack
        }
        if arguments.contains("--vvterm-ui-test-connection-banner-handoff") {
            return .bannerHandoff
        }
        if arguments.contains("--vvterm-ui-test-inactive-connection-banner") {
            return .inactiveBanner
        }
        if arguments.contains("--vvterm-ui-test-notice-disconnected") {
            return .disconnected
        }
        if arguments.contains("--vvterm-ui-test-notice-host-key") {
            return .hostKeyFailure
        }
        return .idle
    }

    @State private var scenario: HarnessScenario = NoticePresentationUITestHarness.initialScenario
    @State private var resetToken = 0

    var body: some View {
        ZStack(alignment: .top) {
            scenarioView(for: scenario)
                .id(resetToken)
            scenarioCapsule
        }
    }

    @ViewBuilder
    private func scenarioView(for scenario: HarnessScenario) -> some View {
        switch scenario {
        case .idle:
            terminalBackdrop {
                Text("Select a scenario from the menu")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .connectionFailure:
            NoticeConnectionStatusHarness(scenario: .failure)
        case .disconnected:
            NoticeConnectionStatusHarness(scenario: .disconnected)
        case .hostKeyFailure:
            NoticeConnectionStatusHarness(scenario: .hostKeyFailure)
        case .connecting:
            NoticeConnectingHarness()
        case .reconnectBanner:
            NoticeReconnectBannerHarness()
        case .operationStack:
            NoticeOperationStackHarness()
        case .diagnostics:
            NoticeDiagnosticDetailHarness()
        case .filesPreview:
            NoticeFilesPreviewHarness()
        case .bannerHandoff:
            ConnectionBannerHandoffHarness()
        case .inactiveBanner:
            InactiveConnectionBannerHarness()
        }
    }

    /// Compact scenario-switch capsule centered at the top (nav-bar title
    /// strip). Kept small (~44pt) and above content (.zIndex(10)) so it never
    /// intercepts the leading back button, nav titles, or sheet content.
    private var scenarioCapsule: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(HarnessScenario.allCases.filter { $0 != .idle }, id: \.self) { option in
                    Button(option.rawValue) {
                        scenario = option
                        // Always bump the token — even re-selecting the same
                        // scenario must recreate the scenario view so every
                        // test starts fresh.
                        resetToken &+= 1
                    }
                    .accessibilityIdentifier("vvterm.noticeTest.scenarioMenu.\(option.rawValue)")
                }
            } label: {
                Text("Scenario")
                    .font(.caption.weight(.semibold))
            }
            .accessibilityIdentifier("vvterm.noticeTest.scenarioMenu")

            Text(scenario.rawValue)
                .font(.caption2.monospaced())
                .accessibilityIdentifier("vvterm.noticeTest.scenario.current")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        .padding(.top, 4)
        .zIndex(10)
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

private struct InactiveConnectionBannerHarness: View {
    private let connectionAttemptID = UUID()

    var body: some View {
        terminalBackdrop {
            ZStack {
                TerminalConnectionStatusView(
                    presentation: .connecting(serverName: "inactive split"),
                    connectionAttemptID: connectionAttemptID,
                    surfaceStyle: terminalSurfaceStyle,
                    isActive: false,
                    onRetry: {},
                    onTrustNewHostKey: {}
                )

                TerminalConnectionStatusView(
                    presentation: .hidden,
                    connectionAttemptID: connectionAttemptID,
                    surfaceStyle: terminalSurfaceStyle,
                    isActive: true,
                    onRetry: {},
                    onTrustNewHostKey: {}
                )
            }
        }
        .accessibilityIdentifier("vvterm.noticeTest.inactiveConnectionBanner")
        .preferredColorScheme(.dark)
    }
}

private struct ConnectionBannerHandoffHarness: View {
    @State private var tmuxPrompt: TmuxAttachPrompt?

    private let paneId = UUID()
    private let connectionAttemptID = UUID()

    var body: some View {
        ZStack {
            terminalBackdrop {
                TerminalConnectionStatusView(
                    presentation: tmuxPrompt == nil
                        ? .connecting(serverName: "production")
                        : .hidden,
                    connectionAttemptID: connectionAttemptID,
                    surfaceStyle: terminalSurfaceStyle,
                    isActive: true,
                    onRetry: {},
                    onTrustNewHostKey: {}
                )
            }

            if tmuxPrompt != nil {
                // In-layout overlay instead of a real sheet: an in-layout
                // NavigationStack still renders the nav bar, and no presented
                // sheet can outlive a test and block the scenario capsule.
                NavigationStack {
                    Text("Choose how to continue the connection.")
                        .navigationTitle("Choose tmux session")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }

            // Deterministic handoff trigger (top-trailing, below the scenario
            // capsule): the original 3s auto-timer made the connecting banner
            // transient — under runner load the stale AX tree could miss the
            // banner's brief life entirely (#43 residual). With the trigger,
            // the banner stays up until the test taps, and every assertion
            // in the test targets a persistent state.
            VStack {
                HStack {
                    Spacer()
                    Button("Present tmux") {
                        tmuxPrompt = TmuxAttachPrompt(
                            id: UUID(),
                            paneId: paneId,
                            serverId: UUID(),
                            serverName: "production",
                            existingSessions: []
                        )
                    }
                    .accessibilityIdentifier("vvterm.noticeTest.bannerHandoff.present")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 56)
                    .padding(.trailing, 12)
                }
                Spacer()
            }
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
    private let connectionAttemptID = UUID()

    var body: some View {
        terminalBackdrop {
            TerminalConnectionStatusView(
                presentation: .connecting(serverName: "production"),
                connectionAttemptID: connectionAttemptID,
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

private struct NoticeConnectionStatusHarness: View {
    enum Scenario {
        case failure
        case disconnected
        case hostKeyFailure

        var presentation: TerminalConnectionStatusPresentation {
            switch self {
            case .failure:
                return .failed(
                    message: "Connection timed out. Please retry.",
                    allowsHostKeyReplacement: false
                )
            case .disconnected:
                return .disconnected(message: "The remote session ended.")
            case .hostKeyFailure:
                return .failed(
                    message: "Host key verification failed.",
                    allowsHostKeyReplacement: true
                )
            }
        }
    }

    let scenario: Scenario

    @State private var path = ["terminal"]
    @State private var presentation: TerminalConnectionStatusPresentation
    @State private var connectionAttemptID = UUID()

    init(scenario: Scenario) {
        self.scenario = scenario
        _presentation = State(initialValue: scenario.presentation)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Text("Server List")
                .accessibilityIdentifier("vvterm.noticeTest.serverList")
                .navigationTitle("Servers")
                .navigationDestination(for: String.self) { _ in
                    terminalBackdrop {
                        TerminalConnectionStatusView(
                            presentation: presentation,
                            connectionAttemptID: connectionAttemptID,
                            surfaceStyle: terminalSurfaceStyle,
                            isActive: true,
                            onRetry: retry,
                            onTrustNewHostKey: {}
                        )
                    }
                    .navigationTitle("Terminal")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                path.removeLast()
                            } label: {
                                Label("Back", systemImage: "chevron.left")
                            }
                            .accessibilityIdentifier("vvterm.noticeTest.back")
                        }
                    }
                }
        }
        .accessibilityIdentifier("vvterm.noticeTest.connectionStatus")
        .preferredColorScheme(.dark)
    }

    private func retry() {
        connectionAttemptID = UUID()
        presentation = .connecting(serverName: "production")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            presentation = scenario.presentation
        }
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
