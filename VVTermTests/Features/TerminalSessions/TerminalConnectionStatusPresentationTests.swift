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
    func automaticReconnectHidesTransientFailedActionSheetBetweenRetryBatches() {
        let presentation = resolve(
            connectionState: .failed("Connection timed out"),
            hasEstablishedConnection: true,
            automaticReconnectAllowed: true,
            terminalExists: true,
            isReady: true
        )

        #expect(presentation == .hidden)
    }

    @Test
    func onlyTransientSSHFailuresAllowAutomaticRetry() {
        #expect(SSHError.timeout.allowsAutomaticReconnectRetry)
        #expect(SSHError.socketError("reset").allowsAutomaticReconnectRetry)
        #expect(SSHError.moshUDPTimeout.allowsAutomaticReconnectRetry)
        #expect(!SSHError.authenticationFailed.allowsAutomaticReconnectRetry)
        #expect(!SSHError.hostKeyVerificationFailed.allowsAutomaticReconnectRetry)
        #expect(!SSHError.moshServerMissing.allowsAutomaticReconnectRetry)
    }

    @Test
    func failedEstablishedSessionKeepsRetryScheduledWhileForegroundConditionsChange() {
        #expect(TerminalAutoReconnectPolicy.shouldScheduleRetry(
            automaticReconnectAllowed: true,
            hasEstablishedConnection: true,
            connectionState: .failed("Temporary transport failure"),
            lastFailureAllowsAutomaticReconnectRetry: true
        ))
        #expect(!TerminalAutoReconnectPolicy.shouldScheduleRetry(
            automaticReconnectAllowed: false,
            hasEstablishedConnection: true,
            connectionState: .failed("Authentication failed"),
            lastFailureAllowsAutomaticReconnectRetry: true
        ))
    }

    /// A trust failure must never re-enter the automatic retry loop: each
    /// retry re-records the pending first-use entry, which would let a
    /// changed key replace the one the prompt is showing.
    @Test
    func trustFailuresAreNeverRetriedAutomatically() {
        let unknownHost = SSHError.hostKeyUnknown(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:presented",
            keyType: 1
        )
        let mismatch = SSHError.hostKeyVerificationFailed

        #expect(!unknownHost.allowsAutomaticReconnectRetry)
        #expect(!mismatch.allowsAutomaticReconnectRetry)
        #expect(!TerminalAutoReconnectPolicy.shouldScheduleRetry(
            automaticReconnectAllowed: true,
            hasEstablishedConnection: true,
            connectionState: .failed(unknownHost.localizedDescription),
            lastFailureAllowsAutomaticReconnectRetry: unknownHost.allowsAutomaticReconnectRetry
        ))
        #expect(!TerminalAutoReconnectPolicy.shouldScheduleRetry(
            automaticReconnectAllowed: true,
            hasEstablishedConnection: true,
            connectionState: .failed(mismatch.localizedDescription),
            lastFailureAllowsAutomaticReconnectRetry: mismatch.allowsAutomaticReconnectRetry
        ))
    }

    /// The first-use review captures the pending entry when the affordance is
    /// tapped, and a connection-state change clears it so a stale alert
    /// cannot confirm a key that replaced the reviewed one.
    @Test
    func firstUseReviewIsCapturedAndClearedOnStateChange() {
        let entry = KnownHostsManager.Entry(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:reviewed",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        )
        let failureMessage = firstUseFailureMessage(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:reviewed"
        )
        var review = HostKeyTrustReviewState()

        // The replace flow captures nil but must still present its alert.
        let replaceCaptured = review.capture(
            disposition: .replaceTrustedHost,
            failureMessage: nil,
            pendingEntry: entry
        )
        #expect(replaceCaptured)
        #expect(review.reviewedEntry == nil)
        #expect(review.reviewedDisposition == .replaceTrustedHost)

        let trustCaptured = review.capture(
            disposition: .trustNewHost,
            failureMessage: failureMessage,
            pendingEntry: entry
        )
        #expect(trustCaptured)
        #expect(review.reviewedEntry?.fingerprint == "SHA256:reviewed")
        #expect(review.reviewedDisposition == .trustNewHost)

        review.connectionStateChanged()
        #expect(review.reviewedEntry == nil)
        #expect(review.reviewedDisposition == .none)
    }

    /// The confirmation must act on the disposition captured with the
    /// reviewed entry: the live connection state can flip while the alert is
    /// up (a first-use prompt becoming a replace prompt, whose action would
    /// delete the saved pin). The capture retains the reviewed disposition,
    /// and a state change invalidates it together with the entry.
    @Test
    func reviewedDispositionIsCapturedAndInvalidatedWithTheEntry() {
        let entry = KnownHostsManager.Entry(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:reviewed",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        )
        var review = HostKeyTrustReviewState()

        review.capture(
            disposition: .trustNewHost,
            failureMessage: firstUseFailureMessage(
                host: "example.com",
                port: 22,
                fingerprint: "SHA256:reviewed"
            ),
            pendingEntry: entry
        )
        #expect(review.reviewedDisposition == .trustNewHost)
        #expect(review.reviewedEntry?.fingerprint == "SHA256:reviewed")

        // The confirmation reads the captured disposition, not a live
        // re-resolve that could have flipped to `.replaceTrustedHost`.
        #expect(review.reviewedDisposition != .replaceTrustedHost)

        review.connectionStateChanged()
        #expect(review.reviewedDisposition == .none)
        #expect(review.reviewedEntry == nil)
    }

    /// The trust review is only capturable when the failure is a first-use
    /// prompt; a missing pending entry captures nothing, so the confirmation
    /// fails closed instead of pinning an unreviewed key.
    @Test
    func firstUseReviewWithoutAPendingEntryCapturesNothing() {
        var review = HostKeyTrustReviewState()
        let captured = review.capture(
            disposition: .trustNewHost,
            failureMessage: firstUseFailureMessage(
                host: "example.com",
                port: 22,
                fingerprint: "SHA256:reviewed"
            ),
            pendingEntry: nil
        )
        #expect(!captured)
        #expect(review.reviewedEntry == nil)
    }

    /// A pending entry that no longer matches the failure the banner is
    /// showing must refuse the capture: the alert would otherwise display a
    /// fingerprint that disagrees with the failure that opened it.
    @Test
    func firstUseReviewRefusesAPendingEntryThatDoesNotMatchTheFailure() {
        let entry = KnownHostsManager.Entry(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:B",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        )
        var review = HostKeyTrustReviewState()

        let captured = review.capture(
            disposition: .trustNewHost,
            failureMessage: firstUseFailureMessage(
                host: "example.com",
                port: 22,
                fingerprint: "SHA256:A"
            ),
            pendingEntry: entry
        )

        #expect(!captured)
        #expect(review.reviewedEntry == nil)
    }

    /// A stale tap after the failure state moved on must not present an
    /// alert: there is no trust disposition to review any more.
    @Test
    func noDispositionRefusesTheCapture() {
        var review = HostKeyTrustReviewState()
        let captured = review.capture(
            disposition: .none,
            failureMessage: nil,
            pendingEntry: nil
        )
        #expect(!captured)
        #expect(review.reviewedEntry == nil)
    }

    /// The fingerprint parser reads the value the failure message carries.
    @Test
    func failureMessageFingerprintIsExtracted() {
        let message = firstUseFailureMessage(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:abc123"
        )
        #expect(SSHError.fingerprint(inFailureMessage: message) == "SHA256:abc123")
        #expect(SSHError.fingerprint(inFailureMessage: "Host key verification failed") == nil)
        #expect(SSHError.fingerprint(inFailureMessage: "") == nil)
    }

    /// A host containing parentheses must not shift fingerprint extraction:
    /// the fingerprint is the last parenthesised group in the message.
    @Test
    func failureMessageFingerprintSurvivesParenthesisedHosts() {
        let message = firstUseFailureMessage(
            host: "my(pc)",
            port: 22,
            fingerprint: "SHA256:abc123"
        )
        #expect(SSHError.fingerprint(inFailureMessage: message) == "SHA256:abc123")
    }

    /// Simulates the review-to-confirmation race: the user reviews A in the
    /// alert, a background attempt overwrites the single pending entry with
    /// B, and the confirmation is refused while the stale B entry is
    /// discarded (the next attempt re-records and re-prompts).
    @Test
    func capturedReviewRefusesARacingPendingEntry() throws {
        let manager = KnownHostsManager.shared
        manager.removeAll()
        defer { manager.removeAll() }

        manager.recordPending(entry: KnownHostsManager.Entry(
            host: "race.example.com",
            port: 22,
            fingerprint: "SHA256:A",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        ))
        var review = HostKeyTrustReviewState()
        review.capture(
            disposition: .trustNewHost,
            failureMessage: firstUseFailureMessage(
                host: "race.example.com",
                port: 22,
                fingerprint: "SHA256:A"
            ),
            pendingEntry: manager.pendingEntry(for: "race.example.com", port: 22)
        )
        #expect(review.reviewedEntry?.fingerprint == "SHA256:A")

        manager.recordPending(entry: KnownHostsManager.Entry(
            host: "race.example.com",
            port: 22,
            fingerprint: "SHA256:B",
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        ))

        let confirmed = manager.confirmPending(
            host: "race.example.com",
            port: 22,
            expectedFingerprint: try #require(review.reviewedEntry?.fingerprint)
        )

        #expect(!confirmed)
        #expect(manager.entry(for: "race.example.com", port: 22) == nil)
        #expect(manager.pendingEntry(for: "race.example.com", port: 22) == nil)
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
    func scenePhaseLagCannotReconnectAfterApplicationEnteredBackground() {
        let shouldReconnect = TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: true,
            applicationIsActive: false,
            networkReadiness: .ready,
            automaticReconnectAllowed: true,
            reconnectInFlight: false,
            hasEstablishedConnection: true,
            connectionState: .disconnected
        )

        #expect(!shouldReconnect)
    }

    @Test
    func foregroundReconnectStartsWhenApplicationIsActive() {
        let shouldReconnect = TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: true,
            applicationIsActive: true,
            networkReadiness: .ready,
            automaticReconnectAllowed: true,
            reconnectInFlight: false,
            hasEstablishedConnection: true,
            connectionState: .disconnected
        )

        #expect(shouldReconnect)
    }

    @Test
    func establishedSessionRetriesAfterReconnectBatchFails() {
        let shouldReconnect = TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: true,
            applicationIsActive: true,
            networkReadiness: .ready,
            automaticReconnectAllowed: true,
            reconnectInFlight: false,
            hasEstablishedConnection: true,
            connectionState: .failed("Network path was not ready")
        )

        #expect(shouldReconnect)
    }

    @Test
    func initialConnectionFailureDoesNotEnterAutomaticRetryLoop() {
        let shouldReconnect = TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: true,
            applicationIsActive: true,
            networkReadiness: .ready,
            automaticReconnectAllowed: true,
            reconnectInFlight: false,
            hasEstablishedConnection: false,
            connectionState: .failed("Authentication failed")
        )

        #expect(!shouldReconnect)
    }

    @Test
    func reconnectAlreadyInFlightRejectsOverlappingActivationTrigger() {
        let shouldReconnect = TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: true,
            applicationIsActive: true,
            networkReadiness: .ready,
            automaticReconnectAllowed: true,
            reconnectInFlight: true,
            hasEstablishedConnection: true,
            connectionState: .disconnected
        )

        #expect(!shouldReconnect)
    }

    @Test(arguments: [NetworkMonitor.Readiness.unknown, .unavailable])
    func automaticReconnectWaitsForReadyNetwork(readiness: NetworkMonitor.Readiness) {
        let shouldReconnect = TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: true,
            applicationIsActive: true,
            networkReadiness: readiness,
            automaticReconnectAllowed: true,
            reconnectInFlight: false,
            hasEstablishedConnection: true,
            connectionState: .disconnected
        )

        #expect(!shouldReconnect)
    }

    @Test
    func tmuxInstallPromptRequiresConfirmedMissingStatus() {
        #expect(TmuxInstallPromptPolicy.shouldPresent(for: TmuxStatus.missing))
        #expect(!TmuxInstallPromptPolicy.shouldPresent(for: TmuxStatus.unknown))
        #expect(!TmuxInstallPromptPolicy.shouldPresent(for: TmuxStatus.background))
        #expect(!TmuxInstallPromptPolicy.shouldPresent(for: TmuxStatus.foreground))
        #expect(!TmuxInstallPromptPolicy.shouldPresent(for: TmuxStatus.off))
        #expect(!TmuxInstallPromptPolicy.shouldPresent(for: TmuxStatus.installing))
        #expect(!TmuxInstallPromptPolicy.shouldPresent(for: nil))
    }

    @Test
    func activeWindowSceneWinsWhileSwiftUIPhaseCatchesUp() {
        #expect(
            TerminalSceneActivityPolicy.isActive(
                environmentIsActive: false,
                windowSceneIsActive: true
            )
        )
    }

    @Test
    func backgroundWindowSceneWinsWhileSwiftUIPhaseCatchesUp() {
        #expect(!TerminalSceneActivityPolicy.isActive(
            environmentIsActive: true,
            windowSceneIsActive: false
        ))
    }

    @Test
    func windowSceneActivityFallsBackToSwiftUIBeforeTerminalAttaches() {
        #expect(
            TerminalSceneActivityPolicy.isActive(
                environmentIsActive: true,
                windowSceneIsActive: nil
            )
        )
    }

    @Test
    func initialConnectionUsesProgressPresentation() {
        let presentation = resolve(
            connectionState: .connecting,
            terminalExists: false,
            isReady: false
        )

        #expect(presentation == .connecting(serverName: "Test Server"))
    }

    @Test
    func tmuxSelectionHidesInitialConnectionStatus() {
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
            hostKeyTrust: .replaceTrustedHost
        )

        #expect(
            presentation == .failed(
                message: "Host key verification failed",
                hostKeyTrust: .replaceTrustedHost
            )
        )
    }

    @Test
    func firstUseHostKeyFailureEnablesTrustAction() {
        let presentation = resolve(
            connectionState: .failed("Host key is not trusted yet for example.com:22 (SHA256:abc)."),
            hostKeyTrust: .trustNewHost
        )

        #expect(
            presentation == .failed(
                message: "Host key is not trusted yet for example.com:22 (SHA256:abc).",
                hostKeyTrust: .trustNewHost
            )
        )
    }

    @Test
    func teleportHostKeyFailureDoesNotOfferPinReplacement() {
        // The Teleport pin hashes the rotating host certificate and is not
        // authoritative (the Host CA decides), so replacing it cannot fix a
        // CA/principal failure and the retry would loop.
        #expect(
            TerminalHostKeyTrustDisposition.resolve(
                failureMessage: "Host key verification failed",
                authMethod: .faceIDTeleport
            ) == .none
        )
        #expect(
            TerminalHostKeyTrustDisposition.resolve(
                failureMessage: SSHError.hostKeyVerificationFailed.localizedDescription,
                authMethod: .faceIDTeleport
            ) == .none
        )
    }

    @Test
    func nonTeleportHostKeyFailureStillOffersPinReplacement() {
        #expect(
            TerminalHostKeyTrustDisposition.resolve(
                failureMessage: "Host key verification failed",
                authMethod: .password
            ) == .replaceTrustedHost
        )
    }

    @Test
    func firstUseHostKeyFailureStillOffersTrust() {
        let message = SSHError.hostKeyUnknown(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:abc",
            keyType: 0
        ).localizedDescription
        #expect(
            TerminalHostKeyTrustDisposition.resolve(
                failureMessage: message,
                authMethod: .password
            ) == .trustNewHost
        )
    }

    @Test
    func teleportFirstUseHostKeyFailureDoesNotOfferPinTrust() {
        // Teleport host keys are verified against the Host CA, so a
        // fingerprint confirmation cannot fix the failure; the first-use
        // spelling must not offer a trust affordance either.
        let message = SSHError.hostKeyUnknown(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:abc",
            keyType: 0
        ).localizedDescription
        #expect(
            TerminalHostKeyTrustDisposition.resolve(
                failureMessage: message,
                authMethod: .faceIDTeleport
            ) == .none
        )
    }

    @Test
    func hostKeyUnknownErrorCarriesTheUiMarkerAndDoesNotAutoRetry() {
        // The terminal UI only has the localized string; the marker prefix is
        // what routes it to the first-use trust affordance.
        #expect(SSHError.hostKeyUnknownMessageMarker == "Host key is not trusted yet")
        let message = SSHError.hostKeyUnknown(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:abc",
            keyType: 0
        ).localizedDescription
        #expect(message.contains(SSHError.hostKeyUnknownMessageMarker))
        #expect(!SSHError.hostKeyUnknown(host: "h", port: 22, fingerprint: "f", keyType: 0).allowsAutomaticReconnectRetry)
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
                hostKeyTrust: .none
            )
        )
    }

    @Test
    func dismissedStatusIdentityDoesNotImmediatelyPresentAgain() throws {
        let attemptID = UUID()
        let identity = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: .failed(message: "Connection timed out", hostKeyTrust: .none),
            connectionAttemptID: attemptID
        ))

        #expect(!TerminalConnectionStatusDismissalPolicy.shouldPresent(
            identity: identity,
            dismissedIdentity: identity,
            isActive: true
        ))
    }

    @Test
    func dismissingStatusDoesNotChangeItsConnectionPresentation() throws {
        let presentation = TerminalConnectionStatusPresentation.disconnected(
            message: "The remote session ended."
        )
        let identity = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: presentation,
            connectionAttemptID: UUID()
        ))

        #expect(identity.presentation == presentation)
    }

    @Test
    func changedStatusPresentsAfterPreviousIdentityWasDismissed() throws {
        let attemptID = UUID()
        let dismissed = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: .failed(message: "Timed out", hostKeyTrust: .none),
            connectionAttemptID: attemptID
        ))
        let changed = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: .disconnected(message: "The remote session ended."),
            connectionAttemptID: attemptID
        ))

        #expect(TerminalConnectionStatusDismissalPolicy.shouldPresent(
            identity: changed,
            dismissedIdentity: dismissed,
            isActive: true
        ))
    }

    @Test
    func newAttemptPresentsEvenWhenFailureTextIsUnchanged() throws {
        let presentation = TerminalConnectionStatusPresentation.failed(
            message: "Connection timed out",
            hostKeyTrust: .none
        )
        let dismissed = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: presentation,
            connectionAttemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        ))
        let nextAttempt = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: presentation,
            connectionAttemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ))

        #expect(TerminalConnectionStatusDismissalPolicy.shouldPresent(
            identity: nextAttempt,
            dismissedIdentity: dismissed,
            isActive: true
        ))
    }

    @Test
    func hiddenOrChangedStatusClearsTheRetainedDismissal() throws {
        let dismissed = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: .failed(message: "Connection timed out", hostKeyTrust: .none),
            connectionAttemptID: UUID()
        ))

        #expect(TerminalConnectionStatusDismissalPolicy.retainedDismissedIdentity(
            currentIdentity: nil,
            dismissedIdentity: dismissed
        ) == nil)
    }

    @Test
    func onlyRecoveryStatusesCreateSheetIdentities() {
        let attemptID = UUID()

        #expect(TerminalConnectionStatusDismissalPolicy.identity(
            for: .hidden,
            connectionAttemptID: attemptID
        ) == nil)
        #expect(TerminalConnectionStatusDismissalPolicy.identity(
            for: .connecting(serverName: "Production"),
            connectionAttemptID: attemptID
        ) == nil)
        #expect(TerminalConnectionStatusDismissalPolicy.identity(
            for: .disconnected(message: nil),
            connectionAttemptID: attemptID
        ) != nil)
        #expect(TerminalConnectionStatusDismissalPolicy.identity(
            for: .failed(
                message: "Authentication failed",
                hostKeyTrust: .none
            ),
            connectionAttemptID: attemptID
        ) != nil)
    }

    private func firstUseFailureMessage(
        host: String,
        port: Int,
        fingerprint: String
    ) -> String {
        SSHError.hostKeyUnknown(
            host: host,
            port: port,
            fingerprint: fingerprint,
            keyType: 1
        ).localizedDescription
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
        hostKeyTrust: TerminalHostKeyTrustDisposition = .none
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
            hostKeyTrust: hostKeyTrust
        )
    }
}
