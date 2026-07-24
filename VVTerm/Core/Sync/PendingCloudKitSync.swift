import Foundation
import CloudKit

enum PendingCloudKitEntity: String, Codable {
    case server
    case workspace
    case terminalTheme
    case terminalThemePreference
    case terminalAccessoryProfile
}

enum PendingCloudKitOperation: String, Codable {
    case upsert
    case delete
}

struct PendingCloudKitMutation: Codable, Identifiable {
    let id: UUID
    let entity: PendingCloudKitEntity
    let operation: PendingCloudKitOperation
    let entityKey: String
    var server: Server?
    var workspace: Workspace?
    var terminalTheme: TerminalTheme?
    var terminalThemePreference: TerminalThemePreference?
    var terminalAccessoryProfile: TerminalAccessoryProfile?
    let createdAt: Date
    var retryCount: Int
    var nextRetryAt: Date?
    var lastErrorCode: String?
    var lastErrorDescription: String?

    static func serverUpsert(_ server: Server) -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: UUID(),
            entity: .server,
            operation: .upsert,
            entityKey: server.id.uuidString,
            server: server,
            workspace: nil,
            terminalTheme: nil,
            terminalThemePreference: nil,
            terminalAccessoryProfile: nil,
            createdAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCode: nil,
            lastErrorDescription: nil
        )
    }

    static func serverDelete(_ server: Server) -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: UUID(),
            entity: .server,
            operation: .delete,
            entityKey: server.id.uuidString,
            server: server,
            workspace: nil,
            terminalTheme: nil,
            terminalThemePreference: nil,
            terminalAccessoryProfile: nil,
            createdAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCode: nil,
            lastErrorDescription: nil
        )
    }

    static func workspaceUpsert(_ workspace: Workspace) -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: UUID(),
            entity: .workspace,
            operation: .upsert,
            entityKey: workspace.id.uuidString,
            server: nil,
            workspace: workspace,
            terminalTheme: nil,
            terminalThemePreference: nil,
            terminalAccessoryProfile: nil,
            createdAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCode: nil,
            lastErrorDescription: nil
        )
    }

    static func workspaceDelete(_ workspace: Workspace) -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: UUID(),
            entity: .workspace,
            operation: .delete,
            entityKey: workspace.id.uuidString,
            server: nil,
            workspace: workspace,
            terminalTheme: nil,
            terminalThemePreference: nil,
            terminalAccessoryProfile: nil,
            createdAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCode: nil,
            lastErrorDescription: nil
        )
    }

    static func terminalThemeUpsert(_ theme: TerminalTheme) -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: UUID(),
            entity: .terminalTheme,
            operation: .upsert,
            entityKey: theme.id.uuidString,
            server: nil,
            workspace: nil,
            terminalTheme: theme,
            terminalThemePreference: nil,
            terminalAccessoryProfile: nil,
            createdAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCode: nil,
            lastErrorDescription: nil
        )
    }

    static func terminalThemeDelete(_ theme: TerminalTheme) -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: UUID(),
            entity: .terminalTheme,
            operation: .delete,
            entityKey: theme.id.uuidString,
            server: nil,
            workspace: nil,
            terminalTheme: theme,
            terminalThemePreference: nil,
            terminalAccessoryProfile: nil,
            createdAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCode: nil,
            lastErrorDescription: nil
        )
    }

    static func terminalThemePreferenceUpsert(_ preference: TerminalThemePreference) -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: UUID(),
            entity: .terminalThemePreference,
            operation: .upsert,
            entityKey: TerminalThemePreference.recordName,
            server: nil,
            workspace: nil,
            terminalTheme: nil,
            terminalThemePreference: preference,
            terminalAccessoryProfile: nil,
            createdAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCode: nil,
            lastErrorDescription: nil
        )
    }

    static func terminalThemePreferenceDelete() -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: UUID(),
            entity: .terminalThemePreference,
            operation: .delete,
            entityKey: TerminalThemePreference.recordName,
            server: nil,
            workspace: nil,
            terminalTheme: nil,
            terminalThemePreference: nil,
            terminalAccessoryProfile: nil,
            createdAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCode: nil,
            lastErrorDescription: nil
        )
    }

    static func terminalAccessoryProfileUpsert(_ profile: TerminalAccessoryProfile) -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: UUID(),
            entity: .terminalAccessoryProfile,
            operation: .upsert,
            entityKey: TerminalAccessoryProfile.recordName,
            server: nil,
            workspace: nil,
            terminalTheme: nil,
            terminalThemePreference: nil,
            terminalAccessoryProfile: profile,
            createdAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCode: nil,
            lastErrorDescription: nil
        )
    }

    static func terminalAccessoryProfileDelete() -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: UUID(),
            entity: .terminalAccessoryProfile,
            operation: .delete,
            entityKey: TerminalAccessoryProfile.recordName,
            server: nil,
            workspace: nil,
            terminalTheme: nil,
            terminalThemePreference: nil,
            terminalAccessoryProfile: nil,
            createdAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCode: nil,
            lastErrorDescription: nil
        )
    }

    var operationPriority: Int {
        switch operation {
        case .upsert: return 0
        case .delete: return 1
        }
    }

    var entityPriority: Int {
        switch entity {
        case .workspace: return 0
        case .server: return 1
        case .terminalTheme: return 2
        case .terminalThemePreference: return 3
        case .terminalAccessoryProfile: return 4
        }
    }

    var entityDescription: String {
        let kind: String
        switch entity {
        case .server: kind = "server"
        case .workspace: kind = "workspace"
        case .terminalTheme: kind = "terminal theme"
        case .terminalThemePreference: kind = "terminal theme preference"
        case .terminalAccessoryProfile: kind = "terminal accessory profile"
        }

        let op: String
        switch operation {
        case .upsert: op = "upsert"
        case .delete: op = "delete"
        }

        return "\(kind) \(op) \(entityKey)"
    }

    var drainPriority: Int {
        switch (entity, operation) {
        case (.workspace, .upsert): return 0
        case (.server, .upsert): return 1
        case (.terminalTheme, .upsert): return 2
        case (.terminalThemePreference, .upsert): return 3
        case (.terminalAccessoryProfile, .upsert): return 4
        case (.server, .delete): return 5
        case (.workspace, .delete): return 6
        case (.terminalTheme, .delete): return 7
        case (.terminalThemePreference, .delete): return 8
        case (.terminalAccessoryProfile, .delete): return 9
        }
    }

    func canAttempt(at date: Date) -> Bool {
        guard let nextRetryAt else { return true }
        return nextRetryAt <= date
    }

    func withFailure(error: Error) -> PendingCloudKitMutation {
        var copy = self
        copy.retryCount += 1
        copy.lastErrorDescription = error.localizedDescription
        copy.lastErrorCode = PendingCloudKitMutation.errorCodeString(for: error)
        let delay = min(pow(2.0, Double(max(0, copy.retryCount - 1))) * 30.0, 3600.0)
        copy.nextRetryAt = Date().addingTimeInterval(delay)
        return copy
    }

    static func errorCodeString(for error: Error) -> String? {
        if let ckError = error as? CKError {
            return String(describing: ckError.code)
        }
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

final class PendingCloudKitSyncQueue {
    private let storageKey: String
    private var items: [PendingCloudKitMutation]

    init(storageKey: String = CloudKitSyncConstants.pendingCloudKitSyncQueueStorageKey) {
        self.storageKey = storageKey
        self.items = []
        load()
    }

    func snapshot() -> [PendingCloudKitMutation] {
        items
    }

    func enqueue(_ mutation: PendingCloudKitMutation) {
        items.removeAll { $0.entity == mutation.entity && $0.entityKey == mutation.entityKey }
        items.append(mutation)
        persist()
    }

    func remove(_ mutationID: UUID) {
        items.removeAll { $0.id == mutationID }
        persist()
    }

    func removeAll() {
        items.removeAll()
        persist()
    }

    func removeAll(where shouldRemove: (PendingCloudKitMutation) -> Bool) {
        items.removeAll(where: shouldRemove)
        persist()
    }

    func canAttempt(_ mutation: PendingCloudKitMutation, at date: Date) -> Bool {
        mutation.canAttempt(at: date)
    }

    func recordFailure(for mutation: PendingCloudKitMutation, error: Error) {
        guard let index = items.firstIndex(where: { $0.id == mutation.id }) else {
            return
        }

        items[index] = items[index].withFailure(error: error)
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([PendingCloudKitMutation].self, from: data) else {
            return
        }

        items = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
