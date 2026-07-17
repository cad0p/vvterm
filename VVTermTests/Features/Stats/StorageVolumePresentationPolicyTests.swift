import XCTest
@testable import VVTerm

final class StorageVolumePresentationPolicyTests: XCTestCase {
    func testCardLimitAppliesAfterHiddenVolumesAreRemoved() {
        let volumes = (0..<7).map { index in
            makeVolume(mountPoint: "/volume-\(index)")
        }
        let hiddenVolumeIDs = Set(volumes.prefix(3).map(\.identity))

        let visibleVolumes = StorageVolumePresentationPolicy.visibleVolumes(
            from: volumes,
            hiddenVolumeIDs: hiddenVolumeIDs
        )
        let cardVolumes = StorageVolumePresentationPolicy.cardVolumes(
            from: visibleVolumes,
            limit: 4
        )

        XCTAssertEqual(cardVolumes.map(\.mountPoint), [
            "/volume-3",
            "/volume-4",
            "/volume-5",
            "/volume-6"
        ])
    }

    func testListFiltersKeepCompleteInventoryAvailableForRestoration() {
        let root = makeVolume(mountPoint: "/")
        let hidden = makeVolume(mountPoint: "/hidden")
        let container = makeVolume(
            mountPoint: "/var/lib/docker/overlay2/one/merged",
            source: "overlay",
            fileSystem: "overlay"
        )
        let volumes = [root, hidden, container]
        let hiddenVolumeIDs: Set<VolumeIdentity> = [hidden.identity, container.identity]

        XCTAssertEqual(
            StorageVolumeListPolicy.filteredVolumes(
                volumes,
                hiddenVolumeIDs: hiddenVolumeIDs,
                filter: .all,
                searchText: ""
            ),
            volumes
        )
        XCTAssertEqual(
            StorageVolumeListPolicy.filteredVolumes(
                volumes,
                hiddenVolumeIDs: hiddenVolumeIDs,
                filter: .visible,
                searchText: ""
            ),
            [root]
        )
        XCTAssertEqual(
            StorageVolumeListPolicy.filteredVolumes(
                volumes,
                hiddenVolumeIDs: hiddenVolumeIDs,
                filter: .hidden,
                searchText: ""
            ),
            [hidden, container]
        )
        XCTAssertEqual(
            StorageVolumeListPolicy.filteredVolumes(
                volumes,
                hiddenVolumeIDs: hiddenVolumeIDs,
                filter: .container,
                searchText: ""
            ),
            [container]
        )
    }

    func testListSearchMatchesMountSourceAndFilesystemWithoutReordering() {
        let root = makeVolume(mountPoint: "/", source: "/dev/nvme0n1", fileSystem: "ext4")
        let backup = makeVolume(mountPoint: "/backup", source: "nas:/backup", fileSystem: "nfs4")
        let media = makeVolume(mountPoint: "/media", source: "/dev/sdb1", fileSystem: "btrfs")
        let volumes = [root, backup, media]

        XCTAssertEqual(filtered(volumes, searchText: "NVME"), [root])
        XCTAssertEqual(filtered(volumes, searchText: "nfs"), [backup])
        XCTAssertEqual(filtered(volumes, searchText: "/media"), [media])
    }

    func testSelectedVolumesFollowInventoryOrder() {
        let root = makeVolume(mountPoint: "/")
        let data = makeVolume(mountPoint: "/data")
        let backup = makeVolume(mountPoint: "/backup")

        XCTAssertEqual(
            StorageVolumeListPolicy.selectedVolumes(
                in: [root, data, backup],
                selectedVolumeIDs: [backup.identity, root.identity]
            ),
            [root, backup]
        )
    }

    func testNegativeCardLimitDoesNotProduceAnInvalidPrefix() {
        XCTAssertTrue(
            StorageVolumePresentationPolicy.cardVolumes(
                from: [makeVolume(mountPoint: "/")],
                limit: -1
            ).isEmpty
        )
    }

    private func filtered(_ volumes: [VolumeInfo], searchText: String) -> [VolumeInfo] {
        StorageVolumeListPolicy.filteredVolumes(
            volumes,
            hiddenVolumeIDs: [],
            filter: .all,
            searchText: searchText
        )
    }

    private func makeVolume(
        mountPoint: String,
        source: String = "/dev/disk0",
        fileSystem: String = "ext4"
    ) -> VolumeInfo {
        VolumeInfo(
            platform: .linux,
            mountPoint: mountPoint,
            source: source,
            fileSystem: fileSystem,
            stableIdentifier: "id-\(mountPoint)",
            used: 400,
            total: 1_000
        )
    }
}
