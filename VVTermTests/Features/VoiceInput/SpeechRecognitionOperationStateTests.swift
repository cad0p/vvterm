import Foundation
import Testing
@testable import VVTerm

struct SpeechRecognitionOperationStateTests {
    @Test
    func finishingOperationContinuesAcceptingItsFinalResult() {
        let generation = UUID()
        let state = SpeechRecognitionOperationState.finishing(generation)

        #expect(state.acceptsResult(for: generation))
        #expect(state.generation == generation)
    }

    @Test
    func replacementRejectsThePreviousOperationsResult() {
        let previousGeneration = UUID()
        let replacementGeneration = UUID()
        let state = SpeechRecognitionOperationState.running(replacementGeneration)

        #expect(!state.acceptsResult(for: previousGeneration))
        #expect(state.acceptsResult(for: replacementGeneration))
    }

    @Test
    func finalResultSignalCompletesTheBoundedWait() async {
        let completion = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        completion.continuation.yield()
        completion.continuation.finish()

        let clock = ContinuousClock()
        let startedAt = clock.now
        await SpeechRecognitionService.waitForRecognitionCompletion(
            completion.stream,
            timeout: .seconds(2)
        )

        #expect(startedAt.duration(to: clock.now) < .seconds(1))
    }
}
