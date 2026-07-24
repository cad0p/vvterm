import Combine
import Foundation

@MainActor
final class ServerVolumeVisibilityStore: ObservableObject {
    static let shared = ServerVolumeVisibilityStore()

    @Published private(set) var preferences: ServerVolumeVisibilityPreferences

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = Self.load(from: defaults)
        if preferences.requiresSchemaMigration {
            preferences.markSchemaMigrationComplete()
            persist()
        }
    }

    func hiddenVolumeIDs(
        for serverID: UUID,
        volumes: [VolumeInfo]
    ) -> Set<VolumeIdentity> {
        VolumeVisibilityPolicy.hiddenVolumeIDs(
            in: volumes,
            visibilityOverrides: preferences.visibilityOverrides(for: serverID)
        )
    }

    func setVolume(_ volume: VolumeInfo, isVisible: Bool, for serverID: UUID) {
        updateVisibilityOverrides(for: [volume], serverID: serverID) { _ in
            isVisible
        }
    }

    func setVolumes(_ volumes: [VolumeInfo], areVisible: Bool, for serverID: UUID) {
        updateVisibilityOverrides(for: volumes, serverID: serverID) { _ in
            areVisible
        }
    }

    private func updateVisibilityOverrides(
        for volumes: [VolumeInfo],
        serverID: UUID,
        isVisible: (VolumeInfo) -> Bool
    ) {
        var overrides = preferences.visibilityOverrides(for: serverID)
        for volume in VolumeVisibilityPolicy.normalized(volumes) {
            let desiredVisibility = isVisible(volume)
            if desiredVisibility == VolumeVisibilityPolicy.isVisibleByDefault(volume) {
                overrides.removeValue(forKey: volume.identity)
            } else {
                overrides[volume.identity] = desiredVisibility
            }
        }

        var next = preferences
        next.setVisibilityOverrides(overrides, for: serverID)
        guard next != preferences else { return }
        preferences = next
        persist()
    }

    private func persist() {
        guard !Self.containsFutureSchema(in: defaults) else { return }
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: ServerVolumeVisibilityPreferences.defaultsKey)
    }

    private static func containsFutureSchema(in defaults: UserDefaults) -> Bool {
        guard let data = defaults.data(forKey: ServerVolumeVisibilityPreferences.defaultsKey),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schemaVersion = object["schemaVersion"] as? NSNumber else {
            return false
        }
        return schemaVersion.intValue > ServerVolumeVisibilityPreferences.currentSchemaVersion
    }

    private static func load(from defaults: UserDefaults) -> ServerVolumeVisibilityPreferences {
        guard let data = defaults.data(forKey: ServerVolumeVisibilityPreferences.defaultsKey),
              let preferences = try? JSONDecoder().decode(ServerVolumeVisibilityPreferences.self, from: data) else {
            return ServerVolumeVisibilityPreferences()
        }
        return preferences
    }
}
