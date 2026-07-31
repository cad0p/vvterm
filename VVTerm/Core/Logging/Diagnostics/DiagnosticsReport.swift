//
//  DiagnosticsReport.swift
//  VVTerm
//
//  Pure diagnostics report models and formatting.
//

import Foundation

/// One log entry captured for a diagnostics report.
struct DiagnosticsLogEntry: Equatable, Sendable {
    enum Level: String, Sendable {
        case debug
        case info
        case notice
        case error
        case fault
        case other
    }

    let date: Date
    let category: String
    let level: Level
    let message: String
}

/// App/device metadata written at the top of every diagnostics report.
struct DiagnosticsMetadata: Equatable, Sendable {
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String
    let exportDate: Date

    static func current(exportDate: Date, bundle: Bundle = .main) -> DiagnosticsMetadata {
        DiagnosticsMetadata(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            // Foundation-qualified: Features/Stats defines its own ProcessInfo.
            osVersion: Foundation.ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: deviceModelName(),
            exportDate: exportDate
        )
    }

    private static func deviceModelName() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}

/// Formats metadata + log entries into the shareable plain-text report.
enum DiagnosticsReportFormatter {
    /// File name for a report exported at `date`, e.g. `vvterm-diagnostics-20260801-123456.log`.
    static func fileName(for date: Date) -> String {
        "\(Self.fileNameFormatter.string(from: date)).log"
    }

    static func makeReport(
        metadata: DiagnosticsMetadata,
        subsystem: String,
        processStart: Date?,
        entries: [DiagnosticsLogEntry],
        collectionError: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("VVTerm Diagnostics")
        lines.append("==================")
        lines.append("Exported:      \(headerFormatter.string(from: metadata.exportDate))")
        lines.append("App Version:   \(metadata.appVersion) (\(metadata.buildNumber))")
        lines.append("OS:            \(metadata.osVersion)")
        lines.append("Device:        \(metadata.deviceModel)")
        lines.append("Subsystem:     \(subsystem)")
        if let processStart {
            lines.append("Process Start: \(headerFormatter.string(from: processStart))")
        }
        lines.append("Entries:       \(entries.count)")
        if let collectionError {
            lines.append("Log collection failed: \(collectionError)")
        }
        lines.append("==================")
        lines.append("")

        if entries.isEmpty {
            lines.append("(no log entries collected)")
        } else {
            for entry in entries {
                lines.append(format(entry))
            }
        }

        return lines.joined(separator: "\n")
    }

    static func format(_ entry: DiagnosticsLogEntry) -> String {
        "\(entryFormatter.string(from: entry.date)) [\(entry.level.rawValue)] [\(entry.category)] \(entry.message)"
    }

    /// Inverse of `format(_:)`, used to read ring-buffer lines back. Returns
    /// nil for lines that were not produced by `format(_:)` (e.g. truncated
    /// rotation boundaries).
    static func parse(_ line: String) -> DiagnosticsLogEntry? {
        // Layout: "yyyy-MM-dd HH:mm:ss.SSS [level] [category] message"
        guard line.count > 27 else { return nil }
        let timestamp = line.prefix(23)
        guard let date = entryFormatter.date(from: String(timestamp)) else { return nil }

        var rest = line.dropFirst(23)
        guard rest.hasPrefix(" [") else { return nil }
        rest = rest.dropFirst(2)
        guard let levelEnd = rest.firstIndex(of: "]") else { return nil }
        let level = DiagnosticsLogEntry.Level(rawValue: String(rest[..<levelEnd])) ?? .other

        rest = rest[rest.index(after: levelEnd)...]
        guard rest.hasPrefix(" [") else { return nil }
        rest = rest.dropFirst(2)
        guard let categoryEnd = rest.firstIndex(of: "]") else { return nil }
        let category = String(rest[..<categoryEnd])

        rest = rest[rest.index(after: categoryEnd)...]
        guard rest.hasPrefix(" ") else { return nil }
        let message = String(rest.dropFirst())

        return DiagnosticsLogEntry(date: date, category: category, level: level, message: message)
    }

    /// UTC timestamps keep device logs easy to correlate across timezones.
    private static let headerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter
    }()

    private static let entryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "'vvterm-diagnostics-'yyyyMMdd-HHmmss"
        return formatter
    }()
}
