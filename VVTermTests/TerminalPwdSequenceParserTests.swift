//
//  TerminalPwdSequenceParserTests.swift
//  VVTermTests
//

import Foundation
import Testing
@testable import VVTerm

struct TerminalPwdSequenceParserTests {
    @Test
    func parsesBellTerminatedWorkingDirectory() {
        var parser = TerminalPwdSequenceParser()

        #expect(parser.parse(data("\u{1B}]7;file://localhost/tmp/foo\u{7}")) == ["file://localhost/tmp/foo"])
    }

    @Test
    func parsesStringTerminatedWorkingDirectory() {
        var parser = TerminalPwdSequenceParser()

        #expect(parser.parse(data("\u{1B}]7;/tmp/foo\u{1B}\\")) == ["/tmp/foo"])
    }

    @Test
    func buffersSplitSequence() {
        var parser = TerminalPwdSequenceParser()

        #expect(parser.parse(data("\u{1B}]7;/tmp/fo")).isEmpty)
        #expect(parser.parse(data("o\u{7}")) == ["/tmp/foo"])
    }

    @Test
    func parsesMultipleSequencesInOneChunk() {
        var parser = TerminalPwdSequenceParser()

        #expect(parser.parse(data("\u{1B}]7;/tmp/a\u{7}\u{1B}]7;/tmp/b\u{7}")) == ["/tmp/a", "/tmp/b"])
    }

    @Test
    func ignoresOtherOSCCodes() {
        var parser = TerminalPwdSequenceParser()

        #expect(parser.parse(data("\u{1B}]0;title\u{7}\u{1B}]7;/tmp\u{7}")) == ["/tmp"])
    }

    @Test
    func ignoresGarbageBeforeSequence() {
        var parser = TerminalPwdSequenceParser()

        #expect(parser.parse(data("prefix\u{1B}]7;/tmp\u{7}")) == ["/tmp"])
    }

    @Test
    func emptyPayloadYieldsNothing() {
        var parser = TerminalPwdSequenceParser()

        #expect(parser.parse(data("\u{1B}]7;\u{7}")).isEmpty)
    }

    @Test
    func preservesQueryAndFragmentInFilePath() {
        var parser = TerminalPwdSequenceParser()

        #expect(parser.parse(data("\u{1B}]7;file://host/tmp/a?b#c\u{7}")) == ["file://host/tmp/a?b#c"])
    }

    @Test
    func passesPercentEncodedPayloadThrough() {
        var parser = TerminalPwdSequenceParser()

        #expect(parser.parse(data("\u{1B}]7;file://host/tmp/100%2Fdone\u{7}")) == ["file://host/tmp/100%2Fdone"])
    }

    @Test
    func toleratesNonUTF8Payload() {
        var parser = TerminalPwdSequenceParser()
        var bytes: [UInt8] = [0x1B, 0x5D, 0x37, 0x3B]
        bytes += [0x2F, 0x74, 0x6D, 0x70, 0xFF, 0x2F, 0x78]
        bytes += [0x07]

        let pwds = parser.parse(Data(bytes))

        #expect(pwds.count == 1)
        #expect(pwds.first?.hasPrefix("/tmp") == true)
        #expect(pwds.first == "/tmp\u{FFFD}/x")
    }

    @Test
    func bulkOutputAfterSequenceDoesNotBreakParser() {
        var parser = TerminalPwdSequenceParser()
        let redraw = String(repeating: "x", count: 5000)

        #expect(parser.parse(data("\u{1B}]7;/tmp\u{7}\(redraw)")) == ["/tmp"])
    }

    @Test
    func retainsPartialEscapeForNextChunk() {
        var parser = TerminalPwdSequenceParser()

        #expect(parser.parse(data("\u{1B}")).isEmpty)
        #expect(parser.parse(data("]7;/tmp\u{7}")) == ["/tmp"])
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
