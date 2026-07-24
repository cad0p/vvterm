import XCTest
@testable import VVTerm

final class ServerStatsDomainTests: XCTestCase {
    func testMemoryPercentReturnsZeroWhenTotalIsZero() {
        var stats = ServerStats()
        stats.memoryUsed = 512
        stats.memoryTotal = 0

        XCTAssertEqual(stats.memoryPercent, 0)
    }

    func testMemoryPercentUsesUsedAndTotalBytes() {
        var stats = ServerStats()
        stats.memoryUsed = 512
        stats.memoryTotal = 1024

        XCTAssertEqual(stats.memoryPercent, 50, accuracy: 0.001)
    }

    func testVolumePercentReturnsZeroWhenTotalIsZero() {
        let volume = VolumeInfo(mountPoint: "/", used: 100, total: 0)

        XCTAssertEqual(volume.percent, 0)
    }

    func testVolumePercentCalculatesUsage() {
        let volume = VolumeInfo(mountPoint: "/", used: 25, total: 100)

        XCTAssertEqual(volume.percent, 25, accuracy: 0.001)
    }

    func testRemotePlatformDetectsWindowsMarkers() {
        XCTAssertEqual(RemotePlatform.detect(from: "MINGW64_NT-10.0"), .windows)
        XCTAssertEqual(RemotePlatform.detect(from: "Windows_NT"), .windows)
    }

    func testRemotePlatformDefaultsUnknownUnixLikeOutputToLinux() {
        XCTAssertEqual(RemotePlatform.detect(from: "Solaris"), .linux)
    }
}
