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
    }

    func hiddenVolumeIDs(for serverID: UUID) -> Set<VolumeIdentity> {
        preferences.hiddenVolumeIDs(for: serverID)
    }

    func setVolume(_ volume: VolumeInfo, isVisible: Bool, for serverID: UUID) {
        var hidden = hiddenVolumeIDs(for: serverID)
        if isVisible {
            hidden.remove(volume.identity)
        } else {
            hidden.insert(volume.identity)
        }
        setHiddenVolumeIDs(hidden, for: serverID)
    }

    func setVolumes(_ volumes: [VolumeInfo], areVisible: Bool, for serverID: UUID) {
        let identities = Set(VolumeVisibilityPolicy.normalized(volumes).map(\.identity))
        var hidden = hiddenVolumeIDs(for: serverID)
        if areVisible {
            hidden.subtract(identities)
        } else {
            hidden.formUnion(identities)
        }
        setHiddenVolumeIDs(hidden, for: serverID)
    }

    func showOnly(_ volumes: [VolumeInfo], among allVolumes: [VolumeInfo], for serverID: UUID) {
        let selected = Set(VolumeVisibilityPolicy.normalized(volumes).map(\.identity))
        let all = Set(VolumeVisibilityPolicy.normalized(allVolumes).map(\.identity))
        var hidden = hiddenVolumeIDs(for: serverID)
        hidden.subtract(all)
        hidden.formUnion(all.subtracting(selected))
        setHiddenVolumeIDs(hidden, for: serverID)
    }

    func restoreAllVolumes(for serverID: UUID) {
        setHiddenVolumeIDs([], for: serverID)
    }

    private func setHiddenVolumeIDs(_ identities: Set<VolumeIdentity>, for serverID: UUID) {
        var next = preferences
        next.setHiddenVolumeIDs(identities, for: serverID)
        guard next != preferences else { return }
        preferences = next
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: ServerVolumeVisibilityPreferences.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> ServerVolumeVisibilityPreferences {
        guard let data = defaults.data(forKey: ServerVolumeVisibilityPreferences.defaultsKey),
              let preferences = try? JSONDecoder().decode(ServerVolumeVisibilityPreferences.self, from: data) else {
            return ServerVolumeVisibilityPreferences()
        }
        return preferences
    }
}
