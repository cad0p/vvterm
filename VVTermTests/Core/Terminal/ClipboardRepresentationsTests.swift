// SPDX-License-Identifier: MIT
//
//  ClipboardRepresentationsTests.swift
//  VVTermTests
//
//  #431 unit coverage for the platform-neutral clipboard representation seam
//  (`VVTerm/Core/Terminal/ClipboardRepresentations.swift`): mime selection
//  (dedupe, unservable skip, caller order), the upstream path escape (the
//  22-character table, single-pass, newline pass-through), the opinionated
//  `text/plain` composition including the `isFileURL` filter, the RFC 2483
//  URI list bytes, and the MIME → pasteboard-identifier mapping.
//
//  These tests execute on the iOS Simulator, so every neutral arm an
//  embedder can reach is executed coverage rather than a macOS-only claim.
//  The macOS provider's own oracle suite is
//  `ClipboardRepresentationsMacOSTests.swift` (macOS destination).
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VVTerm

struct ClipboardRepresentationsTests {

    // MARK: - ClipboardMimeSelection

    @Test
    func mimeSelectionKeepsRequestOrderAndSkipsUnservable() {
        var probed: [String] = []
        let served = ClipboardMimeSelection.select(
            requested: ["text/uri-list", "text/plain", "image/png", "text/plain"],
            data: { mime in
                probed.append(mime)
                switch mime {
                case "text/plain": return Data("plain".utf8)
                case "image/png": return Data([0x89, 0x50, 0x4E, 0x47])
                default: return nil
                }
            }
        )

        #expect(
            probed == ["text/uri-list", "text/plain", "image/png"],
            "the provider must be asked once per unique requested mime, in request order"
        )
        #expect(served == [
            ClipboardRepresentation(mime: "text/plain", data: Data("plain".utf8)),
            ClipboardRepresentation(mime: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47])),
        ], "selection must drop unservable mimes, dedupe, and keep the caller's order")
    }

    @Test
    func mimeSelectionReturnsEmptyForAnEmptyRequest() {
        let served = ClipboardMimeSelection.select(requested: []) { _ in Data("never".utf8) }
        #expect(served.isEmpty, "an empty request must yield no representations")
    }

    // MARK: - ClipboardPathEscape

    @Test
    func pathEscapeSetIsTheExactUpstreamTwentyTwoCharactersInWrittenOrder() {
        #expect(
            ClipboardPathEscape.escapeCharacters == "\\ ()[]{}<>\"'`!#$&;|*?\t",
            "the escape set is upstream's, backslash first — a reordered or pruned set changes which characters are escaped"
        )
        #expect(ClipboardPathEscape.escapeCharacters.count == 22, "upstream's set has 22 characters")
    }

    @Test
    func pathEscapeEscapesEveryCharacterInTheSetExactly() {
        let characters = [
            "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'",
            "`", "!", "#", "$", "&", ";", "|", "*", "?", "\t",
        ]
        #expect(characters.count == 22)
        for character in characters {
            #expect(
                ClipboardPathEscape.escaped(character) == "\\" + character,
                "every escape-set character must be backslash-prefixed: \(character.debugDescription)"
            )
        }
    }

    @Test
    func pathEscapeIsSinglePassAndNeverDoubleEscapesInsertedBackslashes() {
        #expect(
            ClipboardPathEscape.escaped("/tmp/a\\b c") == "/tmp/a\\\\b\\ c",
            "a literal backslash is escaped exactly once; the inserted backslashes are not re-escaped"
        )
        #expect(
            ClipboardPathEscape.escaped("\\ ") == "\\\\\\ ",
            "backslash first means the inserted backslash before the space is not revisited by the backslash pass"
        )

        let allCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"
        let expected = allCharacters.map { "\\" + String($0) }.joined()
        #expect(
            ClipboardPathEscape.escaped(allCharacters) == expected,
            "a multi-character control: every set character escaped once, no double escaping"
        )
    }

    @Test
    func pathEscapeLeavesNewlinesAndUnsafeFreePathsUnchanged() {
        #expect(
            ClipboardPathEscape.escaped("a\nb") == "a\nb",
            "newline is not in the set — the core's unsafe-paste check and the #327 prompt own newline safety"
        )
        #expect(ClipboardPathEscape.escaped("/usr/local/bin") == "/usr/local/bin")
        #expect(ClipboardPathEscape.escaped("") == "")
    }

    // MARK: - ClipboardOpinionatedText

    @Test
    func opinionatedTextComposesFileURLsAsEscapedPaths() {
        let url = URL(fileURLWithPath: "/tmp/a b(c)/file.txt")
        #expect(
            ClipboardOpinionatedText.compose([.fileURL(url)]) == "/tmp/a\\ b\\(c\\)/file.txt"
        )
        #expect(
            ClipboardOpinionatedText.compose([.fileURL(url), .text("plain")]) == "/tmp/a\\ b\\(c\\)/file.txt plain",
            "multiple elements are joined by a single space"
        )
    }

    @Test
    func opinionatedTextKeepsEmptyStringsAndDropsNilElements() {
        #expect(
            ClipboardOpinionatedText.compose([.text("")]) == "",
            "an empty-string element is a servable empty representation, not a missing one"
        )
        #expect(ClipboardOpinionatedText.compose([.text(nil)]) == nil)
        #expect(
            ClipboardOpinionatedText.compose([.fileURL(URL(fileURLWithPath: "/a")), .text(nil)]) == "/a",
            "a nil element before/after a servable one is dropped"
        )
        #expect(ClipboardOpinionatedText.compose([.text("one"), .text(nil), .text("two")]) == "one two")
        #expect(ClipboardOpinionatedText.compose([]) == nil, "nil only for an empty element list")
    }

    @Test
    func opinionatedItemClassificationAppliesTheFileURLFilter() {
        let fileURL = URL(fileURLWithPath: "/tmp/a b")
        #expect(ClipboardOpinionatedItem.classify(decodedURL: fileURL, plainString: "plain") == .fileURL(fileURL))
        #expect(ClipboardOpinionatedItem.classify(decodedURL: nil, plainString: "plain") == .text("plain"))
        #expect(ClipboardOpinionatedItem.classify(decodedURL: nil, plainString: nil) == .text(nil))

        // M1: a `.fileURL` property list that decodes to a non-file URL must
        // fall through to the string, never be escaped as a path.
        let nonFileURL = URL(string: "https://example.com/a%20b.txt")!
        let item = ClipboardOpinionatedItem.classify(decodedURL: nonFileURL, plainString: "https://example.com/a b.txt")
        #expect(item == .text("https://example.com/a b.txt"))
        #expect(
            ClipboardOpinionatedText.compose([item]) == "https://example.com/a b.txt",
            "the non-file URL must not be escaped as a filesystem path"
        )
    }

    // MARK: - ClipboardURIList

    @Test
    func uriListEncodesFileURLsAsAbsoluteStringCRLF() {
        let one = URL(fileURLWithPath: "/tmp/one.txt")
        let two = URL(fileURLWithPath: "/tmp/two.txt")

        let single = ClipboardURIList.encode([one])
        #expect(single == Data("\(one.absoluteString)\r\n".utf8))
        let bytes = [UInt8](single)
        #expect(bytes.suffix(2) == [0x0D, 0x0A], "the RFC 2483 separator is exactly CRLF")

        let pair = ClipboardURIList.encode([one, two])
        #expect(pair == Data("\(one.absoluteString)\r\n\(two.absoluteString)\r\n".utf8))
        #expect(ClipboardURIList.encode([]) == Data())
    }

    // MARK: - ClipboardMimeMapping

    @Test
    func mimeMappingPinsTextPlainAndResolvesUTTypes() {
        #expect(
            ClipboardMimeMapping.pasteboardTypeIdentifier(forMime: "text/plain") == "public.utf8-plain-text",
            "text/plain pins to AppKit's `.string` identifier, not UTType(mimeType:)'s public.plain-text"
        )
        #expect(
            ClipboardMimeMapping.pasteboardTypeIdentifier(forMime: "text/plain") == UTType.utf8PlainText.identifier
        )
        #expect(
            ClipboardMimeMapping.pasteboardTypeIdentifier(forMime: "image/png") == UTType(mimeType: "image/png")!.identifier
        )
        #expect(
            ClipboardMimeMapping.pasteboardTypeIdentifier(forMime: "not a mime") == "not a mime",
            "a structurally invalid mime gets no UTType and falls back to itself"
        )
    }
}
