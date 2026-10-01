// SPDX-License-Identifier: MIT
//
//  SSHProbeShellPinsTests.swift
//  VVTermTests
//
//  Placement pins for #323 ("run the tmux/mosh capability probes in non-login
//  shells"): the four converted builders must call
//  `RemoteTerminalBootstrap.wrapPOSIXProbeCommand`, and every remaining
//  `sh -lc` / `/bin/sh -lc` in the three files that build remote commands must
//  sit in the intentional-login allowlist below. This is the CI-enforced
//  protection against a *literal-token or login-wrapper* recurrence of
//  #121 -> #323 in the files enumerated below (a new probe added with a
//  literal `sh -lc`, with a whitespace variant, or with the login wrapper),
//  because the behavioural route cannot run on iOS.
//
//  WHAT THESE PINS ASSERT (and what they do not see). Five pins, all
//  comment-stripping the source first:
//    1. the set of `func` bodies emitting a login-shell token in the three
//       pinned files equals the intentional-login allowlist, and the token
//       count matches;
//    2. the four converted capability-probe builders call
//       `wrapPOSIXProbeCommand`;
//    3. the terminal-type resolver references neither a login token nor the
//       login wrapper;
//    4. in the three pinned files and the two probe-path resolver files, the
//       set of functions calling the *login* wrapper
//       (`wrapPOSIXShellCommand`) equals an exact allowlist — the pin the
//       literal scan cannot be, because `wrapPOSIXShellCommand(body)` carries
//       no literal token;
//    5. a directory inventory over `VVTerm/Core/SSH/*.swift`: a file outside
//       the pinned set may not emit a literal token, and a file outside the
//       known wrapper-reference set may not reference the wrapper. A new file
//       therefore fails closed and must be consciously allowlisted.
//  Login tokens are matched on a whitespace-collapsed copy, so `sh  -lc` and
//  `sh\n-lc` are caught too.
//
//  A renamed function reddens the exact-name comparisons (a deliberate
//  tripwire, not a silent pass); a token moved to a new function reddens the
//  set comparison and the occurrence-count pin. It is a tripwire, not a
//  proof. Remaining defeats: braces inside string literals are counted by the
//  block walk (balanced in these files today), a default-argument closure
//  would make the walk bind the wrong block, raw strings (`#"..."#`) are not
//  recognized by the comment stripper, comments inside an interpolation are
//  not stripped, a login-shell token assembled at runtime is invisible, an
//  aliased wrapper reference (`let wrap = …wrapPOSIXShellCommand; wrap(x)`)
//  and a wrapper call from outside `VVTerm/Core/SSH/` and its non-recursive
//  sweep are invisible, and the acknowledged #324 passed-probe class
//  (clipboard / rich-paste / stats probes that still run in a login shell)
//  is listed in the wrapper inventory rather than asserted non-login. A
//  commented-out `sh -lc` cannot satisfy the pins (comments are stripped).
//  Any intentional login site added later must be added to the allowlists
//  below deliberately.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the suite at a
//  mutated tree. Measured in `SSHExecGateLivenessPinsTests` on this runner: a
//  plain env var is inert; export
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` into xcodebuild's own
//  environment to reach the simulator test process (or hand-mutate the
//  worktree and restore it).
//

import Foundation
import Testing

@testable import VVTerm

struct SSHProbeShellPinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/SSH/SSHProbeShellPinsTests.swift`).
    private func repositoryRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SSHProbeShellPinsTests.swift
            .deletingLastPathComponent()  // SSH/
            .deletingLastPathComponent()  // VVTermTests/
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - The allowlist

    /// The only functions allowed to build `sh -lc` / `/bin/sh -lc` commands
    /// in the three files that construct remote commands. Login semantics are
    /// intended or required at every site:
    ///
    /// - `bootstrapCommand` — the mosh child startup deliberately launches the
    ///   user's login shell (lines 104 and 106 of the two wrapper layers).
    /// - `terminationCommand` — fire-and-forget server cleanup.
    /// - `installMoshServer` — user-initiated install action; it does
    ///   marker-parse, but keeps login semantics for package-manager
    ///   discovery (the residual hook-firing risk is accepted).
    /// - `installAndAttachScript` — the PTY install script, delivered via
    ///   `sendScript`, not an exec probe.
    /// - `cleanupLegacySessions` — fire-and-forget legacy cleanup.
    /// - `killSessionCommand` — fire-and-forget session kill.
    /// - `wrapPOSIXShellCommand` — the intentional login wrapper itself.
    /// - `unwrapPOSIXShellInvocationIfNeeded` — parses those prefixes from a
    ///   user startup command; it is not an emitter.
    private static let expectedLoginShellSites: [String: [String]] = [
        "VVTerm/Core/SSH/RemoteMoshManager.swift": [
            "bootstrapCommand",
            "installMoshServer",
            "terminationCommand"
        ],
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": [
            "cleanupLegacySessions",
            "installAndAttachScript",
            "killSessionCommand"
        ],
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": [
            "unwrapPOSIXShellInvocationIfNeeded",
            "wrapPOSIXShellCommand"
        ]
    ]

    /// Occurrence counts (`sh -lc` also matches `/bin/sh -lc`), the 9 sites of
    /// plan section 4.3: Mosh 104/106/128/148; Tmux 381/416/1053; Bootstrap
    /// 187/315 (the parser prefix array holds two tokens on one line).
    private static let expectedLoginShellOccurrences: [String: Int] = [
        "VVTerm/Core/SSH/RemoteMoshManager.swift": 4,
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": 3,
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": 3
    ]

    /// Every capability-probe builder that must call
    /// `wrapPOSIXProbeCommand`, plus the file each lives in. The first four
    /// were converted by #323; `tmuxAvailabilityProbeCommand` was already
    /// non-login but inlined the wrapper's text, so it was converted to the
    /// wrapper call too (the single-construction-point half of the security
    /// lens's MAJOR) and is pinned here as the fifth.
    private static let probeBuilders: [(path: String, function: String)] = [
        ("VVTerm/Core/SSH/RemoteMoshManager.swift", "availabilityProbeCommand"),
        ("VVTerm/Core/SSH/RemoteTmuxManager.swift", "sessionPresenceProbeCommand"),
        ("VVTerm/Core/SSH/RemoteTmuxManager.swift", "listSessionCommands"),
        ("VVTerm/Core/SSH/RemoteTmuxManager.swift", "currentPathCommand"),
        ("VVTerm/Core/SSH/RemoteTmuxManager.swift", "tmuxAvailabilityProbeCommand")
    ]

    private static let loginShellTokens = ["sh -lc", "/bin/sh -lc"]

    /// The functions allowed to call the *login* wrapper
    /// (`RemoteTerminalBootstrap.wrapPOSIXShellCommand`) in the three pinned
    /// files and the two resolver files on the probe path. A login *token*
    /// scan cannot see `wrapPOSIXShellCommand(body)`, so this is the allowlist
    /// that catches a new probe adopting the login wrapper.
    ///
    /// - `RemoteTmuxManager.createSessionCommand` — builds the interactive
    ///   terminal window's login shell (the intentional login site at
    ///   `RemoteTmuxManager.swift:622`).
    /// - `RemoteEnvironmentResolver.launchPlan` — the user's interactive
    ///   launch plan (default login shell / startup command), two calls.
    /// - `RemoteMoshManager`, `RemoteTerminalBootstrap`,
    ///   `RemoteTerminalTypeResolver` — none. The mosh/bootstrap login sites
    ///   are literal-token sites covered by pin 1; the type resolver probes
    ///   with `wrapPOSIXProbeCommand`.
    private static let expectedLoginWrapperSites: [String: [String]] = [
        "VVTerm/Core/SSH/RemoteMoshManager.swift": [],
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": ["createSessionCommand"],
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": [],
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift": ["launchPlan"],
        "VVTerm/Core/SSH/RemoteTerminalTypeResolver.swift": []
    ]

    /// Login-wrapper call occurrences inside function bodies (the declaration
    /// and doc mentions are outside every body and do not count), so a second
    /// call inside an allowlisted function still reddens the pin.
    private static let expectedLoginWrapperOccurrences: [String: Int] = [
        "VVTerm/Core/SSH/RemoteMoshManager.swift": 0,
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": 1,
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": 0,
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift": 2,
        "VVTerm/Core/SSH/RemoteTerminalTypeResolver.swift": 0
    ]

    /// Every file in `VVTerm/Core/SSH/` that references the login wrapper,
    /// definition included. The directory-inventory pin fails closed when a
    /// new file appears here, so a new probe cannot adopt the login wrapper
    /// silently. `TerminalRichPasteCoordinator` and
    /// `RemoteClipboardTransferService` are the acknowledged #324 residual
    /// class (parsed probes that still run in a login shell); they are listed
    /// so the inventory is explicit, not because their use is endorsed.
    private static let knownLoginWrapperReferences: Set<String> = [
        "VVTerm/Core/SSH/RemoteClipboardTransferService.swift",
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift",
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift",
        "VVTerm/Core/SSH/RemoteTmuxManager.swift",
        "VVTerm/Core/SSH/TerminalRichPasteCoordinator.swift"
    ]

    /// The three files the per-function login-token allowlist enumerates.
    private static let pinnedCommandBuilderFiles = Set(expectedLoginShellSites.keys)

    // MARK: - Pins

    /// Pin 1 (#323): the only `func` bodies emitting a login shell in the
    /// three remote-command files are the allowlist above.
    @Test
    func testOnlyAllowlistedFunctionsBuildLoginShellCommands() throws {
        for (path, allowed) in Self.expectedLoginShellSites {
            let text = Self.loginShellScan(try source(path))
            let bodies = try Self.functionBodies(in: text)

            for name in allowed {
                #expect(
                    bodies.filter { $0.name == name }.count == 1,
                    "\(path): the allowlisted `\(name)` must resolve to exactly one function body"
                )
            }

            let tokenBodies = bodies.filter { body in
                Self.loginShellTokens.contains { text.range(of: $0, range: body.body) != nil }
            }
            let tokenNames = tokenBodies.map(\.name).sorted()
            #expect(
                tokenNames == allowed.sorted(),
                "\(path): login-shell emitters must be exactly \(allowed.sorted()), got \(tokenNames)"
            )

            let totalOccurrences = Self.occurrences(of: "sh -lc", in: text).count
            let insideBodyOccurrences = tokenBodies.reduce(0) { count, body in
                count + Self.occurrences(of: "sh -lc", in: text, range: body.body).count
            }
            #expect(
                totalOccurrences == insideBodyOccurrences,
                "\(path): every `sh -lc` occurrence must sit inside an enumerated function body"
            )
            #expect(
                totalOccurrences == Self.expectedLoginShellOccurrences[path],
                "\(path): the login-shell occurrence count must stay \(Self.expectedLoginShellOccurrences[path] ?? -1)"
            )
        }
    }

    /// Pin 2 (#323): the four converted capability-probe builders must keep
    /// using the non-login wrapper. A re-inlined `sh -lc` also reddens Pin 1,
    /// but this pin names the builder.
    @Test
    func testCapabilityProbeBuildersCallTheNonLoginProbeWrapper() throws {
        for builder in Self.probeBuilders {
            let text = Self.strippingComments(try source(builder.path))
            let bodies = try Self.functionBodies(in: text)
            let matches = bodies.filter { $0.name == builder.function }
            #expect(
                matches.count == 1,
                "\(builder.path) must keep exactly one `\(builder.function)`"
            )
            let body = try #require(matches.first)
            #expect(
                text.range(of: "wrapPOSIXProbeCommand(", range: body.body) != nil,
                "\(builder.path): \(builder.function) must build its command with wrapPOSIXProbeCommand"
            )
        }
    }

    /// Pin 3 (#323): the terminal-type resolver must never reference the login
    /// token or the login wrapper — it probes with the non-login
    /// `wrapPOSIXProbeCommand`. (`RemoteEnvironmentResolver`'s two intentional
    /// interactive-launch wrapper calls are allowlisted in pin 4; this pin's
    /// scope is the file where the login wrapper is never legitimate.)
    @Test
    func testTerminalTypeResolverNeverReferencesTheLoginShell() throws {
        let path = "VVTerm/Core/SSH/RemoteTerminalTypeResolver.swift"
        let scan = Self.loginShellScan(try source(path))
        for token in Self.loginShellTokens {
            #expect(
                !scan.contains(token),
                "\(path) must not emit a literal login-shell token (`\(token)`)"
            )
        }
        #expect(
            scan.range(of: "wrapPOSIXShellCommand(") == nil,
            "\(path) must probe with wrapPOSIXProbeCommand, never the login wrapper"
        )
    }

    /// Pin 4 (#323): in the three pinned files and the two probe-path resolver
    /// files, the only functions that may call the *login* wrapper are the
    /// allowlist above. This is the pin the literal-token scan cannot be: a
    /// new probe written as `wrapPOSIXShellCommand(body)` carries no literal
    /// `sh -lc`, so pin 1 cannot see it.
    @Test
    func testOnlyAllowlistedFunctionsCallTheLoginShellWrapper() throws {
        for (path, allowed) in Self.expectedLoginWrapperSites {
            let text = Self.strippingComments(try source(path))
            let bodies = try Self.functionBodies(in: text)

            for name in allowed {
                #expect(
                    bodies.filter { $0.name == name }.count == 1,
                    "\(path): the allowlisted `\(name)` must resolve to exactly one function body"
                )
            }

            let callers = bodies
                .filter { text.range(of: "wrapPOSIXShellCommand(", range: $0.body) != nil }
                .map(\.name)
                .sorted()
            #expect(
                callers == allowed.sorted(),
                "\(path): login-wrapper callers must be exactly \(allowed.sorted()), got \(callers)"
            )

            let insideBodyOccurrences = bodies.reduce(0) { count, body in
                count + Self.occurrences(
                    of: "wrapPOSIXShellCommand(",
                    in: text,
                    range: body.body
                ).count
            }
            #expect(
                insideBodyOccurrences == Self.expectedLoginWrapperOccurrences[path],
                "\(path): the login-wrapper call count must stay \(Self.expectedLoginWrapperOccurrences[path] ?? -1)"
            )
        }
    }

    /// Pin 5 (#323): the command-builder directory inventory is explicit. A
    /// new file in `VVTerm/Core/SSH/` that emits a literal login-shell token,
    /// or that references the login wrapper, must be consciously allowlisted —
    /// otherwise this pin fails closed. Pins 1 and 4 only cover the files
    /// enumerated today, so this is the new-file half of the recurrence guard.
    @Test
    func testCommandBuilderDirectoryInventoryIsExplicit() throws {
        let files = try commandBuilderFiles()
        #expect(
            files.count >= 20,
            "the directory sweep must actually enumerate VVTerm/Core/SSH (got \(files.count) files)"
        )

        for path in files {
            let scan = Self.loginShellScan(try source(path))
            if Self.loginShellTokens.contains(where: { scan.range(of: $0) != nil }) {
                #expect(
                    Self.pinnedCommandBuilderFiles.contains(path),
                    "\(path): a literal login-shell token must live in a pinned command-builder file"
                )
            }
            if scan.range(of: "wrapPOSIXShellCommand(") != nil {
                #expect(
                    Self.knownLoginWrapperReferences.contains(path),
                    "\(path): a login-wrapper reference must be consciously allowlisted"
                )
            }
        }
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

    /// The comment-stripped, whitespace-collapsed form the login-token scans
    /// run on. `sh` accepts arbitrary whitespace before `-lc`, so an exact
    /// `sh -lc` substring scan treats `sh  -lc` (and a tab or newline variant)
    /// as absent. Collapsing runs of whitespace makes every such spelling
    /// match, and is deliberately conservative: any `sh` … `-lc` sequence in
    /// code is a login-shell invocation.
    private static func loginShellScan(_ source: String) -> String {
        collapsingWhitespaceRuns(strippingComments(source))
    }

    /// `text` with every run of whitespace (newlines included) replaced by a
    /// single space, so whitespace-variant tokens match.
    private static func collapsingWhitespaceRuns(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var previousWasWhitespace = false
        for character in text {
            if character.isWhitespace {
                if !previousWasWhitespace { result.append(" ") }
                previousWasWhitespace = true
            } else {
                result.append(character)
                previousWasWhitespace = false
            }
        }
        return result
    }

    /// Every `.swift` file directly inside `VVTerm/Core/SSH/`, as
    /// repository-relative paths. Non-recursive: the directory has no
    /// subdirectories today, and a new one would escape the inventory pin
    /// (named in that pin's defeat list).
    private func commandBuilderFiles() throws -> [String] {
        let directory = repositoryRoot().appendingPathComponent("VVTerm/Core/SSH")
        return try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { "VVTerm/Core/SSH/\($0)" }
    }

    /// A `func` declaration's body span and its name.
    private struct FunctionBody {
        let name: String
        let body: Range<String.Index>
    }

    /// Every `func` declaration's body in `text`, in source order. The scan
    /// keys off the literal `func ` keyword (shell function definitions inside
    /// string literals do not carry it) and binds the first brace block after
    /// the declaration name. `nonisolated static func`, `private func`, and
    /// `@Test`-less declarations all match; a default-argument closure would
    /// bind the wrong block (documented defeat list).
    private static func functionBodies(in text: String) throws -> [FunctionBody] {
        var result: [FunctionBody] = []
        for declaration in occurrences(of: "func ", in: text) {
            var cursor = declaration.upperBound
            let nameStart = cursor
            while cursor < text.endIndex,
                  text[cursor].isLetter || text[cursor].isNumber || text[cursor] == "_" {
                cursor = text.index(after: cursor)
            }
            guard cursor > nameStart else { continue }
            let name = String(text[nameStart..<cursor])
            let body = try bracedBlock(after: nameStart..<cursor, in: text)
            result.append(FunctionBody(name: name, body: body))
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
}
