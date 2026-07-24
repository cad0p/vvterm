import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct VoiceRecordingOperationCoordinatorTests {
    private enum Event: Equatable {
        case firstStarted
        case firstReleased
        case firstSucceeded
        case firstFailed
        case secondStarted
        case secondSucceeded
        case secondFailed
    }

    private enum TestError: Error {
        case staleAttempt
    }

    @Test
    func cancellationSuppressesAStaleContinuationResult() async {
        let coordinator = VoiceRecordingOperationCoordinator()
        let gate = CancellationIgnoringGate()
        var events: [Event] = []
        var deliveredText: [String] = []

        let task = coordinator.start(
            operation: { _ in
                events.append(.firstStarted)
                await gate.wait()
                events.append(.firstReleased)
                return "stale transcription"
            },
            onSuccess: {
                deliveredText.append($0)
                events.append(.firstSucceeded)
            },
            onFailure: { _ in events.append(.firstFailed) }
        )

        await gate.waitUntilStarted()
        coordinator.cancel()
        gate.open()
        await task.value

        #expect(events == [.firstStarted, .firstReleased])
        #expect(deliveredText.isEmpty)
    }

    @Test
    func replacementOwnsCompletionWhenCancelledAttemptResumesLater() async {
        let coordinator = VoiceRecordingOperationCoordinator()
        let firstGate = CancellationIgnoringGate()
        var events: [Event] = []

        let firstTask = coordinator.start(
            operation: { _ in
                events.append(.firstStarted)
                await firstGate.wait()
                events.append(.firstReleased)
                throw TestError.staleAttempt
            },
            onSuccess: { _ in events.append(.firstSucceeded) },
            onFailure: { _ in events.append(.firstFailed) }
        )
        await firstGate.waitUntilStarted()

        let secondTask = coordinator.start(
            operation: { _ in events.append(.secondStarted) },
            onSuccess: { _ in events.append(.secondSucceeded) },
            onFailure: { _ in events.append(.secondFailed) }
        )
        await secondTask.value

        firstGate.open()
        await firstTask.value

        #expect(events == [
            .firstStarted,
            .secondStarted,
            .secondSucceeded,
            .firstReleased,
        ])
    }
}
