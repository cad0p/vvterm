import Foundation
import OSLog
import Testing
@testable import VVTerm

@Suite
struct DiagnosticsReportFormatterTests {
    private let exportDate = Date(timeIntervalSince1970: 1_759_000_000)

    private func makeMetadata() -> DiagnosticsMetadata {
        DiagnosticsMetadata(
            appVersion: "1.2.3",
            buildNumber: "45",
            osVersion: "Version 18.5 (Build 22F77)",
            deviceModel: "iPhone16,2",
            exportDate: exportDate
        )
    }

    @Test
    func reportContainsMetadataHeader() {
        let report = DiagnosticsReportFormatter.makeReport(
            metadata: makeMetadata(),
            subsystem: "it.pcad.vvterm",
            processStart: Date(timeIntervalSince1970: 1_758_999_000),
            entries: []
        )

        #expect(report.contains("VVTerm Diagnostics"))
        #expect(report.contains("App Version:   1.2.3 (45)"))
        #expect(report.contains("OS:            Version 18.5 (Build 22F77)"))
        #expect(report.contains("Device:        iPhone16,2"))
        #expect(report.contains("Subsystem:     it.pcad.vvterm"))
        #expect(report.contains("Process Start:"))
        #expect(report.contains("Entries:       0"))
    }

    @Test
    func emptyEntriesProduceExplicitPlaceholder() {
        let report = DiagnosticsReportFormatter.makeReport(
            metadata: makeMetadata(),
            subsystem: "it.pcad.vvterm",
            processStart: nil,
            entries: []
        )

        #expect(report.contains("(no log entries collected)"))
        // Missing process start must not leave a dangling label.
        #expect(!report.contains("Process Start:"))
    }

    @Test
    func entriesAreFormattedWithTimestampLevelAndCategory() {
        let entry = DiagnosticsLogEntry(
            date: Date(timeIntervalSince1970: 1_758_999_500.25),
            category: "teleport-grpc",
            level: .error,
            message: "dial failed"
        )

        let line = DiagnosticsReportFormatter.format(entry)

        #expect(line.hasPrefix("2025-09-"))
        #expect(line.contains("[error] [teleport-grpc] dial failed"))
        #expect(line.contains(".250"))
    }

    @Test
    func collectionFailureIsRecordedInReport() {
        let report = DiagnosticsReportFormatter.makeReport(
            metadata: makeMetadata(),
            subsystem: "it.pcad.vvterm",
            processStart: nil,
            entries: [],
            collectionError: "store unavailable"
        )

        #expect(report.contains("Log collection failed: store unavailable"))
    }

    @Test
    func fileNameIsTimestampedAndStable() {
        let name = DiagnosticsReportFormatter.fileName(
            for: Date(timeIntervalSince1970: 1_759_000_000)
        )

        #expect(name.hasPrefix("vvterm-diagnostics-"))
        #expect(name.hasSuffix(".log"))
        #expect(name == DiagnosticsReportFormatter.fileName(for: Date(timeIntervalSince1970: 1_759_000_000)))
    }
}

@Suite
struct DiagnosticsExporterTests {
    private struct StubCollector: DiagnosticsLogCollecting {
        let entries: [DiagnosticsLogEntry]

        func collectEntries(since: Date) throws -> [DiagnosticsLogEntry] {
            entries
        }
    }

    private struct FailingCollector: DiagnosticsLogCollecting {
        struct StubError: Error {}

        func collectEntries(since: Date) throws -> [DiagnosticsLogEntry] {
            throw StubError()
        }
    }

    @Test
    func exportWritesReportWithCollectedEntries() async throws {
        let collector = StubCollector(entries: [
            DiagnosticsLogEntry(
                date: Date(timeIntervalSince1970: 1_758_999_500),
                category: "SSH",
                level: .info,
                message: "connected"
            )
        ])

        let url = try await DiagnosticsExporter.export(
            collector: collector,
            subsystem: "it.pcad.vvterm",
            exportDate: Date(timeIntervalSince1970: 1_759_000_000)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("Entries:       1"))
        #expect(contents.contains("[info] [SSH] connected"))
        #expect(url.lastPathComponent.hasPrefix("vvterm-diagnostics-"))
    }

    @Test
    func exportStillProducesReportWhenCollectionFails() async throws {
        // Distinct exportDate from the sibling test: Swift Testing runs suite
        // tests in parallel and identical dates would collide on one filename.
        let url = try await DiagnosticsExporter.export(
            collector: FailingCollector(),
            subsystem: "it.pcad.vvterm",
            exportDate: Date(timeIntervalSince1970: 1_759_000_001)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("Log collection failed:"))
        #expect(contents.contains("(no log entries collected)"))
    }

    @Test
    func liveCollectorReadsEntriesFromOwnProcess() async throws {
        // Emit one entry, then verify the real OSLog collector can read it
        // back for the app's subsystem. Guards the OSLogStore integration
        // against API drift (scope/position/entry casting). Unified-log
        // delivery is asynchronous, so poll briefly for the marker.
        Logger.forCategory("DiagnosticsTests").error("vvterm-diagnostics-test-marker")

        let collector = OSLogDiagnosticsCollector()
        var found = false
        for _ in 0..<10 where !found {
            let entries = (try? collector.collectEntries(since: Date().addingTimeInterval(-60))) ?? []
            found = entries.contains { $0.message.contains("vvterm-diagnostics-test-marker") }
            if !found {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        #expect(found)
    }
}
