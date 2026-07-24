//
//  TerminalThemeManager.swift
//  VVTerm
//

import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class TerminalThemeManager: ObservableObject {
    static let shared = TerminalThemeManager()

    @Published private(set) var customThemes: [TerminalTheme] = []

    private struct PreferenceSnapshot: Equatable {
        var darkThemeName: String
        var lightThemeName: String
        var usePerAppearanceTheme: Bool
    }

    private let defaults: UserDefaults
    private let cloudKit: CloudKitManager
    private let syncCoordinator = CloudKitSyncCoordinator.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm", category: "TerminalThemeManager")

    private let customThemesKey = CloudKitSyncConstants.terminalCustomThemesStorageKey
    private let darkThemeKey = CloudKitSyncConstants.terminalThemeNameKey
    private let lightThemeKey = CloudKitSyncConstants.terminalThemeNameLightKey
    private let perAppearanceThemeKey = CloudKitSyncConstants.terminalUsePerAppearanceThemeKey
    private let preferenceUpdatedAtKey = CloudKitSyncConstants.terminalThemePreferenceUpdatedAtKey

    private var defaultsObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var lastKnownPreferenceSnapshot: PreferenceSnapshot
    private var lastForegroundSyncAt: Date = .distantPast
    private var isApplyingRemotePreference = false
    private var pendingPreferenceSyncTask: Task<Void, Never>?
    private let foregroundSyncMinimumInterval: TimeInterval = 20

    private init(defaults: UserDefaults = .standard, cloudKit: CloudKitManager? = nil) {
        self.defaults = defaults
        self.cloudKit = cloudKit ?? .shared
        self.lastKnownPreferenceSnapshot = PreferenceSnapshot(
            darkThemeName: defaults.string(forKey: darkThemeKey) ?? "Aizen Dark",
            lightThemeName: defaults.string(forKey: lightThemeKey) ?? "Aizen Light",
            usePerAppearanceTheme: defaults.object(forKey: perAppearanceThemeKey) as? Bool ?? true
        )

        loadThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        observeThemePreferenceChanges()
        observeForegroundSync()

        Task {
            await syncFromCloud()
            await syncCoordinator.drainPendingMutations()
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        pendingPreferenceSyncTask?.cancel()
    }

    var customThemeNames: [String] {
        customThemes
            .filter { !$0.isDeleted }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    nonisolated static func builtInThemeNames() -> [String] {
        guard let resourcePath = Bundle.main.resourcePath else { return [] }
        let fm = FileManager.default

        let structuredPath = (resourcePath as NSString).appendingPathComponent("ghostty/themes")
        if fm.fileExists(atPath: structuredPath),
           let files = try? fm.contentsOfDirectory(atPath: structuredPath) {
            return files
                .filter { file in
                    let fullPath = (structuredPath as NSString).appendingPathComponent(file)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                    return !isDir.boolValue && !file.hasPrefix(".")
                }
                .sorted()
        }

        guard let files = try? fm.contentsOfDirectory(atPath: resourcePath) else { return [] }
        let knownNonThemes = Set([
            "Info", "Assets", "PkgInfo", "ghostty", "xterm-ghostty",
            "CodeSignature", "embedded", "_CodeSignature"
        ])
        return files
            .filter { file in
                let fullPath = (resourcePath as NSString).appendingPathComponent(file)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                guard !isDir.boolValue else { return false }
                guard !file.hasPrefix(".") else { return false }
                guard !file.contains(".") else { return false }
                guard !knownNonThemes.contains(file) else { return false }
                return true
            }
            .sorted()
    }

    func suggestThemeName(from sourceName: String?) -> String {
        let trimmed = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return uniqueThemeName(from: "Custom Theme")
        }
        let sanitized = sanitizeThemeName(trimmed)
        return uniqueThemeName(from: sanitized.isEmpty ? "Custom Theme" : sanitized)
    }

    func createCustomTheme(name: String, content: String) throws -> TerminalTheme {
        let normalizedContent = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TerminalThemeValidationError.invalidName }
        let sanitized = sanitizeThemeName(trimmed)
        guard !sanitized.isEmpty else { throw TerminalThemeValidationError.invalidName }
        let finalName = uniqueThemeName(from: sanitized)

        let theme = TerminalTheme(
            name: finalName,
            content: normalizedContent,
            updatedAt: Date(),
            deletedAt: nil
        )

        customThemes.append(theme)
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        pushThemeToCloud(theme)
        return theme
    }

    @discardableResult
    func updateCustomTheme(id: UUID, name: String, content: String) throws -> TerminalTheme {
        guard let index = customThemes.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw TerminalThemeValidationError.themeNotFound
        }

        let normalizedContent = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TerminalThemeValidationError.invalidName }

        let sanitized = sanitizeThemeName(trimmed)
        guard !sanitized.isEmpty else { throw TerminalThemeValidationError.invalidName }

        let previousName = customThemes[index].name
        let finalName = uniqueThemeName(from: sanitized, excludingThemeID: id)
        let now = Date()

        customThemes[index].name = finalName
        customThemes[index].content = normalizedContent
        customThemes[index].updatedAt = now
        customThemes[index].deletedAt = nil

        migrateSelectionsForRenamedTheme(from: previousName, to: finalName)
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        pushThemeToCloud(customThemes[index])

        return customThemes[index]
    }

    func deleteCustomTheme(named name: String) {
        guard let index = customThemes.firstIndex(where: { $0.name == name && !$0.isDeleted }) else {
            return
        }

        deleteTheme(at: index)
    }

    func deleteCustomTheme(id: UUID) {
        guard let index = customThemes.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            return
        }

        deleteTheme(at: index)
    }

    private func deleteTheme(at index: Int) {
        customThemes[index].deletedAt = Date()
        customThemes[index].updatedAt = Date()
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        pushThemeToCloud(customThemes[index])
    }

    private func loadThemes() {
        guard let data = defaults.data(forKey: customThemesKey) else {
            customThemes = []
            return
        }
        do {
            customThemes = try JSONDecoder().decode([TerminalTheme].self, from: data)
        } catch {
            customThemes = []
            logger.error("Failed to decode custom themes: \(error.localizedDescription)")
        }
    }

    private func saveThemes() {
        do {
            let data = try JSONEncoder().encode(customThemes)
            defaults.set(data, forKey: customThemesKey)
        } catch {
            logger.error("Failed to encode custom themes: \(error.localizedDescription)")
        }
    }

    private func syncCustomThemeFiles() {
        let fm = FileManager.default
        let directoryURL = TerminalThemeStoragePaths.customThemesDirectoryURL()

        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let visibleThemes = customThemes.filter { !$0.isDeleted }
            let visibleNames = Set(visibleThemes.map(\.name))

            let existingFiles = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            for file in existingFiles {
                guard !visibleNames.contains(file.lastPathComponent) else { continue }
                try? fm.removeItem(at: file)
            }

            for theme in visibleThemes {
                let fileURL = directoryURL.appendingPathComponent(theme.name)
                try theme.content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.error("Failed to sync custom theme files: \(error.localizedDescription)")
        }
    }

    private func ensureThemeSelectionIsValid() {
        let available = Set(Self.builtInThemeNames() + customThemeNames)
        let fallbackDark = "Aizen Dark"
        let fallbackLight = "Aizen Light"

        let darkTheme = defaults.string(forKey: darkThemeKey) ?? fallbackDark
        let lightTheme = defaults.string(forKey: lightThemeKey) ?? fallbackLight

        var changed = false
        if !available.contains(darkTheme) {
            defaults.set(fallbackDark, forKey: darkThemeKey)
            changed = true
        }
        if !available.contains(lightTheme) {
            defaults.set(fallbackLight, forKey: lightThemeKey)
            changed = true
        }

        if changed {
            lastKnownPreferenceSnapshot = currentPreferenceSnapshot()
        }
    }

    private func sanitizeThemeName(_ name: String) -> String {
        var sanitized = name.replacingOccurrences(of: "/", with: "-")
        sanitized = sanitized.replacingOccurrences(of: ":", with: "-")
        sanitized = sanitized.replacingOccurrences(of: "\n", with: " ")
        sanitized = sanitized.replacingOccurrences(of: "\r", with: " ")
        sanitized = sanitized.replacingOccurrences(of: "\t", with: " ")
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uniqueThemeName(from baseName: String, excludingThemeID: UUID? = nil) -> String {
        let builtIn = Set(Self.builtInThemeNames().map(normalizedThemeNameKey(_:)))
        let existing = Set(
            customThemes
                .filter { !$0.isDeleted && $0.id != excludingThemeID }
                .map { normalizedThemeNameKey($0.name) }
        )
        let maxLength = 80

        var root = String(baseName.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        if root.isEmpty { root = "Custom Theme" }

        if !builtIn.contains(normalizedThemeNameKey(root)) &&
            !existing.contains(normalizedThemeNameKey(root)) {
            return root
        }

        var index = 2
        while true {
            let suffix = " \(index)"
            let availableRootLength = max(1, maxLength - suffix.count)
            let candidateRoot = String(root.prefix(availableRootLength)).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = "\(candidateRoot)\(suffix)"
            if !builtIn.contains(normalizedThemeNameKey(candidate)) &&
                !existing.contains(normalizedThemeNameKey(candidate)) {
                return candidate
            }
            index += 1
        }
    }

    private func normalizedThemeNameKey(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func migrateSelectionsForRenamedTheme(from oldName: String, to newName: String) {
        guard oldName != newName else { return }

        if defaults.string(forKey: darkThemeKey) == oldName {
            defaults.set(newName, forKey: darkThemeKey)
        }

        if defaults.string(forKey: lightThemeKey) == oldName {
            defaults.set(newName, forKey: lightThemeKey)
        }
    }

    private func observeThemePreferenceChanges() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleThemePreferenceChange()
            }
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
                await self?.syncFromCloudIfNeededForForeground()
            }
        }
    }

    private func syncFromCloudIfNeededForForeground() async {
        let now = Date()
        guard now.timeIntervalSince(lastForegroundSyncAt) >= foregroundSyncMinimumInterval else {
            return
        }

        lastForegroundSyncAt = now
        await syncFromCloud()
        await syncCoordinator.drainPendingMutations()
    }

    private func handleThemePreferenceChange() {
        guard !isApplyingRemotePreference else { return }
        let snapshot = currentPreferenceSnapshot()
        guard snapshot != lastKnownPreferenceSnapshot else { return }
        lastKnownPreferenceSnapshot = snapshot

        let now = Date()
        defaults.set(now.timeIntervalSince1970, forKey: preferenceUpdatedAtKey)
        schedulePreferenceCloudSync(
            TerminalThemePreference(
                darkThemeName: snapshot.darkThemeName,
                lightThemeName: snapshot.lightThemeName,
                usePerAppearanceTheme: snapshot.usePerAppearanceTheme,
                updatedAt: now
            )
        )
    }

    private func currentPreferenceSnapshot() -> PreferenceSnapshot {
        PreferenceSnapshot(
            darkThemeName: defaults.string(forKey: darkThemeKey) ?? "Aizen Dark",
            lightThemeName: defaults.string(forKey: lightThemeKey) ?? "Aizen Light",
            usePerAppearanceTheme: defaults.object(forKey: perAppearanceThemeKey) as? Bool ?? true
        )
    }

    private func localPreferenceUpdatedAt() -> Date {
        let value = defaults.double(forKey: preferenceUpdatedAtKey)
        guard value > 0 else { return .distantPast }
        return Date(timeIntervalSince1970: value)
    }

    private func schedulePreferenceCloudSync(_ preference: TerminalThemePreference) {
        pendingPreferenceSyncTask?.cancel()
        pendingPreferenceSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushPreferenceToCloud(preference)
        }
    }

    private func pushThemeToCloud(_ theme: TerminalTheme) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard SyncSettings.isEnabled else { return }
            self.syncCoordinator.enqueueTerminalThemeUpsert(theme)
            await self.syncCoordinator.drainPendingMutations()
        }
    }

    private func pushPreferenceToCloud(_ preference: TerminalThemePreference) async {
        guard SyncSettings.isEnabled else { return }
        syncCoordinator.enqueueTerminalThemePreferenceUpsert(preference)
        await syncCoordinator.drainPendingMutations()
    }

    private func syncFromCloud() async {
        guard SyncSettings.isEnabled else { return }

        do {
            let localSnapshot = customThemes
            let remoteThemes = try await cloudKit.fetchTerminalThemes()
            let remoteByID = Dictionary(uniqueKeysWithValues: remoteThemes.map { ($0.id, $0) })

            mergeRemoteThemes(remoteThemes)

            for localTheme in localSnapshot {
                if let remoteTheme = remoteByID[localTheme.id],
                   remoteTheme.updatedAt >= localTheme.updatedAt {
                    continue
                }
                pushThemeToCloud(localTheme)
            }

            if let remotePreference = try await cloudKit.fetchTerminalThemePreference() {
                applyRemotePreferenceIfNewer(remotePreference)
            } else {
                let localUpdatedAt = localPreferenceUpdatedAt()
                let seedUpdatedAt: Date
                if localUpdatedAt == .distantPast {
                    seedUpdatedAt = Date()
                    defaults.set(seedUpdatedAt.timeIntervalSince1970, forKey: preferenceUpdatedAtKey)
                } else {
                    seedUpdatedAt = localUpdatedAt
                }

                let localPreference = TerminalThemePreference(
                    darkThemeName: currentPreferenceSnapshot().darkThemeName,
                    lightThemeName: currentPreferenceSnapshot().lightThemeName,
                    usePerAppearanceTheme: currentPreferenceSnapshot().usePerAppearanceTheme,
                    updatedAt: seedUpdatedAt
                )
                await pushPreferenceToCloud(localPreference)
            }
        } catch {
            logger.warning("Custom theme CloudKit sync failed: \(error.localizedDescription)")
        }
    }

    private func mergeRemoteThemes(_ remoteThemes: [TerminalTheme]) {
        var localByID = Dictionary(uniqueKeysWithValues: customThemes.map { ($0.id, $0) })

        for remoteTheme in remoteThemes {
            if let localTheme = localByID[remoteTheme.id] {
                if remoteTheme.updatedAt > localTheme.updatedAt {
                    localByID[remoteTheme.id] = remoteTheme
                }
            } else {
                localByID[remoteTheme.id] = remoteTheme
            }
        }

        customThemes = Array(localByID.values)
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
    }

    private func applyRemotePreferenceIfNewer(_ preference: TerminalThemePreference) {
        let localUpdatedAt = localPreferenceUpdatedAt()
        guard preference.updatedAt > localUpdatedAt else { return }

        isApplyingRemotePreference = true
        defaults.set(preference.darkThemeName, forKey: darkThemeKey)
        defaults.set(preference.lightThemeName, forKey: lightThemeKey)
        defaults.set(preference.usePerAppearanceTheme, forKey: perAppearanceThemeKey)
        defaults.set(preference.updatedAt.timeIntervalSince1970, forKey: preferenceUpdatedAtKey)
        isApplyingRemotePreference = false

        ensureThemeSelectionIsValid()
        lastKnownPreferenceSnapshot = currentPreferenceSnapshot()
    }
}
