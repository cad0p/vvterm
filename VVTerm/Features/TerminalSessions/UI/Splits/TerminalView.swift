//
//  TerminalView.swift
//  VVTerm
//
//  Renders a single tab's terminal content (with optional splits).
//  Each tab is isolated - splits happen within the tab, not across tabs.
//

import Foundation
import SwiftUI
import os.log
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Terminal Tab View

/// Renders a single terminal tab with its split layout
struct TerminalTabView: View {
    let tab: TerminalTab
    let server: Server
    @ObservedObject var tabManager: TerminalTabManager
    let isSelected: Bool

    @State private var layoutVersion: Int = 0
    @State private var showingCloseConfirmation = false
    @State private var showingSplitPaneUpgradeAlert = false

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true
    @AppStorage("terminalVoiceButtonEnabled") private var voiceButtonEnabled = true

    @StateObject private var audioService = AudioService()
    @StateObject private var voiceRecordingOperation = VoiceRecordingOperationCoordinator()
    @State private var showingVoiceRecording = false
    @State private var voiceProcessing = false
    @State private var showingPermissionError = false
    @State private var permissionErrorMessage = ""
    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif

    private var dividerColor: Color {
        ThemeColorParser.splitDividerColor(for: effectiveThemeName)
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var focusedTerminal: GhosttyTerminalView? {
        TerminalTabManager.shared.getTerminal(for: tab.focusedPaneId)
    }

    private var hasFocusedTerminal: Bool {
        focusedTerminal != nil
    }

    /// Split actions for menu commands - only active when this tab is selected
    private var splitActions: TerminalSplitActions? {
        guard isSelected else { return nil }
        return TerminalSplitActions(
            splitHorizontal: { splitHorizontal() },
            splitVertical: { splitVertical() },
            splitLeft: { splitLeft() },
            splitUp: { splitUp() },
            closePane: { requestClosePane() }
        )
    }

    var body: some View {
        ZStack {
            // Refresh when terminals register/unregister so overlays can update immediately.
            let _ = tabManager.terminalRegistryVersion
            if let layout = tab.layout {
                renderNode(layout)
            } else {
                // Single pane - no splits
                TerminalPaneView(
                    paneId: tab.rootPaneId,
                    server: server,
                    isFocused: true,
                    isTabSelected: isSelected,
                    onFocus: { },
                    onProcessExit: { handlePaneExit(paneId: tab.rootPaneId) },
                    terminalContextMenuActions: terminalContextMenuActions(for: tab.rootPaneId),
                    showsVoiceButton: isSelected
                        && voiceButtonEnabled
                        && !showingVoiceRecording
                        && hasFocusedTerminal,
                    onVoiceTrigger: { startVoiceRecording() }
                )
            }

            if shouldShowVoiceOverlay {
                platformVoiceOverlay
            }
        }
        .terminalCommandFocusValues(
            activeServerId: isSelected ? server.id : nil,
            activePaneId: isSelected ? tab.focusedPaneId : nil,
            splitActions: splitActions
        )
        .terminalKeyboardAvoidance(
            focusedPaneId: isSelected ? tab.focusedPaneId : nil,
            paneIds: tab.allPaneIds,
            terminalRegistryVersion: tabManager.terminalRegistryVersion,
            terminalProvider: { tabManager.getTerminal(for: $0) }
        )
        .alert("Close this terminal?", isPresented: $showingCloseConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Close", role: .destructive) {
                closeCurrentPane()
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("The SSH connection will be terminated.")
        }
        .alert("Voice Input Unavailable", isPresented: $showingPermissionError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(permissionErrorMessage)
        }
        .splitPaneProFeatureAlert(isPresented: $showingSplitPaneUpgradeAlert)
        .onAppear {
            updateKeyMonitor()
        }
        .onChange(of: isSelected) { _ in
            updateKeyMonitor()
            if !isSelected {
                cancelVoiceRecording()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                cancelVoiceRecording()
            }
        }
        .onChange(of: showingVoiceRecording) { isRecording in
            publishVoiceRecordingState(isRecording)
        }
        .onChange(of: tab.focusedPaneId) { _ in
            if showingVoiceRecording {
                publishVoiceRecordingState(true)
            }
        }
        .onDisappear {
            cleanupKeyMonitor()
            cancelVoiceRecording()
            publishVoiceRecordingState(false)
        }
    }

    private func requestClosePane() {
        showingCloseConfirmation = true
    }

    // MARK: - Render Split Tree

    private func renderNode(_ node: TerminalSplitNode) -> AnyView {
        switch node {
        case .leaf(let paneId):
            return AnyView(
                TerminalPaneView(
                    paneId: paneId,
                    server: server,
                    isFocused: tab.focusedPaneId == paneId,
                    isTabSelected: isSelected,
                    onFocus: { focusPane(paneId) },
                    onProcessExit: { handlePaneExit(paneId: paneId) },
                    terminalContextMenuActions: terminalContextMenuActions(for: paneId),
                    showsVoiceButton: isSelected
                        && voiceButtonEnabled
                        && !showingVoiceRecording
                        && tab.focusedPaneId == paneId
                        && hasFocusedTerminal,
                    onVoiceTrigger: { startVoiceRecording() }
                )
                .id("\(paneId)-\(layoutVersion)")
            )

        case .split(let split):
            let currentNode = node
            let ratioBinding = Binding<CGFloat>(
                get: { CGFloat(split.ratio) },
                set: { newRatio in
                    updateRatio(node: currentNode, newRatio: Double(newRatio))
                }
            )

            return AnyView(
                SplitView(
                    split.direction == .horizontal ? .horizontal : .vertical,
                    ratioBinding,
                    dividerColor: dividerColor,
                    left: { renderNode(split.left) },
                    right: { renderNode(split.right) },
                    onEqualize: { equalizeLayout() }
                )
            )
        }
    }

    // MARK: - Actions

    private func focusPane(_ paneId: UUID) {
        var updatedTab = tab
        updatedTab.focusedPaneId = paneId
        tabManager.updateTab(updatedTab)
    }

    private func updateRatio(node: TerminalSplitNode, newRatio: Double) {
        guard var layout = tab.layout else { return }
        let updated = node.withUpdatedRatio(newRatio)
        layout = layout.replacingNode(node, with: updated)
        var updatedTab = tab
        updatedTab.layout = layout
        tabManager.updateTab(updatedTab)
    }

    private func equalizeLayout() {
        guard let layout = tab.layout else { return }
        var updatedTab = tab
        updatedTab.layout = layout.equalized()
        tabManager.updateTab(updatedTab)
    }

    private func handlePaneExit(paneId: UUID) {
        let startToken = tabManager.connectionStartToken(for: paneId)
        tabManager.updatePaneState(paneId, connectionState: .disconnected)
        guard let startToken else { return }
        Task {
            await tabManager.unregisterSSHClient(
                for: paneId,
                ifOwnedBy: startToken
            )
        }
    }

    // MARK: - Split Actions

    func splitHorizontal() {
        splitPane(tab.focusedPaneId, placement: .right)
    }

    func splitVertical() {
        splitPane(tab.focusedPaneId, placement: .down)
    }

    func splitLeft() {
        splitPane(tab.focusedPaneId, placement: .left)
    }

    func splitUp() {
        splitPane(tab.focusedPaneId, placement: .up)
    }

    private func splitPane(_ paneId: UUID, placement: TerminalSplitPlacement) {
        guard StoreManager.shared.isPro else {
            showingSplitPaneUpgradeAlert = true
            return
        }
        focusPane(paneId)
        let newPaneId: UUID?
        switch placement {
        case .right:
            newPaneId = tabManager.splitRight(tab: tab, paneId: paneId)
        case .left:
            newPaneId = tabManager.splitLeft(tab: tab, paneId: paneId)
        case .down:
            newPaneId = tabManager.splitDown(tab: tab, paneId: paneId)
        case .up:
            newPaneId = tabManager.splitUp(tab: tab, paneId: paneId)
        }
        guard newPaneId != nil else { return }
        layoutVersion += 1
    }

    private func terminalContextMenuActions(for paneId: UUID) -> TerminalContextMenuActions {
        TerminalContextMenuActions(
            focus: { focusPane(paneId) },
            splitRight: { splitPane(paneId, placement: .right) },
            splitLeft: { splitPane(paneId, placement: .left) },
            splitDown: { splitPane(paneId, placement: .down) },
            splitUp: { splitPane(paneId, placement: .up) },
            currentTitle: {
                tabManager.displayTitle(forPane: paneId, fallback: tab.title) ?? tab.title
            },
            setTitle: { title in
                tabManager.setPaneTitleOverride(title, for: paneId)
            }
        )
    }

    func closeCurrentPane() {
        tabManager.closePane(tab: tab, paneId: tab.focusedPaneId)
    }

    // MARK: - Voice Input

    private var voiceOverlay: some View {
        VoiceRecordingView(
            audioService: audioService,
            onStop: { finishVoiceRecording() },
            onCancel: {
                cancelVoiceRecording()
            },
            isProcessing: $voiceProcessing
        )
    }

    private var shouldShowVoiceOverlay: Bool {
        guard isSelected, hasFocusedTerminal, showingVoiceRecording else { return false }
        #if os(iOS)
        return tabManager.paneStates[tab.focusedPaneId]?.connectionState.isConnected == true
        #else
        return true
        #endif
    }

    private var platformVoiceOverlay: some View {
        #if os(iOS)
        voiceOverlay
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 16)
            .padding(.bottom, 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(1)
        #else
        voiceOverlay
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        #endif
    }

    #if os(macOS)
    private func updateKeyMonitor() {
        if isSelected {
            setupKeyMonitor()
        } else {
            cleanupKeyMonitor()
        }
    }

    private func setupKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            handleMonitoredKeyDown(event)
        }
    }

    private func cleanupKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleMonitoredKeyDown(_ event: NSEvent) -> NSEvent? {
        handleVoiceShortcut(event)
    }

    private func handleVoiceShortcut(_ event: NSEvent) -> NSEvent? {
        guard isSelected else { return event }

        let keyCodeEscape: UInt16 = 53
        let keyCodeReturn: UInt16 = 36

        if showingVoiceRecording {
            if event.keyCode == keyCodeEscape {
                cancelVoiceRecording()
                return nil
            }
            if event.keyCode == keyCodeReturn {
                toggleVoiceRecording()
                return nil
            }
        }

        guard MacTerminalShortcut.toggleVoiceRecording.matches(event) else {
            return event
        }
        toggleVoiceRecording()
        return nil
    }
    #else
    private func updateKeyMonitor() {}
    private func cleanupKeyMonitor() {}
    #endif

    private func toggleVoiceRecording() {
        if showingVoiceRecording {
            finishVoiceRecording()
        } else {
            startVoiceRecording()
        }
    }

    private func startVoiceRecording() {
        clearPendingVoiceReturnForFocusedPane()
        voiceRecordingOperation.cancel()
        audioService.cancelRecording()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showingVoiceRecording = true
        }
        #if os(iOS)
        let terminal = focusedTerminal
        let lifecycleState: @MainActor @Sendable () -> AudioCaptureLifecycleState = { [weak terminal] in
            AudioCaptureLifecycleState(
                applicationIsActive: UIApplication.shared.applicationState == .active,
                sceneIsActive: terminal?.window?.windowScene?.activationState == .foregroundActive
            )
        }
        #else
        let lifecycleState: @MainActor @Sendable () -> AudioCaptureLifecycleState = {
            AudioCaptureLifecycleState(
                applicationIsActive: NSApplication.shared.isActive,
                sceneIsActive: NSApplication.shared.isActive
            )
        }
        #endif
        voiceRecordingOperation.start(
            operation: { [audioService] operationID in
                try await audioService.startRecording(
                    operationID: operationID,
                    lifecycleState: lifecycleState
                )
            },
            onSuccess: { _ in },
            onFailure: { error in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    showingVoiceRecording = false
                }
                voiceProcessing = false
                if let recordingError = error as? AudioService.RecordingError {
                    permissionErrorMessage = recordingError.localizedDescription
                } else {
                    permissionErrorMessage = error.localizedDescription
                }
                showingPermissionError = true
            }
        )
    }

    private func cancelVoiceRecording() {
        voiceRecordingOperation.cancel()
        audioService.cancelRecording()
        showingVoiceRecording = false
        voiceProcessing = false
    }

    private func finishVoiceRecording() {
        guard !voiceProcessing else { return }
        voiceProcessing = true
        voiceRecordingOperation.start(
            operation: { [audioService] operationID in
                await audioService.stopRecording(operationID: operationID)
            },
            onSuccess: { text in
                let fallback = text.isEmpty ? audioService.partialTranscription : text
                sendTranscriptionToTerminal(fallback)
                showingVoiceRecording = false
                voiceProcessing = false
            },
            onFailure: { _ in
                showingVoiceRecording = false
                voiceProcessing = false
            }
        )
    }

    private func sendTranscriptionToTerminal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let terminal = focusedTerminal else { return }
        let paneId = tab.focusedPaneId
        #if os(iOS)
        let shouldShowReturnControl = tabManager.keyboardCoordinator.isUserHidden
        #endif
        terminal.sendText(trimmed)
        #if os(iOS)
        if shouldShowReturnControl {
            tabManager.setTerminalPendingVoiceReturn(true, for: paneId)
        }
        #endif
    }

    private func publishVoiceRecordingState(_ isRecording: Bool) {
        #if os(iOS)
        for paneId in tab.allPaneIds where !isRecording || paneId != tab.focusedPaneId {
            tabManager.setTerminalVoiceRecording(false, for: paneId)
        }
        if isRecording {
            tabManager.setTerminalVoiceRecording(true, for: tab.focusedPaneId)
        }
        #endif
    }

    private func clearPendingVoiceReturnForFocusedPane() {
        #if os(iOS)
        tabManager.setTerminalPendingVoiceReturn(false, for: tab.focusedPaneId)
        #endif
    }
}

// MARK: - Terminal Pane View

/// Renders a single terminal pane (leaf in split tree)
struct TerminalPaneView: View {
    private enum ReconnectPreparation: Equatable {
        case idle
        case running(TerminalTabManager.ReconnectPreparationToken)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }
    let paneId: UUID
    let server: Server
    let isFocused: Bool
    let isTabSelected: Bool
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let terminalContextMenuActions: TerminalContextMenuActions
    let showsVoiceButton: Bool
    let onVoiceTrigger: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var isReady = false
    @State private var credentials: ServerCredentials?
    @State private var credentialLoadErrorMessage: String?
    @State private var reconnectToken = UUID()
    @State private var showingTmuxInstallPrompt = false
    @State private var showingMoshInstallPrompt = false
    @State private var isInstallingMosh = false
    @State private var operationNotice: NoticeItem?
    @State private var dismissFallbackBanner = false
    @State private var reconnectPreparation = ReconnectPreparation.idle
    @State private var automaticReconnectRetryTask: Task<Void, Never>?
    @State private var terminalBackgroundColor: Color = Self.initialTerminalBackgroundColor()
    @State private var connectWatchdogToken = UUID()
    @State private var showingRetrustHostConfirmation = false
    @StateObject private var richPasteUI = TerminalRichPasteUIModel()
    @ObservedObject private var networkMonitor: NetworkMonitor = .shared

    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true
    @AppStorage(TerminalDefaults.sshAutoReconnectKey) private var autoReconnectEnabled = true

    private var paneState: TerminalPaneState? {
        TerminalTabManager.shared.paneStates[paneId]
    }

    private var connectionState: ConnectionState {
        paneState?.connectionState ?? .idle
    }

    private var reconnectInFlight: Bool {
        reconnectPreparation.isRunning
    }

    private var isHostKeyVerificationFailure: Bool {
        guard case .failed(let error) = connectionState else { return false }
        return error == SSHError.hostKeyVerificationFailed.localizedDescription
            || error.contains("Host key verification failed")
    }

    private var retrustHostConfirmationMessage: String {
        let endpoint = "\(server.host):\(server.port)"
        return String(
            format: String(localized: "VVTerm saved a different SSH host key for %@. Only continue if you recreated this server or trust the new host."),
            endpoint
        )
    }

    /// Should this pane actually have focus (both tab selected AND pane focused)
    private var shouldFocus: Bool {
        isTabSelected && isFocused
    }

    /// Check if terminal already exists (reuse case)
    private var terminalExists: Bool {
        TerminalTabManager.shared.getTerminal(for: paneId) != nil
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var fallbackBannerMessage: String? {
        guard paneState?.activeTransport == .sshFallback else { return nil }
        guard !dismissFallbackBanner else { return nil }
        return paneState?.moshFallbackReason?.bannerMessage ?? String(localized: "Using SSH fallback for this session.")
    }

    private var shouldPromptMoshInstall: Bool {
        guard server.connectionMode == .mosh else { return false }
        guard paneState?.activeTransport == .sshFallback else { return false }
        return paneState?.moshFallbackReason?.shouldOfferServerMaintenance == true
    }

    private var moshServerPromptTitle: String {
        paneState?.moshFallbackReason == .serverRuntimeBroken
            ? String(localized: "Repair mosh-server?")
            : String(localized: "Install mosh-server?")
    }

    private var moshServerPromptAction: String {
        paneState?.moshFallbackReason == .serverRuntimeBroken
            ? String(localized: "Repair")
            : String(localized: "Install")
    }

    private var moshServerPromptMessage: String {
        paneState?.moshFallbackReason == .serverRuntimeBroken
            ? String(localized: "Mosh is selected, but the installed mosh-server cannot run. Repair its package installation and reconnect?")
            : String(localized: "Mosh is selected for this server, but mosh-server is missing on the host.")
    }

    private var shouldShowMoshDurabilityHint: Bool {
        guard server.connectionMode == .mosh else { return false }
        return paneState?.tmuxStatus == .off
    }

    private var shouldUseReconnectBannerPresentation: Bool {
        TerminalConnectionPresentationPolicy.usesReconnectBanner(
            connectionState: connectionState,
            hasEstablishedConnection: paneState?.hasEstablishedConnection == true,
            automaticReconnectAllowed: automaticReconnectAllowed,
            isReconnectPreparationInFlight: reconnectInFlight
        )
    }

    private var automaticReconnectAllowed: Bool {
        guard autoReconnectEnabled else { return false }
        if case .failed = connectionState {
            return paneState?.disconnectReason?.allowsAutomaticReconnect == true
        }
        return paneState?.disconnectReason?.allowsAutomaticReconnect ?? true
    }

    private var isAwaitingTmuxSelection: Bool {
        TerminalTabManager.shared.tmuxAttachPrompt?.paneId == paneId
    }

    private var noticeSurfaceStyle: NoticeSurfaceStyle {
        .terminal(
            backgroundColor: terminalBackgroundColor,
            foregroundColor: ThemeColorParser.previewPalette(for: effectiveThemeName).foreground
        )
    }

    private var disconnectedStatusMessage: String? {
        if let message = paneState?.disconnectReason?.statusMessage {
            return message
        }

        if paneState?.tmuxStatus.indicatesTmux == true {
            return String(localized: "tmux session is still running on the server.")
        }

        if shouldShowMoshDurabilityHint {
            return String(localized: "Without tmux, app backgrounding can interrupt running commands.")
        }

        return nil
    }

    private var connectionStatusPresentation: TerminalConnectionStatusPresentation {
        .resolve(
            credentialLoadErrorMessage: credentialLoadErrorMessage,
            connectionState: connectionState,
            serverName: server.name,
            hasEstablishedConnection: paneState?.hasEstablishedConnection == true,
            automaticReconnectAllowed: automaticReconnectAllowed,
            isReconnectPreparationInFlight: reconnectInFlight,
            isAwaitingTmuxSelection: isAwaitingTmuxSelection,
            terminalExists: terminalExists,
            isReady: isReady,
            disconnectedMessage: disconnectedStatusMessage,
            isHostKeyVerificationFailure: isHostKeyVerificationFailure
        )
    }

    private var reconnectBannerMessage: String? {
        guard shouldUseReconnectBannerPresentation else { return nil }

        if case .reconnecting(let attempt) = connectionState {
            return String(format: String(localized: "Reconnecting (attempt %lld)…"), Int64(attempt))
        }

        return String(localized: "Reconnecting…")
    }

    private var topBannerNotice: NoticeItem? {
        if let reconnectBannerMessage {
            return NoticeItem(
                id: "pane-reconnect-\(paneId.uuidString)",
                lane: .topBanner,
                level: .warning,
                leading: .activity,
                message: reconnectBannerMessage
            )
        }

        if let fallbackBannerMessage {
            return NoticeItem(
                id: "pane-fallback-\(paneId.uuidString)",
                lane: .topBanner,
                level: .warning,
                leading: .icon("arrow.trianglehead.2.clockwise"),
                message: fallbackBannerMessage,
                detail: paneState?.moshFallbackDiagnostics?.copyText,
                dismissAction: { dismissFallbackBanner = true }
            )
        }

        return richPasteUI.topBannerNotice
    }

    private var bottomOperationNotice: NoticeItem? {
        if paneState?.tmuxStatus == .installing {
            return NoticeItem(
                id: "pane-tmux-install-\(paneId.uuidString)",
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: String(localized: "Installing tmux"),
                message: String(localized: "Preparing persistent shell support.")
            )
        }

        if isInstallingMosh {
            return NoticeItem(
                id: "pane-mosh-install-\(paneId.uuidString)",
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

    private var voiceTriggerBottomInset: CGFloat {
        bottomOperationNotice == nil ? 0 : 104
    }

    var body: some View {
        NoticeHost(
            topBanner: topBannerNotice,
            bottomOperation: bottomOperationNotice,
            bannerSurfaceStyle: noticeSurfaceStyle,
            operationSurfaceStyle: noticeSurfaceStyle
        ) {
            ZStack {
                terminalBackgroundColor

                if ghosttyApp.readiness == .ready, let credentials = credentials {
                    terminalSurface(credentials: credentials)
                }

                TerminalConnectionStatusView(
                    presentation: connectionStatusPresentation,
                    surfaceStyle: noticeSurfaceStyle,
                    isActive: shouldFocus,
                    onRetry: retryConnection,
                    onTrustNewHostKey: { showingRetrustHostConfirmation = true }
                )

                if shouldShowFloatingVoiceButton {
                    voiceTriggerButton
                        .padding(.bottom, voiceTriggerBottomInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.opacity)
                }
            }
        }
        .opacity(isFocused ? 1.0 : 0.7)
        .clipped()
        .task {
            ghosttyApp.startIfNeeded()
            updateTerminalBackgroundColor()
            // If terminal exists, mark ready immediately
            if terminalExists {
                isReady = true
            }
            do {
                credentials = try KeychainManager.shared.getCredentials(for: server)
                credentialLoadErrorMessage = nil
            } catch {
                credentialLoadErrorMessage = String(localized: "Failed to load credentials")
            }

            showingTmuxInstallPrompt = TmuxInstallPromptPolicy.shouldPresent(
                for: paneState?.tmuxStatus
            )
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
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                attemptAutoReconnectIfNeeded()
            }
        }
        .onChange(of: networkMonitor.readiness) { readiness in
            if readiness == .ready {
                attemptAutoReconnectIfNeeded()
            }
        }
        .onChange(of: isReady) { _ in
            connectWatchdogToken = UUID()
            startConnectWatchdog()
        }
        .onChange(of: connectionState) { state in
            if state.isConnecting || state.isConnected {
                cancelScheduledAutomaticReconnect()
                connectWatchdogToken = UUID()
                startConnectWatchdog()
            } else if case .disconnected = state {
                attemptAutoReconnectIfNeeded()
            } else if case .failed = state {
                scheduleAutomaticReconnectAfterFailure()
            }
        }
        .onChange(of: paneState?.tmuxStatus) { status in
            showingTmuxInstallPrompt = TmuxInstallPromptPolicy.shouldPresent(for: status)
        }
        .onChange(of: isAwaitingTmuxSelection) { isAwaitingSelection in
            connectWatchdogToken = UUID()
            if !isAwaitingSelection {
                startConnectWatchdog()
            }
        }
        .onChange(of: paneState?.moshFallbackReason) { _ in
            if paneState?.activeTransport == .sshFallback {
                dismissFallbackBanner = false
            }
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .onChange(of: paneState?.activeTransport) { transport in
            dismissFallbackBanner = transport != .sshFallback ? false : dismissFallbackBanner
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .task(id: paneState?.activeTransport == .sshFallback ? paneState?.moshFallbackReason : nil) {
            guard paneState?.activeTransport == .sshFallback else { return }
            dismissFallbackBanner = false
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismissFallbackBanner = true
        }
        .onDisappear {
            cancelScheduledAutomaticReconnect()
        }
        .alert("Install tmux?", isPresented: $showingTmuxInstallPrompt) {
            Button("Install") {
                Task {
                    await TerminalTabManager.shared.startTmuxInstall(for: paneId) {
                        retryConnection()
                    }
                }
            }
            Button("Continue without persistence", role: .cancel) {
                disableTmuxForServer()
            }
        } message: {
            Text("tmux keeps your terminal session alive across app restarts and disconnects.")
        }
        .alert(moshServerPromptTitle, isPresented: $showingMoshInstallPrompt) {
            Button(moshServerPromptAction) {
                Task {
                    await installMoshServerAndReconnect()
                }
            }
            Button("Continue with SSH", role: .cancel) {}
        } message: {
            Text(moshServerPromptMessage)
        }
        .alert("Replace Trusted Host?", isPresented: $showingRetrustHostConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Replace and Reconnect", role: .destructive) {
                retrustHostAndRetry()
            }
        } message: {
            Text(retrustHostConfirmationMessage)
        }
        .terminalRichPastePrompt(using: richPasteUI)
    }

    private var shouldShowFloatingVoiceButton: Bool {
        #if os(macOS)
        showsVoiceButton && isFocused && isTabSelected && connectionState.isConnected
        #else
        false
        #endif
    }

    @ViewBuilder
    private func terminalSurface(credentials: ServerCredentials) -> some View {
        #if os(iOS)
        SSHTerminalPaneWrapper(
            paneId: paneId,
            server: server,
            credentials: credentials,
            richPasteUIModel: richPasteUI,
            isActive: shouldFocus,
            terminalContextMenuActions: terminalContextMenuActions,
            onProcessExit: onProcessExit,
            onReady: { isReady = true },
            onVoiceTrigger: voiceTriggerHandlerForTerminal,
            onSceneActivation: attemptAutoReconnectIfNeeded
        )
        .id(reconnectToken)
        .allowsHitTesting(connectionState.isConnected)
        #else
        SSHTerminalPaneWrapper(
            paneId: paneId,
            server: server,
            credentials: credentials,
            richPasteUIModel: richPasteUI,
            isActive: shouldFocus,
            terminalContextMenuActions: terminalContextMenuActions,
            onProcessExit: onProcessExit,
            onReady: { isReady = true }
        )
        .id(reconnectToken)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        #endif
    }

    private var voiceTriggerHandlerForTerminal: (() -> Void)? {
        #if os(iOS)
        guard showsVoiceButton else { return nil }
        return {
            guard connectionState.isConnected, isReady else { return }
            onVoiceTrigger()
        }
        #else
        guard showsVoiceButton, connectionState.isConnected, isReady else { return nil }
        return onVoiceTrigger
        #endif
    }

    private func disableTmuxForServer() {
        TerminalTabManager.shared.disableTmux(for: server.id)
    }

    private func retrustHostAndRetry() {
        KnownHostsManager.shared.remove(host: server.host, port: server.port)
        retryConnection()
    }

    private func attemptAutoReconnectIfNeeded() {
        #if os(iOS)
        let applicationIsActive = UIApplication.shared.applicationState == .active
        #else
        let applicationIsActive = NSApplication.shared.isActive
        #endif
        guard TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: foregroundSceneIsActive,
            applicationIsActive: applicationIsActive,
            networkReadiness: networkMonitor.readiness,
            automaticReconnectAllowed: automaticReconnectAllowed,
            reconnectInFlight: reconnectInFlight,
            hasEstablishedConnection: paneState?.hasEstablishedConnection == true,
            connectionState: connectionState
        ) else { return }
        retryConnection(requiresReadyNetwork: true)
    }

    private func retryConnection() {
        retryConnection(requiresReadyNetwork: false)
    }

    private func retryConnection(requiresReadyNetwork: Bool) {
        cancelScheduledAutomaticReconnect()
        guard !requiresReadyNetwork || networkMonitor.readiness == .ready else { return }
        guard !reconnectPreparation.isRunning else { return }
        guard !connectionState.isConnecting else { return }
        credentialLoadErrorMessage = nil
        operationNotice = nil
        if credentials == nil {
            do {
                credentials = try KeychainManager.shared.getCredentials(for: server)
                credentialLoadErrorMessage = nil
            } catch {
                credentialLoadErrorMessage = String(localized: "Failed to load credentials")
                return
            }
        }
        let tabManager = TerminalTabManager.shared
        guard let preparationToken = tabManager.beginReconnectPreparation(for: paneId) else { return }
        tabManager.clearMoshFallbackDiagnostics(for: paneId)
        reconnectPreparation = .running(preparationToken)
        connectWatchdogToken = UUID()
        Task {
            defer {
                tabManager.finishReconnectPreparation(preparationToken)
                if reconnectPreparation == .running(preparationToken) {
                    reconnectPreparation = .idle
                }
            }
            guard tabManager.isCurrentReconnectPreparation(preparationToken) else { return }
            guard !requiresReadyNetwork || networkMonitor.readiness == .ready else { return }
            #if os(iOS)
            guard UIApplication.shared.applicationState == .active,
                  foregroundSceneIsActive else {
                return
            }
            #endif
            guard tabManager.isCurrentReconnectPreparation(preparationToken) else { return }
            guard !requiresReadyNetwork || networkMonitor.readiness == .ready else { return }

            await tabManager.unregisterSSHClient(for: paneId)
            guard tabManager.isCurrentReconnectPreparation(preparationToken) else { return }
            guard tabManager.paneStates[paneId] != nil else { return }
            #if os(iOS)
            guard UIApplication.shared.applicationState == .active,
                  foregroundSceneIsActive else {
                return
            }
            #endif
            guard tabManager.isCurrentReconnectPreparation(preparationToken) else { return }
            guard !requiresReadyNetwork || networkMonitor.readiness == .ready else { return }

            isReady = false
            let hasEstablishedConnection = paneState?.hasEstablishedConnection == true
            tabManager.updatePaneState(
                paneId,
                connectionState: TerminalConnectionAttemptPolicy.state(
                    attempt: 1,
                    hasEstablishedConnection: hasEstablishedConnection
                )
            )
            reconnectToken = UUID()
            connectWatchdogToken = UUID()
            startConnectWatchdog()
        }
    }

    private func scheduleAutomaticReconnectAfterFailure() {
        guard automaticReconnectRetryTask == nil else { return }
        #if os(iOS)
        let applicationIsActive = UIApplication.shared.applicationState == .active
        #else
        let applicationIsActive = NSApplication.shared.isActive
        #endif
        guard TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: foregroundSceneIsActive,
            applicationIsActive: applicationIsActive,
            networkReadiness: networkMonitor.readiness,
            automaticReconnectAllowed: automaticReconnectAllowed,
            reconnectInFlight: reconnectInFlight,
            hasEstablishedConnection: paneState?.hasEstablishedConnection == true,
            connectionState: connectionState
        ) else { return }

        automaticReconnectRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            automaticReconnectRetryTask = nil
            attemptAutoReconnectIfNeeded()
        }
    }

    private func cancelScheduledAutomaticReconnect() {
        automaticReconnectRetryTask?.cancel()
        automaticReconnectRetryTask = nil
    }

    private var foregroundSceneIsActive: Bool {
        #if os(iOS)
        let windowScene = TerminalTabManager.shared
            .getTerminal(for: paneId)?
            .window?
            .windowScene
        let windowSceneIsActive = windowScene.map {
            $0.activationState == .foregroundActive
        }
        return TerminalSceneActivityPolicy.isActive(
            environmentIsActive: scenePhase == .active,
            windowSceneIsActive: windowSceneIsActive
        )
        #else
        return scenePhase == .active
        #endif
    }

    private func startConnectWatchdog() {
        guard TerminalConnectionWatchdogPolicy.shouldMonitor(
            connectionState: connectionState,
            isReady: isReady,
            terminalExists: terminalExists,
            isAwaitingUserSelection: isAwaitingTmuxSelection
        ) else { return }
        let token = connectWatchdogToken
        Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard token == connectWatchdogToken else { return }
                guard !isAwaitingTmuxSelection else { return }
                let stillConnecting = connectionState.isConnecting
                let stillConnectedWithoutTerminal = connectionState.isConnected && !isReady && !terminalExists
                guard stillConnecting || stillConnectedWithoutTerminal else { return }

                if stillConnectedWithoutTerminal {
                    TerminalTabManager.shared.updatePaneState(paneId, connectionState: .disconnected)
                    retryConnection()
                    return
                }

                if TerminalTabManager.shared.shellId(for: paneId) != nil {
                    TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
                    return
                }

                let inFlight = TerminalTabManager.shared.isShellStartInFlight(for: paneId)
                if inFlight {
                    // Keep polling while a shell start is still in flight so stale locks
                    // and hung attempts are eventually surfaced to the user.
                    startConnectWatchdog()
                    return
                }

                TerminalTabManager.shared.updatePaneState(
                    paneId,
                    connectionState: .failed(String(localized: "Connection timed out. Please retry."))
                )
            }
        }
    }

    @MainActor
    private func installMoshServerAndReconnect() async {
        guard !isInstallingMosh else { return }
        isInstallingMosh = true
        defer { isInstallingMosh = false }

        do {
            try await TerminalTabManager.shared.installMoshServer(for: paneId)
            operationNotice = nil
            retryConnection()
        } catch {
            operationNotice = NoticeItem(
                id: "pane-mosh-install-error-\(paneId.uuidString)",
                lane: .bottomOperation,
                level: .error,
                leading: .icon("xmark.octagon.fill"),
                title: String(localized: "mosh-server install failed"),
                message: error.localizedDescription,
                dismissAction: { operationNotice = nil }
            )
        }
    }

    private func updateTerminalBackgroundColor() {
        let themeName = effectiveThemeName
        Task.detached(priority: .utility) {
            let resolved = ThemeColorParser.backgroundColor(for: themeName)!
            await MainActor.run {
                terminalBackgroundColor = resolved
                UserDefaults.standard.set(resolved.toHex(), forKey: "terminalBackgroundColor")
            }
        }
    }

    private static func initialTerminalBackgroundColor() -> Color {
        let defaults = UserDefaults.standard

        if let cachedHex = defaults.string(forKey: "terminalBackgroundColor") {
            return Color.fromHex(cachedHex)
        }

        let usePerAppearanceTheme = defaults.object(forKey: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) as? Bool ?? true
        let darkThemeName = defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameKey) ?? "Aizen Dark"
        let lightThemeName = defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameLightKey) ?? "Aizen Light"
        #if os(macOS)
        let isDarkAppearance = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #else
        let isDarkAppearance = UITraitCollection.current.userInterfaceStyle == .dark
        #endif
        let themeName = usePerAppearanceTheme ? (isDarkAppearance ? darkThemeName : lightThemeName) : darkThemeName

        return ThemeColorParser.backgroundColor(for: themeName)!
    }

    private var voiceTriggerButton: some View {
        Button {
            onVoiceTrigger()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Voice input (Command+Shift+M)"))
        .padding(14)
    }
}
