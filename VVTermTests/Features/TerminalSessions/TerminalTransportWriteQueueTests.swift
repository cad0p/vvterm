import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
struct TerminalTransportWriteQueueTests {
    @Test
    @MainActor
    func preservesInputOrderWhenAnEarlierWriteSuspends() async {
        let queue = TerminalTransportWriteQueue()
        let recorder = TerminalTransportWriteRecorder()

        queue.enqueue {
            try? await Task.sleep(for: .milliseconds(30))
            await recorder.append(1)
        }
        queue.enqueue {
            await recorder.append(2)
        }
        queue.enqueue {
            await recorder.append(3)
        }

        await queue.waitForPendingWrites()

        let values = await recorder.values
        #expect(values == [1, 2, 3])
    }
}

private actor TerminalTransportWriteRecorder {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
