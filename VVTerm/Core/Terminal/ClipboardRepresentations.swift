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
//  (unit tests). The macOS provider is targeted by the macOS-destination
//  oracle suite, which is runtime-unverified on this tree — see the #431
//  verification walk §2. The platform providers only extract pasteboard
//  values and wrap the results back into AppKit/UIKit types.
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
    /// The plain string is an autoclosure so a file-URL item never triggers
    /// the provider's `.string` read: upstream's `if/else` only asks for the
    /// string in its non-file branch, and this restores that short-circuit
    /// without moving the `isFileURL` decision out of this neutral layer.
    static func classify(
        decodedURL: URL?,
        plainString: @autoclosure () -> String?
    ) -> ClipboardOpinionatedItem {
        if let decodedURL, decodedURL.isFileURL {
            return .fileURL(decodedURL)
        }
        return .text(plainString())
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

/// Upstream's path escaping (`Ghostty.Shell.escape`), with one deliberate
/// local divergence: `escapeCharacters` also escapes CR. The divergence is
/// recorded on the set itself and tracked by #442 for the core-side gap.
enum ClipboardPathEscape {
    /// The escape set in upstream's written order, `\` first — upstream's 22
    /// characters plus a local CR, 23 in total. `\` stays first because the
    /// single pass depends on it iterating before every character it inserts.
    ///
    /// `\n` is not in the set by design: newline safety is owned by the
    /// core's unsafe-paste check and the #327 confirmation prompt, not by the
    /// escape. CR is, deliberately: the core's `isSafe`/`isSafeWith` does not
    /// treat CR as unsafe (unlike `\n`), and the app has no pre-paste hook to
    /// rely on — `confirm_read_clipboard` fires only after `UnsafePaste` or
    /// `UnauthorizedPaste` — so the app-side lever is the representation it
    /// composes. `\`+CR neutralizes the line break: it is read as a line
    /// continuation, or as readline's accept-line burning a trailing
    /// backslash. Residual: the pasted word is the CR-less path, and only the
    /// user's Enter submits it. The same gap for arbitrary text pastes is
    /// tracked by #442.
    static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t\r"

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
    ///
    /// The `text/plain` branch mirrors upstream's failable write-path
    /// pasteboard-type initializer; the read path handles `text/plain` in its
    /// own switch case, so the branch is currently exercised only by the
    /// helper tests.
    static func pasteboardTypeIdentifier(forMime mime: String) -> String {
        if mime == "text/plain" {
            return UTType.utf8PlainText.identifier
        }
        guard let type = UTType(mimeType: mime) else { return mime }
        return type.identifier
    }
}
