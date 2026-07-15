import Foundation

struct AudioCaptureLifecycleState: Equatable, Sendable {
    let applicationIsActive: Bool
    let sceneIsActive: Bool

    var allowsCapture: Bool {
        applicationIsActive && sceneIsActive
    }
}

enum AudioCaptureStartupRejection: Equatable {
    case inactiveLifecycle
    case unavailableInputFormat
}

enum AudioCaptureStartupPolicy {
    static func rejection(
        lifecycle: AudioCaptureLifecycleState,
        sampleRate: Double,
        channelCount: Int
    ) -> AudioCaptureStartupRejection? {
        guard lifecycle.allowsCapture else { return .inactiveLifecycle }
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else {
            return .unavailableInputFormat
        }
        return nil
    }
}
