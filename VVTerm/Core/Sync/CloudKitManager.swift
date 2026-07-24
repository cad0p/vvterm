import CloudKit
import Foundation
import Combine
import os.log

// MARK: - CloudKit Manager

struct CloudKitChanges {
    let servers: [Server]
    let workspaces: [Workspace]
    let deletedServerIDs: [UUID]
    let deletedWorkspaceIDs: [UUID]
    let isFullFetch: Bool
}

@MainActor
final class CloudKitManager: ObservableObject {
    static let shared = CloudKitManager()

    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?
    @Published var isAvailable: Bool = false
    @Published var accountStatusDetail: String = String(localized: "Checking...")

    private let container: CKContainer
    private let database: CKDatabase
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CloudKit")
    private let recordZoneName = CloudKitSyncConstants.recordZoneName
    private lazy var recordZone = CKRecordZone(zoneName: recordZoneName)
    private var recordZoneID: CKRecordZone.ID { recordZone.zoneID }
    private var changeTokenKey: String { CloudKitSyncConstants.changeTokenKey(for: recordZoneName) }
    private var zoneReadyKey: String { CloudKitSyncConstants.zoneReadyKey(for: recordZoneName) }

    // Record types
    private enum RecordType {
        static let server = "Server"
        static let workspace = "Workspace"
        static let terminalTheme = "TerminalTheme"
        static let terminalThemePreference = "TerminalThemePreference"
        static let userPreference = "UserPreference"
    }

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case error(String)
        case offline
        case disabled

        var description: String {
            switch self {
            case .idle: return String(localized: "Synced")
            case .syncing: return String(localized: "Syncing...")
            case .error(let message): return String(format: String(localized: "Error: %@"), message)
            case .offline: return String(localized: "Offline")
            case .disabled: return String(localized: "Disabled")
            }
        }
    }

    private var accountStatusChecked = false
    private var isSyncEnabled: Bool { SyncSettings.isEnabled }
    private var fetchChangesTask: Task<CloudKitChanges, Error>?
    private var ensureZoneTask: Task<Void, Error>?
    private var zoneReady: Bool

    private init() {
        container = CKContainer(identifier: CloudKitSyncConstants.cloudKitContainerIdentifier)
        database = container.privateCloudDatabase
        zoneReady = UserDefaults.standard.bool(forKey: CloudKitSyncConstants.zoneReadyKey(for: recordZoneName))
        Task { await checkAccountStatus() }
    }

    // MARK: - Account Status

    /// Ensures account status is checked before performing operations
    private func ensureAccountStatusChecked() async {
        guard isSyncEnabled else {
            applySyncDisabledState()
            accountStatusChecked = true
            return
        }
        // Re-check when unavailable so transient account/network states can recover
        guard !accountStatusChecked || !isAvailable else { return }
        await checkAccountStatus()
    }

    private func checkAccountStatus() async {
        guard isSyncEnabled else {
            applySyncDisabledState()
            accountStatusChecked = true
            return
        }

        do {
            let status = try await container.accountStatus()
            let statusDescription: String
            switch status {
            case .available:
                statusDescription = String(localized: "available")
            case .noAccount:
                statusDescription = String(localized: "noAccount - User not signed into iCloud")
            case .restricted:
                statusDescription = String(localized: "restricted - iCloud access restricted (parental controls, MDM, etc.)")
            case .couldNotDetermine:
                statusDescription = String(localized: "couldNotDetermine - Unable to determine iCloud status")
            case .temporarilyUnavailable:
                statusDescription = String(localized: "temporarilyUnavailable - iCloud temporarily unavailable")
            @unknown default:
                statusDescription = String(format: String(localized: "unknown status: %@"), String(status.rawValue))
            }

            logger.info("CloudKit account status: \(statusDescription)")
            logger.info("Container identifier: \(self.container.containerIdentifier ?? "nil")")

            isAvailable = status == .available
            accountStatusDetail = statusDescription
            accountStatusChecked = true
            if isAvailable {
                if case .offline = syncStatus {
                    syncStatus = .idle
                }
            } else {
                syncStatus = .offline
                logger.warning("CloudKit not available. Status: \(statusDescription)")
            }
        } catch {
            logger.error("CloudKit account status check failed: \(error.localizedDescription)")
            isAvailable = false
            accountStatusDetail = String(format: String(localized: "Error: %@"), error.localizedDescription)
            syncStatus = .error(error.localizedDescription)
            accountStatusChecked = true
        }
    }

    private func applySyncDisabledState() {
        isAvailable = false
        syncStatus = .disabled
        accountStatusDetail = String(localized: "Disabled")
    }

    func handleSyncToggle(_ enabled: Bool) {
        if enabled {
            accountStatusChecked = false
            Task {
                await checkAccountStatus()
                await subscribeToChanges()
            }
        } else {
            applySyncDisabledState()
        }
    }

    // MARK: - Change Fetching (Incremental, No Queries)

    func fetchChanges(forceFullFetch: Bool = false) async throws -> CloudKitChanges {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()

        if !forceFullFetch, let task = fetchChangesTask {
            return try await task.value
        }

        let task = Task { try await self.withZoneRetry { try await self.fetchChangesFromCloudKit(forceFullFetch: forceFullFetch) } }
        if !forceFullFetch {
            fetchChangesTask = task
        }
        defer {
            if !forceFullFetch {
                fetchChangesTask = nil
            }
        }

        return try await task.value
    }

    private func fetchChangesFromCloudKit(forceFullFetch: Bool) async throws -> CloudKitChanges {
        syncStatus = .syncing
        defer { syncStatus = .idle }

        let previousToken = forceFullFetch ? nil : loadChangeToken()

        do {
            let changes = try await fetchChangesFromCloudKit(
                previousToken: previousToken,
                isFullFetch: forceFullFetch || previousToken == nil
            )
            lastSyncDate = Date()
            logger.info(
                "Fetched \(changes.workspaces.count) workspaces, \(changes.servers.count) servers (full fetch: \(changes.isFullFetch))"
            )
            return changes
        } catch {
            if isChangeTokenExpired(error) {
                logger.warning("CloudKit change token expired; resetting and performing full fetch")
                clearChangeToken()
                let changes = try await fetchChangesFromCloudKit(previousToken: nil, isFullFetch: true)
                lastSyncDate = Date()
                return changes
            }

            logger.error("Failed to fetch changes: \(error.localizedDescription)")
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    private func fetchChangesFromCloudKit(
        previousToken: CKServerChangeToken?,
        isFullFetch: Bool
    ) async throws -> CloudKitChanges {
        let zoneID = recordZoneID
        var token = previousToken
        var moreComing = true

        var servers: [Server] = []
        var workspaces: [Workspace] = []
        var deletedServerIDs: [UUID] = []
        var deletedWorkspaceIDs: [UUID] = []

        while moreComing {
            let batch = try await fetchZoneChanges(zoneID: zoneID, previousToken: token)

            for record in batch.records {
                switch record.recordType {
                case RecordType.server:
                    if let server = Server(from: record) {
                        servers.append(server)
                    }
                case RecordType.workspace:
                    if let workspace = Workspace(from: record) {
                        workspaces.append(workspace)
                    }
                default:
                    break
                }
            }

            for deletion in batch.deletions {
                switch deletion.recordType {
                case RecordType.server:
                    if let id = UUID(uuidString: deletion.recordID.recordName) {
                        deletedServerIDs.append(id)
                    }
                case RecordType.workspace:
                    if let id = UUID(uuidString: deletion.recordID.recordName) {
                        deletedWorkspaceIDs.append(id)
                    }
                default:
                    break
                }
            }

            token = batch.serverChangeToken
            moreComing = batch.moreComing
        }

        if let token = token {
            saveChangeToken(token)
        }

        return CloudKitChanges(
            servers: servers,
            workspaces: workspaces,
            deletedServerIDs: deletedServerIDs,
            deletedWorkspaceIDs: deletedWorkspaceIDs,
            isFullFetch: isFullFetch
        )
    }

    // MARK: - Server Operations

    func saveServer(_ server: Server) async throws {
        try await prepareSyncMutation()
        let record = server.toRecord(in: recordZoneID)
        try await performSyncMutation(
            successLog: "Saved server \(server.name) to CloudKit",
            failureLog: "Failed to save server"
        ) {
            try await withZoneRetry {
                try await saveRecordWithUpsert(record)
            }
        }
    }

    func deleteServer(_ server: Server) async throws {
        try await prepareSyncMutation()
        let recordID = CKRecord.ID(recordName: server.id.uuidString, zoneID: recordZoneID)
        _ = try await performSyncMutation(
            successLog: "Deleted server \(server.name) from CloudKit",
            failureLog: "Failed to delete server"
        ) {
            _ = try await withZoneRetry {
                try await database.modifyRecords(saving: [], deleting: [recordID])
            }
        }
    }

    // MARK: - Workspace Operations

    func saveWorkspace(_ workspace: Workspace) async throws {
        try await prepareSyncMutation()
        let record = workspace.toRecord(in: recordZoneID)
        try await performSyncMutation(
            successLog: "Saved workspace \(workspace.name) to CloudKit",
            failureLog: "Failed to save workspace"
        ) {
            try await withZoneRetry {
                try await saveRecordWithUpsert(record)
            }
        }
    }

    func deleteWorkspace(_ workspace: Workspace) async throws {
        try await prepareSyncMutation()
        let recordID = CKRecord.ID(recordName: workspace.id.uuidString, zoneID: recordZoneID)
        _ = try await performSyncMutation(
            successLog: "Deleted workspace \(workspace.name) from CloudKit",
            failureLog: "Failed to delete workspace"
        ) {
            _ = try await withZoneRetry {
                try await database.modifyRecords(saving: [], deleting: [recordID])
            }
        }
    }

    // MARK: - Terminal Theme Operations

    func fetchTerminalThemes() async throws -> [TerminalTheme] {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()
        let records = try await withZoneRetry {
            try await fetchAllRecordsFromCloudKit(matchingRecordTypes: [RecordType.terminalTheme])
        }
        return records.compactMap(TerminalTheme.init(from:))
    }

    func saveTerminalTheme(_ theme: TerminalTheme) async throws {
        try await prepareSyncMutation()
        let record = theme.toRecord(in: recordZoneID)
        try await performSyncMutation(
            successLog: "Saved terminal theme \(theme.name) to CloudKit",
            failureLog: "Failed to save terminal theme"
        ) {
            try await withZoneRetry {
                try await saveRecordWithUpsert(record)
            }
        }
    }

    func fetchTerminalThemePreference() async throws -> TerminalThemePreference? {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()
        let recordID = CKRecord.ID(recordName: TerminalThemePreference.recordName, zoneID: recordZoneID)

        do {
            let record = try await withZoneRetry {
                try await database.record(for: recordID)
            }
            return TerminalThemePreference(from: record)
        } catch let ckError as CKError where ckError.code == .unknownItem || ckError.code == .zoneNotFound {
            return nil
        } catch {
            throw error
        }
    }

    func saveTerminalThemePreference(_ preference: TerminalThemePreference) async throws {
        try await prepareSyncMutation()
        let record = preference.toRecord(in: recordZoneID)
        try await performSyncMutation(
            successLog: "Saved terminal theme preference to CloudKit",
            failureLog: "Failed to save terminal theme preference"
        ) {
            try await withZoneRetry {
                try await saveRecordWithUpsert(record)
            }
        }
    }

    // MARK: - Terminal Accessory Preference Operations

    func fetchTerminalAccessoryProfile() async throws -> TerminalAccessoryProfile? {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()
        let recordID = terminalAccessoryRecordID()

        do {
            let record = try await withZoneRetry {
                try await database.record(for: recordID)
            }
            guard let profile = decodeTerminalAccessoryProfile(from: record) else {
                logger.warning("Terminal accessory profile payload was invalid; ignoring remote value")
                return nil
            }
            return profile
        } catch let ckError as CKError where ckError.code == .unknownItem || ckError.code == .zoneNotFound {
            return nil
        } catch {
            throw error
        }
    }

    func saveTerminalAccessoryProfile(_ profile: TerminalAccessoryProfile) async throws {
        try await prepareSyncMutation()
        let recordID = terminalAccessoryRecordID()
        let record = try makeTerminalAccessoryRecord(from: profile.normalized(), recordID: recordID)
        try await performSyncMutation(
            successLog: "Saved terminal accessory profile to CloudKit",
            failureLog: "Failed to save terminal accessory profile"
        ) {
            try await withZoneRetry {
                try await saveRecordWithUpsert(record)
            }
        }
    }

    func syncTerminalAccessoryProfile(_ localProfile: TerminalAccessoryProfile) async throws -> TerminalAccessoryProfile {
        try await prepareSyncMutation()
        syncStatus = .syncing
        defer { syncStatus = .idle }

        let recordID = terminalAccessoryRecordID()
        let normalizedLocal = localProfile.normalized()

        var baseRecord: CKRecord?
        var mergedProfile = normalizedLocal

        do {
            let remoteRecord = try await withZoneRetry {
                try await database.record(for: recordID)
            }
            baseRecord = remoteRecord
            if let remoteProfile = decodeTerminalAccessoryProfile(from: remoteRecord) {
                let normalizedRemote = remoteProfile.normalized()
                mergedProfile = TerminalAccessoryProfile.merged(local: normalizedLocal, remote: normalizedRemote).normalized()
                if mergedProfile == normalizedRemote {
                    lastSyncDate = Date()
                    return normalizedRemote
                }
            } else {
                logger.warning("Terminal accessory remote payload was invalid; keeping local profile")
            }
        } catch let ckError as CKError where ckError.code == .unknownItem || ckError.code == .zoneNotFound {
            baseRecord = nil
            mergedProfile = normalizedLocal
        }

        var attempts = 0
        while attempts < 4 {
            attempts += 1

            let candidateRecord = try makeTerminalAccessoryRecord(
                from: mergedProfile,
                recordID: recordID,
                existingRecord: baseRecord
            )

            do {
                try await withZoneRetry {
                    try await saveRecord(candidateRecord, savePolicy: .ifServerRecordUnchanged)
                }
                lastSyncDate = Date()
                return mergedProfile
            } catch {
                if let serverRecord = extractServerRecord(from: error),
                   let serverProfile = decodeTerminalAccessoryProfile(from: serverRecord) {
                    let normalizedRemote = serverProfile.normalized()
                    let conflictResolved = TerminalAccessoryProfile.merged(local: mergedProfile, remote: normalizedRemote).normalized()

                    if conflictResolved == normalizedRemote {
                        lastSyncDate = Date()
                        return normalizedRemote
                    }

                    mergedProfile = conflictResolved
                    baseRecord = serverRecord
                    continue
                }

                if isUnknownItemError(error) {
                    baseRecord = nil
                    continue
                }

                logger.error("Failed to sync terminal accessory profile: \(error.localizedDescription)")
                syncStatus = .error(error.localizedDescription)
                throw error
            }
        }

        logger.error("Failed to sync terminal accessory profile after retries")
        throw CloudKitError.recordNotFound
    }

    private func prepareSyncMutation() async throws {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }
        try await ensureCustomZone()
    }

    private func performSyncMutation<T>(
        successLog: String,
        failureLog: String,
        _ operation: () async throws -> T
    ) async throws -> T {
        syncStatus = .syncing
        defer { syncStatus = .idle }

        do {
            let result = try await operation()
            lastSyncDate = Date()
            logger.info("\(successLog)")
            return result
        } catch {
            logger.error("\(failureLog): \(error.localizedDescription)")
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Subscriptions

    func subscribeToChanges() async {
        await ensureAccountStatusChecked()
        guard isSyncEnabled, isAvailable else { return }

        let subscriptionID = CloudKitSyncConstants.databaseSubscriptionID

        let notification = CKSubscription.NotificationInfo()
        notification.shouldSendContentAvailable = true

        let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
        subscription.notificationInfo = notification

        do {
            if let existing = try? await database.subscription(for: subscriptionID) as? CKDatabaseSubscription,
               existing.notificationInfo?.shouldSendContentAvailable == true {
                logger.debug("CloudKit database subscription already configured")
                return
            }

            try await database.save(subscription)
            logger.info("Subscribed to database changes")
        } catch {
            logger.error("Failed to subscribe to database changes: \(error.localizedDescription)")
        }
    }

    // MARK: - Record Fetching (No Queries)

    private struct ZoneChangeBatch {
        let records: [CKRecord]
        let deletions: [Deletion]
        let serverChangeToken: CKServerChangeToken?
        let moreComing: Bool
    }

    private struct Deletion {
        let recordID: CKRecord.ID
        let recordType: CKRecord.RecordType
    }

    private func loadChangeToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: changeTokenKey) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveChangeToken(_ token: CKServerChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        ) else {
            return
        }
        UserDefaults.standard.set(data, forKey: changeTokenKey)
    }

    private func clearChangeToken() {
        UserDefaults.standard.removeObject(forKey: changeTokenKey)
    }

    private func isChangeTokenExpired(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }
        return ckError.code == .changeTokenExpired
    }

    private func fetchAllRecordsFromCloudKit(
        matchingRecordTypes recordTypes: Set<String>? = nil
    ) async throws -> [CKRecord] {
        try await ensureCustomZone()
        let zoneID = recordZoneID
        var token: CKServerChangeToken?
        var records: [CKRecord] = []
        var moreComing = true

        while moreComing {
            let batch = try await fetchZoneChanges(zoneID: zoneID, previousToken: token)
            if let recordTypes {
                records.append(contentsOf: batch.records.filter { recordTypes.contains($0.recordType) })
            } else {
                records.append(contentsOf: batch.records)
            }
            token = batch.serverChangeToken
            moreComing = batch.moreComing
        }

        return records
    }

    private func fetchZoneChanges(
        zoneID: CKRecordZone.ID,
        previousToken: CKServerChangeToken?
    ) async throws -> ZoneChangeBatch {
        let logger = logger
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ZoneChangeBatch, Error>) in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: previousToken,
                resultsLimit: nil,
                desiredKeys: nil
            )
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: configuration]
            )
            operation.qualityOfService = .userInitiated

            var records: [CKRecord] = []
            var deletions: [Deletion] = []
            var serverChangeToken: CKServerChangeToken?
            var moreComing = false
            var zoneError: Error?

            operation.recordWasChangedBlock = { recordID, recordResult in
                switch recordResult {
                case .success(let record):
                    records.append(record)
                case .failure(let error):
                    logger.error(
                        "Failed to fetch record \(recordID.recordName): \(error.localizedDescription)"
                    )
                }
            }

            operation.recordWithIDWasDeletedBlock = { recordID, recordType in
                deletions.append(Deletion(recordID: recordID, recordType: recordType))
            }

            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let info):
                    serverChangeToken = info.serverChangeToken
                    moreComing = info.moreComing
                case .failure(let error):
                    zoneError = error
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    if let zoneError = zoneError {
                        continuation.resume(throwing: zoneError)
                    } else {
                        continuation.resume(
                            returning: ZoneChangeBatch(
                                records: records,
                                deletions: deletions,
                                serverChangeToken: serverChangeToken,
                                moreComing: moreComing
                            )
                        )
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            self.database.add(operation)
        }
    }

    private func terminalAccessoryRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: TerminalAccessoryProfile.recordName, zoneID: recordZoneID)
    }

    private func decodeTerminalAccessoryProfile(from record: CKRecord) -> TerminalAccessoryProfile? {
        guard let payload = record["payload"] as? Data else {
            return nil
        }

        guard var profile = try? JSONDecoder().decode(TerminalAccessoryProfile.self, from: payload) else {
            return nil
        }

        if let schemaVersion = record["schemaVersion"] as? Int, schemaVersion > 0 {
            profile.schemaVersion = schemaVersion
        }

        if let updatedAt = record["updatedAt"] as? Date, updatedAt > profile.updatedAt {
            profile.updatedAt = updatedAt
        }

        if let writerDeviceID = record["lastWriterDeviceId"] as? String, !writerDeviceID.isEmpty {
            profile.lastWriterDeviceId = writerDeviceID
        }

        return profile.normalized()
    }

    private func makeTerminalAccessoryRecord(
        from profile: TerminalAccessoryProfile,
        recordID: CKRecord.ID,
        existingRecord: CKRecord? = nil
    ) throws -> CKRecord {
        let normalizedProfile = profile.normalized()
        let payload: Data
        do {
            payload = try JSONEncoder().encode(normalizedProfile)
        } catch {
            throw CloudKitError.encodingFailed
        }

        let record = existingRecord ?? CKRecord(recordType: RecordType.userPreference, recordID: recordID)
        record["schemaVersion"] = normalizedProfile.schemaVersion
        record["payload"] = payload
        record["updatedAt"] = normalizedProfile.updatedAt
        record["lastWriterDeviceId"] = normalizedProfile.lastWriterDeviceId
        return record
    }

    private func extractServerRecord(from error: Error) -> CKRecord? {
        guard let ckError = error as? CKError else { return nil }

        if ckError.code == .serverRecordChanged {
            return ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
        }

        if ckError.code == .partialFailure,
           let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            for partialError in partialErrors.values {
                if let serverRecord = extractServerRecord(from: partialError) {
                    return serverRecord
                }
            }
        }

        return nil
    }

    private func isUnknownItemError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }

        if ckError.code == .unknownItem || ckError.code == .zoneNotFound {
            return true
        }

        if ckError.code == .partialFailure,
           let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            return partialErrors.values.contains { isUnknownItemError($0) }
        }

        return false
    }

    // MARK: - Upsert Helper

    /// Save a record using CKModifyRecordsOperation with changedKeys policy
    /// This handles both insert (new record) and update (existing record)
    private func saveRecordWithUpsert(_ record: CKRecord) async throws {
        try await saveRecord(record, savePolicy: .changedKeys)
    }

    private func saveRecord(
        _ record: CKRecord,
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = savePolicy
            operation.qualityOfService = .userInitiated

            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }

    // MARK: - Force Sync

    func forceSync() async {
        lastSyncDate = nil
        accountStatusChecked = false
        clearChangeToken()
        await checkAccountStatus()
    }

    // MARK: - Cleanup

    /// Delete all records from CloudKit (use with caution!)
    func deleteAllRecords() async throws {
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let records = try await withZoneRetry {
            try await fetchAllRecordsFromCloudKit()
        }
        let recordIDs = records
            .filter {
                $0.recordType == RecordType.server ||
                $0.recordType == RecordType.workspace ||
                $0.recordType == RecordType.terminalTheme ||
                $0.recordType == RecordType.terminalThemePreference ||
                $0.recordType == RecordType.userPreference
            }
            .map(\.recordID)

        // Batch delete
        if !recordIDs.isEmpty {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
                operation.qualityOfService = .userInitiated

                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                self.database.add(operation)
            }
        }

        let deletedServers = records.filter { $0.recordType == RecordType.server }.count
        let deletedWorkspaces = records.filter { $0.recordType == RecordType.workspace }.count
        let deletedThemes = records.filter { $0.recordType == RecordType.terminalTheme }.count
        let deletedThemePreferences = records.filter { $0.recordType == RecordType.terminalThemePreference }.count
        let deletedUserPreferences = records.filter { $0.recordType == RecordType.userPreference }.count
        logger.info(
            "Deleted \(deletedServers) servers, \(deletedWorkspaces) workspaces, \(deletedThemes) themes, \(deletedThemePreferences) theme preferences, \(deletedUserPreferences) user preferences from CloudKit"
        )
        lastSyncDate = Date()
    }

    // MARK: - Error Helpers

    /// Check if an error is a schema-related error (record type not found)
    static func isSchemaError(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .unknownItem, .invalidArguments:
                // unknownItem: record type doesn't exist
                // invalidArguments: field/index issues
                return true
            default:
                return false
            }
        }
        // Check error message for schema-related keywords
        let message = error.localizedDescription.lowercased()
        return message.contains("record type") || message.contains("field") || message.contains("queryable")
    }

    // MARK: - Record Zone

    private func ensureCustomZone() async throws {
        if zoneReady {
            return
        }

        if let task = ensureZoneTask {
            try await task.value
            return
        }

        let task = Task { try await self.createZoneIfNeeded() }
        ensureZoneTask = task
        defer { ensureZoneTask = nil }
        try await task.value
    }

    private func createZoneIfNeeded() async throws {
        let results = try await database.recordZones(for: [recordZoneID])
        if let result = results[recordZoneID] {
            switch result {
            case .success:
                setZoneReady(true)
                return
            case .failure(let error):
                if isZoneNotFound(error) {
                    _ = try await database.modifyRecordZones(saving: [recordZone], deleting: [])
                    setZoneReady(true)
                    return
                }
                throw error
            }
        }

        _ = try await database.modifyRecordZones(saving: [recordZone], deleting: [])
        setZoneReady(true)
    }

    private func setZoneReady(_ ready: Bool) {
        zoneReady = ready
        UserDefaults.standard.set(ready, forKey: zoneReadyKey)
    }

    private func withZoneRetry<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard isZoneNotFound(error) else {
                throw error
            }

            logger.warning("CloudKit zone was missing during operation; recreating and retrying once")
            setZoneReady(false)
            try await ensureCustomZone()
            return try await operation()
        }
    }

    private func isZoneNotFound(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }
        return ckError.code == .zoneNotFound || ckError.code == .unknownItem
    }
}

// MARK: - CloudKit Error

enum CloudKitError: LocalizedError {
    case notAvailable
    case recordNotFound
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "iCloud is not available"
        case .recordNotFound: return "Record not found"
        case .encodingFailed: return "Failed to encode data"
        case .decodingFailed: return "Failed to decode data"
        }
    }
}
