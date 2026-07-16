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

    static func outputFrameCapacity(
        inputFrameCount: UInt32,
        inputSampleRate: Double,
        targetSampleRate: Double
    ) -> UInt32? {
        guard inputSampleRate.isFinite,
              inputSampleRate > 0,
              targetSampleRate.isFinite,
              targetSampleRate > 0 else {
            return nil
        }
        let scaledFrameCount = Double(inputFrameCount) * targetSampleRate / inputSampleRate
        guard scaledFrameCount.isFinite,
              scaledFrameCount >= 0,
              scaledFrameCount < Double(UInt32.max) else {
            return nil
        }
        return UInt32(scaledFrameCount) + 1
    }
}
