// SPDX-License-Identifier: MIT
//
//  ClipboardRepresentationsMacOSTests.swift
//  VVTermTests
//
//  #431 executed oracle for the macOS `Clipboard.data(forMime:)` provider
//  (the `#if os(macOS)` half of `VVTerm/Core/Terminal/Clipboard.swift`).
//  The neutral seam is Simulator-executed by
//  `ClipboardRepresentationsTests.swift`; this suite drives the real
//  provider against `NSPasteboard.general` for the three upstream arms:
//
//    - a file-URL-only copy -> the escaped filesystem path (text/plain) and
//      the RFC 2483 URI list (text/uri-list);
//    - a text copy -> the string;
//    - a UTType-mapped MIME -> the pasteboard type's data.
//
//  Runs at `-destination 'platform=macOS,arch=arm64'`. The suite mutates the
//  general pasteboard, so it is serialized (it does not run in the iOS
//  Simulator unit job; the macOS run targets this suite explicitly).
//

#if os(macOS)
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct ClipboardRepresentationsMacOSTests {

    /// A file-URL-only copy has no `.string` payload — the measured shape
    /// this workstream's plan §1 records — so it is the case that used to
    /// paste nothing.
    @Test
    func fileURLCopyServesTheEscapedPathAndURIList() throws {
        let url = URL(fileURLWithPath: "/tmp/vvterm-431 a(b).txt")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .fileURL)

        #expect(
            pasteboard.string(forType: .string) == nil,
            "positive control: a file-URL-only copy must carry no string payload"
        )

        let escapedPath = "/tmp/vvterm-431\\ a\\(b\\).txt"
        #expect(Clipboard.data(forMime: "text/plain") == Data(escapedPath.utf8))
        #expect(
            Clipboard.data(forMime: "text/uri-list") == Data("\(url.absoluteString)\r\n".utf8),
            "the URI list is the file URL's absolute string plus CRLF"
        )
        #expect(Clipboard.data(forMime: "image/png") == nil)
    }

    @Test
    func textCopyServesTheStringAsTextPlain() {
        let payload = "vvterm-#431 mac text \(UUID().uuidString)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)

        #expect(Clipboard.data(forMime: "text/plain") == Data(payload.utf8))
        #expect(Clipboard.data(forMime: "text/uri-list") == nil)
    }

    @Test
    func utTypeMappedMimeServesThePasteboardData() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let type = try #require(UTType(mimeType: "image/png"))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: NSPasteboard.PasteboardType(type.identifier))

        #expect(Clipboard.data(forMime: "image/png") == png)
        #expect(
            Clipboard.data(forMime: "application/vnd.vvterm.unmappable") == nil,
            "an unseedable representation must return nil, not fabricated bytes"
        )
    }

    /// The provider's dedupe/unservable-skip semantics over the real
    /// pasteboard: one text payload yields exactly the one text/plain
    /// representation even when the callback asks twice and for a URI list.
    @Test
    func selectionOverTheRealProviderDedupesAndSkipsUnservable() {
        let payload = "vvterm-#431 selection \(UUID().uuidString)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)

        let selected = ClipboardMimeSelection.select(
            requested: ["text/plain", "text/uri-list", "text/plain"]
        ) { mime in
            Clipboard.data(forMime: mime)
        }
        #expect(selected == [ClipboardRepresentation(mime: "text/plain", data: Data(payload.utf8))])
    }
}
#endif
