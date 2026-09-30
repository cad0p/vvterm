// SPDX-License-Identifier: MIT
//
//  BrowserMFAPresenterStubs.swift
//  VVTermTests
//
//  Shared test doubles for the `BrowserMFAPresenting` seam. The ceremony
//  tests exercise paths that must never reach Safari (the empty-challenge
//  path), so the stub records any presentation attempt instead of opening a
//  session.
//

#if DEBUG
import Foundation
@testable import VVTerm

/// A presenter stub that records presentation attempts and never opens a
/// browser session.
@MainActor
final class RecordingBrowserMFAPresenter: BrowserMFAPresenting {
    private(set) var presentedURLs: [URL] = []

    func present(
        url: URL,
        completion: @escaping @Sendable (Error?) -> Void
    ) async -> any BrowserMFASessionHandle {
        presentedURLs.append(url)
        return StubBrowserMFASessionHandle()
    }
}

/// A no-op session handle.
@MainActor
final class StubBrowserMFASessionHandle: BrowserMFASessionHandle {
    let didStart = true
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

/// A presenter stub whose handle reports `didStart == false`, so the
/// ceremony's fail-fast guard is exercised without Safari (A7).
@MainActor
final class NotStartedBrowserMFAPresenter: BrowserMFAPresenting {
    func present(
        url: URL,
        completion: @escaping @Sendable (Error?) -> Void
    ) async -> any BrowserMFASessionHandle {
        NotStartedBrowserMFASessionHandle()
    }
}

/// A session handle that never started.
@MainActor
final class NotStartedBrowserMFASessionHandle: BrowserMFASessionHandle {
    let didStart = false
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}
#endif
