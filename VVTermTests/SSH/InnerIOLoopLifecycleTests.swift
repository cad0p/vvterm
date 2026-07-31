// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  InnerIOLoopLifecycleTests.swift
//  VVTermTests
//
//  Regression tests for issue #77 (Teleport: first connect hangs after
//  inner auth; shell "starts" but no bytes ever reach the terminal).
//
//  Teleport servers use a two-session path: the OUTER session is the
//  Teleport PROXY (rejects `exec`/`pty`/`shell`/`sftp`), and all
//  target-node channel I/O runs on the INNER session. Inner shell channels
//  and inner exec requests are drained by `SSHSession.innerIOLoop()`, which
//  breaks when it goes idle (no inner channels, no inner exec requests).
//
//  The bug: when the loop broke on idle, `innerIOTask` was never cleared —
//  it kept pointing at a *completed* task, so the `innerIOTask == nil`
//  guard in `startInnerIOLoop()` rejected every later restart. Inner exec
//  requests enqueued after that point were never drained (the Ghostty
//  terminfo install stalled until its 12s timeout on every connect), and
//  the inner shell channel was never read — the shell "started" but zero
//  bytes ever arrived (blinking orange cursor forever).
//
//  The fix clears `innerIOTask` when the loop exits naturally and restarts
//  the loop immediately if inner work arrived while the previous loop was
//  winding down (lost-wakeup guard). `shouldRestartInnerIOLoop` is the pure
//  restart decision extracted from `innerIOLoopDidExit()`; the actor
//  wiring itself is verified on-device against a real Teleport cluster.
//

import XCTest
@testable import VVTerm

final class InnerIOLoopLifecycleTests: XCTestCase {

    // MARK: - SSHSession inner I/O loop restart decision

    /// An inner shell channel pending at loop exit MUST restart the loop —
    /// otherwise the shell's output is never drained and the terminal shows
    /// a forever-connecting cursor (the issue #77 symptom).
    func testRestartsWhenInnerShellChannelPending() {
        XCTAssertTrue(
            SSHSession.shouldRestartInnerIOLoop(hasInnerChannels: true, hasInnerExec: false)
        )
    }

    /// An inner exec request pending at loop exit MUST restart the loop —
    /// otherwise the exec hangs until its caller-side timeout (the 12s
    /// Ghostty terminfo install stall on every Teleport connect).
    func testRestartsWhenInnerExecRequestPending() {
        XCTAssertTrue(
            SSHSession.shouldRestartInnerIOLoop(hasInnerChannels: false, hasInnerExec: true)
        )
    }

    func testRestartsWhenBothInnerWorkKindsPending() {
        XCTAssertTrue(
            SSHSession.shouldRestartInnerIOLoop(hasInnerChannels: true, hasInnerExec: true)
        )
    }

    /// A truly idle loop must stay down so the session does not spin a
    /// polling task while no inner work exists.
    func testDoesNotRestartWhenIdle() {
        XCTAssertFalse(
            SSHSession.shouldRestartInnerIOLoop(hasInnerChannels: false, hasInnerExec: false)
        )
    }
}
