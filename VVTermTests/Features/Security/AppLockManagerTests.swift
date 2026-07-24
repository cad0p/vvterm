import XCTest
@testable import VVTerm

@MainActor
final class AppLockManagerTests: XCTestCase {
    private final class StubBiometricAuthService: BiometricAuthServing {
        var availabilityResult: BiometricAvailability
        var authenticateError: Error?
        private(set) var authenticateReasons: [String] = []

        init(availabilityResult: BiometricAvailability) {
            self.availabilityResult = availabilityResult
        }

        func availability() -> BiometricAvailability {
            availabilityResult
        }

        func authenticate(localizedReason: String, allowPasscodeFallback: Bool) async throws {
            authenticateReasons.append(localizedReason)
            if let authenticateError {
                throw authenticateError
            }
        }
    }

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "VVTermTests.AppLockManager.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testEnableFullAppLockRequiresAvailableBiometry() async {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .unavailable("Biometry unavailable")
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        await manager.requestSetFullAppLockEnabled(true)

        XCTAssertFalse(manager.fullAppLockEnabled)
        XCTAssertEqual(manager.lastErrorMessage, "Biometry unavailable")
        XCTAssertTrue(authService.authenticateReasons.isEmpty)
    }

    func testEnableFullAppLockAuthenticatesAndUnlocksApp() async {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        await manager.requestSetFullAppLockEnabled(true)

        XCTAssertTrue(manager.fullAppLockEnabled)
        XCTAssertFalse(manager.isAppLocked)
        XCTAssertEqual(authService.authenticateReasons.count, 1)
    }

    func testGraceSecondsClampToUpperBound() {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.touchID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        manager.authGraceSeconds = 900

        XCTAssertEqual(manager.authGraceSeconds, 300)
    }
}
