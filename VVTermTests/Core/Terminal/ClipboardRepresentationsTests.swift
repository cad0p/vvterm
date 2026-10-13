// SPDX-License-Identifier: MIT
//
//  ClipboardRepresentationsTests.swift
//  VVTermTests
//
//  #431 unit coverage for the platform-neutral clipboard representation seam
//  (`VVTerm/Core/Terminal/ClipboardRepresentations.swift`): mime selection
//  (dedupe, unservable skip, caller order), the path escape (the 23-character
//  table — upstream's 22 plus the local CR divergence — single-pass, the
//  odd-backslash CR guard, newline pass-through), the opinionated
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
#if os(iOS)
import UIKit
#endif
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
    func pathEscapeSetIsUpstreamTwentyTwoPlusLocalCRInWrittenOrder() {
        #expect(
            ClipboardPathEscape.escapeCharacters == "\\ ()[]{}<>\"'`!#$&;|*?\t\r",
            "the set is upstream's 22 characters in written order plus a deliberate local CR at the end — a reordered or pruned set changes which characters are escaped"
        )
        #expect(
            ClipboardPathEscape.escapeCharacters.count == 23,
            "upstream's set has 22 characters; the local CR divergence (issue #438) makes 23"
        )
    }

    @Test
    func pathEscapeEscapesEveryCharacterInTheSetExactly() {
        let characters = [
            "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'",
            "`", "!", "#", "$", "&", ";", "|", "*", "?", "\t", "\r",
        ]
        #expect(characters.count == 23)
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
        #expect(
            ClipboardPathEscape.escaped("\\\r") == "\\\\\\\r",
            "CR is after `\\` in the set, so the extra guard backslash is inserted by the CR pass and never doubled by the backslash pass — the case that pins CR's position after `\\`"
        )

        let allCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t\r"
        let expected = allCharacters.map { "\\" + String($0) }.joined()
        #expect(
            ClipboardPathEscape.escaped(allCharacters) == expected,
            "a multi-character control: every set character escaped once, no double escaping"
        )
    }

    /// #438: escaping does not remove the CR — it backslash-guards it, so the
    /// invariant is guard parity: at every CR in the output, the run of
    /// backslashes immediately before it has odd length. A "contains no CR"
    /// assertion would be false by design and would pin the wrong mechanism.
    @Test
    func pathEscapeEscapesCarriageReturnAsABackslashGuard() {
        #expect(
            ClipboardPathEscape.escaped("/tmp/a\rb") == "/tmp/a\\\rb",
            "a CR in a copied path is escaped as `\\`+CR, not left bare (the #438 divergence)"
        )
        #expect(
            ClipboardPathEscape.escaped("\r") == "\\\r",
            "a lone CR is guarded too"
        )
    }

    @Test
    func pathEscapeGuardsEveryCarriageReturnWithAnOddBackslashCount() {
        let samples = [
            "/tmp/a\rb",
            "\r",
            "\r\r",
            "a\tb\rc",
            "x\\\rz",
            "x\\\\\rz",
            "/tmp/dir with space/na\rme",
        ]
        for sample in samples {
            let escaped = ClipboardPathEscape.escaped(sample)
            let characters = Array(escaped)
            for index in characters.indices where characters[index] == "\r" {
                var guardCount = 0
                var cursor = index - 1
                while cursor >= 0, characters[cursor] == "\\" {
                    guardCount += 1
                    cursor -= 1
                }
                #expect(
                    guardCount % 2 == 1,
                    "every CR in the escaped output must be guarded by an odd number of backslashes; \(sample.debugDescription) escaped to \(escaped.debugDescription) with \(guardCount)"
                )
            }
        }
        #expect(
            ClipboardPathEscape.escaped("/tmp/a\rb").contains("\r"),
            "positive control: the escape guards the CR rather than removing it"
        )
    }

    @Test
    func pathEscapeLeavesNewlinesAndUnsafeFreePathsUnchanged() {
        #expect(
            ClipboardPathEscape.escaped("a\nb") == "a\nb",
            "newline is not in the set — an unbracketed LF paste trips the core's unsafe-paste check and the #327 prompt; bracketed LF pastes are framed and treated as safe by default"
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

        // #438: the CR divergence must show up in the composed representation
        // the core actually serves, single-item and in the multi-item join.
        let crURL = URL(fileURLWithPath: "/tmp/a\rb")
        #expect(
            ClipboardOpinionatedText.compose([.fileURL(crURL)]) == "/tmp/a\\\rb",
            "a copied path with CR composes as the backslash-guarded form"
        )
        #expect(
            ClipboardOpinionatedText.compose([.fileURL(crURL), .text("plain")]) == "/tmp/a\\\rb plain",
            "the two-item case keeps the guarded CR path and the join space"
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

    @Test
    func opinionatedItemClassificationDefersTheStringReadForFileURLs() {
        var reads = 0
        _ = ClipboardOpinionatedItem.classify(
            decodedURL: URL(fileURLWithPath: "/tmp/a b"),
            plainString: {
                reads += 1
                return "plain"
            }()
        )
        #expect(reads == 0, "a decoded file URL must short-circuit before the plain-string read (upstream's if/else)")

        _ = ClipboardOpinionatedItem.classify(decodedURL: nil, plainString: {
            reads += 1
            return "plain"
        }())
        #expect(reads == 1, "a non-file item must fall through and read the plain string exactly once")
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

    // MARK: - iOS provider

    #if os(iOS)
    /// #431 iOS provider: `text/plain` serves the general pasteboard's string
    /// as UTF-8 bytes; every other requested MIME is unservable. The seeding
    /// puts a PNG and a file URL on the pasteboard first, so the `nil`
    /// assertions falsify the mime policy rather than merely an absent
    /// payload. A file-URL copy has no `.string` payload on iOS, so the
    /// opinionated file-path representation stays macOS-only.
    @Test
    func iosProviderServesOnlyTextPlain() {
        let payload = "vvterm-#431-ios-\(UUID().uuidString)"
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let fileURL = URL(fileURLWithPath: "/tmp/vvterm-431-ios.txt")
        let pasteboard = UIPasteboard.general
        Clipboard.copy(payload)
        pasteboard.addItems([[
            UTType.png.identifier: png,
            UTType.fileURL.identifier: Data(fileURL.absoluteString.utf8),
        ]])
        #expect(pasteboard.string == payload, "positive control: the seeded text item still reads back")
        #expect(Clipboard.data(forMime: "text/plain") == Data(payload.utf8))
        #expect(Clipboard.data(forMime: "text/uri-list") == nil)
        #expect(Clipboard.data(forMime: "image/png") == nil)
    }
    #endif
}
