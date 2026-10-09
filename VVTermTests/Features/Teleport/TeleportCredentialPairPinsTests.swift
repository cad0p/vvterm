// SPDX-License-Identifier: MIT
//
//  TeleportCredentialPairPinsTests.swift
//  VVTermTests
//
//  The host-side pin for the atomic credential-pair write (#296): the host
//  adapter's `storeCredentialPair` body must keep exactly one `MainActor.run`
//  hop and call the keyring's pair witness — never the two singles, which
//  would reintroduce the tear inside the hop.
//
//  The package owns the other #296 pins (the coordinators' single pair call
//  and the keyring's synchronous, key-first, non-destructive body): they read
//  `swift-teleport` sources and live in the package's
//  `Tests/TeleportPackageTests/TeleportCredentialPairPinsTests.swift`.
//
//  See:
//    - VVTerm/Core/Teleport/TeleportKeyRingCredentialStore.swift (the subject)
//    - VVTermTests/Features/Teleport/TeleportCredentialStoreTests.swift (the
//      behavioural pair-write coverage)
//

#if DEBUG
import Foundation
import Testing
import TeleportCore
import TeleportAuth
@testable import VVTerm

@MainActor
struct TeleportCredentialPairPinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/Features/Teleport/TeleportCredentialPairPinsTests.swift`).
    private func repositoryRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportCredentialPairPinsTests.swift
            .deletingLastPathComponent()  // Teleport/
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

    /// The body span `{ … }` of the brace-delimited block that opens at `open`,
    /// found by a character-level depth walk.
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
    /// it opens: `bracedBlock` binds the first `{` after the anchor, so an
    /// anchor that already contains the opening brace skips the intended block
    /// and binds its first nested block instead. A mis-slice cannot pass
    /// vacuously: an absent block fails the `#require` here, and the
    /// containment asserts it feeds fail when a pinned token sits outside.
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

    /// Every occurrence of `needle` in `text` (optionally within `range`), in
    /// source order.
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

    // MARK: - Pins

    /// Pin 3: the adapter's pair body is one `MainActor.run` hop that calls the
    /// keyring's pair witness — never the two singles (which would reintroduce
    /// the tear inside the hop).
    @Test
    func testAdapterPairBodyKeepsOneMainActorHop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/Teleport/TeleportKeyRingCredentialStore.swift"))

        let declaration = try #require(
            text.range(of: "func storeCredentialPair("),
            "the adapter must implement the pair witness"
        )
        let body = try Self.bracedBlock(after: declaration, in: text)

        // Positive control: the resolved span is the pair body that calls the
        // keyring's pair witness.
        #expect(text[body].contains("storeCredentialPair("), "the resolved span must be the adapter's pair body")
        #expect(
            Self.occurrences(of: "MainActor.run", in: text, range: body).count == 1,
            "the adapter's pair body must keep exactly one MainActor.run hop"
        )
        #expect(Self.occurrences(of: "storeLoginCert(", in: text, range: body).isEmpty)
        #expect(Self.occurrences(of: "storeBootstrapCert(", in: text, range: body).isEmpty)
        #expect(Self.occurrences(of: "storeEd25519PrivateKey(", in: text, range: body).isEmpty)
    }

}

#endif
