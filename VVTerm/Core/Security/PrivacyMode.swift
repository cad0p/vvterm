import SwiftUI

enum PrivacyModeSettings {
    static let enabledKey = "security.privacyModeEnabled"
}

enum AppContentProtectionPolicy {
    static func shouldPrepareForSceneDeactivation(
        fullAppLockEnabled: Bool,
        privacyModeEnabled: Bool,
        isAppLocked: Bool
    ) -> Bool {
        shouldObscureContent(
            sceneIsActive: false,
            fullAppLockEnabled: fullAppLockEnabled,
            privacyModeEnabled: privacyModeEnabled,
            isAppLocked: isAppLocked
        )
    }

    static func shouldObscureContent(
        sceneIsActive: Bool,
        fullAppLockEnabled: Bool,
        privacyModeEnabled: Bool,
        isAppLocked: Bool
    ) -> Bool {
        isAppLocked
            || (!sceneIsActive && (fullAppLockEnabled || privacyModeEnabled))
    }
}

enum SensitiveContentMask {
    static let placeholder = "••••••••"

    static func value(_ value: String, privacyModeEnabled: Bool) -> String {
        privacyModeEnabled ? placeholder : value
    }
}

private struct PrivacyModeEnabledEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var privacyModeEnabled: Bool {
        get { self[PrivacyModeEnabledEnvironmentKey.self] }
        set { self[PrivacyModeEnabledEnvironmentKey.self] = newValue }
    }
}

extension Server {
    var displayAddressWithPort: String {
        "\(username)@\(host):\(port)"
    }

    func visibleHost(privacyModeEnabled: Bool) -> String {
        SensitiveContentMask.value(host, privacyModeEnabled: privacyModeEnabled)
    }

    func visibleAddress(privacyModeEnabled: Bool) -> String {
        privacyModeEnabled ? SensitiveContentMask.placeholder : displayAddressWithPort
    }
}

extension DiscoveredSSHHost {
    var displayEndpoint: String {
        "\(host):\(port)"
    }

    func visibleDisplayName(privacyModeEnabled _: Bool) -> String {
        return displayName
    }

    func visibleEndpoint(privacyModeEnabled _: Bool) -> String {
        displayEndpoint
    }
}
