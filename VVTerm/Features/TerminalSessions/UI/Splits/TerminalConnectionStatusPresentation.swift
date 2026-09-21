import Foundation

extension TerminalDisconnectReason {
    var statusMessage: String? {
        switch self {
        case .transportEnded:
            return nil
        case .tmuxDetached:
            return String(localized: "tmux session is still running on the server.")
        case .externalTmuxEnded:
            return String(localized: "The tmux session has ended.")
        }
    }
}

/// Which host-key trust affordance the failure banner offers.
enum TerminalHostKeyTrustDisposition: Hashable {
    /// No host-key action (ordinary failure).
    case none
    /// A saved pin mismatched the presented key — confirm, replace, retry.
    case replaceTrustedHost
    /// First use — confirm the new key, save it, retry.
    case trustNewHost

    /// Resolve the host-key affordance for a failed-connection message.
    ///
    /// Teleport host-key failures come from the Host CA check, not from the
    /// fingerprint pin, so replacing the pin cannot fix the failure and the
    /// retry would loop. Teleport failures therefore route to `.none`; the
    /// failure message already points at the refresh path.
    static func resolve(
        failureMessage: String,
        authMethod: AuthMethod
    ) -> TerminalHostKeyTrustDisposition {
        if failureMessage == SSHError.hostKeyVerificationFailed.localizedDescription
            || failureMessage.contains("Host key verification failed") {
            return authMethod == .faceIDTeleport ? .none : .replaceTrustedHost
        }
        if failureMessage.contains(SSHError.hostKeyUnknownMessageMarker) {
            // Teleport host keys are verified against the Host CA, so a
            // fingerprint confirmation cannot fix a Teleport host-key failure
            // — the same reason the verification-failed branch routes
            // Teleport to `.none`. Unreachable today (the Teleport path
            // throws the verification error above), mirrored here as defense
            // in depth.
            return authMethod == .faceIDTeleport ? .none : .trustNewHost
        }
        return .none
    }
}

/// The pending first-use key the user is reviewing, captured when the trust
/// affordance is tapped.
///
/// The pending entry is a single slot that a concurrent connection attempt
/// can overwrite between the prompt and the confirmation, so the alert copy
/// and the confirmation both read this snapshot instead of the live
/// `connectionState`. `connectionStateChanged()` invalidates the snapshot:
/// once the failure the alert describes is gone, the alert must not confirm
/// a key that replaced the reviewed one.
struct HostKeyTrustReviewState {
    private(set) var reviewedEntry: KnownHostsManager.Entry?
    /// The disposition captured with the reviewed entry. The live connection
    /// state can change while the alert is up (a first-use prompt becoming a
    /// replace prompt); the confirmation must act on what the user reviewed,
    /// not on the state that happens to be current at confirm time.
    private(set) var reviewedDisposition: TerminalHostKeyTrustDisposition = .none

    /// Capture the key the user is about to review.
    ///
    /// For a first-use prompt the pending entry must still match the
    /// fingerprint in the failure message the current UI is showing. A
    /// parallel attempt can replace the single pending slot, and prompting
    /// with a key that does not match the banner behind the alert would
    /// present two different fingerprints for the same failure; the capture
    /// is refused instead so the caller re-reads the key.
    ///
    /// - Returns: `true` when the alert may be presented.
    @discardableResult
    mutating func capture(
        disposition: TerminalHostKeyTrustDisposition,
        failureMessage: String?,
        pendingEntry: KnownHostsManager.Entry?
    ) -> Bool {
        switch disposition {
        case .trustNewHost:
            guard let pendingEntry,
                  let expectedFingerprint = SSHError.fingerprint(
                    inFailureMessage: failureMessage ?? ""
                  ),
                  pendingEntry.fingerprint == expectedFingerprint else {
                reviewedEntry = nil
                reviewedDisposition = .none
                return false
            }
            reviewedEntry = pendingEntry
            reviewedDisposition = .trustNewHost
            return true
        case .replaceTrustedHost:
            reviewedEntry = nil
            reviewedDisposition = .replaceTrustedHost
            return true
        case .none:
            reviewedEntry = nil
            reviewedDisposition = .none
            return false
        }
    }

    mutating func connectionStateChanged() {
        reviewedEntry = nil
        reviewedDisposition = .none
    }
}

enum TerminalConnectionStatusPresentation: Hashable {
    case hidden
    case connecting(serverName: String)
    case disconnected(message: String?)
    case failed(message: String, hostKeyTrust: TerminalHostKeyTrustDisposition)

    static func resolve(
        credentialLoadErrorMessage: String?,
        connectionState: ConnectionState,
        serverName: String,
        hasEstablishedConnection: Bool,
        automaticReconnectAllowed: Bool,
        isReconnectPreparationInFlight: Bool,
        isAwaitingTmuxSelection: Bool,
        terminalExists: Bool,
        isReady: Bool,
        disconnectedMessage: String?,
        hostKeyTrust: TerminalHostKeyTrustDisposition
    ) -> Self {
        if let credentialLoadErrorMessage {
            return .failed(
                message: credentialLoadErrorMessage,
                hostKeyTrust: .none
            )
        }

        if isAwaitingTmuxSelection {
            return .hidden
        }

        if TerminalConnectionPresentationPolicy.usesReconnectBanner(
            connectionState: connectionState,
            hasEstablishedConnection: hasEstablishedConnection,
            automaticReconnectAllowed: automaticReconnectAllowed,
            isReconnectPreparationInFlight: isReconnectPreparationInFlight
        ) {
            return .hidden
        }

        switch connectionState {
        case .connecting:
            return .connecting(serverName: serverName)
        case .reconnecting:
            return .hidden
        case .disconnected:
            return .disconnected(message: disconnectedMessage)
        case .failed(let error):
            return .failed(
                message: error,
                hostKeyTrust: hostKeyTrust
            )
        case .connected, .idle:
            return !isReady && !terminalExists ? .connecting(serverName: serverName) : .hidden
        }
    }
}

struct TerminalConnectionStatusPresentationIdentity: Hashable {
    let presentation: TerminalConnectionStatusPresentation
    let connectionAttemptID: UUID
}

enum TerminalConnectionStatusDismissalPolicy {
    static func identity(
        for presentation: TerminalConnectionStatusPresentation,
        connectionAttemptID: UUID
    ) -> TerminalConnectionStatusPresentationIdentity? {
        switch presentation {
        case .hidden, .connecting:
            return nil
        case .disconnected, .failed:
            return TerminalConnectionStatusPresentationIdentity(
                presentation: presentation,
                connectionAttemptID: connectionAttemptID
            )
        }
    }

    static func shouldPresent(
        identity: TerminalConnectionStatusPresentationIdentity?,
        dismissedIdentity: TerminalConnectionStatusPresentationIdentity?,
        isActive: Bool
    ) -> Bool {
        isActive && identity != nil && identity != dismissedIdentity
    }

    static func retainedDismissedIdentity(
        currentIdentity: TerminalConnectionStatusPresentationIdentity?,
        dismissedIdentity: TerminalConnectionStatusPresentationIdentity?
    ) -> TerminalConnectionStatusPresentationIdentity? {
        currentIdentity == dismissedIdentity ? dismissedIdentity : nil
    }
}

enum TerminalConnectionPresentationPolicy {
    static func usesReconnectBanner(
        connectionState: ConnectionState,
        hasEstablishedConnection: Bool,
        automaticReconnectAllowed: Bool,
        isReconnectPreparationInFlight: Bool
    ) -> Bool {
        if isReconnectPreparationInFlight {
            return true
        }

        if case .reconnecting = connectionState {
            return true
        }

        guard hasEstablishedConnection else { return false }

        if connectionState.isConnecting {
            return true
        }

        switch connectionState {
        case .disconnected, .failed:
            return automaticReconnectAllowed
        case .idle, .connecting, .reconnecting, .connected:
            return false
        }
    }
}

enum TerminalConnectionWatchdogPolicy {
    static func shouldMonitor(
        connectionState: ConnectionState,
        isReady: Bool,
        terminalExists: Bool,
        isAwaitingUserSelection: Bool
    ) -> Bool {
        guard !isAwaitingUserSelection else { return false }

        return connectionState.isConnecting
            || (connectionState.isConnected && !isReady && !terminalExists)
    }
}

enum TerminalConnectionStartPolicy {
    static func shouldStart(connectionState: ConnectionState) -> Bool {
        switch connectionState {
        case .connecting, .reconnecting, .connected:
            return true
        case .disconnected, .failed, .idle:
            return false
        }
    }
}

enum TerminalSceneActivityPolicy {
    static func isActive(
        environmentIsActive: Bool,
        windowSceneIsActive: Bool?
    ) -> Bool {
        windowSceneIsActive ?? environmentIsActive
    }
}

enum TerminalAutoReconnectPolicy {
    static func shouldScheduleRetry(
        automaticReconnectAllowed: Bool,
        hasEstablishedConnection: Bool,
        connectionState: ConnectionState,
        lastFailureAllowsAutomaticReconnectRetry: Bool
    ) -> Bool {
        guard automaticReconnectAllowed, hasEstablishedConnection else { return false }
        // Trust failures (unknown or mismatched host key) and every other
        // `SSHError` that is not retryable must wait for the user; retrying
        // them would overwrite the pending first-use entry the prompt is
        // showing.
        guard lastFailureAllowsAutomaticReconnectRetry else { return false }
        if case .failed = connectionState {
            return true
        }
        return false
    }

    static func shouldAttempt(
        sceneIsActive: Bool,
        applicationIsActive: Bool,
        networkReadiness: NetworkMonitor.Readiness,
        automaticReconnectAllowed: Bool,
        reconnectInFlight: Bool,
        hasEstablishedConnection: Bool,
        connectionState: ConnectionState
    ) -> Bool {
        let isRecoverableState: Bool
        switch connectionState {
        case .disconnected, .failed:
            isRecoverableState = true
        case .idle, .connecting, .reconnecting, .connected:
            isRecoverableState = false
        }

        return sceneIsActive
            && applicationIsActive
            && networkReadiness == .ready
            && automaticReconnectAllowed
            && !reconnectInFlight
            && hasEstablishedConnection
            && isRecoverableState
    }
}

enum TmuxInstallPromptPolicy {
    static func shouldPresent(for status: TmuxStatus?) -> Bool {
        status == .missing
    }
}
