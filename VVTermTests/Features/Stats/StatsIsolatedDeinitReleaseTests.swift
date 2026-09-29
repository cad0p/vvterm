// SPDX-License-Identifier: MIT
//
//  StatsIsolatedDeinitReleaseTests.swift
//  VVTermTests
//
//  Regression + pins for issue #280: `StatsCollectionContext`,
//  `ServerStatsCollector` and `ViewTabConfigurationManager` are
//  MainActor-isolated classes whose compiler-synthesized deinits were
//  *isolated* deinits
//  (`__isolated_deallocating_deinit`). Releasing either object outside a
//  Swift task context — as a synchronous XCTest method does — takes the
//  MainActor executor deinit path
//  (`swift_task_deinitOnExecutorMainActorBackDeploy`, swiftlang/swift#88036)
//  and aborts in libmalloc: `pointer being freed was not allocated`. An
//  explicit empty `nonisolated deinit {}` keeps the release non-isolated.
//
//  THE RUNTIME TEST IS A LOCAL GATE ONLY. The abort is runtime-bound: it
//  reproduces on the iOS 26.3.1 simulator runtime (iPhone 17) but not on
//  the CI xcode-27 runner, which ran the previously-failing suite green
//  with both markers absent. `StatsIsolatedDeinitPinsTests` below is the
//  CI-visible gate; this runtime test is the local proof that the markers
//  actually remove the abort.
//
//  The runtime test methods must be synchronous. An `async` method runs
//  inside a task context, so the isolated-deinit path is not taken and
//  the test would pass even with the markers absent (vacuous). They are
//  `@MainActor` because `ServerStatsCollector` is explicitly `@MainActor`
//  — a nonisolated method cannot even construct it (hard compile error) —
//  and because the other two classes are MainActor-isolated by the app
//  target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Passing at all
//  is the assertion: the failure mode is a process abort, not an
//  `XCTAssert`.
//

import Foundation
import Testing
import XCTest

@testable import VVTerm

// MARK: - Runtime regression test (local gate)

@MainActor
final class StatsIsolatedDeinitReleaseTests: XCTestCase {

    /// `StatsCollectionContext` has no explicit isolation annotation; the
    /// app target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes it
    /// MainActor-isolated, so its release from this synchronous method is
    /// the exact reproduction shape.
    func testStatsCollectionContextReleasesSynchronouslyWithoutTrapping() {
        weak var weakContext: StatsCollectionContext?
        do {
            let context = StatsCollectionContext()
            weakContext = context
        }
        // The `weak` assertion proves the object was deallocated at the scope
        // exit *inside* this synchronous method — that release is the one that
        // aborts when the marker is absent. (Pre-fix this method never reaches
        // the assertion: the process aborts at the scope exit.)
        XCTAssertNil(
            weakContext,
            "the context must be deallocated at the scope exit, not deferred to the end of the method"
        )
    }

    /// `ServerStatsCollector` is explicitly `@MainActor` and internally
    /// owns a `StatsCollectionContext` (`ServerStatsCollector.swift`), so
    /// this release aborts pre-fix through either class's synthesized
    /// deinit.
    func testServerStatsCollectorReleasesSynchronouslyWithoutTrapping() {
        weak var weakCollector: ServerStatsCollector?
        do {
            let collector = ServerStatsCollector()
            weakCollector = collector
        }
        XCTAssertNil(
            weakCollector,
            "the collector must be deallocated at the scope exit, not deferred to the end of the method"
        )
    }

    /// Control: `ServerVolumeVisibilityStore` already carries the marker
    /// and must keep releasing cleanly. Suite-scoped defaults so the
    /// control never reads or writes `.standard`.
    func testAlreadyMarkedVolumeVisibilityStoreReleasesSynchronouslyWithoutTrapping() throws {
        let suiteName = "StatsIsolatedDeinitReleaseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        weak var weakStore: ServerVolumeVisibilityStore?
        do {
            let store = ServerVolumeVisibilityStore(defaults: defaults)
            weakStore = store
        }
        XCTAssertNil(
            weakStore,
            "the already-marked control must deallocate at the scope exit"
        )
    }

    /// `ViewTabConfigurationManager` is explicitly `@MainActor` with a
    /// synthesized deinit. It is not in `Features/Stats`: the full local
    /// unit-target run for this issue aborted in
    /// `ViewTabConfigurationManagerTests` (two tests, one per launch), and
    /// the marker was applied under the issue's scope rule. Suite-scoped
    /// defaults so the shared instance's `.standard` store is untouched.
    func testViewTabConfigurationManagerReleasesSynchronouslyWithoutTrapping() throws {
        let suiteName = "StatsIsolatedDeinitReleaseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        weak var weakManager: ViewTabConfigurationManager?
        do {
            let manager = ViewTabConfigurationManager(defaults: defaults)
            weakManager = manager
        }
        XCTAssertNil(
            weakManager,
            "the manager must be deallocated at the scope exit, not deferred to the end of the method"
        )
    }
}

// MARK: - CI-visible source pin

/// Pins the `nonisolated deinit {}` markers added by this PR by reading
/// the source tree.
///
/// This exists because the runtime test above cannot protect CI: the CI
/// xcode-27 runner does not take the aborting path, so it stayed green
/// with both markers absent. These pins are the CI-visible gate.
///
/// WHAT THESE PINS SEE (and what they do not). Each pin comment-strips the
/// source, resolves the class body with `bracedBlock(after:)`, checks a
/// known member first (positive control, so a mis-resolved span cannot
/// satisfy the assertion), then asserts the body contains exactly one
/// `nonisolated deinit {}` **at brace depth 1** — the class's own member
/// level — so a marker moved into a nested declaration inside the same body
/// is red too.
///
/// Reported defeats (each measured against the real sources): a marker moved
/// to another class (the moved-from body count drops to 0), a rename (the
/// anchor no longer resolves), a multi-line `nonisolated deinit {` + `}`
/// spelling (the exact-token count drops to 0), and a marker moved into a
/// nested type (the depth assertion goes red).
///
/// VERIFIED FALSE GREENS, deliberately not claimed as caught: a marker inside
/// `#if false` and a marker inside a string literal (`let x = "nonisolated
/// deinit {}"`) both keep the token at depth 1, so the pin stays green. It is
/// a tripwire, not a proof — the runtime test is the local proof — and a body
/// that keeps the token but drops the actual isolation passes the pin and
/// fails the runtime test only on a runtime that takes the aborting path.
struct StatsIsolatedDeinitPinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/Features/Stats/StatsIsolatedDeinitReleaseTests.swift`).
    private func repositoryRoot() -> URL {
        // Counterfactual hook: the mutation runs point this at a copy of
        // the source with a marker removed to prove the pin fails there.
        // NOTE: the variable must actually reach the test process. The
        // measured-working form is
        // `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` exported
        // into xcodebuild's own environment (the `TEST_RUNNER_` prefix is
        // consumed by the test runner and forwarded without it); a plain
        // `VVTERM_PINS_SOURCE_ROOT` is inert here.
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // StatsIsolatedDeinitReleaseTests.swift
            .deletingLastPathComponent()  // Stats/
            .deletingLastPathComponent()  // Features/
            .deletingLastPathComponent()  // VVTermTests/
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - Source helpers

    /// A comment-stripped copy of `source` for the token scans: characters
    /// inside `//` line comments and nested `/* … */` block comments become
    /// spaces; newlines are preserved, so slice anchors still resolve. String
    /// contents are copied verbatim (so a `//` inside a literal is not read as
    /// a comment); the scanner covers `"…"` (with `\` escapes) and `"""…"""`
    /// but not raw strings (`#"…"#`) or comments inside an interpolation.
    private static func strippingComments(_ source: String) -> String {
        let characters = Array(source)
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        var blockCommentDepth = 0
        var inLineComment = false
        var stringDelimiter: Int? = nil  // 1 for `"…"`, 3 for `"""…"""`
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    result.append("\n")
                } else {
                    result.append(" ")
                }
                index += 1
                continue
            }
            if blockCommentDepth > 0 {
                if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                    blockCommentDepth += 1
                    result.append("  ")
                    index += 2
                } else if character == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                    blockCommentDepth -= 1
                    result.append("  ")
                    index += 2
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                    index += 1
                }
                continue
            }
            if let delimiter = stringDelimiter {
                result.append(character)
                index += 1
                if escaped {
                    escaped = false
                    continue
                }
                if character == "\\" {
                    escaped = true
                    continue
                }
                if delimiter == 1, character == "\"" {
                    stringDelimiter = nil
                    continue
                }
                if delimiter == 3,
                   character == "\"",
                   index + 1 < characters.count,
                   characters[index] == "\"",
                   characters[index + 1] == "\"" {
                    result.append("\"\"")
                    index += 2
                    stringDelimiter = nil
                }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                inLineComment = true
                result.append("  ")
                index += 2
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                blockCommentDepth = 1
                result.append("  ")
                index += 2
                continue
            }
            if character == "\"" {
                if index + 2 < characters.count, characters[index + 1] == "\"", characters[index + 2] == "\"" {
                    stringDelimiter = 3
                    result.append("\"\"\"")
                    index += 3
                } else {
                    stringDelimiter = 1
                    result.append("\"")
                    index += 1
                }
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    /// The body span `{ … }` of the brace-delimited block that opens at
    /// `open`, found by a character-level depth walk.
    private static func bracedBlock(
        openingAt open: String.Index,
        in text: String
    ) throws -> Range<String.Index> {
        try #require(text[open] == "{", "the explicit block open must be a `{`")
        var depth = 0
        var close: String.Index?
        var index = open
        while index < text.endIndex, close == nil {
            if text[index] == "{" {
                depth += 1
            } else if text[index] == "}" {
                depth -= 1
                if depth == 0 { close = index }
            }
            index = text.index(after: index)
        }
        let blockClose = try #require(close, "the pin block's braces must balance")
        return text.index(after: open)..<blockClose
    }

    /// The body span of the first brace-delimited block after `anchor`.
    ///
    /// The anchor must be **brace-less** for the intended block to be the one
    /// it opens: `bracedBlock` binds the first `{` after the anchor.
    private static func bracedBlock(
        after anchor: Range<String.Index>,
        in text: String
    ) throws -> Range<String.Index> {
        let open = try #require(
            text[anchor.upperBound...].firstIndex(of: "{"),
            "the pin anchor must be followed by a `{`"
        )
        return try bracedBlock(openingAt: open, in: text)
    }

    /// Every occurrence of `needle` in `text` (optionally within `range`),
    /// in source order.
    private static func occurrences(
        of needle: String,
        in text: String,
        range: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        let searchRange = range ?? text.startIndex..<text.endIndex
        var result: [Range<String.Index>] = []
        var searchStart = searchRange.lowerBound
        while let found = text.range(of: needle, range: searchStart..<searchRange.upperBound) {
            result.append(found)
            searchStart = found.upperBound
        }
        return result
    }

    /// The brace depth at `index`, counted from the start of `text`.
    ///
    /// A top-level member of a class body sits at depth 1 (the class's own
    /// `{` opened it); a member of a nested declaration sits at depth ≥ 2.
    /// Used to keep the marker assertions from being satisfied by a marker
    /// that was moved into a nested type inside the same class body.
    ///
    /// Braces inside string literals are counted (the comment stripper copies
    /// string contents verbatim), so a literal containing an unbalanced `{`
    /// before the marker would skew this. None of the three pinned bodies has
    /// one, and a skewed depth fails the assertion rather than passing it.
    private static func braceDepth(at index: String.Index, in text: String) -> Int {
        var depth = 0
        var cursor = text.startIndex
        while cursor < index {
            if text[cursor] == "{" {
                depth += 1
            } else if text[cursor] == "}" {
                depth -= 1
            }
            cursor = text.index(after: cursor)
        }
        return depth
    }

    // MARK: - Pins

    /// `StatsCollectionContext` (the reproducer's class) must keep exactly
    /// one `nonisolated deinit {}` in its body.
    @Test
    func testStatsCollectionContextCarriesExactlyOneNonisolatedDeinit() throws {
        let text = Self.strippingComments(
            try source("VVTerm/Features/Stats/Infrastructure/Platforms/PlatformStatsCollector.swift")
        )
        let anchor = try #require(
            text.range(of: "final class StatsCollectionContext: @unchecked Sendable"),
            "PlatformStatsCollector.swift must keep the `StatsCollectionContext` class declaration"
        )
        let body = try Self.bracedBlock(after: anchor, in: text)

        // Positive control: the resolved span is the real class body, not a
        // facade wrapper or another block.
        let controls = Self.occurrences(
            of: "func withLock<T>(_ block: () -> T) -> T",
            in: text,
            range: body
        )
        #expect(
            controls.count == 1,
            "StatsCollectionContext's body must contain exactly one `withLock<T>(_:)` (positive control)"
        )

        let markers = Self.occurrences(of: "nonisolated deinit {}", in: text, range: body)
        #expect(
            markers.count == 1,
            "StatsCollectionContext must carry exactly one `nonisolated deinit {}`"
        )
        if let marker = markers.first {
            #expect(
                Self.braceDepth(at: marker.lowerBound, in: text) == 1,
                "the StatsCollectionContext marker must be a top-level member, not nested in another declaration"
            )
        }
    }

    /// `ServerStatsCollector` must keep exactly one
    /// `nonisolated deinit {}` in its body.
    @Test
    func testServerStatsCollectorCarriesExactlyOneNonisolatedDeinit() throws {
        let text = Self.strippingComments(
            try source("VVTerm/Features/Stats/Application/ServerStatsCollector.swift")
        )
        let anchor = try #require(
            text.range(of: "final class ServerStatsCollector: ObservableObject"),
            "ServerStatsCollector.swift must keep the `ServerStatsCollector` class declaration"
        )
        let body = try Self.bracedBlock(after: anchor, in: text)

        // Positive control: the resolved span is the real class body.
        let controls = Self.occurrences(
            of: "func startCollecting(",
            in: text,
            range: body
        )
        #expect(
            controls.count == 1,
            "ServerStatsCollector's body must contain exactly one `startCollecting(` (positive control)"
        )

        let markers = Self.occurrences(of: "nonisolated deinit {}", in: text, range: body)
        #expect(
            markers.count == 1,
            "ServerStatsCollector must carry exactly one `nonisolated deinit {}`"
        )
        if let marker = markers.first {
            #expect(
                Self.braceDepth(at: marker.lowerBound, in: text) == 1,
                "the ServerStatsCollector marker must be a top-level member, not nested in another declaration"
            )
        }
    }

    /// `ViewTabConfigurationManager` must keep exactly one
    /// `nonisolated deinit {}` in its body. It is the third marker this PR
    /// adds (the full-unit acceptance run surfaced it); keeping it pinned
    /// here means all three are guarded by the same CI-visible gate.
    @Test
    func testViewTabConfigurationManagerCarriesExactlyOneNonisolatedDeinit() throws {
        let text = Self.strippingComments(
            try source("VVTerm/Features/ConnectionViews/Application/ViewTabConfigurationManager.swift")
        )
        let anchor = try #require(
            text.range(of: "final class ViewTabConfigurationManager: ObservableObject"),
            "ViewTabConfigurationManager.swift must keep the `ViewTabConfigurationManager` class declaration"
        )
        let body = try Self.bracedBlock(after: anchor, in: text)

        // Positive control: the resolved span is the real class body.
        let controls = Self.occurrences(
            of: "private func loadConfiguration()",
            in: text,
            range: body
        )
        #expect(
            controls.count == 1,
            "ViewTabConfigurationManager's body must contain exactly one `loadConfiguration()` (positive control)"
        )

        let markers = Self.occurrences(of: "nonisolated deinit {}", in: text, range: body)
        #expect(
            markers.count == 1,
            "ViewTabConfigurationManager must carry exactly one `nonisolated deinit {}`"
        )
        if let marker = markers.first {
            #expect(
                Self.braceDepth(at: marker.lowerBound, in: text) == 1,
                "the ViewTabConfigurationManager marker must be a top-level member, not nested in another declaration"
            )
        }
    }
}
