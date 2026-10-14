// SPDX-License-Identifier: MIT
//  PinScanSupport.swift
//
//  The shared pin-scan support for the `VVTermTests` pin suites (issue #450).
//
//  Every pin suite used to carry its own private copy of `repositoryRoot()`,
//  `source(_:)`, the comment lexers, and `PinFailure`. This file is the single
//  home for those helpers. The suites own their *assertions*; the plumbing
//  lives here.
//
//  `repositoryRoot(filePath:)` resolves at the call site (`#filePath` is a
//  default argument), so a caller in `VVTermTests/…` still walks up to the
//  directory containing `VVTerm.xcodeproj`. The counterfactual hook
//  `VVTERM_PINS_SOURCE_ROOT` — exported into xcodebuild's environment as
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT` — points every consumer at a mutated
//  tree.
//
//  Scanner selection (callers → semantics). Pick deliberately:
//
//  - `strippingComments(_:)` — the canonical scanner (85 call sites at
//    #453). Since issue #455 it runs the shared worker's verbatim-string
//    mode, so it is
//    hash-aware (`#"…"#`, any hash count) and interpolation-aware; it is
//    byte-identical to `strippingCommentsKeepingLiterals(_:)`.
//  - `strippingCommentsKeepingLiterals(_:)` (R1) — the login-token scan in
//    `SSH/SSHProbeShellPinsTests.swift` (5 calls): a documented alias of
//    `strippingComments(_:)` with string contents kept verbatim. The name
//    stays because it declares the scanner's role at those call sites;
//    retiring it is a deliberate follow-up, not part of #455.
//  - `strippingCommentsAndStrings(_:)` (R2) — the SSH call-form scans (6
//    calls): the shared worker with string interiors blanked and
//    interpolation bodies scanned as code. The #453 shrink is fixed; the
//    documented residual is the raw-string close search, which can still exit
//    early on a `"#` inside a raw interpolation body (pinned by the
//    `raw-string-interp-embedded-close` golden row).
//  - `strippingCommentsAndStringsPreservingUTF16(_:)` (R3) — the declared-test
//    attribution walk in `WorkflowShardSplitPinsTests.swift` (1 call), whose
//    consumers index the result with `NSRange`/UTF-16 offsets: hash-prefix
//    aware, its literal end skips interpolation bodies through nested strings
//    and comments, and per-unit blanking preserves the UTF-16 length on every
//    input.
//  - `strippingYAMLComments(_:)`, `normalizedWhitespace(_:)`, `isInside(_:_:)`
//    — the small shared helpers used by the census and whitespace pins.
//
//  All four scanners are fail-open lexers (the census's `maskedCode` is the
//  fail-closed one). The #453 defects are fixed in place by issue #455 (D1–D3,
//  D5): comment-aware interpolation close, Swift-exact line terminators with
//  the terminator kept verbatim, hash-exact nested-quote-proof R3 literal
//  ends, and a hash-aware canonical scanner that delegates to the same worker
//  as R1 (which stays declared as its alias). The shared predicate
//  `PinScan.isSwiftLineTerminator` is the single home for the terminator set;
//  `PinScanCensus` delegates to it and the census's shared-helper list records
//  the name. Migrating a scanner is a behavior change: the golden rows must
//  move with it.

import Foundation

/// A pin-scan failure that carries a human-readable description. Replaces the
/// per-suite `struct PinFailure` copies.
struct PinFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}

/// The shared pin-scan plumbing. An `enum` namespace keeps migrated calls
/// textually distinguishable from a residual local copy, so the census pin can
/// prove "no unqualified local copy remains".
enum PinScan {
    /// The repository root: the nearest ancestor of `filePath` containing
    /// `VVTerm.xcodeproj`. Honors the counterfactual hook first and fails
    /// closed when no root is found.
    static func repositoryRoot(filePath: String = #filePath) throws -> URL {
        // Counterfactual hook: the mutation runs point this at a copy of the
        // source with the pinned file mutated. The measured-working form is
        // `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` exported into
        // xcodebuild's own environment (the `TEST_RUNNER_` prefix is consumed
        // by the test runner and forwarded without it).
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        var url = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("VVTerm.xcodeproj").path
            ) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw PinFailure(
            "could not locate the repository root (no VVTerm.xcodeproj above \(filePath)) — re-derive this pin"
        )
    }

    /// Reads a repository-relative text file, wrapping failures in
    /// `PinFailure`. `filePath` is forwarded to `repositoryRoot(filePath:)` so
    /// the internal call stays bound to the caller's file.
    static func source(_ relativePath: String, filePath: String = #filePath) throws -> String {
        let url = try repositoryRoot(filePath: filePath).appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PinFailure("could not read \(relativePath) at \(url.path): \(error)")
        }
    }

    /// A comment-stripped copy of `source`: characters inside `//` line
    /// comments and nested `/* … */` block comments become spaces; Swift line
    /// terminators (LF, CRLF, CR) are preserved verbatim, so slice anchors
    /// still resolve. String contents are copied verbatim (so a `//` inside a
    /// literal is not read as a comment), hash-aware (`#"…"#`, `##"…"##`)
    /// and interpolation-descent aware. This is the shared worker in
    /// `blankingStringContents: false` mode, which makes the canonical scanner
    /// byte-identical to `strippingCommentsKeepingLiterals(_:)` (issue #455);
    /// both names are kept because each names a caller-facing role.
    static func strippingComments(_ source: String) -> String {
        scanning(source, blankingStringContents: false)
    }

    /// A YAML comment-stripped copy of `source`: a `#` that starts a comment
    /// (at line start or preceded by whitespace, outside a quoted scalar)
    /// blanks the rest of the line; newlines are preserved, so line anchors
    /// still resolve. Single-quoted (`''` escapes) and double-quoted (`\`
    /// escapes) scalars are copied verbatim, so a `#` or a `needs: build`
    /// literal inside a scalar is not read as a comment.
    static func strippingYAMLComments(_ source: String) -> String {
        let characters = Array(source)
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        var inSingleQuoted = false
        var inDoubleQuoted = false
        var escaped = false
        var atLineStart = true
        var previousWasWhitespace = true
        while index < characters.count {
            let character = characters[index]
            if inSingleQuoted {
                result.append(character)
                index += 1
                if character == "'" {
                    if index < characters.count, characters[index] == "'" {
                        // YAML single-quote escape: `''` stays inside the scalar.
                        result.append("'")
                        index += 1
                    } else {
                        inSingleQuoted = false
                    }
                }
                atLineStart = false
                previousWasWhitespace = false
                continue
            }
            if inDoubleQuoted {
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
                if character == "\"" {
                    inDoubleQuoted = false
                }
                atLineStart = false
                previousWasWhitespace = false
                continue
            }
            if character == "#", atLineStart || previousWasWhitespace {
                while index < characters.count, !PinScan.isSwiftLineTerminator(characters[index]) {
                    result.append(" ")
                    index += 1
                }
                continue
            }
            if PinScan.isSwiftLineTerminator(character) {
                result.append(character)
                index += 1
                atLineStart = true
                previousWasWhitespace = true
                continue
            }
            if character == "'" {
                inSingleQuoted = true
            } else if character == "\"" {
                inDoubleQuoted = true
            }
            result.append(character)
            index += 1
            atLineStart = false
            previousWasWhitespace = character.isWhitespace
        }
        return result
    }

    /// The whitespace-collapsed copy of `text`.
    static func normalizedWhitespace(_ text: Substring) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Whether `index` is strictly inside `block`.
    static func isInside(_ block: Range<String.Index>, _ index: String.Index) -> Bool {
        block.lowerBound < index && index < block.upperBound
    }

    /// A comment-stripped copy of `source` that keeps string-literal contents
    /// verbatim: characters inside `//` line comments and nested `/* … */`
    /// block comments become spaces, while string contents — including raw
    /// strings (`#"…"#`, any hash count) and interpolations — are copied with
    /// the literal, so a `//` inside a string is not read as a comment. Swift
    /// line terminators (LF, CRLF, CR) are preserved verbatim so slice anchors
    /// resolve. This is R1, the scanner behind the login-token scan in
    /// `SSH/SSHProbeShellPinsTests`.
    ///
    /// Documented alias (issue #455): the canonical `strippingComments(_:)`
    /// runs the same worker (`blankingStringContents: false`), so the two
    /// scanners are byte-identical. The name stays because it declares this
    /// scanner's role at the 5 login-token call sites (the census's
    /// `expectedCallSites` count is unchanged); retiring it is a deliberate
    /// follow-up, not part of the unification.
    static func strippingCommentsKeepingLiterals(_ source: String) -> String {
        strippingComments(source)
    }

    /// A comment-stripped copy of `source` whose string-literal *contents* are
    /// blanked (delimiters and LF characters kept): R2, the scanner behind the
    /// call-form scans in `SSH/SSHProbeShellPinsTests`, so a call-form literal
    /// such as `"wrapPOSIXShellCommand("` cannot satisfy a call pin. It
    /// recognizes one-line, multi-line and raw strings (hash count matched)
    /// and keeps interpolation bodies (`\( … )`, `\#( … )`) as code by
    /// scanning them recursively.
    ///
    /// Known limits (measured and pinned by `PinScanSupportGoldenTests`): the
    /// escaped-triple-quote form (`"""a \""" b"""`) still closes at the first
    /// `"""` sequence, so the escaped quote and the following text can leak;
    /// the escaped-triple-quote golden row is the fixed-output record of that
    /// residual (issue #455).
    static func strippingCommentsAndStrings(_ source: String) -> String {
        Self.scanning(source, blankingStringContents: true)
    }

    /// The single worker behind `strippingComments`,
    /// `strippingCommentsKeepingLiterals` and `strippingCommentsAndStrings`.
    /// Comments become spaces in both modes; Swift line terminators (LF,
    /// CRLF, CR) are preserved verbatim so slice anchors and range arithmetic
    /// resolve. When blanking string contents, an interpolation (`\( … )`) is
    /// kept as code — its body is scanned recursively, because a real call
    /// inside an interpolation is not a string decoy. When copying strings
    /// verbatim the whole literal, interpolation included, is kept as text, so
    /// the login-token scan keeps seeing tokens inside interpolated literals.
    static func scanning(
        _ source: String,
        blankingStringContents: Bool
    ) -> String {
        let characters = Array(source)
        var result: [Character] = []
        result.reserveCapacity(characters.count)
        result.append(contentsOf: scan(
            characters,
            from: 0,
            to: characters.count,
            blankingStringContents: blankingStringContents
        ))
        return String(result)
    }

    /// The recursive worker behind `scanning(_:blankingStringContents:)`.
    static func scan(
        _ characters: [Character],
        from start: Int,
        to end: Int,
        blankingStringContents: Bool
    ) -> [Character] {
        var result: [Character] = []
        result.reserveCapacity(end - start)
        var index = start
        var blockCommentDepth = 0
        var inLineComment = false
        while index < end {
            let character = characters[index]
            if inLineComment {
                if PinScan.isSwiftLineTerminator(character) {
                    inLineComment = false
                    result.append(character)
                } else {
                    result.append(" ")
                }
                index += 1
                continue
            }
            if blockCommentDepth > 0 {
                if character == "/", index + 1 < end, characters[index + 1] == "*" {
                    blockCommentDepth += 1
                    result.append(contentsOf: "  ")
                    index += 2
                } else if character == "*", index + 1 < end, characters[index + 1] == "/" {
                    blockCommentDepth -= 1
                    result.append(contentsOf: "  ")
                    index += 2
                } else {
                    result.append(PinScan.isSwiftLineTerminator(character) ? character : " ")
                    index += 1
                }
                continue
            }
            if character == "/", index + 1 < end, characters[index + 1] == "/" {
                inLineComment = true
                result.append(contentsOf: "  ")
                index += 2
                continue
            }
            if character == "/", index + 1 < end, characters[index + 1] == "*" {
                blockCommentDepth = 1
                result.append(contentsOf: "  ")
                index += 2
                continue
            }
            if let delimiter = Self.stringDelimiter(at: index, in: characters, to: end) {
                if blankingStringContents {
                    let scanned = Self.scannedString(
                        characters,
                        openingAt: index,
                        delimiter: delimiter
                    )
                    result.append(contentsOf: scanned.characters)
                    index = scanned.afterDelimiter
                } else {
                    let close = Self.stringEnd(from: index, delimiter: delimiter, in: characters)
                    result.append(contentsOf: characters[index..<close.index])
                    index = close.index
                }
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    /// Whether `character` is one of Swift's own line terminators: LF, CRLF
    /// (one `Character`) or CR. Deliberately NOT `Character.isNewline`:
    /// Swift keeps a `//` comment open through U+000B/U+000C/U+0085/U+2028/
    /// U+2029, and treating those as terminators would let a comment end
    /// early and a following quote swallow real code. This is the scanners'
    /// single home for the predicate; `PinScanCensus` delegates here so the
    /// scanners and the census cannot drift apart (issue #455).
    static func isSwiftLineTerminator(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }

    /// The string-delimiter sequence beginning at `start` (`"`, `"""`, `#"`,
    /// `##"`, …), or nil when the characters there do not open a string.
    static func stringDelimiter(
        at start: Int,
        in characters: [Character],
        to end: Int
    ) -> String? {
        var cursor = start
        while cursor < end, characters[cursor] == "#" {
            cursor += 1
        }
        guard cursor < end, characters[cursor] == "\"" else { return nil }
        let hashes = String(repeating: "#", count: cursor - start)
        if cursor + 2 < end, characters[cursor + 1] == "\"", characters[cursor + 2] == "\"" {
            return hashes + "\"\"\""
        }
        return hashes + "\""
    }

    /// A copy of the string literal that opens at `start`: the content is
    /// blanked while interpolation bodies are scanned recursively so their
    /// calls stay visible — `\( … )` for the quoted strings and `\#( … )`
    /// (the delimiter's hash count) for raw strings — and the closing
    /// delimiter is preserved. Returns the copy and the index just past the
    /// literal.
    static func scannedString(
        _ characters: [Character],
        openingAt start: Int,
        delimiter: String
    ) -> (characters: [Character], afterDelimiter: Int) {
        var result: [Character] = []
        result.append(contentsOf: characters[start..<(start + delimiter.count)])
        let contentStart = start + delimiter.count
        let close = Self.stringEnd(from: start, delimiter: delimiter, in: characters)
        var cursor = contentStart
        // Raw-string delimiters are hash-*prefixed* (`#"`, `##"`, `#"""`),
        // so raw-ness is `hasPrefix`, not `hasSuffix`.
        let isRaw = delimiter.hasPrefix("#")
        let hashCount = delimiter.filter { $0 == "#" }.count
        while cursor < close.contentEnd {
            let character = characters[cursor]
            if character == "\\" {
                var escapeIndex = cursor + 1
                if isRaw {
                    var hashes = 0
                    while escapeIndex < close.contentEnd, characters[escapeIndex] == "#" {
                        hashes += 1
                        escapeIndex += 1
                    }
                    guard hashes == hashCount else {
                        // Fewer/more hashes than the delimiter: literal text,
                        // blanked with the rest of the content.
                        result.append(" ")
                        cursor += 1
                        continue
                    }
                }
                if escapeIndex < close.contentEnd, characters[escapeIndex] == "(" {
                    let interpolation = Self.interpolationEnd(
                        in: characters,
                        from: escapeIndex + 1,
                        to: close.contentEnd
                    )
                    result.append(contentsOf: characters[cursor...escapeIndex])
                    result.append(contentsOf: scan(
                        characters,
                        from: interpolation.openDepth,
                        to: interpolation.closeDepth,
                        blankingStringContents: true
                    ))
                    result.append(")")
                    cursor = interpolation.closeDepth + 1
                    continue
                }
                if !isRaw, cursor + 1 < close.contentEnd {
                    result.append(character)
                    result.append(contentsOf: Self.blanked(characters, from: cursor + 1, to: min(cursor + 2, close.contentEnd)))
                    cursor += 2
                    continue
                }
            }
            result.append(PinScan.isSwiftLineTerminator(character) ? character : " ")
            cursor += 1
        }
        result.append(contentsOf: characters[close.contentEnd..<close.index])
        return (result, close.index)
    }

    /// The end of an interpolation whose body starts at `start`: the body
    /// (returned as `openDepth..<closeDepth`) ends at the matching `)` at
    /// bracket depth zero; a `)` inside a string literal inside the body does
    /// not close it, a nested interpolation is skipped along with its own
    /// string, and a `//` or nested `/* … */` comment inside the body is
    /// skipped so a `(` or `)` in comment text is never a bracket. A body
    /// that never closes (including an unterminated block comment) runs to
    /// `end` and returns an empty span (fail-open: nothing is executed, the
    /// text stays blanked).
    static func interpolationEnd(
        in characters: [Character],
        from start: Int,
        to end: Int
    ) -> (openDepth: Int, closeDepth: Int) {
        var cursor = start
        var depth = 0
        while cursor < end {
            let character = characters[cursor]
            if character == "/", cursor + 1 < end, characters[cursor + 1] == "/" {
                cursor += 2
                while cursor < end, !PinScan.isSwiftLineTerminator(characters[cursor]) {
                    cursor += 1
                }
                continue
            }
            if character == "/", cursor + 1 < end, characters[cursor + 1] == "*" {
                var blockDepth = 1
                cursor += 2
                while cursor < end, blockDepth > 0 {
                    if characters[cursor] == "/", cursor + 1 < end, characters[cursor + 1] == "*" {
                        blockDepth += 1
                        cursor += 2
                    } else if characters[cursor] == "*", cursor + 1 < end, characters[cursor + 1] == "/" {
                        blockDepth -= 1
                        cursor += 2
                    } else {
                        cursor += 1
                    }
                }
                if blockDepth > 0 { return (end, end) }
                continue
            }
            if character == "(" || character == "[" || character == "{" {
                depth += 1
                cursor += 1
            } else if character == ")" {
                if depth == 0 {
                    return (start, cursor)
                }
                depth -= 1
                cursor += 1
            } else if character == "]" || character == "}" {
                if depth > 0 { depth -= 1 }
                cursor += 1
            } else if let delimiter = Self.stringDelimiter(at: cursor, in: characters, to: end) {
                cursor = Self.stringEnd(from: cursor, delimiter: delimiter, in: characters).index
            } else {
                cursor += 1
            }
        }
        return (end, end)
    }

    /// The end of the string literal that opens at `start`, where the opening
    /// delimiter is `delimiter` (one quote plus its hash prefix, three quotes,
    /// or one quote). `contentEnd` is the index just past the content (where
    /// the closing sequence begins); `closing` is that sequence (the quote or
    /// `"""` suffix); `index` is the first character after it. A raw string
    /// has no escapes; a non-raw one treats a backslash as escaping the next
    /// character — including `\(`, whose interpolation contents are scanned
    /// with a bracket stack (and any string inside them skipped) so a `"` or
    /// `)` inside an interpolation cannot terminate the outer literal.
    static func stringEnd(
        from start: Int,
        delimiter: String,
        in characters: [Character]
    ) -> (contentEnd: Int, closing: [Character], index: Int) {
        let isRaw = delimiter.hasPrefix("#")
        let quoteCount = delimiter.filter { $0 == "\"" }.count
        let hashes = delimiter.filter { $0 == "#" }.count
        var cursor = start + delimiter.count
        while cursor < characters.count {
            if isRaw {
                let closingLength = quoteCount + hashes
                if cursor + closingLength <= characters.count,
                   Array(characters[cursor..<(cursor + closingLength)])
                    == Array(repeating: "\"", count: quoteCount)
                        + Array(repeating: "#", count: hashes) {
                    return (cursor, Array(characters[cursor..<(cursor + closingLength)]), cursor + closingLength)
                }
                cursor += 1
            } else if quoteCount == 3 {
                if cursor + 3 <= characters.count,
                   characters[cursor] == "\"",
                   characters[cursor + 1] == "\"",
                   characters[cursor + 2] == "\"" {
                    return (cursor, Array("\"\"\""), cursor + 3)
                }
                cursor += 1
            } else if characters[cursor] == "\\" {
                if cursor + 1 < characters.count, characters[cursor + 1] == "(" {
                    cursor = Self.interpolationEnd(in: characters, from: cursor + 2, to: characters.count).closeDepth + 1
                } else {
                    cursor += 2
                }
            } else if characters[cursor] == "\"" {
                return (cursor, Array("\""), cursor + 1)
            } else {
                cursor += 1
            }
        }
        return (characters.count, [], characters.count)
    }

    /// `characters[from..<to]` with every character that is not a Swift line
    /// terminator replaced by a space (LF, CRLF and CR are preserved verbatim
    /// so the scan keeps the input's line structure).
    static func blanked(
        _ characters: [Character],
        from: Int,
        to: Int
    ) -> [Character] {
        guard from < to else { return [] }
        return characters[from..<to].map { PinScan.isSwiftLineTerminator($0) ? $0 : " " }
    }

    /// Blanks `//` and nested `/* */` comments plus string interiors while
    /// preserving the UTF-16 length (LF units are kept), so UTF-16 regex match
    /// offsets and line numbers stay aligned with the source. Hash-prefix
    /// aware: `#"…"#`, `##"…"##`, … close only on `"` + the same number of
    /// `#`. This is R3, the scanner behind the declared-test attribution walk
    /// in `WorkflowShardSplitPinsTests`, whose consumers index the result with
    /// `NSRange`/UTF-16 offsets.
    ///
    /// The literal end (issue #455) uses the delimiter's exact hash count for
    /// a raw interpolation escape (`\#(` for `#"…"#`, `\##(` for `##"…"##`)
    /// and skips the interpolation body with a bracket stack that looks through
    /// nested string literals and `//`/nested `/* … */` comments, so a nested
    /// `"`, `(` or `)` cannot exit the literal early. Blanking is per UTF-16
    /// unit with LF units kept, so the output's length always matches.
    static func strippingCommentsAndStringsPreservingUTF16(_ source: String) -> String {
        let units = Array(source.utf16)
        let slash: UInt16 = 0x2F
        let star: UInt16 = 0x2A
        let newline: UInt16 = 0x0A
        let carriageReturn: UInt16 = 0x0D
        let space: UInt16 = 0x20
        var result: [UInt16] = []
        result.reserveCapacity(units.count)
        var index = 0
        var inLineComment = false
        var blockDepth = 0
        while index < units.count {
            let unit = units[index]
            if inLineComment {
                if unit == newline {
                    inLineComment = false
                    result.append(unit)
                } else if unit == carriageReturn {
                    // A lone CR ends the comment like LF does; Swift keeps a
                    // comment open through U+2028/U+2029 but not through CR.
                    inLineComment = false
                    result.append(space)
                } else {
                    result.append(space)
                }
                index += 1
                continue
            }
            if blockDepth > 0 {
                if unit == slash, index + 1 < units.count, units[index + 1] == star {
                    blockDepth += 1
                    result.append(space)
                    result.append(space)
                    index += 2
                } else if unit == star, index + 1 < units.count, units[index + 1] == slash {
                    blockDepth -= 1
                    result.append(space)
                    result.append(space)
                    index += 2
                } else {
                    result.append(unit == newline ? newline : space)
                    index += 1
                }
                continue
            }
            if unit == slash, index + 1 < units.count, units[index + 1] == slash {
                inLineComment = true
                result.append(space)
                result.append(space)
                index += 2
                continue
            }
            if unit == slash, index + 1 < units.count, units[index + 1] == star {
                blockDepth = 1
                result.append(space)
                result.append(space)
                index += 2
                continue
            }
            if unit == 0x22 || unit == 0x23 {
                if let end = stringLiteralEnd(in: units, at: index) {
                    var cursor = index
                    while cursor < end {
                        result.append(units[cursor] == newline ? newline : space)
                        cursor += 1
                    }
                    index = end
                    continue
                }
            }
            result.append(unit)
            index += 1
        }
        return String(decoding: result, as: UTF16.self)
    }

    /// End (exclusive UTF-16 offset) of the string literal opening at `start`
    /// (a `"` or the first `#` of a raw prefix), or nil when `start` opens no
    /// literal. A non-raw `\` escapes the next unit; an interpolation escape
    /// must carry the delimiter's exact hash count (`\(`, `\#(`, `\##(`), and
    /// its body is skipped with `interpolationClose` so nested strings and
    /// comments cannot terminate the literal. Unterminated literals run to EOF,
    /// which fails the count closed.
    static func stringLiteralEnd(in units: [UInt16], at start: Int) -> Int? {
        let hash: UInt16 = 0x23
        let quote: UInt16 = 0x22
        let backslash: UInt16 = 0x5C
        let parenOpen: UInt16 = 0x28
        var cursor = start
        var hashes = 0
        while cursor < units.count, units[cursor] == hash {
            hashes += 1
            cursor += 1
        }
        guard cursor < units.count, units[cursor] == quote else { return nil }
        let triple = cursor + 2 < units.count
            && units[cursor + 1] == quote
            && units[cursor + 2] == quote
        var index = cursor + (triple ? 3 : 1)
        while index < units.count {
            if units[index] == backslash {
                var escapeIndex = index + 1
                var escapeHashes = 0
                while escapeIndex < units.count, escapeHashes < hashes, units[escapeIndex] == hash {
                    escapeHashes += 1
                    escapeIndex += 1
                }
                if escapeHashes == hashes, escapeIndex < units.count, units[escapeIndex] == parenOpen {
                    guard let close = interpolationClose(in: units, from: escapeIndex + 1) else {
                        return units.count
                    }
                    index = close + 1
                    continue
                }
                if hashes == 0 {
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if units[index] == quote {
                if triple {
                    if index + 2 < units.count,
                       units[index + 1] == quote,
                       units[index + 2] == quote,
                       matchesHashSuffix(units, at: index + 3, count: hashes) {
                        return index + 3 + hashes
                    }
                } else if matchesHashSuffix(units, at: index + 1, count: hashes) {
                    return index + 1 + hashes
                }
            }
            index += 1
        }
        return units.count
    }

    /// The index of the `)` matching the interpolation whose body starts at
    /// `start`, or nil when it never closes. Nested brackets are tracked, and
    /// a string literal or `//`/nested `/* … */` comment inside the body is
    /// skipped wholesale, so a `"`, `(` or `)` there cannot close the outer
    /// interpolation. Mirrors `PinScanCensus.interpolationClose`.
    static func interpolationClose(in units: [UInt16], from start: Int) -> Int? {
        let slash: UInt16 = 0x2F
        let star: UInt16 = 0x2A
        let newline: UInt16 = 0x0A
        let carriageReturn: UInt16 = 0x0D
        var depth = 0
        var index = start
        while index < units.count {
            let unit = units[index]
            if unit == slash, index + 1 < units.count, units[index + 1] == slash {
                index += 2
                while index < units.count, units[index] != newline, units[index] != carriageReturn {
                    index += 1
                }
                continue
            }
            if unit == slash, index + 1 < units.count, units[index + 1] == star {
                var blockDepth = 1
                index += 2
                while index < units.count, blockDepth > 0 {
                    if units[index] == slash, index + 1 < units.count, units[index + 1] == star {
                        blockDepth += 1
                        index += 2
                    } else if units[index] == star, index + 1 < units.count, units[index + 1] == slash {
                        blockDepth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                }
                if blockDepth > 0 { return nil }
                continue
            }
            if unit == 0x28 || unit == 0x5B || unit == 0x7B {
                depth += 1
                index += 1
            } else if unit == 0x29 {
                if depth == 0 { return index }
                depth -= 1
                index += 1
            } else if unit == 0x5D || unit == 0x7D {
                if depth > 0 { depth -= 1 }
                index += 1
            } else if unit == 0x22 || unit == 0x23 {
                if let end = stringLiteralEnd(in: units, at: index) {
                    index = end
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return nil
    }

    static func matchesHashSuffix(_ units: [UInt16], at index: Int, count: Int) -> Bool {
        guard count > 0 else { return true }
        guard index + count <= units.count else { return false }
        for offset in 0..<count where units[index + offset] != 0x23 {
            return false
        }
        return true
    }
}
