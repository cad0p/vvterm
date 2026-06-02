//
//  TerminalTitleSequenceParser.swift
//  VVTerm
//

import Foundation

nonisolated struct TerminalTitleSequenceParser {
    private var buffer: [UInt8] = []
    private let maxBufferLength: Int

    init(maxBufferLength: Int = 4096) {
        self.maxBufferLength = maxBufferLength
    }

    mutating func parse(_ data: Data) -> [String] {
        buffer.append(contentsOf: data)

        var titles: [String] = []
        var searchIndex = 0

        while searchIndex < buffer.count {
            guard let escapeIndex = buffer[searchIndex...].firstIndex(of: 0x1B) else {
                buffer.removeAll(keepingCapacity: true)
                return titles
            }

            guard escapeIndex + 1 < buffer.count else {
                keepUnfinishedSequence(from: escapeIndex)
                return titles
            }

            guard buffer[escapeIndex + 1] == 0x5D else {
                searchIndex = escapeIndex + 1
                continue
            }

            guard let terminator = terminatorIndex(startingAt: escapeIndex + 2) else {
                keepUnfinishedSequence(from: escapeIndex)
                return titles
            }

            let payload = buffer[(escapeIndex + 2)..<terminator.start]
            if let title = title(from: payload) {
                titles.append(title)
            }

            buffer.removeFirst(terminator.start + terminator.length)
            searchIndex = 0
        }

        buffer.removeAll(keepingCapacity: true)
        return titles
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

    private func title(from payload: ArraySlice<UInt8>) -> String? {
        guard let separator = payload.firstIndex(of: 0x3B) else { return nil }
        let code = String(decoding: payload[payload.startIndex..<separator], as: UTF8.self)
        guard code == "0" || code == "1" || code == "2" else { return nil }

        let titleBytes = payload[payload.index(after: separator)..<payload.endIndex]
        let title = String(decoding: titleBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
