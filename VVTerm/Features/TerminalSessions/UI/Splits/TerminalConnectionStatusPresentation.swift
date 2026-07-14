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

enum TerminalConnectionStatusPresentation: Equatable {
    case hidden
    case connecting(serverName: String)
    case disconnected(message: String?)
    case failed(message: String, allowsHostKeyReplacement: Bool)

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
        isHostKeyVerificationFailure: Bool
    ) -> Self {
        if let credentialLoadErrorMessage {
            return .failed(
                message: credentialLoadErrorMessage,
                allowsHostKeyReplacement: false
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
                allowsHostKeyReplacement: isHostKeyVerificationFailure
            )
        case .connected, .idle:
            return !isReady && !terminalExists ? .connecting(serverName: serverName) : .hidden
        }
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

        return connectionState == .disconnected && automaticReconnectAllowed
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
