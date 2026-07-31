//
//  DiagnosticsRecorder.swift
//  VVTerm
//
//  On-device ring buffer for the diagnostics "narrative spine".
//

import Foundation

/// Mirrors high-value lifecycle events into a small append-only file in
/// Caches. Unified logging's per-process in-memory buffer is purged by logd
/// under memory pressure (only error/fault entries survive), which wiped
/// out the info-level narrative during real reproductions (issue #81).
/// Events recorded here survive logd purges and are merged into every
/// exported diagnostics report.
///
/// Only record non-sensitive narrative events (stage names, UUIDs, counts,
/// outcomes). Never record credentials, raw hosts, or terminal content.
final class DiagnosticsRecorder: @unchecked Sendable {
    static let shared = DiagnosticsRecorder()

    private let queue = DispatchQueue(label: "vvterm.diagnostics-recorder")
    private let fileURL: URL
    private let maxBytes: Int
    private let keepBytes: Int

    init(fileURL: URL? = nil, maxBytes: Int = 2_000_000, keepBytes: Int = 1_000_000) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            self.fileURL = caches?
                .appendingPathComponent("vvterm-diagnostics-ring.log")
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("vvterm-diagnostics-ring.log")
        }
        self.maxBytes = maxBytes
        self.keepBytes = keepBytes
    }

    func record(level: DiagnosticsLogEntry.Level, category: String, message: String, date: Date = Date()) {
        // One event per line keeps the ring trivially parseable.
        let sanitized = message.replacingOccurrences(of: "\n", with: " ")
        let entry = DiagnosticsLogEntry(date: date, category: category, level: level, message: sanitized)
        let line = DiagnosticsReportFormatter.format(entry)
        queue.async { self.appendLine(line) }
    }

    func entries(since: Date) -> [DiagnosticsLogEntry] {
        queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            return text
                .split(separator: "\n")
                .compactMap { DiagnosticsReportFormatter.parse(String($0)) }
                .filter { $0.date >= since }
        }
    }

    private func appendLine(_ line: String) {
        rotateIfNeeded()
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func rotateIfNeeded() {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? Int,
            size > maxBytes,
            let data = try? Data(contentsOf: fileURL),
            data.count > keepBytes
        else { return }

        let tail = data.suffix(keepBytes)
        // Resume at a line boundary so the kept tail stays parseable.
        if let boundary = tail.firstIndex(of: UInt8(ascii: "\n")), boundary + 1 < tail.endIndex {
            try? Data(tail[(boundary + 1)...]).write(to: fileURL, options: .atomic)
        } else {
            try? Data(tail).write(to: fileURL, options: .atomic)
        }
    }
}
