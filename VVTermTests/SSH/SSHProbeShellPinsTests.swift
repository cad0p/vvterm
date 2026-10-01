// SPDX-License-Identifier: MIT
//
//  SSHProbeShellPinsTests.swift
//  VVTermTests
//
//  Placement pins for #323 ("run the tmux/mosh capability probes in non-login
//  shells"): the four converted builders must call
//  `RemoteTerminalBootstrap.wrapPOSIXProbeCommand`, and every remaining
//  `sh -lc` / `/bin/sh -lc` in the three files that build remote commands must
//  sit in the intentional-login allowlist below. This is the only CI-enforced
//  protection against the recurrence mechanism #121 -> #323 (a new probe
//  added with a literal `sh -lc`), because the behavioural route cannot run on
//  iOS.
//
//  WHAT THESE PINS ASSERT (and what they do not see). Each pin comment-strips
//  the source, enumerates brace-delimited `func` bodies, and compares the set
//  of bodies containing a login-shell token against the allowlist; a second
//  pin requires each capability-probe builder's body to call
//  `wrapPOSIXProbeCommand`. A renamed function reddens the exact-name
//  comparison (a deliberate tripwire, not a silent pass); a token moved to a
//  new function reddens the set comparison and the occurrence-count pin. It
//  is a tripwire, not a proof: braces inside string literals are counted by
//  the block walk (they are balanced in these files today), a default-argument
//  closure would make the walk bind the wrong block, raw strings (`#"..."#`)
//  are not recognized by the comment stripper, and a login-shell token
//  assembled at runtime is invisible. A commented-out `sh -lc` cannot satisfy
//  the pins (comments are stripped). The allowlist below is the full defeat
//  list: any intentional login site added later must be added here
//  deliberately.
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

    /// The four capability probes converted by #323, plus the file each lives
    /// in. `tmuxAvailabilityProbeCommand` is the already-correct sibling and
    /// is covered by its own assertion in `RemoteTmuxManagerParserTests`.
    private static let probeBuilders: [(path: String, function: String)] = [
        ("VVTerm/Core/SSH/RemoteMoshManager.swift", "availabilityProbeCommand"),
        ("VVTerm/Core/SSH/RemoteTmuxManager.swift", "sessionPresenceProbeCommand"),
        ("VVTerm/Core/SSH/RemoteTmuxManager.swift", "listSessionCommands"),
        ("VVTerm/Core/SSH/RemoteTmuxManager.swift", "currentPathCommand")
    ]

    private static let loginShellTokens = ["sh -lc", "/bin/sh -lc"]

    // MARK: - Pins

    /// Pin 1 (#323): the only `func` bodies emitting a login shell in the
    /// three remote-command files are the allowlist above.
    @Test
    func testOnlyAllowlistedFunctionsBuildLoginShellCommands() throws {
        for (path, allowed) in Self.expectedLoginShellSites {
            let text = Self.strippingComments(try source(path))
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

    /// Pin 3 (#323): the resolver files on the probe path must never emit a
    /// login-shell command. They are outside the three-file allowlist scan, so
    /// this pin keeps a future edit from introducing the token there.
    @Test
    func testResolverFilesNeverBuildLoginShellCommands() throws {
        for path in [
            "VVTerm/Core/SSH/RemoteTerminalTypeResolver.swift",
            "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift"
        ] {
            let text = Self.strippingComments(try source(path))
            #expect(!text.contains("sh -lc"), "\(path) must not emit a login-shell command")
            #expect(!text.contains("/bin/sh -lc"), "\(path) must not emit a login-shell command")
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
