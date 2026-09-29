// SPDX-License-Identifier: MIT
//
//  TeleportCredentialPairPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #296: the cert and its paired ed25519 private key
//  must be written as one atomic pair.
//
//  Why source pins: the pair's atomicity is a *shape* property (one
//  non-suspending body, key-first) rather than a value — the coordinator-level
//  T1 tests use a suspension-capable conformer. T4's injectable
//  keychain-write seam covers the pair body's failure propagation, but it
//  *replaces* the real `SecItem*` body: pin 4 guards the production writer
//  (update-first, non-destructive), and the behavioural test in
//  `TeleportCredentialStoreTests` (`realPairWriteUpdatesTheSeededKeychainItemInPlace`)
//  measures it against a seeded keychain item. These pins are the structural
//  tripwires over the production files.
//
//  FORMATTING HEURISTIC, NOT A PROOF: a pin is defeated by a rename, an alias,
//  a hoisted helper, a multi-line call, or a call inside a string literal.
//  Every pin here is a tripwire for the regression shape, not proof of the
//  discipline. Comments are stripped before every scan, so a commented-out
//  call cannot satisfy (or trip) an assertion; a call inside a string literal
//  still can. The file-wide `count == 1` asserts deliberately make a *new*
//  pair call site red: a second owner must update the pin on purpose.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scans at a
//  mutated tree (measured per pin in the #296 PR report). NOTE: the variable
//  must actually reach the test process. Measured on this runner (2026-09-29,
//  iOS Simulator destination): a plain env var is inert, while exporting
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` into xcodebuild's own
//  environment reaches the test process. Never set in CI.
//

#if DEBUG
import Foundation
import Testing

@testable import VVTerm

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

    /// Pin 1: both coordinators make exactly one `storeCredentialPair(` call
    /// and zero `storeLoginCert(` / `storeBootstrapCert(` /
    /// `storeEd25519PrivateKey(` calls. The single writes stay on the protocol
    /// as seed/test primitives, but no coordinator may call them: the
    /// two-call shape is the #296 tear.
    @Test
    func testCoordinatorsWriteOnlyTheAtomicPair() throws {
        let coordinatorPaths = [
            "VVTerm/Features/Teleport/Application/TeleportLoginCoordinator.swift",
            "VVTerm/Features/Teleport/Application/TeleportBootstrapCoordinator.swift",
        ]
        for path in coordinatorPaths {
            let text = Self.strippingComments(try source(path))

            // Positive control: the coordinator still drives the pair seam,
            // and it is the keyring call (not a local wrapper).
            let pairCalls = Self.occurrences(of: "storeCredentialPair(", in: text)
            #expect(pairCalls.count == 1, "\(path) must make exactly one storeCredentialPair( call")
            #expect(text.contains("keyRing.storeCredentialPair("), "\(path) must call the keyRing's pair witness")

            #expect(Self.occurrences(of: "storeLoginCert(", in: text).isEmpty, "\(path) must not call storeLoginCert(")
            #expect(Self.occurrences(of: "storeBootstrapCert(", in: text).isEmpty, "\(path) must not call storeBootstrapCert(")
            #expect(Self.occurrences(of: "storeEd25519PrivateKey(", in: text).isEmpty, "\(path) must not call storeEd25519PrivateKey(")
        }
    }

    /// Pin 2: `TeleportKeyRing.storeCredentialPair` is a non-`async` `throws`
    /// witness whose body suspends nowhere (`await`-free — an absent body
    /// fails the pin, never passes vacuously) and writes the keychain before
    /// committing the record.
    @Test
    func testKeyRingPairBodyIsSynchronousKeyFirstAndNonAsync() throws {
        let text = Self.strippingComments(try source("VVTerm/Features/Teleport/Application/TeleportKeyRing.swift"))

        let declaration = try #require(
            text.range(of: "func storeCredentialPair("),
            "TeleportKeyRing must keep the pair witness"
        )
        let openBrace = try #require(
            text[declaration.upperBound...].firstIndex(of: "{"),
            "the pair declaration must open a body"
        )
        let declarationTail = text[declaration.upperBound..<openBrace]
        #expect(
            !declarationTail.contains("async"),
            "the pair witness must be non-async (the adapter's one-hop MainActor.run depends on it)"
        )
        #expect(declarationTail.contains("throws"), "the pair witness must throw")

        // `bracedBlock` throws when the body is absent/unbalanced, so the
        // no-await assert below cannot pass vacuously.
        let body = try Self.bracedBlock(openingAt: openBrace, in: text)
        #expect(!text[body].contains("await"), "the keyring pair body must suspend nowhere")

        // Positive control: the resolved span is the pair body, not a nested
        // block — it commits the record and saves it.
        #expect(text[body].contains("credentials[clusterId] = cred"), "the resolved span must be the pair body")
        #expect(text[body].contains("save()"), "the resolved span must save the record")

        // Key-first ordering: the keychain write precedes the record commit,
        // so a failed key write cannot leave the record pointing at a cert
        // whose key is gone. G2: exact-occurrence counts first, so a
        // duplicated write/commit inside the body reddens the pin instead of
        // silently satisfying the first-match range below.
        #expect(
            Self.occurrences(of: "keychainWriter(privateKeyPEM", in: text, range: body).count == 1,
            "the pair body must write the key exactly once"
        )
        #expect(
            Self.occurrences(of: "credentials[clusterId] = cred", in: text, range: body).count == 1,
            "the pair body must commit the record exactly once"
        )
        // G7: the commit's certValidBefore assignment is part of the pair
        // shape — a record committed without it points at a cert whose
        // validity is unknown.
        #expect(
            text[body].contains("cred.certValidBefore = validBefore"),
            "the record commit must write the cert's validBefore"
        )
        let keyWrite = try #require(
            text.range(of: "keychainWriter(privateKeyPEM", range: body),
            "the pair body must write the key through the keychain seam"
        )
        let recordCommit = try #require(
            text.range(of: "credentials[clusterId] = cred", range: body),
            "the pair body must commit the record"
        )
        #expect(
            keyWrite.lowerBound < recordCommit.lowerBound,
            "the key write must precede the record commit"
        )
    }

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

    /// Pin 4 (F2): the real ed25519 keychain write is `SecItemUpdate`-first and
    /// never deletes the prior item. Body-scoped because `clear()` (same file)
    /// also contains `SecItemDelete(`, and every writer failure must be
    /// fail-closed (throw) rather than destructive.
    ///
    /// Defeat list (same as the other pins): a rename, an alias, a hoisted
    /// helper, a multi-line call, or a call inside a string literal defeats the
    /// token scan. Counterfactual hook: `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT`
    /// (see the file header).
    @Test
    func testKeyRingRealKeychainWriteIsUpdateFirstAndNonDestructive() throws {
        let text = Self.strippingComments(try source("VVTerm/Features/Teleport/Application/TeleportKeyRing.swift"))

        let declaration = try #require(
            text.range(of: "private static func writeEd25519PrivateKeyToKeychain("),
            "TeleportKeyRing must keep the real ed25519 keychain writer"
        )
        let body = try Self.bracedBlock(after: declaration, in: text)

        // Positive controls: the resolved span is the writer body, not a
        // nested block or the wrong declaration.
        #expect(text[body].contains("kSecClassGenericPassword"), "the resolved span must be the keychain writer body")
        #expect(text[body].contains("TeleportPackageError.keychain("), "the resolved span must be the writer's throw path")

        #expect(
            !text[body].contains("SecItemDelete("),
            "the ed25519 write must never delete the prior item (clear()'s delete is outside this body)"
        )
        #expect(text[body].contains("SecItemUpdate("), "the update-first shape is the non-destructive property")

        let notFound = try #require(
            text.range(of: "case errSecItemNotFound", range: body),
            "the add must be gated on the update's not-found status"
        )
        let add = try #require(
            text.range(of: "SecItemAdd(", range: body),
            "the writer must add only when no item exists"
        )
        #expect(
            notFound.lowerBound < add.lowerBound,
            "the SecItemAdd( must come after the case errSecItemNotFound gate"
        )
        #expect(
            Self.occurrences(of: "SecItemAdd(", in: text, range: body).count == 1,
            "the writer must add the item exactly once"
        )
        #expect(
            Self.occurrences(of: "SecItemUpdate(", in: text, range: body).count == 1,
            "the writer must update the item exactly once (no delete/retry loop)"
        )
    }
}

#endif
