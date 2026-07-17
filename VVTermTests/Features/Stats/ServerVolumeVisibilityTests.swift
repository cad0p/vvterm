import XCTest
@testable import VVTerm

@MainActor
final class ServerVolumeVisibilityTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ServerVolumeVisibilityTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testVolumesAreVisibleByDefaultAndPreferencesAreIsolatedPerServer() {
        let firstServer = UUID()
        let secondServer = UUID()
        let volume = makeVolume(mountPoint: "/data", stableIdentifier: "data-uuid")
        let store = ServerVolumeVisibilityStore(defaults: defaults)

        XCTAssertEqual(
            VolumeVisibilityPolicy.visibleVolumes(
                from: [volume],
                hiddenVolumeIDs: store.hiddenVolumeIDs(for: firstServer)
            ),
            [volume]
        )

        store.setVolume(volume, isVisible: false, for: firstServer)

        XCTAssertEqual(store.hiddenVolumeIDs(for: firstServer), [volume.identity])
        XCTAssertTrue(store.hiddenVolumeIDs(for: secondServer).isEmpty)
    }

    func testHiddenVolumeSurvivesRelaunchAndTemporaryDisappearance() {
        let serverID = UUID()
        let volume = makeVolume(mountPoint: "/data", stableIdentifier: "data-uuid")
        var store: ServerVolumeVisibilityStore? = ServerVolumeVisibilityStore(defaults: defaults)
        store?.setVolume(volume, isVisible: false, for: serverID)

        store = ServerVolumeVisibilityStore(defaults: defaults)

        XCTAssertEqual(store?.hiddenVolumeIDs(for: serverID), [volume.identity])
        XCTAssertTrue(VolumeVisibilityPolicy.visibleVolumes(
            from: [],
            hiddenVolumeIDs: store?.hiddenVolumeIDs(for: serverID) ?? []
        ).isEmpty)
        XCTAssertTrue(VolumeVisibilityPolicy.visibleVolumes(
            from: [volume],
            hiddenVolumeIDs: store?.hiddenVolumeIDs(for: serverID) ?? []
        ).isEmpty)
    }

    func testReformattedOrReplacedVolumeDoesNotInheritHiddenIdentity() {
        let original = makeVolume(mountPoint: "/data", stableIdentifier: "old-uuid")
        let replacement = makeVolume(mountPoint: "/data", stableIdentifier: "new-uuid")

        XCTAssertNotEqual(original.identity, replacement.identity)
        XCTAssertEqual(
            VolumeVisibilityPolicy.visibleVolumes(
                from: [replacement],
                hiddenVolumeIDs: [original.identity]
            ),
            [replacement]
        )
    }

    func testStableFilesystemIdentitySurvivesCapacityChangesAtSameMount() {
        let before = VolumeInfo(
            platform: .linux,
            mountPoint: "/data",
            source: "/dev/sda1",
            fileSystem: "ext4",
            stableIdentifier: "DATA-UUID",
            used: 400,
            total: 1_000
        )
        let afterResize = VolumeInfo(
            platform: .linux,
            mountPoint: "/data",
            source: "/dev/mapper/data",
            fileSystem: "ext4",
            stableIdentifier: "data-uuid",
            used: 500,
            total: 2_000
        )

        XCTAssertEqual(before.identity, afterResize.identity)
    }

    func testFallbackIdentitySurvivesCapacityChangesAtSameMount() {
        let before = makeVolume(mountPoint: "/data", stableIdentifier: nil)
        let afterResize = VolumeInfo(
            platform: .linux,
            mountPoint: "/data",
            source: "/dev/disk0",
            fileSystem: "ext4",
            used: 600,
            total: 2_000
        )

        XCTAssertEqual(before.identity, afterResize.identity)
    }

    func testWindowsMountIdentityIsCaseAndSlashInsensitive() {
        let first = VolumeInfo(
            platform: .windows,
            mountPoint: "c:/",
            source: "c:/",
            fileSystem: "NTFS",
            stableIdentifier: "volume-1",
            used: 1,
            total: 2
        )
        let second = VolumeInfo(
            platform: .windows,
            mountPoint: "C:\\",
            source: "C:\\",
            fileSystem: "ntfs",
            stableIdentifier: "VOLUME-1",
            used: 1,
            total: 2
        )

        XCTAssertEqual(first.identity, second.identity)
    }

    func testNormalizationRemovesDuplicateMountRowsWithoutChangingFirstSeenOrder() {
        let root = makeVolume(mountPoint: "/", stableIdentifier: "root")
        let data = makeVolume(mountPoint: "/data", stableIdentifier: "data")
        let duplicateRoot = makeVolume(mountPoint: "/", stableIdentifier: nil)

        XCTAssertEqual(
            VolumeVisibilityPolicy.normalized([root, data, duplicateRoot]),
            [root, data]
        )
    }

    func testBulkContainerVisibilityPreservesIndividualOverrides() {
        let serverID = UUID()
        let root = makeVolume(mountPoint: "/", stableIdentifier: "root")
        let firstContainer = makeVolume(
            mountPoint: "/var/lib/docker/overlay2/one/merged",
            source: "overlay",
            fileSystem: "overlay"
        )
        let secondContainer = makeVolume(
            mountPoint: "/var/lib/docker/overlay2/two/merged",
            source: "overlay",
            fileSystem: "overlay"
        )
        let store = ServerVolumeVisibilityStore(defaults: defaults)
        store.setVolume(root, isVisible: false, for: serverID)

        store.setVolumes([firstContainer, secondContainer], areVisible: false, for: serverID)
        XCTAssertEqual(
            store.hiddenVolumeIDs(for: serverID),
            [root.identity, firstContainer.identity, secondContainer.identity]
        )

        store.setVolume(firstContainer, isVisible: true, for: serverID)
        XCTAssertEqual(
            store.hiddenVolumeIDs(for: serverID),
            [root.identity, secondContainer.identity]
        )
    }

    func testShowOnlySelectedDoesNotDiscardHiddenPreferencesForMissingVolumes() {
        let serverID = UUID()
        let missing = makeVolume(mountPoint: "/offline", stableIdentifier: "offline")
        let selected = makeVolume(mountPoint: "/", stableIdentifier: "root")
        let unselected = makeVolume(mountPoint: "/data", stableIdentifier: "data")
        let store = ServerVolumeVisibilityStore(defaults: defaults)
        store.setVolume(missing, isVisible: false, for: serverID)

        store.showOnly([selected], among: [selected, unselected], for: serverID)

        XCTAssertEqual(store.hiddenVolumeIDs(for: serverID), [missing.identity, unselected.identity])
    }

    func testMalformedPersistedPreferencesMigrateToDefaultVisibility() {
        defaults.set(Data("not-json".utf8), forKey: ServerVolumeVisibilityPreferences.defaultsKey)

        let store = ServerVolumeVisibilityStore(defaults: defaults)

        XCTAssertTrue(store.hiddenVolumeIDs(for: UUID()).isEmpty)
    }

    func testUnsupportedFutureSchemaFailsSafeWithoutOverwritingIt() throws {
        let futureData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "hiddenVolumeIDsByServer": [:]
        ])
        defaults.set(futureData, forKey: ServerVolumeVisibilityPreferences.defaultsKey)

        let store = ServerVolumeVisibilityStore(defaults: defaults)

        XCTAssertTrue(store.hiddenVolumeIDs(for: UUID()).isEmpty)
        XCTAssertEqual(defaults.data(forKey: ServerVolumeVisibilityPreferences.defaultsKey), futureData)
    }

    func testVolumeKindClassifiesContainerAndNetworkMounts() {
        XCTAssertEqual(
            VolumeKind.classify(source: "overlay", mountPoint: "/var/lib/docker/overlay2/x", fileSystem: "overlay"),
            .container
        )
        XCTAssertEqual(
            VolumeKind.classify(source: "nas:/exports/media", mountPoint: "/media", fileSystem: "nfs4"),
            .network
        )
    }

    func testContainerBulkSelectionKeepsOverlayRootEligibleForIndividualControlOnly() {
        let root = makeVolume(
            mountPoint: "/",
            source: "overlay",
            fileSystem: "overlay"
        )
        let docker = makeVolume(
            mountPoint: "/var/lib/docker/overlay2/x/merged",
            source: "overlay",
            fileSystem: "overlay"
        )

        XCTAssertEqual(VolumeVisibilityPolicy.containerVolumeIDs(in: [root, docker]), [docker.identity])
    }

    private func makeVolume(
        mountPoint: String,
        source: String = "/dev/disk0",
        fileSystem: String = "ext4",
        stableIdentifier: String? = nil
    ) -> VolumeInfo {
        VolumeInfo(
            platform: .linux,
            mountPoint: mountPoint,
            source: source,
            fileSystem: fileSystem,
            stableIdentifier: stableIdentifier,
            used: 400,
            total: 1_000
        )
    }
}
