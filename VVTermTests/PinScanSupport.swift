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
//  `PinScan.strippingComments(_:)` is the canonical hash-unaware scanner; it
//  covers `"…"`, `"""…"""`, and `\` escapes, but not raw strings (`#"…"#`) or
//  comments inside an interpolation. The hash/interpolation-aware scanner in
//  `SSH/SSHProbeShellPinsTests.swift` deliberately stays local for that reason
//  (it is allowlisted by `PinScanCensusPinsTests`).

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
    /// comments and nested `/* … */` block comments become spaces; newlines are
    /// preserved, so slice anchors still resolve. String contents are copied
    /// verbatim (so a `//` inside a literal is not read as a comment); the
    /// scanner covers `"…"` (with `\` escapes) and `"""…"""` but not raw
    /// strings (`#"…"#`) or comments inside an interpolation.
    static func strippingComments(_ source: String) -> String {
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
                while index < characters.count, characters[index] != "\n" {
                    result.append(" ")
                    index += 1
                }
                continue
            }
            if character == "\n" {
                result.append("\n")
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
}
