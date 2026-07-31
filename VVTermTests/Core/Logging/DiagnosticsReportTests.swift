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
    func formatAndParseRoundTrip() {
        let entry = DiagnosticsLogEntry(
            date: Date(timeIntervalSince1970: 1_758_999_500.25),
            category: "SSH",
            level: .info,
            message: "startup stage=sshHandshake stageMs=345 totalMs=462 outcome=ok detail=none"
        )

        let parsed = DiagnosticsReportFormatter.parse(DiagnosticsReportFormatter.format(entry))

        #expect(parsed?.category == entry.category)
        #expect(parsed?.level == entry.level)
        #expect(parsed?.message == entry.message)
        // Millisecond precision survives the round trip.
        #expect(abs((parsed?.date.timeIntervalSince(entry.date)) ?? 1) < 0.001)
    }

    @Test
    func parseRejectsTruncatedOrForeignLines() {
        #expect(DiagnosticsReportFormatter.parse("") == nil)
        #expect(DiagnosticsReportFormatter.parse("not a log line") == nil)
        // Truncated rotation boundary: line cut mid-timestamp.
        #expect(DiagnosticsReportFormatter.parse("6-07-31 13:22:57.877 [info] [SSH] x") == nil)
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
        let recorder = DiagnosticsRecorder(fileURL: freshRingURL())

        let url = try await DiagnosticsExporter.export(
            collector: collector,
            recorder: recorder,
            subsystem: "it.pcad.vvterm",
            exportDate: Date(timeIntervalSince1970: 1_759_000_000)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let contents = try String(contentsOf: url, encoding: .utf8)
        // Stub entry + the export marker recorded into the fresh ring.
        #expect(contents.contains("Entries:       2"))
        #expect(contents.contains("[info] [SSH] connected"))
        #expect(contents.contains("[notice] [Diagnostics] export requested"))
        #expect(url.lastPathComponent.hasPrefix("vvterm-diagnostics-"))
    }

    private func freshRingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-test-ring-\(UUID().uuidString).log")
    }

    @Test
    func exportStillProducesReportWhenCollectionFails() async throws {
        // Distinct exportDate from the sibling test: Swift Testing runs suite
        // tests in parallel and identical dates would collide on one filename.
        let url = try await DiagnosticsExporter.export(
            collector: FailingCollector(),
            recorder: DiagnosticsRecorder(fileURL: freshRingURL()),
            subsystem: "it.pcad.vvterm",
            exportDate: Date(timeIntervalSince1970: 1_759_000_001)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("Log collection failed:"))
        // Even when unified-log collection fails, the ring-buffer spine
        // (here: the export marker itself) still lands in the report.
        #expect(contents.contains("[notice] [Diagnostics] export requested"))
    }

    @Test
    func mergeDeduplicatesMirroredEvents() {
        let base = Date(timeIntervalSince1970: 1_759_000_000)
        let mirroredRing = DiagnosticsLogEntry(
            date: base, category: "SSH", level: .info, message: "Disconnected"
        )
        // Same event via OSLog, 300ms later, same text.
        let mirroredOSLog = DiagnosticsLogEntry(
            date: base.addingTimeInterval(0.3), category: "SSH", level: .info, message: "Disconnected"
        )
        let oslogOnly = DiagnosticsLogEntry(
            date: base.addingTimeInterval(1), category: "Ghostty", level: .info, message: "surface ready"
        )
        let ringOnly = DiagnosticsLogEntry(
            date: base.addingTimeInterval(2), category: "TerminalTabManager", level: .info, message: "Closed tab"
        )

        let merged = DiagnosticsExporter.mergedEntries(
            ring: [mirroredRing, ringOnly],
            oslog: [mirroredOSLog, oslogOnly]
        )

        #expect(merged.count == 3)
        #expect(merged.contains(mirroredRing))
        #expect(merged.contains(oslogOnly))
        #expect(merged.contains(ringOnly))
        #expect(!merged.contains(mirroredOSLog))
        #expect(merged.map(\.date) == merged.map(\.date).sorted())
    }

    @Test
    func mergePassesThroughWhenRingIsEmpty() {
        let entry = DiagnosticsLogEntry(
            date: Date(timeIntervalSince1970: 1_759_000_000),
            category: "SSH",
            level: .info,
            message: "connected"
        )
        #expect(DiagnosticsExporter.mergedEntries(ring: [], oslog: [entry]) == [entry])
    }

    @Test
    func collectionWindowExtendsToRecentPriorLaunches() {
        let exportDate = Date(timeIntervalSince1970: 1_759_000_000)
        // Process started 5 minutes ago: window reaches back the full 2h so
        // a previous launch that died mid-reproduction is still captured.
        let recentStart = exportDate.addingTimeInterval(-5 * 60)
        let since = DiagnosticsExporter.collectionStartDate(
            processStart: recentStart,
            exportDate: exportDate
        )
        #expect(since == exportDate.addingTimeInterval(-DiagnosticsExporter.maxCollectionWindow))
    }

    @Test
    func collectionWindowCoversWholeLongRunningProcess() {
        let exportDate = Date(timeIntervalSince1970: 1_759_000_000)
        // Process started 3 hours ago (beyond the window): collect from
        // process start so the current session is never truncated.
        let oldStart = exportDate.addingTimeInterval(-3 * 60 * 60)
        let since = DiagnosticsExporter.collectionStartDate(
            processStart: oldStart,
            exportDate: exportDate
        )
        #expect(since == oldStart)
    }

    @Test
    func collectionWindowWithoutProcessStartFallsBackToWindow() {
        let exportDate = Date(timeIntervalSince1970: 1_759_000_000)
        let since = DiagnosticsExporter.collectionStartDate(
            processStart: nil,
            exportDate: exportDate
        )
        #expect(since == exportDate.addingTimeInterval(-DiagnosticsExporter.maxCollectionWindow))
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

@Suite
struct DiagnosticsRecorderTests {
    private func freshRecorder(maxBytes: Int = 2_000_000, keepBytes: Int = 1_000_000) -> DiagnosticsRecorder {
        DiagnosticsRecorder(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("vvterm-test-ring-\(UUID().uuidString).log"),
            maxBytes: maxBytes,
            keepBytes: keepBytes
        )
    }

    @Test
    func recordedEntriesAreReadableByExportPipeline() {
        let recorder = freshRecorder()
        let before = Date().addingTimeInterval(-1)
        recorder.record(level: .info, category: "TerminalTabManager", message: "Closed tab abc")
        recorder.record(level: .notice, category: "Diagnostics", message: "export requested")

        let entries = recorder.entries(since: before)

        #expect(entries.count == 2)
        #expect(entries[0].category == "TerminalTabManager")
        #expect(entries[0].level == .info)
        #expect(entries[0].message == "Closed tab abc")
        #expect(entries[1].level == .notice)
    }

    @Test
    func entriesNewerThanSinceAreFiltered() {
        let recorder = freshRecorder()
        recorder.record(level: .info, category: "SSH", message: "old")

        let entries = recorder.entries(since: Date().addingTimeInterval(60))

        #expect(entries.isEmpty)
    }

    @Test
    func multilineMessagesAreSanitizedToOneLine() {
        let recorder = freshRecorder()
        recorder.record(level: .info, category: "SSH", message: "line one\nline two")

        let entries = recorder.entries(since: .distantPast)

        #expect(entries.count == 1)
        #expect(entries[0].message == "line one line two")
    }

    @Test
    func rotationKeepsFileBoundedAndParseable() {
        let recorder = freshRecorder(maxBytes: 400, keepBytes: 200)
        for index in 0..<20 {
            recorder.record(
                level: .info,
                category: "SSH",
                message: "event number \(index) with some padding text"
            )
        }

        let entries = recorder.entries(since: .distantPast)

        // Oldest events were rotated away, newest survive, all parse.
        #expect(entries.count < 20)
        #expect(entries.contains { $0.message.contains("event number 19") })
        #expect(!entries.contains { $0.message.contains("event number 0 ") })
        #expect(entries.map(\.date) == entries.map(\.date).sorted())
    }
}
