import Foundation
import CloudKit
import os.log

@MainActor
final class CloudKitSyncCoordinator {
    static let shared = CloudKitSyncCoordinator()

    private let cloudKit = CloudKitManager.shared
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "CloudKitSyncCoordinator"
    )
    private let queue = PendingCloudKitSyncQueue()
    private var isDraining = false
    private var shouldDrainAgain = false
    static let terminalAccessoryProfileDidResolveNotification = Notification.Name(
        "TerminalAccessoryProfileDidResolveFromCloudKit"
    )

    private init() {}

    func snapshot() -> [PendingCloudKitMutation] {
        queue.snapshot()
    }

    func clearPendingMutations() {
        queue.removeAll()
    }

    func clearPendingMutations(for entities: Set<PendingCloudKitEntity>) {
        queue.removeAll { entities.contains($0.entity) }
    }

    func removePendingMutation(_ mutationID: UUID) {
        queue.remove(mutationID)
    }

    func enqueueServerUpsert(_ server: Server) {
        queue.enqueue(.serverUpsert(server))
    }

    func enqueueServerDelete(_ server: Server) {
        queue.enqueue(.serverDelete(server))
    }

    func enqueueWorkspaceUpsert(_ workspace: Workspace) {
        queue.enqueue(.workspaceUpsert(workspace))
    }

    func enqueueWorkspaceDelete(_ workspace: Workspace) {
        queue.enqueue(.workspaceDelete(workspace))
    }

    func enqueueTerminalThemeUpsert(_ theme: TerminalTheme) {
        queue.enqueue(.terminalThemeUpsert(theme))
    }

    func enqueueTerminalThemePreferenceUpsert(_ preference: TerminalThemePreference) {
        queue.enqueue(.terminalThemePreferenceUpsert(preference))
    }

    func enqueueTerminalAccessoryProfileUpsert(_ profile: TerminalAccessoryProfile) {
        queue.enqueue(.terminalAccessoryProfileUpsert(profile))
    }

    func drainPendingMutations() async {
        guard SyncSettings.isEnabled else { return }
        guard !isDraining else {
            shouldDrainAgain = true
            return
        }

        isDraining = true
        defer {
            isDraining = false
            shouldDrainAgain = false
        }

        while true {
            let drainRequestedDuringIteration = shouldDrainAgain
            shouldDrainAgain = false
            let snapshot = queue.snapshot()
            guard !snapshot.isEmpty else { return }

            var didProgress = false
            let orderedMutations = snapshot.sorted(by: pendingSyncDrainOrder)

            for mutation in orderedMutations {
                guard queue.canAttempt(mutation, at: Date()) else {
                    continue
                }

                do {
                    try await syncPendingMutation(mutation)
                    queue.remove(mutation.id)
                    didProgress = true
                } catch {
                    if isIgnorableDeleteSyncError(error, for: mutation) {
                        queue.remove(mutation.id)
                        didProgress = true
                        continue
                    }

                    queue.recordFailure(for: mutation, error: error)
                    logger.warning(
                        "Pending CloudKit sync failed for \(mutation.entityDescription): \(error.localizedDescription)"
                    )

                    if shouldPausePendingSyncDrain(for: error) {
                        return
                    }
                }
            }

            if !didProgress {
                if shouldDrainAgain || drainRequestedDuringIteration {
                    continue
                }
                return
            }
        }
    }

    private func syncPendingMutation(_ mutation: PendingCloudKitMutation) async throws {
        switch (mutation.entity, mutation.operation) {
        case (.server, .upsert):
            if let server = mutation.server {
                try await cloudKit.saveServer(server)
            }
        case (.server, .delete):
            if let server = mutation.server {
                try await cloudKit.deleteServer(server)
            }
        case (.workspace, .upsert):
            if let workspace = mutation.workspace {
                try await cloudKit.saveWorkspace(workspace)
            }
        case (.workspace, .delete):
            if let workspace = mutation.workspace {
                try await cloudKit.deleteWorkspace(workspace)
            }
        case (.terminalTheme, .upsert), (.terminalTheme, .delete):
            if let theme = mutation.terminalTheme {
                try await cloudKit.saveTerminalTheme(theme)
            }
        case (.terminalThemePreference, .upsert):
            if let preference = mutation.terminalThemePreference {
                try await cloudKit.saveTerminalThemePreference(preference)
            }
        case (.terminalThemePreference, .delete):
            break
        case (.terminalAccessoryProfile, .upsert):
            if let profile = mutation.terminalAccessoryProfile {
                let resolvedProfile = try await cloudKit.syncTerminalAccessoryProfile(profile)
                NotificationCenter.default.post(
                    name: Self.terminalAccessoryProfileDidResolveNotification,
                    object: self,
                    userInfo: ["profile": resolvedProfile]
                )
            }
        case (.terminalAccessoryProfile, .delete):
            break
        }
    }

    private func pendingSyncDrainOrder(_ lhs: PendingCloudKitMutation, _ rhs: PendingCloudKitMutation) -> Bool {
        if lhs.drainPriority != rhs.drainPriority {
            return lhs.drainPriority < rhs.drainPriority
        }

        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func isIgnorableDeleteSyncError(_ error: Error, for mutation: PendingCloudKitMutation) -> Bool {
        guard mutation.operation == .delete else { return false }
        guard let ckError = error as? CKError else { return false }

        switch ckError.code {
        case .unknownItem, .zoneNotFound:
            return true
        default:
            return false
        }
    }

    private func shouldPausePendingSyncDrain(for error: Error) -> Bool {
        if let cloudKitError = error as? CloudKitError, cloudKitError == .notAvailable {
            return true
        }

        guard let ckError = error as? CKError else { return false }

        switch ckError.code {
        case .notAuthenticated, .permissionFailure, .quotaExceeded, .requestRateLimited,
             .serviceUnavailable, .networkUnavailable, .networkFailure:
            return true
        default:
            return false
        }
    }
}
