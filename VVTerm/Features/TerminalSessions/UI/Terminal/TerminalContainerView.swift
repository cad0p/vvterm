//
//  TerminalContainerView.swift
//  VVTerm
//

import SwiftUI

// MARK: - Terminal Container View

struct TerminalContainerView: View {
    let session: ConnectionSession
    let server: Server?
    var isActive: Bool = true
    var onVoiceRecordingChange: ((Bool) -> Void)? = nil
    var onVoiceTranscriptionSent: (() -> Void)? = nil
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State var isReady = false
    @State private var credentialLoadErrorMessage: String?
    @State private var credentials: ServerCredentials?
    @State private var reconnectToken = UUID()
    @State private var showingTmuxInstallPrompt = false
    @State private var showingMoshInstallPrompt = false
    @State private var isInstallingMosh = false
    @State private var operationNotice: NoticeItem?
    @State private var dismissFallbackBanner = false
    @State private var reconnectInFlight = false
    @State private var connectWatchdogToken = UUID()
    @State private var hasEstablishedConnection = false
    @State private var showingRetrustHostConfirmation = false
    @StateObject private var richPasteUI = TerminalRichPasteUIModel()
    @AppStorage("sshAutoReconnect") private var autoReconnectEnabled = true

    /// Check if terminal already exists (was previously created)
    private var terminalAlreadyExists: Bool {
        ConnectionSessionManager.shared.hasTerminal(for: session.id)
    }

    // Voice input state
    #if os(macOS) || os(iOS)
    @StateObject var audioService = AudioService()
    @State var showingVoiceRecording = false
    @State var voiceProcessing = false
    @State var showingPermissionError = false
    @State var permissionErrorMessage = ""
    @AppStorage("terminalVoiceButtonEnabled") var voiceButtonEnabled = true
    #endif

    #if os(macOS)
    @State var keyMonitor = TerminalVoiceKeyMonitor()
    #endif

    /// Terminal background color from theme
    @State private var terminalBackgroundColor: Color = Self.initialTerminalBackgroundColor()

    /// Theme name from settings
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var fallbackBannerMessage: String? {
        guard session.activeTransport == .sshFallback else { return nil }
        guard !dismissFallbackBanner else { return nil }
        return session.moshFallbackReason?.bannerMessage ?? String(localized: "Using SSH fallback for this session.")
    }

    private var shouldPromptMoshInstall: Bool {
        guard server?.connectionMode == .mosh else { return false }
        guard session.activeTransport == .sshFallback else { return false }
        return session.moshFallbackReason == .serverMissing
    }

    private var shouldShowMoshDurabilityHint: Bool {
        guard server?.connectionMode == .mosh else { return false }
        return session.tmuxStatus == .off
    }

    private var shouldAllowTerminalInteraction: Bool {
        session.connectionState.isConnected
    }

    private var shouldUseInlineReconnectPresentation: Bool {
        hasEstablishedConnection && terminalAlreadyExists && session.connectionState.isConnecting
    }

    private var noticeSurfaceStyle: NoticeSurfaceStyle {
        .terminal(backgroundColor: terminalBackgroundColor)
    }

    private var connectionState: ConnectionState {
        session.connectionState
    }

    private var isHostKeyVerificationFailure: Bool {
        guard case .failed(let error) = connectionState else { return false }
        return error == SSHError.hostKeyVerificationFailed.localizedDescription
            || error.contains("Host key verification failed")
    }

    private var retrustHostConfirmationMessage: String {
        guard let server else {
            return String(localized: "VVTerm will forget the saved SSH host key and reconnect.")
        }
        let endpoint = "\(server.host):\(server.port)"
        return String(
            format: String(localized: "VVTerm saved a different SSH host key for %@. Only continue if you recreated this server or trust the new host."),
            endpoint
        )
    }

    private var shouldAttemptConnection: Bool {
        terminalAlreadyExists || connectionState.isConnected || connectionState.isConnecting
    }

    private var isFailedState: Bool {
        credentialLoadErrorMessage != nil || {
            if case .failed = connectionState { return true }
            return false
        }()
    }

    private var hasServerAndCredentials: Bool {
        server != nil && credentials != nil
    }

    private var shouldShowInitializing: Bool {
        credentialLoadErrorMessage == nil
            &&
        !terminalAlreadyExists
            && !isFailedState
            && connectionState != .disconnected
            && (ghosttyApp.readiness != .ready || !isReady)
    }

    private var shouldShowInitializingOverlay: Bool {
        shouldShowInitializing && hasServerAndCredentials
    }

    private var reconnectBannerMessage: String? {
        guard shouldUseInlineReconnectPresentation else { return nil }

        if case .reconnecting(let attempt) = connectionState {
            return String(format: String(localized: "Reconnecting (attempt %lld)…"), Int64(attempt))
        }

        return String(localized: "Reconnecting…")
    }

    private var topBannerNotice: NoticeItem? {
        if let reconnectBannerMessage {
            return NoticeItem(
                id: "terminal-reconnect-\(session.id.uuidString)",
                lane: .topBanner,
                level: .warning,
                leading: .activity,
                message: reconnectBannerMessage
            )
        }

        if let fallbackBannerMessage {
            return NoticeItem(
                id: "terminal-fallback-\(session.id.uuidString)",
                lane: .topBanner,
                level: .warning,
                leading: .icon("arrow.trianglehead.2.clockwise"),
                message: fallbackBannerMessage,
                dismissAction: { dismissFallbackBanner = true }
            )
        }

        return richPasteUI.topBannerNotice
    }

    var bottomOperationNotice: NoticeItem? {
        if session.tmuxStatus == .installing {
            return NoticeItem(
                id: "terminal-tmux-install-\(session.id.uuidString)",
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: String(localized: "Installing tmux"),
                message: String(localized: "Preparing persistent shell support.")
            )
        }

        if isInstallingMosh {
            return NoticeItem(
                id: "terminal-mosh-install-\(session.id.uuidString)",
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: String(localized: "Installing mosh-server"),
                message: String(localized: "Preparing the remote host for Mosh.")
            )
        }

        if let operationNotice {
            return operationNotice
        }

        return richPasteUI.bottomOperationNotice
    }

    var body: some View {
        platformVoicePresentation(terminalBodyContent)
        .alert("Install tmux?", isPresented: $showingTmuxInstallPrompt) {
            Button("Install") {
                Task {
                    await ConnectionSessionManager.shared.startTmuxInstall(for: session.id)
                }
            }
            Button("Continue without persistence", role: .cancel) {
                disableTmuxForServer()
            }
        } message: {
            Text("tmux keeps your terminal session alive across app restarts and disconnects.")
        }
        .alert("Install mosh-server?", isPresented: $showingMoshInstallPrompt) {
            Button("Install") {
                Task {
                    await installMoshServerAndReconnect()
                }
            }
            Button("Continue with SSH", role: .cancel) {}
        } message: {
            Text("Mosh is selected for this server, but mosh-server is missing on the host.")
        }
        .alert("Replace Trusted Host?", isPresented: $showingRetrustHostConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Replace and Reconnect", role: .destructive) {
                retrustHostAndRetry()
            }
        } message: {
            Text(retrustHostConfirmationMessage)
        }
    }

    private var terminalBodyContent: some View {
        NoticeHost(
            topBanner: topBannerNotice,
            bottomOperation: bottomOperationNotice,
            bannerSurfaceStyle: noticeSurfaceStyle,
            operationSurfaceStyle: noticeSurfaceStyle
        ) {
            ZStack {
                terminalBackgroundLayer
                terminalSurfaceLayer
                stateOverlayLayer
                platformVoiceOverlayLayer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            loadCredentialsIfNeeded(force: true)
        }
        .onChange(of: server?.id) { _ in
            loadCredentialsIfNeeded(force: true)
        }
        .onAppear {
            updateTerminalBackgroundColor()
            if terminalAlreadyExists {
                hasEstablishedConnection = true
            }
            if session.connectionState.isConnected {
                hasEstablishedConnection = true
            }
            if session.tmuxStatus == .missing {
                showingTmuxInstallPrompt = true
            }
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
            startConnectWatchdog()
            attemptAutoReconnectIfNeeded()
        }
        .onChange(of: terminalThemeName) { _ in updateTerminalBackgroundColor() }
        .onChange(of: terminalThemeNameLight) { _ in updateTerminalBackgroundColor() }
        .onChange(of: usePerAppearanceTheme) { _ in updateTerminalBackgroundColor() }
        .onChange(of: colorScheme) { _ in updateTerminalBackgroundColor() }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                updateTerminalBackgroundColor()
                attemptAutoReconnectIfNeeded()
            }
        }
        .onChange(of: isReady) { _ in
            connectWatchdogToken = UUID()
            startConnectWatchdog()
        }
        .onChange(of: session.connectionState) { state in
            if state.isConnecting || state.isConnected {
                if terminalAlreadyExists {
                    hasEstablishedConnection = true
                }
                if state.isConnected {
                    hasEstablishedConnection = true
                }
                reconnectInFlight = false
                connectWatchdogToken = UUID()
                startConnectWatchdog()
            } else if case .disconnected = state {
                attemptAutoReconnectIfNeeded()
            }
        }
        .onChange(of: session.tmuxStatus) { status in
            if status == .missing {
                showingTmuxInstallPrompt = true
            }
        }
        .onChange(of: session.moshFallbackReason) { _ in
            if session.activeTransport == .sshFallback {
                dismissFallbackBanner = false
            }
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .onChange(of: session.activeTransport) { transport in
            dismissFallbackBanner = transport != .sshFallback ? false : dismissFallbackBanner
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .task(id: session.activeTransport == .sshFallback ? session.moshFallbackReason : nil) {
            guard session.activeTransport == .sshFallback else { return }
            dismissFallbackBanner = false
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismissFallbackBanner = true
        }
        .terminalRichPastePrompt(using: richPasteUI)
    }

    @ViewBuilder
    private var terminalBackgroundLayer: some View {
        #if os(iOS)
        terminalBackgroundColor
        #else
        terminalBackgroundColor.ignoresSafeArea()
        #endif
    }

    @ViewBuilder
    private var terminalSurfaceLayer: some View {
        if shouldAttemptConnection {
            Color.clear
                .onAppear {
                    ghosttyApp.startIfNeeded()
                }

            if let server, let credentials {
                if ghosttyApp.readiness == .ready {
                    terminalWrapperView(server: server, credentials: credentials)
                    .allowsHitTesting(shouldAllowTerminalInteraction)
                    .id(reconnectToken)
                    .onAppear {
                        if terminalAlreadyExists {
                            isReady = true
                        }
                        platformTerminalWrapperDidAppear()
                    }
                    .onDisappear {
                        platformTerminalWrapperDidDisappear()
                    }
                }

                terminalInitializationOverlay
            }
        }
    }

    @ViewBuilder
    private func terminalWrapperView(server: Server, credentials: ServerCredentials) -> some View {
        SSHTerminalWrapper(
            session: session,
            server: server,
            credentials: credentials,
            richPasteUIModel: richPasteUI,
            isActive: isActive,
            onProcessExit: {
                DispatchQueue.main.async {
                    ConnectionSessionManager.shared.handleShellExit(for: session.id)
                }
            },
            onReady: {
                isReady = true
            },
            onVoiceTrigger: voiceTriggerHandler
        )
    }

    @ViewBuilder
    private var terminalInitializationOverlay: some View {
        if ghosttyApp.readiness == .error {
            BlockingStatusView(surfaceStyle: noticeSurfaceStyle) {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Terminal initialization failed")
                        .foregroundStyle(.red)
                }
                .multilineTextAlignment(.center)
            }
        } else if shouldShowInitializingOverlay {
            BlockingStatusView(showsScrim: false, surfaceStyle: noticeSurfaceStyle) {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Initializing terminal...")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var stateOverlayLayer: some View {
        if ghosttyApp.readiness != .error && !shouldShowInitializingOverlay {
            if let credentialLoadErrorMessage {
                BlockingStatusView(surfaceStyle: noticeSurfaceStyle) {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        Text("Connection Failed")
                            .font(.headline)
                        Text(credentialLoadErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await retryConnection() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .multilineTextAlignment(.center)
                }
            } else {
                switch connectionState {
                case .connecting:
                    if !shouldUseInlineReconnectPresentation {
                        BlockingStatusView(showsScrim: false, surfaceStyle: noticeSurfaceStyle) {
                            VStack(spacing: 16) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text("Connecting...")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .multilineTextAlignment(.center)
                        }
                    }
                case .reconnecting:
                    if !shouldUseInlineReconnectPresentation {
                        BlockingStatusView(showsScrim: false, surfaceStyle: noticeSurfaceStyle) {
                            VStack(spacing: 16) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text("Reconnecting...")
                                    .foregroundStyle(.orange)
                            }
                            .multilineTextAlignment(.center)
                        }
                    }
                case .disconnected:
                    BlockingStatusView(surfaceStyle: noticeSurfaceStyle) {
                        VStack(spacing: 16) {
                            Image(systemName: "bolt.slash")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Disconnected")
                                .foregroundStyle(.secondary)
                            if session.tmuxStatus.indicatesTmux {
                                Text("tmux session is still running on the server.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            } else if shouldShowMoshDurabilityHint {
                                Text("Without tmux, app backgrounding can interrupt running commands.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            Button("Reconnect") {
                                Task { await retryConnection() }
                            }
                            .buttonStyle(.bordered)
                        }
                        .multilineTextAlignment(.center)
                    }
                case .failed(let error):
                    BlockingStatusView(showsScrim: false, surfaceStyle: noticeSurfaceStyle) {
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundStyle(.red)
                            Text("Connection Failed")
                                .font(.headline)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if isHostKeyVerificationFailure {
                                Button("Trust New Host Key") {
                                    showingRetrustHostConfirmation = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Button("Retry") {
                                Task { await retryConnection() }
                            }
                            .buttonStyle(.bordered)
                        }
                        .multilineTextAlignment(.center)
                    }
                case .connected, .idle:
                    EmptyView()
                }
            }
        }
    }

    private func updateTerminalBackgroundColor() {
        if let color = ThemeColorParser.backgroundColor(for: effectiveThemeName) {
            terminalBackgroundColor = color
            UserDefaults.standard.set(color.toHex(), forKey: "terminalBackgroundColor")
        } else {
            terminalBackgroundColor = Self.platformFallbackBackgroundColor()
        }
    }

    private static func initialTerminalBackgroundColor() -> Color {
        if let cachedHex = UserDefaults.standard.string(forKey: "terminalBackgroundColor") {
            return Color.fromHex(cachedHex)
        }
        return platformFallbackBackgroundColor()
    }

    private func disableTmuxForServer() {
        guard let server else { return }
        ConnectionSessionManager.shared.disableTmux(for: server.id)
    }

    private func retrustHostAndRetry() {
        guard let server else { return }
        KnownHostsManager.shared.remove(host: server.host, port: server.port)
        Task { await retryConnection() }
    }

    private func attemptAutoReconnectIfNeeded() {
        guard scenePhase == .active else { return }
        guard !reconnectInFlight else { return }
        guard !ConnectionSessionManager.shared.isSuspendingForBackground else { return }
        guard autoReconnectEnabled else { return }
        guard session.connectionState == .disconnected else { return }
        Task { await retryConnection() }
    }

    private func startConnectWatchdog() {
        let shouldWatchConnecting = session.connectionState.isConnecting
        let shouldWatchConnectedNoTerminal = session.connectionState.isConnected && !isReady && !terminalAlreadyExists
        guard shouldWatchConnecting || shouldWatchConnectedNoTerminal else { return }
        let token = connectWatchdogToken

        Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard token == connectWatchdogToken else { return }

                let stillConnecting = session.connectionState.isConnecting
                let stillConnectedNoTerminal = session.connectionState.isConnected && !isReady && !terminalAlreadyExists
                guard stillConnecting || stillConnectedNoTerminal else { return }

                if stillConnectedNoTerminal {
                    ConnectionSessionManager.shared.updateSessionState(session.id, to: .disconnected)
                    Task { await retryConnection() }
                    return
                }

                if ConnectionSessionManager.shared.shellId(for: session.id) != nil {
                    ConnectionSessionManager.shared.updateSessionState(session.id, to: .connected)
                    return
                }

                let inFlight = ConnectionSessionManager.shared.isShellStartInFlight(for: session.id)
                if inFlight {
                    // Keep polling while shell start is in-flight so a hung start cannot
                    // leave the UI stuck in "Connecting...".
                    startConnectWatchdog()
                    return
                }

                ConnectionSessionManager.shared.updateSessionState(
                    session.id,
                    to: .failed(String(localized: "Connection timed out. Please retry."))
                )
            }
        }
    }

    @MainActor
    private func retryConnection() async {
        guard !reconnectInFlight else { return }
        guard !session.connectionState.isConnecting else { return }
        reconnectInFlight = true
        defer { reconnectInFlight = false }
        isReady = false
        operationNotice = nil
        loadCredentialsIfNeeded(force: false)
        guard credentials != nil else { return }
        ghosttyApp.startIfNeeded()
        try? await ConnectionSessionManager.shared.reconnect(session: session)
        connectWatchdogToken = UUID()
        startConnectWatchdog()
        reconnectToken = UUID()
    }

    @MainActor
    private func installMoshServerAndReconnect() async {
        guard !isInstallingMosh else { return }
        isInstallingMosh = true
        defer { isInstallingMosh = false }

        do {
            try await ConnectionSessionManager.shared.installMoshServer(for: session.id)
            operationNotice = nil
            await retryConnection()
        } catch {
            operationNotice = NoticeItem(
                id: "terminal-mosh-install-error-\(session.id.uuidString)",
                lane: .bottomOperation,
                level: .error,
                leading: .icon("xmark.octagon.fill"),
                title: String(localized: "mosh-server install failed"),
                message: error.localizedDescription,
                dismissAction: { operationNotice = nil }
            )
        }
    }

    @MainActor
    private func loadCredentialsIfNeeded(force: Bool) {
        guard let server else { return }
        if !force, credentials != nil { return }
        do {
            credentials = try KeychainManager.shared.getCredentials(for: server)
            credentialLoadErrorMessage = nil
        } catch {
            credentialLoadErrorMessage = String(
                format: String(localized: "Failed to load credentials: %@"),
                error.localizedDescription
            )
        }
    }

    func handleVoiceTranscription(_ text: String) {
        if sendTranscriptionToTerminal(text) {
            onVoiceTranscriptionSent?()
        }
    }

    @discardableResult
    private func sendTranscriptionToTerminal(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        ConnectionSessionManager.shared.sendText(trimmed, to: session.id)
        return true
    }

}

// MARK: - Terminal Empty State View

struct TerminalEmptyStateView: View {
    let server: Server?
    let onNewTerminal: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text(server?.name ?? String(localized: "Terminal"))
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("No terminals open")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onNewTerminal) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("New Terminal")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.tint, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
