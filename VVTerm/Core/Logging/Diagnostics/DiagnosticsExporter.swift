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
        // On iOS/macOS an app may only read its own process's entries.
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
        subsystem: String = Bundle.main.bundleIdentifier ?? "it.pcad.vvterm",
        exportDate: Date = Date(),
        fileManager: FileManager = .default
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let processStart = processStartDate()
            var collectionError: String?
            var entries: [DiagnosticsLogEntry] = []
            do {
                entries = try collector.collectEntries(since: processStart ?? .distantPast)
            } catch {
                collectionError = error.localizedDescription
            }

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
