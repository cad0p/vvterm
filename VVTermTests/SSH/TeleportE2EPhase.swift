// SPDX-License-Identifier: MIT
//
//  TeleportE2EPhase.swift
//  VVTermTests
//
//  Phase attribution for the real-Teleport E2E suite (issue #412, parent
//  #238). The gated `TeleportServerIntegrationTests` legs run only in
//  `teleport-e2e.yml`; when one fails, swift-testing reports the `@Test`
//  declaration line, not the throw site, so the failure must name its own
//  phase/operation. `withTeleportE2EPhase` wraps a throwing operation (and
//  wraps the error it throws); `traceTeleportE2EPhase` traces a non-throwing
//  operation so a hung test is named by the last `begin` line. The trace goes
//  to stdout, flushed per line: the workflow captures test stdout through a
//  block-buffered `tee` pipe, and an allowance/process kill must not lose the
//  last line.
//

import Foundation
import Testing

/// The operation groups of the real-Teleport E2E path, in call order.
enum TeleportE2EPhase: String, CaseIterable {
    case fixtures
    case keyring
    case connect
    case innerSession
    case exec
    case sftp
    case shell
    case ceremony
    case teardown
}

/// The attributed failure of a wrapped E2E phase. `description` is the
/// swift-testing rendering channel ("Caught error: …"), so the phase and the
/// per-call detail survive into the failure line that a CI triage reads.
struct TeleportE2EPhaseFailure: Error, CustomStringConvertible {
    let phase: TeleportE2EPhase
    let detail: String?
    let elapsed: Duration
    let underlying: any Error

    var description: String {
        let label = detail.map { "phase=\(phase.rawValue) detail=\($0)" } ?? "phase=\(phase.rawValue)"
        return "teleport-e2e \(label) elapsed=\(elapsed) underlying=\(underlying)"
    }
}

/// Trace sink. Defaults to stdout, flushed per line: the e2e workflow captures
/// test stdout with `xcodebuild test | tee test.log` (a block-buffered pipe),
/// so an allowance/process kill must not lose the last `begin`.
typealias TeleportE2EPhaseTrace = @MainActor (String) -> Void

@MainActor
func flushTeleportE2EPhaseTrace(_ line: String) {
    print(line)
    fflush(stdout)
}

/// One trace line: `teleport-e2e test=<name> phase=<raw> detail=<detail> begin`
/// (blank test name/detail are omitted). The test name is carried because the
/// e2e xcodebuild does not disable parallel testing, so gated @MainActor tests
/// can interleave their trace lines at suspension points.
@MainActor
private func teleportE2EPhaseLine(
    phase: TeleportE2EPhase,
    detail: String?,
    event: String
) -> String {
    var parts = ["teleport-e2e"]
    if let name = Test.current?.name, !name.isEmpty {
        parts.append("test=\(name)")
    }
    parts.append("phase=\(phase.rawValue)")
    if let detail, !detail.isEmpty {
        parts.append("detail=\(detail)")
    }
    parts.append(event)
    return parts.joined(separator: " ")
}

/// Runs `body` on the main actor, emitting `begin`/`end`/`failed` and wrapping
/// any thrown error. An already-wrapped `TeleportE2EPhaseFailure` is re-thrown
/// unchanged, so the innermost (finest) wrap is the one reported.
@MainActor
func withTeleportE2EPhase<T>(
    _ phase: TeleportE2EPhase,
    detail: String? = nil,
    trace: TeleportE2EPhaseTrace = flushTeleportE2EPhaseTrace,
    _ body: @MainActor () async throws -> T
) async throws -> T {
    trace(teleportE2EPhaseLine(phase: phase, detail: detail, event: "begin"))
    let start = ContinuousClock.now
    do {
        let value = try await body()
        trace(teleportE2EPhaseLine(
            phase: phase,
            detail: detail,
            event: "end elapsed=\(start.duration(to: .now))"
        ))
        return value
    } catch {
        let elapsed = start.duration(to: .now)
        trace(teleportE2EPhaseLine(
            phase: phase,
            detail: detail,
            event: "failed elapsed=\(elapsed) underlying=\(error)"
        ))
        if let failure = error as? TeleportE2EPhaseFailure {
            throw failure
        }
        throw TeleportE2EPhaseFailure(
            phase: phase,
            detail: detail,
            elapsed: elapsed,
            underlying: error
        )
    }
}

/// Trace-only variant for operations that cannot throw (shell drain, ceremony
/// begin, teardown): emits `begin`/`end` so a killed test still names the last
/// operation entered.
@MainActor
func traceTeleportE2EPhase<T>(
    _ phase: TeleportE2EPhase,
    detail: String? = nil,
    trace: TeleportE2EPhaseTrace = flushTeleportE2EPhaseTrace,
    _ body: @MainActor () async -> T
) async -> T {
    trace(teleportE2EPhaseLine(phase: phase, detail: detail, event: "begin"))
    let start = ContinuousClock.now
    let value = await body()
    trace(teleportE2EPhaseLine(
        phase: phase,
        detail: detail,
        event: "end elapsed=\(start.duration(to: .now))"
    ))
    return value
}
