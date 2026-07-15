import Testing
@testable import VVTerm

struct AudioCaptureStartupPolicyTests {
    @Test
    func backgroundApplicationRejectsAudioStartup() {
        let rejection = AudioCaptureStartupPolicy.rejection(
            lifecycle: AudioCaptureLifecycleState(
                applicationIsActive: false,
                sceneIsActive: true
            ),
            sampleRate: 48_000,
            channelCount: 1
        )

        #expect(rejection == .inactiveLifecycle)
    }

    @Test
    func inactiveSceneRejectsAudioStartup() {
        let rejection = AudioCaptureStartupPolicy.rejection(
            lifecycle: AudioCaptureLifecycleState(
                applicationIsActive: true,
                sceneIsActive: false
            ),
            sampleRate: 48_000,
            channelCount: 1
        )

        #expect(rejection == .inactiveLifecycle)
    }

    @Test(arguments: [
        (sampleRate: 0.0, channelCount: 1),
        (sampleRate: 48_000.0, channelCount: 0),
        (sampleRate: Double.nan, channelCount: 1)
    ])
    func unavailableInputFormatRejectsAudioStartup(sampleRate: Double, channelCount: Int) {
        let rejection = AudioCaptureStartupPolicy.rejection(
            lifecycle: AudioCaptureLifecycleState(
                applicationIsActive: true,
                sceneIsActive: true
            ),
            sampleRate: sampleRate,
            channelCount: channelCount
        )

        #expect(rejection == .unavailableInputFormat)
    }

    @Test
    func partialStartupCleanupReleasesEveryOwnedResource() {
        let plan = AudioCaptureCleanupPlan(
            hasEngine: true,
            tapInstalled: true,
            audioSessionActive: true
        )

        #expect(plan.removeTap)
        #expect(plan.stopEngine)
        #expect(plan.deactivateAudioSession)
    }
}
