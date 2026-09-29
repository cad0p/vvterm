import Foundation
import LocalAuthentication

@MainActor
final class BiometricAuthService: BiometricAuthServing {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    static let shared = BiometricAuthService()

    private init() {}

    func availability() -> BiometricAvailability {
        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return .available(Self.mapBiometryType(context.biometryType))
        }

        return .unavailable(Self.preflightMessage(for: error))
    }

    func authenticate(localizedReason: String, allowPasscodeFallback: Bool = true) async throws {
        let reason = localizedReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            throw BiometricAuthError.failed(String(localized: "Authentication reason is missing."))
        }

        let context = LAContext()
        let policy: LAPolicy = allowPasscodeFallback
            ? .deviceOwnerAuthentication
            : .deviceOwnerAuthenticationWithBiometrics

        do {
            _ = try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            throw Self.mapEvaluateError(error)
        }
    }

    private static func mapBiometryType(_ type: LABiometryType) -> BiometryKind {
        switch type {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        default:
            return .none
        }
    }

    private static func preflightMessage(for error: NSError?) -> String {
        guard let error else {
            return String(localized: "Biometric authentication is unavailable on this device.")
        }

        if let code = LAError.Code(rawValue: error.code) {
            switch code {
            case .biometryNotEnrolled:
                return String(localized: "Biometric authentication is not set up on this device.")
            case .biometryNotAvailable:
                return String(localized: "Biometric authentication is unavailable on this device.")
            case .biometryLockout:
                return String(localized: "Biometric authentication is locked. Unlock the device to try again.")
            case .passcodeNotSet:
                return String(localized: "Set a device passcode before using biometric authentication.")
            default:
                break
            }
        }

        return error.localizedDescription
    }

    private static func mapEvaluateError(_ error: Error) -> BiometricAuthError {
        let nsError = error as NSError

        guard let code = LAError.Code(rawValue: nsError.code) else {
            return .failed(nsError.localizedDescription)
        }

        switch code {
        case .userCancel, .systemCancel, .appCancel, .userFallback:
            return .cancelled
        case .biometryNotEnrolled:
            return .unavailable(String(localized: "Biometric authentication is not set up on this device."))
        case .biometryNotAvailable:
            return .unavailable(String(localized: "Biometric authentication is unavailable on this device."))
        case .biometryLockout:
            return .failed(String(localized: "Biometric authentication is locked. Unlock the device and try again."))
        case .passcodeNotSet:
            return .unavailable(String(localized: "Set a device passcode before using biometric authentication."))
        case .authenticationFailed:
            return .failed(String(localized: "Authentication failed."))
        default:
            return .failed(nsError.localizedDescription)
        }
    }
}
