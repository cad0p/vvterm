// SPDX-License-Identifier: MIT
//
//  TeleportE2EPhaseFailureTests.swift
//  VVTermTests
//
//  Offline coverage for the teleport-e2e phase attribution (issue #412,
//  parent #238): the wrapper's error shape, its swift-testing rendering
//  channel, the finest-wrap re-throw, the elapsed measurement, cancellation,
//  and the begin/end/failed trace lines. The gated real-server legs that use
//  the wrappers run only in `teleport-e2e.yml`; this suite is the always-on
//  proof of the mechanics, and it runs in the required `unit-tests` job.
//

import Foundation
import Testing
@testable import VVTerm

private enum ProbeError: Error, Equatable {
    case boom
}

private final class ProbeReferenceError: Error {}

@MainActor
struct TeleportE2EPhaseFailureTests {

    @Test
    func throwYieldsPhaseDetailUnderlyingAndElapsed() async throws {
        let probe = ProbeReferenceError()
        let error = try await #require(throws: TeleportE2EPhaseFailure.self) {
            try await withTeleportE2EPhase(.exec, detail: "probe") {
                throw probe
            }
        }
        #expect(error.phase == .exec)
        #expect(error.detail == "probe")
        #expect((error.underlying as? ProbeReferenceError) === probe)
        #expect(error.description.contains("elapsed="))
    }

    @Test
    func descriptionNamesPhaseDetailElapsedAndUnderlying() async throws {
        let error = try await #require(throws: TeleportE2EPhaseFailure.self) {
            try await withTeleportE2EPhase(.exec, detail: "probe") {
                throw ProbeError.boom
            }
        }
        let rendered = error.description
        #expect(rendered.hasPrefix("teleport-e2e "))
        #expect(rendered.contains("phase=exec"))
        #expect(rendered.contains("detail=probe"))
        #expect(rendered.contains("elapsed="))
        #expect(rendered.contains("underlying=boom"))
        #expect(String(describing: error).contains("underlying=boom"))

        // The historical failure mode (run 36018236342): the exec call's 60 s
        // budget expiring, reported as `.timeout` on the @Test declaration.
        let timeout = try await #require(throws: TeleportE2EPhaseFailure.self) {
            try await withTeleportE2EPhase(.connect, detail: "tlsRouting") {
                throw SSHError.timeout
            }
        }
        #expect(timeout.description.contains("phase=connect"))
        #expect(timeout.description.contains("underlying=timeout"))
    }

    @Test
    func successPassesTheValueThrough() async throws {
        let value = try await withTeleportE2EPhase(.shell, detail: "drain") {
            42
        }
        #expect(value == 42)
    }

    @Test
    func nestedFailureRethrowsTheFinestWrap() async throws {
        let error = try await #require(throws: TeleportE2EPhaseFailure.self) {
            try await withTeleportE2EPhase(.shell, detail: "outer") {
                try await withTeleportE2EPhase(.exec, detail: "inner") {
                    throw ProbeError.boom
                }
            }
        }
        #expect(error.phase == .exec)
        #expect(error.detail == "inner")
    }

    @Test(arguments: TeleportE2EPhase.allCases)
    func everyPhaseRawValueReachesTheDescription(_ phase: TeleportE2EPhase) async throws {
        let error = try await #require(throws: TeleportE2EPhaseFailure.self) {
            try await withTeleportE2EPhase(phase, detail: "probe") {
                throw ProbeError.boom
            }
        }
        #expect(error.description.contains("phase=\(phase.rawValue)"))
        #expect(error.description.contains("detail=probe"))
    }

    @Test
    func elapsedIsMeasuredOnTheThrowPath() async throws {
        let error = try await #require(throws: TeleportE2EPhaseFailure.self) {
            try await withTeleportE2EPhase(.exec, detail: "probe") {
                try await Task.sleep(for: .milliseconds(20))
                throw ProbeError.boom
            }
        }
        #expect(error.elapsed > .zero)
        #expect(error.description.contains("elapsed="))
    }

    @Test
    func cancellationIsWrapped() async throws {
        let error = try await #require(throws: TeleportE2EPhaseFailure.self) {
            try await withTeleportE2EPhase(.teardown, detail: "disconnect") {
                throw CancellationError()
            }
        }
        #expect(error.phase == .teardown)
        #expect(error.underlying is CancellationError)
    }

    @Test
    func traceRecordsBeginEndAndFailureForBothWrappers() async throws {
        var lines: [String] = []
        let recorder: TeleportE2EPhaseTrace = { lines.append($0) }

        // trace-only wrapper: begin + end, value passed through.
        let drained = await traceTeleportE2EPhase(.shell, detail: "drain", trace: recorder) {
            "drained"
        }
        #expect(drained == "drained")
        // `#require`, not `#expect`: a missing line must FAIL here — indexing
        // after a non-aborting `#expect` crashes the test process, and
        // xcodebuild then restarts the suite (turning one red into a
        // restart loop with no per-test attribution).
        try #require(lines.count == 2)
        #expect(lines[0].hasSuffix(" begin"))
        #expect(lines[0].contains("phase=shell"))
        #expect(lines[0].contains("detail=drain"))
        #expect(lines[1].contains(" end elapsed="))
        #expect(!lines[1].contains("failed"))
        #expect(lines.allSatisfy { $0.contains("test=") })

        // throwing wrapper, success path: begin + end, value passed through.
        lines.removeAll()
        let value = try await withTeleportE2EPhase(.ceremony, detail: "login", trace: recorder) {
            7
        }
        #expect(value == 7)
        try #require(lines.count == 2)
        #expect(lines[0].hasSuffix(" begin"))
        #expect(lines[0].contains("phase=ceremony"))
        #expect(lines[0].contains("detail=login"))
        #expect(lines[1].contains(" end elapsed="))

        // throwing wrapper, failure path: begin + failed, no end.
        lines.removeAll()
        let error = try await #require(throws: TeleportE2EPhaseFailure.self) {
            try await withTeleportE2EPhase(.exec, detail: "probe", trace: recorder) {
                throw ProbeError.boom
            }
        }
        #expect(error.phase == .exec)
        try #require(lines.count == 2)
        #expect(lines[0].hasSuffix(" begin"))
        #expect(lines[0].contains("phase=exec"))
        #expect(lines[0].contains("detail=probe"))
        #expect(lines[1].contains(" failed elapsed="))
        #expect(lines[1].contains("underlying=boom"))
        #expect(!lines[1].contains(" end elapsed="))
    }
}
