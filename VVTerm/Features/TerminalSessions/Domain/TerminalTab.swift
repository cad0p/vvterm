//
//  TerminalTab.swift
//  VVTerm
//
//  A tab containing one or more terminal panes (via splits).
//  Each tab is independent - splits happen within a tab, not across tabs.
//

import Foundation

// MARK: - Terminal Tab

/// Represents a single tab in the terminal toolbar.
/// Each tab can contain multiple panes via splits.
struct TerminalTab: Identifiable, Equatable, Codable {
    let id: UUID
    let serverId: UUID
    var title: String
    var createdAt: Date

    /// The split layout for this tab. Nil means single pane (the root pane).
    var layout: TerminalSplitNode?

    /// The currently focused pane ID within this tab
    var focusedPaneId: UUID

    /// Root pane ID - the original pane created with this tab
    let rootPaneId: UUID

    init(
        id: UUID = UUID(),
        serverId: UUID,
        title: String,
        createdAt: Date = Date(),
        rootPaneId: UUID = UUID(),
        focusedPaneId: UUID? = nil,
        layout: TerminalSplitNode? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.title = title
        self.createdAt = createdAt
        self.rootPaneId = rootPaneId
        self.focusedPaneId = focusedPaneId ?? rootPaneId
        self.layout = layout
    }

    /// All pane IDs in this tab (from layout or just root)
    var allPaneIds: [UUID] {
        layout?.allPaneIds() ?? [rootPaneId]
    }

    /// Number of panes in this tab
    var paneCount: Int {
        layout?.leafCount ?? 1
    }

    /// Whether this tab has splits
    var hasSplits: Bool {
        layout != nil && (layout?.leafCount ?? 1) > 1
    }
}

// MARK: - Terminal Pane State

/// State for a single terminal pane (leaf in split tree)
struct TerminalPaneState {
    let paneId: UUID
    let tabId: UUID
    let serverId: UUID
    var connectionState: ConnectionState
    var disconnectReason: TerminalDisconnectReason?
    /// Whether the most recent connection failure is one the automatic
    /// reconnect loop may retry. Recorded from
    /// `SSHError.allowsAutomaticReconnectRetry` when the failure is handled;
    /// trust failures (unknown or mismatched host key) always wait for the
    /// user, so a pending first-use key cannot be overwritten by a retry.
    private(set) var lastFailureAllowsAutomaticReconnectRetry: Bool
    private(set) var hasEstablishedConnection: Bool
    var lastActivity: Date
    var tmuxStatus: TmuxStatus
    var workingDirectory: String?
    var presentationOverrides: TerminalPresentationOverrides
    var seedPaneId: UUID?
    /// Runtime transport for this pane (never persisted).
    var activeTransport: ShellTransport
    /// Set only when this pane is running over SSH fallback from Mosh.
    var moshFallbackReason: MoshFallbackReason?
    /// Privacy-safe, non-persisted detail for the active Mosh fallback.
    var moshFallbackDiagnostics: MoshFallbackDiagnostics?
    /// Minimal non-secret context needed to recognize tmux lifecycle markers
    /// when an existing ET session is resumed after process relaunch.
    var eternalTerminalTmuxResumeContext: EternalTerminalTmuxResumeContext?

    init(paneId: UUID, tabId: UUID, serverId: UUID) {
        self.paneId = paneId
        self.tabId = tabId
        self.serverId = serverId
        self.connectionState = .connecting
        self.disconnectReason = nil
        self.lastFailureAllowsAutomaticReconnectRetry = true
        self.hasEstablishedConnection = false
        self.lastActivity = Date()
        self.tmuxStatus = .unknown
        self.workingDirectory = nil
        self.presentationOverrides = .empty
        self.seedPaneId = nil
        self.activeTransport = .ssh
        self.moshFallbackReason = nil
        self.moshFallbackDiagnostics = nil
        self.eternalTerminalTmuxResumeContext = nil
    }

    mutating func markConnectionEstablished() {
        hasEstablishedConnection = true
        lastFailureAllowsAutomaticReconnectRetry = true
    }

    mutating func markConnectionAttemptStarted() {
        lastFailureAllowsAutomaticReconnectRetry = true
    }

    mutating func recordConnectionFailure(allowsAutomaticReconnectRetry: Bool) {
        // Sticky: the Eternal Terminal runtime can report one failure more
        // than once, and only the report carrying the retained bootstrap
        // cause classifies a trust failure as non-retryable. A later generic
        // report must not re-enable the automatic retry loop over a prompt
        // the user has not answered. A fresh attempt
        // (`markConnectionAttemptStarted`) or a successful connection
        // (`markConnectionEstablished`) clears the classification.
        lastFailureAllowsAutomaticReconnectRetry =
            lastFailureAllowsAutomaticReconnectRetry && allowsAutomaticReconnectRetry
    }
}
