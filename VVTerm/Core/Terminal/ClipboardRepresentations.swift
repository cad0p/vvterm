// SPDX-License-Identifier: MIT
//
//  ClipboardRepresentations.swift
//  VVTerm
//
//  Platform-neutral clipboard read decisions (#431), ported from upstream
//  ghostty `1e9e14a`: `macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift`
//  (`ghosttyData(forMime:)`, `getOpinionatedStringContents()`, `ghosttyFileURLs`)
//  and `macos/Sources/Ghostty/Ghostty.Shell.swift` (`escape`).
//
//  The classification and composition live here, one layer above the
//  platform pasteboard, so every arm is executable on the iOS Simulator
//  (unit tests) and in the macOS-destination oracle suite. The platform
//  providers only extract pasteboard values and wrap the results back into
//  AppKit/UIKit types.
//

import Foundation
import UniformTypeIdentifiers

/// One clipboard representation served to the ghostty read callback.
struct ClipboardRepresentation: Equatable, Sendable {
    let mime: String
    let data: Data
}

/// Turns the callback's requested mimes into the representations the
/// clipboard can produce.
enum ClipboardMimeSelection {
    /// Dedupes the requested mimes in caller order, skips the ones the
    /// clipboard cannot serve (`data` returns nil), and keeps the caller's
    /// order in the result.
    static func select(
        requested: [String],
        data: (String) -> Data?
    ) -> [ClipboardRepresentation] {
        var seen = Set<String>()
        var representations: [ClipboardRepresentation] = []
        for mime in requested {
            guard seen.insert(mime).inserted else { continue }
            guard let representation = data(mime) else { continue }
            representations.append(ClipboardRepresentation(mime: mime, data: representation))
        }
        return representations
    }
}

/// One pasteboard item classified for the opinionated `text/plain`
/// composition. The provider only extracts the decoded `.fileURL` property
/// list and the plain string; the `isFileURL` filter (part of the upstream
/// spec, not an optimization) lives in `classify` so the decision is
/// unit-tested rather than trusted at the AppKit boundary.
enum ClipboardOpinionatedItem: Equatable, Sendable {
    case fileURL(URL)
    case text(String?)

    /// Classifies one provider extraction. A decoded URL that is not a file
    /// URL (and a missing decode) falls through to the string representation.
    static func classify(decodedURL: URL?, plainString: String?) -> ClipboardOpinionatedItem {
        if let decodedURL, decodedURL.isFileURL {
            return .fileURL(decodedURL)
        }
        return .text(plainString)
    }
}

/// The opinionated `text/plain` composition (upstream
/// `getOpinionatedStringContents()`).
enum ClipboardOpinionatedText {
    /// Drops nil elements; a file URL becomes its escaped filesystem path and
    /// a text element its string (an empty string is a servable
    /// representation). Elements are joined by a single space; the result is
    /// nil only when the element list is empty.
    static func compose(_ items: [ClipboardOpinionatedItem]) -> String? {
        let strings: [String] = items.compactMap { item in
            switch item {
            case .fileURL(let url):
                return ClipboardPathEscape.escaped(url.path)
            case .text(let string):
                return string
            }
        }
        guard !strings.isEmpty else { return nil }
        return strings.joined(separator: " ")
    }
}

/// The `text/uri-list` encoding for copied files (RFC 2483): each URL as its
/// absolute string plus CRLF, concatenated. The caller filters for file URLs
/// before calling.
enum ClipboardURIList {
    static func encode(_ urls: [URL]) -> Data {
        Data(urls.map { $0.absoluteString + "\r\n" }.joined().utf8)
    }
}

/// Upstream's path escaping (`Ghostty.Shell.escape`).
enum ClipboardPathEscape {
    /// The escape set in upstream's written order, `\` first. `\n` is not in
    /// the set by design: newline safety is owned by the core's unsafe-paste
    /// check and the #327 confirmation prompt, not by the escape.
    static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    /// Single pass over the escape set in written order: every occurrence of
    /// each character becomes a backslash plus that character. Because `\`
    /// is first and each character is processed once, backslashes inserted by
    /// the escape are never re-escaped.
    static func escaped(_ path: String) -> String {
        var result = path
        for character in escapeCharacters {
            result = result.replacingOccurrences(of: String(character), with: "\\\(character)")
        }
        return result
    }
}

/// The MIME → pasteboard-type-identifier resolution (upstream
/// `NSPasteboard.PasteboardType(mimeType:)`).
enum ClipboardMimeMapping {
    /// `text/plain` pins to the platform plain-text identifier (AppKit
    /// `.string`, `public.utf8-plain-text`); everything else resolves through
    /// `UTType(mimeType:)`'s identifier. A structurally invalid mime gets no
    /// UTType and falls back to the raw mime string (valid unknown mimes
    /// resolve to a dynamic identifier, as upstream does).
    static func pasteboardTypeIdentifier(forMime mime: String) -> String {
        if mime == "text/plain" {
            return UTType.utf8PlainText.identifier
        }
        guard let type = UTType(mimeType: mime) else { return mime }
        return type.identifier
    }
}
