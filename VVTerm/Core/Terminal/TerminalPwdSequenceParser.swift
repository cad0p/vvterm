//
//  TerminalPwdSequenceParser.swift
//  VVTerm
//

import Foundation

/// Parses OSC 7 (working directory) sequences from a raw terminal byte
/// stream: `ESC ] 7 ; <payload> BEL` (or ST). The payload is typically a
/// `file://host/path` URL, but may be a bare path; the caller normalizes.
///
/// The embedded ghostty core only surfaces the first PWD change through its
/// action callback, so the app parses the stream itself to keep the
/// pane working directory fresh (used for new-tab cwd, tmux attach, and
/// diagnostics).
nonisolated struct TerminalPwdSequenceParser {
    private var buffer: [UInt8] = []
    private let maxBufferLength: Int

    init(maxBufferLength: Int = 4096) {
        self.maxBufferLength = maxBufferLength
    }

    mutating func parse(_ data: Data) -> [String] {
        buffer.append(contentsOf: data)

        var pwds: [String] = []
        var searchIndex = 0

        while searchIndex < buffer.count {
            guard let escapeIndex = buffer[searchIndex...].firstIndex(of: 0x1B) else {
                buffer.removeAll(keepingCapacity: true)
                return pwds
            }

            guard escapeIndex + 1 < buffer.count else {
                keepUnfinishedSequence(from: escapeIndex)
                return pwds
            }

            guard buffer[escapeIndex + 1] == 0x5D else {
                searchIndex = escapeIndex + 1
                continue
            }

            guard let terminator = terminatorIndex(startingAt: escapeIndex + 2) else {
                keepUnfinishedSequence(from: escapeIndex)
                return pwds
            }

            let payload = buffer[(escapeIndex + 2)..<terminator.start]
            if let pwd = pwd(from: payload) {
                pwds.append(pwd)
            }

            buffer.removeFirst(terminator.start + terminator.length)
            searchIndex = 0
        }

        buffer.removeAll(keepingCapacity: true)
        return pwds
    }

    private mutating func keepUnfinishedSequence(from index: Int) {
        if index > 0 {
            buffer.removeFirst(index)
        }
        trimRetainedBuffer()
    }

    private mutating func trimRetainedBuffer() {
        guard buffer.count > maxBufferLength else { return }
        buffer.removeFirst(buffer.count - maxBufferLength)
    }

    private func terminatorIndex(startingAt startIndex: Int) -> (start: Int, length: Int)? {
        var index = startIndex

        while index < buffer.count {
            if buffer[index] == 0x07 {
                return (index, 1)
            }

            if buffer[index] == 0x1B {
                guard index + 1 < buffer.count else { return nil }
                if buffer[index + 1] == 0x5C {
                    return (index, 2)
                }
            }

            index += 1
        }

        return nil
    }

    private func pwd(from payload: ArraySlice<UInt8>) -> String? {
        guard let separator = payload.firstIndex(of: 0x3B) else { return nil }
        let code = String(decoding: payload[payload.startIndex..<separator], as: UTF8.self)
        guard code == "7" else { return nil }

        let pwdBytes = payload[payload.index(after: separator)..<payload.endIndex]
        let pwd = String(decoding: pwdBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pwd.isEmpty ? nil : pwd
    }
}
