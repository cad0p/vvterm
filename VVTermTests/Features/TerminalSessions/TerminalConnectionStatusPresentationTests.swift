import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TerminalConnectionStatusPresentationTests {
    @Test
    func establishedReconnectUsesBannerInsteadOfBlockingStatus() {
        let presentation = resolve(
            connectionState: .reconnecting(attempt: 2),
            hasEstablishedConnection: true,
            terminalExists: true,
            isReady: true
        )

        #expect(presentation == .hidden)
    }

    @Test
    func automaticReconnectNeverUsesActionSheet() {
        let presentation = resolve(
            connectionState: .reconnecting(attempt: 1),
            terminalExists: false,
            isReady: false
        )

        #expect(presentation == .hidden)
    }

    @Test
    func automaticReconnectHidesTransientDisconnectedActionSheet() {
        let presentation = resolve(
            connectionState: .disconnected,
            hasEstablishedConnection: true,
            automaticReconnectAllowed: true,
            terminalExists: true,
            isReady: true
        )

        #expect(presentation == .hidden)
    }

    @Test
    func intentionalTmuxDetachShowsDisconnectedStateInsteadOfReconnectBanner() {
        let presentation = resolve(
            connectionState: .disconnected,
            hasEstablishedConnection: true,
            automaticReconnectAllowed: false,
            terminalExists: true,
            isReady: true,
            disconnectedMessage: "tmux session is still running on the server."
        )

        #expect(
            presentation == .disconnected(
                message: "tmux session is still running on the server."
            )
        )
    }

    @Test
    func reconnectPreparationHidesPreviousFailureSheet() {
        let presentation = resolve(
            connectionState: .failed("Connection timed out"),
            hasEstablishedConnection: true,
            isReconnectPreparationInFlight: true,
            terminalExists: true,
            isReady: false
        )

        #expect(presentation == .hidden)
    }

    @Test
    func establishedConnectingStateUsesBannerEvenWhileTerminalReattaches() {
        let presentation = resolve(
            connectionState: .connecting,
            hasEstablishedConnection: true,
            terminalExists: false,
            isReady: false
        )

        #expect(presentation == .hidden)
    }

    @Test
    func restoredPaneKeepsReconnectPresentationAcrossViewRecreation() {
        var paneState = TerminalPaneState(
            paneId: UUID(),
            tabId: UUID(),
            serverId: UUID()
        )
        paneState.markConnectionEstablished()
        paneState.connectionState = .disconnected

        let presentation = resolve(
            connectionState: .connecting,
            hasEstablishedConnection: paneState.hasEstablishedConnection,
            terminalExists: false,
            isReady: false
        )

        #expect(presentation == .hidden)
    }

    @Test
    func firstReconnectAttemptUsesReconnectState() {
        #expect(
            TerminalConnectionAttemptPolicy.state(
                attempt: 1,
                hasEstablishedConnection: true
            ) == .reconnecting(attempt: 1)
        )
    }

    @Test
    func firstInitialAttemptUsesConnectingState() {
        #expect(
            TerminalConnectionAttemptPolicy.state(
                attempt: 1,
                hasEstablishedConnection: false
            ) == .connecting
        )
    }

    @Test
    func disconnectedStateCannotStartASecondConnectionDirectly() {
        #expect(!TerminalConnectionStartPolicy.shouldStart(connectionState: .disconnected))
        #expect(TerminalConnectionStartPolicy.shouldStart(connectionState: .reconnecting(attempt: 1)))
    }

    @Test
    func initialConnectionUsesProgressSheet() {
        let presentation = resolve(
            connectionState: .connecting,
            terminalExists: false,
            isReady: false
        )

        #expect(presentation == .connecting(serverName: "Test Server"))
    }

    @Test
    func tmuxSelectionDismissesInitialConnectionSheet() {
        let presentation = resolve(
            connectionState: .connecting,
            isAwaitingTmuxSelection: true,
            terminalExists: false,
            isReady: false
        )

        #expect(presentation == .hidden)
    }

    @Test
    func tmuxSelectionSuspendsConnectionWatchdog() {
        let shouldMonitor = TerminalConnectionWatchdogPolicy.shouldMonitor(
            connectionState: .connecting,
            isReady: false,
            terminalExists: false,
            isAwaitingUserSelection: true
        )

        #expect(!shouldMonitor)
    }

    @Test
    func connectionWatchdogResumesAfterTmuxSelection() {
        let shouldMonitor = TerminalConnectionWatchdogPolicy.shouldMonitor(
            connectionState: .connecting,
            isReady: false,
            terminalExists: false,
            isAwaitingUserSelection: false
        )

        #expect(shouldMonitor)
    }

    @Test
    func manualDisconnectedStateCarriesRecoveryContextIntoActionPresentation() {
        let message = "tmux session is still running on the server."
        let presentation = resolve(
            connectionState: .disconnected,
            disconnectedMessage: message
        )

        #expect(presentation == .disconnected(message: message))
    }

    @Test
    func tmuxDisconnectMessagesReflectLifecycleReason() {
        #expect(
            TerminalDisconnectReason.externalTmuxEnded.statusMessage
                == String(localized: "The tmux session has ended.")
        )
        #expect(
            TerminalDisconnectReason.tmuxDetached.statusMessage
                == String(localized: "tmux session is still running on the server.")
        )
        #expect(TerminalDisconnectReason.transportEnded.statusMessage == nil)
    }

    @Test
    func hostKeyFailureEnablesReplacementAction() {
        let presentation = resolve(
            connectionState: .failed("Host key verification failed"),
            isHostKeyVerificationFailure: true
        )

        #expect(
            presentation == .failed(
                message: "Host key verification failed",
                allowsHostKeyReplacement: true
            )
        )
    }

    @Test
    func credentialFailureTakesPrecedenceOverConnectionState() {
        let presentation = resolve(
            credentialLoadErrorMessage: "Failed to load credentials",
            connectionState: .connected,
            terminalExists: true,
            isReady: true
        )

        #expect(
            presentation == .failed(
                message: "Failed to load credentials",
                allowsHostKeyReplacement: false
            )
        )
    }

    private func resolve(
        credentialLoadErrorMessage: String? = nil,
        connectionState: ConnectionState,
        hasEstablishedConnection: Bool = false,
        automaticReconnectAllowed: Bool = false,
        isReconnectPreparationInFlight: Bool = false,
        isAwaitingTmuxSelection: Bool = false,
        terminalExists: Bool = true,
        isReady: Bool = true,
        disconnectedMessage: String? = nil,
        isHostKeyVerificationFailure: Bool = false
    ) -> TerminalConnectionStatusPresentation {
        .resolve(
            credentialLoadErrorMessage: credentialLoadErrorMessage,
            connectionState: connectionState,
            serverName: "Test Server",
            hasEstablishedConnection: hasEstablishedConnection,
            automaticReconnectAllowed: automaticReconnectAllowed,
            isReconnectPreparationInFlight: isReconnectPreparationInFlight,
            isAwaitingTmuxSelection: isAwaitingTmuxSelection,
            terminalExists: terminalExists,
            isReady: isReady,
            disconnectedMessage: disconnectedMessage,
            isHostKeyVerificationFailure: isHostKeyVerificationFailure
        )
    }
}
