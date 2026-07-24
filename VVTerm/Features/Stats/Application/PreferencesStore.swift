import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    @Published private(set) var preferences: StatsPreferences

    private let defaults: UserDefaults
    private let cloudKit: CloudKitManager
    private let syncCoordinator = CloudKitSyncCoordinator.shared
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "StatsPreferences"
    )

    private var foregroundObserver: NSObjectProtocol?
    private var syncToggleObserver: NSObjectProtocol?
    private var cloudResolutionObserver: NSObjectProtocol?
    private var pendingSyncTask: Task<Void, Never>?
    private var lastKnownSyncEnabled: Bool
    private var lastForegroundSyncAt: Date = .distantPast
    private let foregroundSyncMinimumInterval: TimeInterval = 20

    init(defaults: UserDefaults = .standard, cloudKit: CloudKitManager? = nil) {
        self.defaults = defaults
        self.cloudKit = cloudKit ?? CloudKitManager.shared
        self.preferences = PreferencesStore.loadPreferences(from: defaults)
        self.lastKnownSyncEnabled = SyncSettings.isEnabled

        observeForegroundSync()
        observeSyncToggleChanges()
        observeCloudResolutionChanges()

        Task {
            await syncWithCloud()
            await syncCoordinator.drainPendingMutations()
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let syncToggleObserver {
            NotificationCenter.default.removeObserver(syncToggleObserver)
        }
        if let cloudResolutionObserver {
            NotificationCenter.default.removeObserver(cloudResolutionObserver)
        }
        pendingSyncTask?.cancel()
    }

    func setStyle(_ style: StatsPreferences.Style) {
        applyMutation { preferences, now in
            preferences.style = style
            preferences.updatedAt = now
            preferences.lastWriterDeviceId = DeviceIdentity.id
        }
    }

    func setBlockVisibility(_ id: StatsPreferences.BlockID, isVisible: Bool) {
        guard id != .system || isVisible else { return }

        applyMutation { preferences, now in
            var normalized = preferences.normalized()
            guard let blockIndex = normalized.blocks.firstIndex(where: { $0.id == id }) else {
                return
            }

            if !isVisible, normalized.blocks.filter(\.isVisible).count <= 1 {
                return
            }

            normalized.blocks[blockIndex].isVisible = isVisible
            normalized.blocks[blockIndex].updatedAt = now
            normalized.updatedAt = now
            normalized.lastWriterDeviceId = DeviceIdentity.id
            preferences = normalized
        }
    }

    func moveBlocks(fromOffsets source: IndexSet, toOffset destination: Int) {
        applyMutation { preferences, now in
            var normalized = preferences.normalized()
            var blocks = normalized.orderedBlocks

            blocks.moveElements(fromOffsets: source, toOffset: destination)

            for index in blocks.indices {
                blocks[index].order = index
                blocks[index].updatedAt = now
            }

            normalized.blocks = blocks
            normalized.updatedAt = now
            normalized.lastWriterDeviceId = DeviceIdentity.id
            preferences = normalized
        }
    }

    func setBlockOrder(_ orderedIDs: [StatsPreferences.BlockID]) {
        applyMutation { preferences, now in
            var normalized = preferences.normalized()
            let currentBlocksByID = Dictionary(uniqueKeysWithValues: normalized.blocks.map { ($0.id, $0) })
            let validIDs = orderedIDs.filter { currentBlocksByID[$0] != nil }
            var finalIDs: [StatsPreferences.BlockID] = []

            for id in validIDs where !finalIDs.contains(id) {
                finalIDs.append(id)
            }
            for block in normalized.orderedBlocks where !finalIDs.contains(block.id) {
                finalIDs.append(block.id)
            }

            var blocks: [StatsPreferences.Block] = []
            for (index, id) in finalIDs.enumerated() {
                guard var block = currentBlocksByID[id] else { continue }
                block.order = index
                block.updatedAt = now
                blocks.append(block)
            }

            normalized.blocks = blocks
            normalized.updatedAt = now
            normalized.lastWriterDeviceId = DeviceIdentity.id
            preferences = normalized
        }
    }

    private func applyMutation(_ mutate: (inout StatsPreferences, Date) -> Void) {
        var nextPreferences = preferences
        mutate(&nextPreferences, Date())
        applyPreferences(nextPreferences)
    }

    private func applyPreferences(_ nextPreferences: StatsPreferences, scheduleCloudSync: Bool = true) {
        let normalized = nextPreferences.normalized()
        guard normalized != preferences else { return }

        preferences = normalized
        persistPreferences()

        if scheduleCloudSync {
            scheduleSyncWithCloud()
        }
    }

    private func persistPreferences() {
        do {
            let encoded = try JSONEncoder().encode(preferences)
            defaults.set(encoded, forKey: StatsPreferences.defaultsKey)
        } catch {
            logger.error("Failed to encode stats preferences: \(error.localizedDescription)")
        }
    }

    private static func loadPreferences(from defaults: UserDefaults) -> StatsPreferences {
        guard let data = defaults.data(forKey: StatsPreferences.defaultsKey) else {
            let defaultPreferences = StatsPreferences.defaultValue.normalized()
            if let encoded = try? JSONEncoder().encode(defaultPreferences) {
                defaults.set(encoded, forKey: StatsPreferences.defaultsKey)
            }
            return defaultPreferences
        }

        do {
            let decoded = try JSONDecoder().decode(StatsPreferences.self, from: data)
            let normalized = decoded.normalized()
            if normalized != decoded, let encoded = try? JSONEncoder().encode(normalized) {
                defaults.set(encoded, forKey: StatsPreferences.defaultsKey)
            }
            return normalized
        } catch {
            let defaultPreferences = StatsPreferences.defaultValue.normalized()
            if let encoded = try? JSONEncoder().encode(defaultPreferences) {
                defaults.set(encoded, forKey: StatsPreferences.defaultsKey)
            }
            return defaultPreferences
        }
    }

    private func scheduleSyncWithCloud() {
        pendingSyncTask?.cancel()
        pendingSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            await self?.enqueuePreferencesSync()
        }
    }

    private func enqueuePreferencesSync() async {
        guard SyncSettings.isEnabled else { return }
        syncCoordinator.enqueueStatsPreferencesUpsert(preferences)
        await syncCoordinator.drainPendingMutations()
    }

    private func syncWithCloud() async {
        guard SyncSettings.isEnabled else { return }

        do {
            let cloudResolved = try await cloudKit.syncStatsPreferences(preferences)
            let mergedWithCurrent = StatsPreferences.merged(local: preferences, remote: cloudResolved).normalized()
            applyPreferences(mergedWithCurrent, scheduleCloudSync: false)
        } catch {
            logger.warning("Stats preferences CloudKit sync failed: \(error.localizedDescription)")
        }
    }

    private func observeForegroundSync() {
        #if os(iOS)
        let name = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #else
        return
        #endif

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncWithCloudIfNeededForForeground()
            }
        }
    }

    private func syncWithCloudIfNeededForForeground() async {
        let now = Date()
        guard now.timeIntervalSince(lastForegroundSyncAt) >= foregroundSyncMinimumInterval else {
            return
        }

        lastForegroundSyncAt = now
        await syncWithCloud()
        await syncCoordinator.drainPendingMutations()
    }

    private func observeSyncToggleChanges() {
        syncToggleObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isEnabled = SyncSettings.isEnabled
                guard isEnabled != self.lastKnownSyncEnabled else { return }
                self.lastKnownSyncEnabled = isEnabled
                if isEnabled {
                    await self.syncWithCloud()
                } else {
                    self.pendingSyncTask?.cancel()
                    self.pendingSyncTask = nil
                }
            }
        }
    }

    private func observeCloudResolutionChanges() {
        cloudResolutionObserver = NotificationCenter.default.addObserver(
            forName: CloudKitSyncCoordinator.statsPreferencesDidResolveNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let resolvedPreferences = notification.userInfo?["preferences"] as? StatsPreferences
            Task { @MainActor [weak self] in
                guard let self,
                      let resolvedPreferences else {
                    return
                }

                let mergedWithCurrent = StatsPreferences
                    .merged(local: self.preferences, remote: resolvedPreferences)
                    .normalized()
                self.applyPreferences(mergedWithCurrent, scheduleCloudSync: false)
            }
        }
    }
}

private extension Array {
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty else { return }

        let movingElements = source.map { self[$0] }
        for index in source.sorted(by: >) {
            remove(at: index)
        }

        let removedBeforeDestination = source.filter { $0 < destination }.count
        let adjustedDestination = Swift.max(0, Swift.min(destination - removedBeforeDestination, count))
        insert(contentsOf: movingElements, at: adjustedDestination)
    }
}
