//
//  Clipboard.swift
//  VVTerm
//
//  Shared pasteboard helper for text and image clipboard payloads
//

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

struct ClipboardImagePayload: Sendable {
    let data: Data
    let mimeType: String
    let utType: String
    let suggestedExtension: String

    nonisolated var sizeBytes: Int { data.count }
}

struct ClipboardSnapshot: Sendable {
    let text: String?
    let image: ClipboardImagePayload?

    nonisolated var hasText: Bool {
        guard let text else { return false }
        return !text.isEmpty
    }

    nonisolated var hasImage: Bool {
        image != nil
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// The declared pasteboard MIME types, best-effort mapped from the
    /// pasteboard's declared types. Metadata only: this never reads pasteboard
    /// data, so the core's mode-5522 listing request cannot load the clipboard.
    /// Types without a MIME mapping are simply not reported.
    static func availableMimeTypes() -> [String] {
        let declared = NSPasteboard.general.types ?? []
        let hasFileURL = declared.contains(.fileURL)
        let mapped = declared.compactMap { type in
            mappedMime(type.rawValue)
        }

        var result: [String] = []
        var seen = Set<String>()
        // Plain text (or a copied file, servable as text) is reported under the
        // canonical MIME the core asks for.
        if hasFileURL || mapped.contains("text/plain") {
            seen.insert("text/plain")
            result.append("text/plain")
        }
        // Copied files are additionally served as a URI list.
        if hasFileURL {
            seen.insert("text/uri-list")
            result.append("text/uri-list")
        }
        for mime in mapped where seen.insert(mime).inserted {
            result.append(mime)
        }
        return result
    }

    private static func mappedMime(_ typeIdentifier: String) -> String? {
        guard let mime = UTType(typeIdentifier)?.preferredMIMEType else { return nil }
        return mime == "text/plain;charset=utf-8" ? "text/plain" : mime
    }

    static func copy(lines: [String], separator: String = "\n") {
        copy(lines.joined(separator: separator))
    }

    @MainActor
    static func snapshot() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        return ClipboardSnapshot(
            text: normalizedText(pasteboard.string(forType: .string)),
            image: imagePayload(from: pasteboard)
        )
    }

    private static func normalizedText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func imagePayload(from pasteboard: NSPasteboard) -> ClipboardImagePayload? {
        if let pngData = pasteboard.data(forType: .png),
           !pngData.isEmpty {
            return ClipboardImagePayload(
                data: pngData,
                mimeType: UTType.png.preferredMIMEType ?? "image/png",
                utType: UTType.png.identifier,
                suggestedExtension: "png"
            )
        }

        let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        let image = imageData.flatMap(NSImage.init(data:))
            ?? (pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage)

        guard let image else { return nil }
        return encodedImagePayload(from: image)
    }

    private static func encodedImagePayload(from image: NSImage) -> ClipboardImagePayload? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        guard let data = bitmap.representation(using: .png, properties: [:]),
              !data.isEmpty else {
            return nil
        }

        return ClipboardImagePayload(
            data: data,
            mimeType: UTType.png.preferredMIMEType ?? "image/png",
            utType: UTType.png.identifier,
            suggestedExtension: "png"
        )
    }
}
#else
import UIKit
import UniformTypeIdentifiers

struct ClipboardImagePayload: Sendable {
    let data: Data
    let mimeType: String
    let utType: String
    let suggestedExtension: String

    nonisolated var sizeBytes: Int { data.count }
}

struct ClipboardSnapshot: Sendable {
    let text: String?
    let image: ClipboardImagePayload?

    nonisolated var hasText: Bool {
        guard let text else { return false }
        return !text.isEmpty
    }

    nonisolated var hasImage: Bool {
        image != nil
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func readString() -> String? {
        UIPasteboard.general.string
    }

    /// The declared pasteboard MIME types, best-effort mapped from the
    /// pasteboard's declared UTIs. Metadata only: this never reads pasteboard
    /// data, so the core's mode-5522 listing request cannot load the clipboard.
    /// Types without a MIME mapping are simply not reported.
    static func availableMimeTypes() -> [String] {
        let declared = UIPasteboard.general.types.compactMap { UTType($0) }
        let hasFileURL = declared.contains { $0.conforms(to: .fileURL) }
        let mapped = declared.compactMap { type in
            type.preferredMIMEType.map { $0 == "text/plain;charset=utf-8" ? "text/plain" : $0 }
        }

        var result: [String] = []
        var seen = Set<String>()
        // Plain text (or a copied file, servable as text) is reported under the
        // canonical MIME the core asks for.
        if hasFileURL || mapped.contains("text/plain") {
            seen.insert("text/plain")
            result.append("text/plain")
        }
        // Copied files are additionally served as a URI list.
        if hasFileURL {
            seen.insert("text/uri-list")
            result.append("text/uri-list")
        }
        for mime in mapped where seen.insert(mime).inserted {
            result.append(mime)
        }
        return result
    }

    static func copy(lines: [String], separator: String = "\n") {
        copy(lines.joined(separator: separator))
    }

    @MainActor
    static func snapshot() -> ClipboardSnapshot {
        let pasteboard = UIPasteboard.general
        return ClipboardSnapshot(
            text: normalizedText(pasteboard.string),
            image: pasteboard.image.flatMap { encodedImagePayload(from: $0) }
        )
    }

    private static func normalizedText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func encodedImagePayload(from image: UIImage) -> ClipboardImagePayload? {
        guard let data = image.pngData(), !data.isEmpty else { return nil }

        return ClipboardImagePayload(
            data: data,
            mimeType: UTType.png.preferredMIMEType ?? "image/png",
            utType: UTType.png.identifier,
            suggestedExtension: "png"
        )
    }
}
#endif
