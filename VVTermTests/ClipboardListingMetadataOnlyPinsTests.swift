// SPDX-License-Identifier: MIT
//
//  ClipboardListingMetadataOnlyPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #431: `Clipboard.availableMimeTypes()` must stay
//  metadata-only in both platform arms. The pin locks the listing helper's
//  own text against data reads; the mode-5522 listing guarantee itself rests
//  on the core's zero-mime `.list` contract (`src/apprt/embedded.zig:757-759`)
//  plus `clipboard-read = deny` for kitty lists. No runtime test can prove
//  "no pasteboard provider was poked" (the iOS Simulator unit job cannot even
//  bind the macOS pasteboard, and a read is only observable through provider
//  side effects).
//
//    A1  the macOS listing body (brace-balanced, comments stripped) contains
//        none of the pasteboard read spellings (`data(forType:`,
//        `string(forType:`, `propertyList(forType:`, `readObjects(`,
//        `pasteboardItems`) and none of the internal read helpers
//        (`readString()`, `snapshot(`, `data(forMime:)`).
//    A2  the iOS listing body contains none of the iOS read spellings
//        (`.string`, `.data(forPasteboardType:`, `.image`, `.items`) and none
//        of the internal read helpers.
//    A3  exactly two `availableMimeTypes` definitions exist, exactly one per
//        platform region (`#if os(macOS)` / `#else` / `#endif`), so a
//        first-match slice cannot silently pin one arm when the other moves.
//    B1  the read callback goes through `Clipboard.data(forMime:)` via
//        `ClipboardMimeSelection.select` and does not call
//        `Clipboard.readString()` directly.
//    B2  the read callback body contains no `"text/plain"` string literal at
//        all, so neither a re-added guard (`==`/`!=`) nor a filter can
//        re-introduce the text/plain-only read semantics.
//
//  FORMATTING HEURISTIC, NOT A PROOF: this file parses Swift as text. The
//  listing body is extracted by the first `{` after the definition token and
//  naive brace balancing; a brace inside a string literal in that body would
//  mis-slice it (comments are stripped first, so a comment-embedded decoy is
//  not code).
//
//  Measured counterfactual battery (2026-10-12, `VVTERM_PINS_SOURCE_ROOT`
//  mutant trees; the fold round re-ran all 10 mutants through a standalone
//  SwiftTesting runner because the xcodebuild harness wedged before `Testing
//  started`, and the #431 walk records each mutant's verdict and failing
//  assertion; its rc column is derived from the runner's exit status):
//    - macOS read in the listing (`data(forType:`)        -> red, A1
//    - iOS `.string` read in the listing                   -> red, A2
//    - comment-only token + benign local rename            -> green
//    - helper call via a banned token (`data(forMime:`)    -> red, A1
//    - innocuously named helper that reads                 -> green (named defeat)
//    - delete/rename an arm's definition                   -> red, A2 + A3
//    - arm order swapped                                   -> green
//    - legitimate provider `pasteboardItems`/`string(forType:`) -> green
//    - callback serves `Clipboard.readString()` again      -> red, B1
//    - callback re-adds a `text/plain`-only guard          -> red, B2
////
//  Honest defeat list:
//    - a read reached through a helper whose call token is not one of the
//      modelled spellings escapes A1/A2 (e.g. a new `listingMetadata()` helper
//      called by the listing and implemented elsewhere). The internal reads
//      ARE banned as call tokens, so the measured `Clipboard.data(forMime:`
//      helper mutant reds; an innocuously named helper does not. This is the
//      recorded residual: the pin locks the listing body's own text, not the
//      transitive call graph;
//    - the mode-5522 listing guarantee is not enforced by this pin beyond the
//      listing helper's text: the read callback computes `contents`
//      unconditionally before its `list` check (upstream's loop shape), so a
//      future core that passed mimes with `list = true` would read data
//      during a listing and every assertion here would stay green. The
//      zero-mime `.list` contract is the core's (`embedded.zig:757-759`), and
//      `clipboard-read = deny` suppresses kitty lists;
//    - the pin proves text, not runtime liveness; a callback that wraps the
//      provider in another function reds B1 only if the wrapper call replaces
//      the modelled spellings, which is exactly what B1 pins;
//    - B2 fails closed on the `"text/plain"` literal, so a re-added
//      `mime != "text/plain"` guard or a `contents.filter { $0.mime ==
//      "text/plain" }` filter is red as well; a guard that avoids the literal
//      entirely (e.g. via a shared constant) is the same class as the
//      helper-call defeat above and remains recorded residual;
//    - a string literal containing a read spelling (e.g. a log message) fails
//      A1/A2 conservatively — fail-closed, not an escape;
//    - a coherent edit of code plus this pin passes; update-on-purpose pins
//      cannot detect their own authorized update.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scan at a
//  mutated tree copy. The variable reaches the test process only as
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT` in xcodebuild's own environment
//  (a plain env var is inert on the simulator destination). Never set in CI.
//

import Foundation
import Testing
@testable import VVTerm

struct ClipboardListingMetadataOnlyPinsTests {

    private static let clipboardPath = "VVTerm/Core/Terminal/Clipboard.swift"
    private static let ghosttyAppPath = "VVTerm/GhosttyTerminal/Ghostty.App.swift"

    private static let listingDefinition = "static func availableMimeTypes() -> [String]"
    private static let readCallbackDefinition = "static func readClipboard("

    private static let macosListingForbidden = [
        "data(forType:",
        "string(forType:",
        "propertyList(forType:",
        "readObjects(",
        "pasteboardItems",
    ]

    private static let iosListingForbidden = [
        ".string",
        ".data(forPasteboardType:",
        ".image",
        ".items",
    ]

    private static let internalReadForbidden = [
        "readString()",
        "snapshot(",
        "data(forMime:",
    ]

    private enum PlatformArm: String {
        case macOS
        case iOS
    }

    @Test
    func testA1TheMacOSListingBodyReadsNothing() throws {
        let body = try Self.listingBody(for: .macOS)
        let found = Self.macosListingForbidden.filter { body.contains($0) }
        #expect(
            found.isEmpty,
            "the macOS availableMimeTypes body must only inspect declared pasteboard types; found read spellings \(found) — the mode-5522 listing guarantee is metadata-only (issue #431)"
        )
        let internalReads = Self.internalReadForbidden.filter { body.contains($0) }
        #expect(
            internalReads.isEmpty,
            "the macOS listing body must not call an internal read helper; found \(internalReads) (issue #431)"
        )
    }

    @Test
    func testA2TheIOSListingBodyReadsNothing() throws {
        let body = try Self.listingBody(for: .iOS)
        let found = Self.iosListingForbidden.filter { body.contains($0) }
        #expect(
            found.isEmpty,
            "the iOS availableMimeTypes body must only inspect declared pasteboard types; found read spellings \(found) — the mode-5522 listing guarantee is metadata-only (issue #431)"
        )
        let internalReads = Self.internalReadForbidden.filter { body.contains($0) }
        #expect(
            internalReads.isEmpty,
            "the iOS listing body must not call an internal read helper; found \(internalReads) (issue #431)"
        )
    }

    @Test
    func testA3ExactlyTwoListingDefinitionsOnePerPlatformRegion() throws {
        let source = Self.strippingComments(try Self.source(Self.clipboardPath))
        let total = Self.occurrences(of: Self.listingDefinition, in: source)
        #expect(
            total == 2,
            "exactly two `availableMimeTypes` definitions must exist (one per platform arm); found \(total) — re-derive this pin if an arm is added or renamed (issue #431)"
        )
        let macOSRegion = try Self.platformRegion(.macOS, in: source)
        let iosRegion = try Self.platformRegion(.iOS, in: source)
        #expect(
            Self.occurrences(of: Self.listingDefinition, in: macOSRegion) == 1,
            "the macOS region must hold exactly one `availableMimeTypes` definition (issue #431)"
        )
        #expect(
            Self.occurrences(of: Self.listingDefinition, in: iosRegion) == 1,
            "the iOS region must hold exactly one `availableMimeTypes` definition (issue #431)"
        )
    }

    @Test
    func testB1TheReadCallbackGoesThroughTheProvider() throws {
        let body = try Self.readCallbackBody()
        let providerCalls = Self.occurrences(of: "Clipboard.data(forMime:", in: body)
        #expect(
            providerCalls == 1,
            "the read callback must serve representations through `Clipboard.data(forMime:)` exactly once; found \(providerCalls) (issue #431)"
        )
        let selections = Self.occurrences(of: "ClipboardMimeSelection.select(", in: body)
        #expect(
            selections == 1,
            "the read callback must route the requested mimes through `ClipboardMimeSelection.select` exactly once; found \(selections) (issue #431)"
        )
        let directReads = Self.occurrences(of: "readString(", in: body)
        #expect(
            directReads == 0,
            "the read callback must not call `Clipboard.readString()` directly — the provider owns representation selection; found \(directReads) (issue #431)"
        )
    }

    @Test
    func testB2TheReadCallbackContainsNoTextPlainLiteral() throws {
        let body = try Self.readCallbackBody()
        let literals = Self.occurrences(of: "\"text/plain\"", in: body)
        #expect(
            literals == 0,
            "the read callback must contain no `\"text/plain\"` string literal — every requested mime goes through the provider, and any guard (`==`/`!=`) or filter spelling would re-add the text/plain-only semantics; found \(literals) (issue #431)"
        )
    }

    // MARK: - Source helpers

    private static func listingBody(for arm: PlatformArm) throws -> String {
        let source = Self.strippingComments(try Self.source(Self.clipboardPath))
        let region = try Self.platformRegion(arm, in: source)
        let bodies = Self.bracedBodies(after: Self.listingDefinition, in: region)
        guard bodies.count == 1 else {
            throw PinFailure(
                "expected exactly one `\(Self.listingDefinition)` in the \(arm.rawValue) region of \(Self.clipboardPath), found \(bodies.count) — re-derive this pin"
            )
        }
        return bodies[0]
    }

    private static func readCallbackBody() throws -> String {
        let source = Self.strippingComments(try Self.source(Self.ghosttyAppPath))
        let bodies = Self.bracedBodies(after: Self.readCallbackDefinition, in: source)
        guard bodies.count == 1 else {
            throw PinFailure(
                "expected exactly one `\(Self.readCallbackDefinition)` in \(Self.ghosttyAppPath), found \(bodies.count) — re-derive this pin"
            )
        }
        return bodies[0]
    }

    /// The `#if os(macOS)` … `#else` … `#endif` region split of
    /// `Clipboard.swift`. The file must keep exactly one of each marker, so
    /// the split cannot silently pin the wrong arm.
    private static func platformRegion(_ arm: PlatformArm, in source: String) throws -> String {
        for marker in ["#if os(macOS)", "#else", "#endif"] {
            let count = Self.occurrences(of: marker, in: source)
            guard count == 1 else {
                throw PinFailure(
                    "expected exactly one `\(marker)` in \(Self.clipboardPath), found \(count) — re-derive this pin"
                )
            }
        }
        let macOSStart = try Self.requireRange(of: "#if os(macOS)", in: source).upperBound
        let elseRange = try Self.requireRange(of: "#else", in: source)
        switch arm {
        case .macOS:
            return String(source[macOSStart..<elseRange.lowerBound])
        case .iOS:
            let endRange = try Self.requireRange(of: "#endif", in: source, after: elseRange.upperBound)
            return String(source[elseRange.upperBound..<endRange.lowerBound])
        }
    }

    /// The body span `{ … }` of every brace-delimited block that opens at the
    /// first `{` after `token`, in text order. Used for the listing bodies and
    /// the read callback; nested braces balance normally.
    private static func bracedBodies(after token: String, in text: String) -> [String] {
        var bodies: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: token, range: searchStart..<text.endIndex) {
            searchStart = range.upperBound
            guard let open = text[range.upperBound...].firstIndex(of: "{") else { continue }
            var depth = 0
            var index = open
            var closed = false
            while index < text.endIndex {
                let character = text[index]
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        closed = true
                        break
                    }
                }
                index = text.index(after: index)
            }
            guard closed else { continue }
            let end = text.index(after: index)
            bodies.append(String(text[open..<end]))
        }
        return bodies
    }

    private static func requireRange(
        of token: String,
        in source: String,
        after start: String.Index? = nil
    ) throws -> Range<String.Index> {
        guard let range = source.range(of: token, range: (start ?? source.startIndex)..<source.endIndex) else {
            throw PinFailure("`\(token)` not found in the scanned source — re-derive this pin")
        }
        return range
    }

    private static func occurrences(of token: String, in text: String) -> Int {
        text.components(separatedBy: token).count - 1
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = try repositoryRoot().appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PinFailure("could not read \(relativePath) at \(url.path): \(error)")
        }
    }

    private static func repositoryRoot() throws -> URL {
        // Counterfactual hook: the battery runs point this at a copy of the
        // scanned sources. The measured-working form is
        // `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` exported into
        // xcodebuild's own environment (the `TEST_RUNNER_` prefix is consumed
        // by the test runner and forwarded without it).
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("VVTerm.xcodeproj").path
            ) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw PinFailure(
            "could not locate the repository root (no VVTerm.xcodeproj above \(#filePath)) — re-derive this pin"
        )
    }

    /// A comment-stripped copy of `source`: characters inside `//` line
    /// comments and nested `/* … */` block comments become spaces; newlines
    /// are preserved, so slice anchors still resolve. String contents are
    /// copied verbatim. Duplicated from the merged pin suites so each family's
    /// pin file is self-contained and reverts independently.
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

}
