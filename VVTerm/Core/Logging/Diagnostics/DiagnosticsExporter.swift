//
//  DiagnosticsExporter.swift
//  VVTerm
//
//  Collects this process's unified-log entries since launch and writes a
//  shareable diagnostics report to a temporary file.
//

import Foundation
import OSLog

/// Abstraction over the log store so formatting/orchestration stays testable.
protocol DiagnosticsLogCollecting: Sendable {
    func collectEntries(since: Date) throws -> [DiagnosticsLogEntry]
}

struct OSLogDiagnosticsCollector: DiagnosticsLogCollecting {
    let subsystem: String

    init(subsystem: String = Bundle.main.bundleIdentifier ?? "it.pcad.vvterm") {
        self.subsystem = subsystem
    }

    func collectEntries(since: Date) throws -> [DiagnosticsLogEntry] {
        // On iOS an app may only read its own process's entries (the
        // persisted-store APIs are macOS-only). That in-memory buffer is
        // purged by logd under memory pressure — DiagnosticsRecorder is the
        // reliable spine and is merged in by the exporter.
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: since)

        return try store.getEntries(at: position)
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == subsystem }
            .map {
                DiagnosticsLogEntry(
                    date: $0.date,
                    category: $0.category,
                    level: DiagnosticsLogEntry.Level($0.level),
                    message: $0.composedMessage
                )
            }
    }
}

extension DiagnosticsLogEntry.Level {
    init(_ level: OSLogEntryLog.Level) {
        switch level {
        case .debug: self = .debug
        case .info: self = .info
        case .notice: self = .notice
        case .error: self = .error
        case .fault: self = .fault
        default: self = .other
        }
    }
}

enum DiagnosticsExporter {
    /// Exports a diagnostics report to a temporary file and returns its URL.
    /// Log collection failures are recorded inside the report instead of
    /// throwing, so the user always gets a shareable file.
    static func export(
        collector: any DiagnosticsLogCollecting = OSLogDiagnosticsCollector(),
        recorder: DiagnosticsRecorder = .shared,
        subsystem: String = Bundle.main.bundleIdentifier ?? "it.pcad.vvterm",
        exportDate: Date = Date(),
        fileManager: FileManager = .default
    ) async throws -> URL {
        // Marker lands in the ring ahead of the collection below (same
        // serial queue), so the report shows exactly when sharing happened.
        recorder.record(
            level: .notice,
            category: "Diagnostics",
            message: "export requested"
        )
        return try await Task.detached(priority: .userInitiated) {
            let processStart = processStartDate()
            var collectionError: String?
            var oslogEntries: [DiagnosticsLogEntry] = []
            let since = collectionStartDate(processStart: processStart, exportDate: exportDate)
            do {
                oslogEntries = try collector.collectEntries(since: since)
            } catch {
                collectionError = error.localizedDescription
            }
            // The ring buffer survives logd buffer purges under memory
            // pressure, so the narrative spine is present even when the
            // unified-log collection comes back gutted or fails outright.
            let ringEntries = recorder.entries(since: since)
            let entries = mergedEntries(ring: ringEntries, oslog: oslogEntries)

            let report = DiagnosticsReportFormatter.makeReport(
                metadata: .current(exportDate: exportDate),
                subsystem: subsystem,
                processStart: processStart,
                entries: entries,
                collectionError: collectionError
            )

            let url = fileManager.temporaryDirectory
                .appendingPathComponent(DiagnosticsReportFormatter.fileName(for: exportDate))
            try report.write(to: url, atomically: true, encoding: .utf8)
            return url
        }.value
    }

    /// Removes a previously exported report once sharing completed, so
    /// timestamped reports don't accumulate in the temporary directory.
    static func cleanup(reportAt url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// How far back before the export the report may reach. Covers the
    /// current launch plus recent prior launches, so a reproduction that
    /// ended in an app restart still has its lead-up captured.
    static let maxCollectionWindow: TimeInterval = 2 * 60 * 60

    /// Earliest timestamp collected into a report: the full current process
    /// lifetime, extended backwards up to `maxCollectionWindow` so previous
    /// launches are included when the process started recently.
    static func collectionStartDate(processStart: Date?, exportDate: Date) -> Date {
        let windowStart = exportDate.addingTimeInterval(-maxCollectionWindow)
        guard let processStart else { return windowStart }
        return min(processStart, windowStart)
    }

    /// Merges ring-buffer and unified-log entries into one timeline. Events
    /// mirrored to both sources appear once (ring copy wins); entries unique
    /// to either source are all kept.
    static func mergedEntries(
        ring: [DiagnosticsLogEntry],
        oslog: [DiagnosticsLogEntry]
    ) -> [DiagnosticsLogEntry] {
        guard !ring.isEmpty else { return oslog }

        // Dedupe key: category + message, bucketed by 2s so mirrored events
        // match even if the two timestamps differ by a fraction of a second.
        var buckets: [Int: Set<String>] = [:]
        for entry in ring {
            let bucket = Int(entry.date.timeIntervalSince1970 / 2)
            buckets[bucket, default: []].insert("\(entry.category)\u{0}\(entry.message)")
        }

        var merged = ring
        for entry in oslog {
            let key = "\(entry.category)\u{0}\(entry.message)"
            let bucket = Int(entry.date.timeIntervalSince1970 / 2)
            let isDuplicate = (bucket - 1 ... bucket + 1).contains {
                buckets[$0]?.contains(key) == true
            }
            if !isDuplicate {
                merged.append(entry)
            }
        }
        return merged.sorted { $0.date < $1.date }
    }

    /// Real start time of this process, so the report covers exactly the
    /// current app launch without needing an early startup hook.
    private static func processStartDate() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
            return nil
        }
        let start = info.kp_proc.p_starttime
        return Date(
            timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        )
    }
}
