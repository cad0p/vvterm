import Testing
@testable import VVTerm

struct AppContentProtectionPolicyTests {
    @Test(arguments: [
        (sceneIsActive: false, fullAppLockEnabled: false, privacyModeEnabled: true, isAppLocked: false),
        (sceneIsActive: false, fullAppLockEnabled: true, privacyModeEnabled: false, isAppLocked: false),
        (sceneIsActive: true, fullAppLockEnabled: true, privacyModeEnabled: false, isAppLocked: true),
    ])
    func protectedStateObscuresContent(
        sceneIsActive: Bool,
        fullAppLockEnabled: Bool,
        privacyModeEnabled: Bool,
        isAppLocked: Bool
    ) {
        #expect(
            AppContentProtectionPolicy.shouldObscureContent(
                sceneIsActive: sceneIsActive,
                fullAppLockEnabled: fullAppLockEnabled,
                privacyModeEnabled: privacyModeEnabled,
                isAppLocked: isAppLocked
            )
        )
    }

    @Test
    func activeUnlockedAppDoesNotObscureContent() {
        #expect(
            !AppContentProtectionPolicy.shouldObscureContent(
                sceneIsActive: true,
                fullAppLockEnabled: true,
                privacyModeEnabled: true,
                isAppLocked: false
            )
        )
    }
}
