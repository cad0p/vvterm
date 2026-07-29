// SPDX-License-Identifier: AGPL-3.0-or-later
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
    /// The value returned by `open(url:)`. Default `true` (Safari "opened").
    var scriptedOpenResult: Bool = true

    /// The URLs passed to `open(url:)`, in order.
    private(set) var openedURLs: [URL] = []

    /// The number of times `cancel()` was called.
    private(set) var cancelCallCount = 0

    func open(url: URL) async -> Bool {
        openedURLs.append(url)
        return scriptedOpenResult
    }

    func cancel() {
        cancelCallCount += 1
    }
}
#endif
