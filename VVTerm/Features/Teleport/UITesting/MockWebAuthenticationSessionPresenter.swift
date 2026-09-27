// SPDX-License-Identifier: MIT
//
//  MockWebAuthenticationSessionPresenter.swift
//  VVTerm
//
//  A mock `WebAuthenticationSessionPresenting` for unit tests. Records
//  `open(url:)` / `cancel()` calls without actually presenting Safari.
//

#if DEBUG
import Foundation

/// A mock Safari presenter. `open(url:)` returns `scriptedOpenResult`
/// (default `true`) without launching ASWebAuthenticationSession.
/// `cancel()` is recorded but does nothing.
@MainActor
final class MockWebAuthenticationSessionPresenter: WebAuthenticationSessionPresenting {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    /// The value returned by `open(url:)`. Default `true` (Safari "opened").
    var scriptedOpenResult: Bool = true

    /// The URLs passed to `open(url:)`, in order.
    private(set) var openedURLs: [URL] = []

    /// The number of times `cancel()` was called.
    private(set) var cancelCallCount = 0

    /// The number of currently live sessions: `open(url:)` starts one,
    /// `cancel()` closes it. Unlike the production presenter, the mock does
    /// NOT cancel-before-replace — a caller that starts a second session while
    /// one is still live must be detected, so this count reaching 2 is the
    /// leak signal (#267 review, L1-2).
    private(set) var liveSessionCount = 0

    func open(url: URL) async -> Bool {
        openedURLs.append(url)
        liveSessionCount += 1
        return scriptedOpenResult
    }

    func cancel() {
        cancelCallCount += 1
        liveSessionCount = 0
    }

    /// Bounded wait until `open(url:)` has been entered at least `count`
    /// times. Lets a test interleave two attempts deterministically (the
    /// second open either happens or the test fails on the returned flag —
    /// never on a timeout hang).
    @discardableResult
    func waitUntilOpenStarted(_ count: Int, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while openedURLs.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return openedURLs.count >= count
    }
}
#endif
