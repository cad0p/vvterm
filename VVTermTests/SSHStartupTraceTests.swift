import Foundation
import os
import Testing
@testable import VVTerm

struct SSHStartupTraceTests {
    @Test
    func recordsMonotonicStructuredStageEvents() {
        let events = OSAllocatedUnfairLock(initialState: [SSHStartupTrace.Event]())
        let trace = SSHStartupTrace(logger: Logger()) { event in
            events.withLock { $0.append(event) }
        }

        let token = trace.begin(.dnsResolution)
        trace.end(token, detail: "candidates_2")
        trace.recordOnce(.firstTerminalByte, detail: "ssh")
        trace.recordOnce(.firstTerminalByte, detail: "ssh")

        let recorded = events.withLock { $0 }
        #expect(recorded.count == 2)
        #expect(recorded.map(\.stage) == [.dnsResolution, .firstTerminalByte])
        #expect(recorded.allSatisfy { $0.stageMilliseconds >= 0 })
        #expect(recorded[1].totalMilliseconds >= recorded[0].totalMilliseconds)
        #expect(recorded[0].detail == "candidates_2")
    }
}
