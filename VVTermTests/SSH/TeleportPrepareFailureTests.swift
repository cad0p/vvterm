// SPDX-License-Identifier: MIT
//
//  TeleportPrepareFailureTests.swift
//  VVTermTests
//
//  Coverage for #268: the proxy's subsystem rejection text must be captured
//  bounded and sanitized, the stored prepare failure must survive to the
//  mask points, and the diagnostics spine must render the new error case
//  without its server-text payload.
//

import Foundation
import os
import Testing
@testable import VVTerm

/// Lock-protected call counter for the capture deadline test.
private final class CaptureCallCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    func increment() -> Int { lock.withLock { $0 += 1; return $0 } }
    var value: Int { lock.withLock { $0 } }
}

/// Scripted `libssh2_channel_read_ex` results for the capture tests.
private final class ScriptedChannelReader: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Int]())
    private let fillByte: UInt8

    init(results: [Int], fillByte: UInt8 = 0x41) {
        self.fillByte = fillByte
        lock.withLock { $0 = results }
    }

    func read(_ buffer: UnsafeMutableBufferPointer<UInt8>) -> Int {
        lock.withLock { results in
            guard !results.isEmpty else { return 0 }
            let result = results.removeFirst()
            if result > 0 {
                for index in 0..<min(result, buffer.count) {
                    buffer[index] = fillByte
                }
            }
            return result
        }
    }
}

struct TeleportPrepareFailureTests {

    // MARK: - Sanitizer

    @Test
    func sanitizeStripsC0C1AndDEL() {
        // 0x00 (NUL), 0x1B (ESC, 8-bit CSI's C0 cousin), 0x7F (DEL),
        // 0x9B (8-bit CSI, C1): all must be removed before the text reaches
        // the Ghostty banner.
        var input = Data("ok ".utf8)
        input.append(contentsOf: [0x00, 0x1B, 0x9B, 0x7F])
        input.append(Data("[31mred".utf8))
        #expect(TeleportSubsystemFailureMessage.sanitize(input) == "ok [31mred")
    }

    @Test
    func sanitizeDecodesByTheActualByteCountAndKeepsTrailingText() throws {
        // A full, non-NUL-terminated buffer: `String(cString:)` would read
        // past it. The tail must survive when it is inside the character cap.
        let text = "agent forwarding has not been requested"
        let data = Data(repeating: UInt8(ascii: "A"), count: 100) + Data(text.utf8)
        let sanitized = try #require(TeleportSubsystemFailureMessage.sanitize(data))
        #expect(sanitized.suffix(text.count) == Substring(text))
        #expect(sanitized.count == 100 + text.count)
    }

    @Test
    func sanitizeHandlesAFullNonNULBuffer() throws {
        // Every byte printable, no NUL terminator: the decode must use the
        // actual byte count and the character cap must bound the output.
        let sanitized = try #require(
            TeleportSubsystemFailureMessage.sanitize(Data(repeating: UInt8(ascii: "x"), count: 4096))
        )
        #expect(sanitized.count == TeleportSubsystemFailureMessage.characterLimit)
    }

    @Test
    func sanitizeReturnsNilForEmptyOrControlOnlyInput() {
        #expect(TeleportSubsystemFailureMessage.sanitize(Data()) == nil)
        #expect(TeleportSubsystemFailureMessage.sanitize(Data([0x00, 0x1B, 0x9B, 0x7F, 0x0A, 0x20])) == nil)
    }

    @Test
    func sanitizeKeepsNonASCIIPrintableText() {
        #expect(TeleportSubsystemFailureMessage.sanitize(Data("né — ok".utf8)) == "né — ok")
    }

    @Test
    func displayUsesTheSanitizedTextWhenPresent() {
        let message = TeleportSubsystemFailureMessage.display(
            code: -22,
            stderr: Data("agent forwarding has not been requested\n".utf8)
        )
        #expect(message == "agent forwarding has not been requested")
    }

    @Test
    func displayFallsBackToTheCodeWhenThereIsNoText() {
        #expect(
            TeleportSubsystemFailureMessage.display(code: -22, stderr: Data())
                == "proxy subsystem rejected (code -22)"
        )
        #expect(
            TeleportSubsystemFailureMessage.display(code: -22, stderr: Data([0x00, 0x1B]))
                == "proxy subsystem rejected (code -22)"
        )
    }

    // MARK: - Bounded capture

    @Test
    func captureReadsUntilEOF() async {
        let reader = ScriptedChannelReader(results: [5, 3, 0])
        let data = await TeleportSubsystemStderrCapture.capture(
            byteLimit: 64,
            deadline: ContinuousClock.now + .seconds(1),
            read: { reader.read($0) },
            sleep: {}
        )
        #expect(data == Data(repeating: 0x41, count: 8))
    }

    @Test
    func captureCapsAtTheByteLimit() async {
        let reader = ScriptedChannelReader(results: [64, 64, 64])
        let data = await TeleportSubsystemStderrCapture.capture(
            byteLimit: 100,
            deadline: ContinuousClock.now + .seconds(1),
            read: { reader.read($0) },
            sleep: {}
        )
        #expect(data.count == 100)
    }

    @Test
    func captureStopsOnAHardError() async {
        let reader = ScriptedChannelReader(results: [10, -13])
        let data = await TeleportSubsystemStderrCapture.capture(
            byteLimit: 64,
            deadline: ContinuousClock.now + .seconds(1),
            read: { reader.read($0) },
            sleep: {}
        )
        #expect(data.count == 10)
    }

    @Test
    func captureStopsAtTheDeadlineWhileEAGAINSpins() async {
        let counter = CaptureCallCounter()
        let start = ContinuousClock.now
        let data = await TeleportSubsystemStderrCapture.capture(
            byteLimit: 64,
            deadline: start + .milliseconds(25),
            read: { _ in
                _ = counter.increment()
                return Int(LIBSSH2_ERROR_EAGAIN)
            },
            sleep: { try? await Task.sleep(nanoseconds: 2_000_000) }
        )
        #expect(data.isEmpty)
        #expect(counter.value > 0)
        #expect(counter.value < 100, "the deadline must bound the EAGAIN retry loop")
        #expect(start.duration(to: ContinuousClock.now) < .seconds(5))
    }

    // MARK: - Stored failure rule

    @Test
    func storedFailureKeepsTheSSHError() throws {
        let failure = SSHError.teleportPrepareFailed("agent forwarding has not been requested")
        let stored = try #require(SSHSession.storedTeleportPrepareFailure(for: failure, previous: nil))
        guard case .teleportPrepareFailed(let message) = stored else {
            Issue.record("unexpected stored failure: \(stored)")
            return
        }
        #expect(message == "agent forwarding has not been requested")
    }

    @Test
    func storedFailureNeverStoresCancellation() throws {
        #expect(SSHSession.storedTeleportPrepareFailure(for: CancellationError(), previous: nil) == nil)
        let previous = SSHError.teleportPrepareFailed("previous")
        let stored = try #require(
            SSHSession.storedTeleportPrepareFailure(for: CancellationError(), previous: previous)
        )
        guard case .teleportPrepareFailed(let message) = stored else {
            Issue.record("unexpected stored failure: \(stored)")
            return
        }
        #expect(message == "previous")
    }

    @Test
    func storedFailureKeepsThePreviousFailureForNonSSHErrors() throws {
        let previous = SSHError.teleportPrepareFailed("previous")
        struct Unrelated: Error {}
        let stored = try #require(
            SSHSession.storedTeleportPrepareFailure(for: Unrelated(), previous: previous)
        )
        guard case .teleportPrepareFailed(let message) = stored else {
            Issue.record("unexpected stored failure: \(stored)")
            return
        }
        #expect(message == "previous")
    }

    // MARK: - Error rendering

    @Test
    func errorDescriptionCarriesTheProxyTextForTransientUI() {
        let error = SSHError.teleportPrepareFailed("access denied to deploy connecting to pc-admin")
        #expect(error.errorDescription?.contains("access denied to deploy connecting to pc-admin") == true)
        #expect(error.allowsAutomaticReconnectRetry == false)
    }

    @Test
    func diagnosticsMessageStripsTheServerText() {
        // The proxy text can embed the node name and the host login; the
        // shareable diagnostics spine must render the case name only.
        let message = SSHError.diagnosticsMessage(
            for: SSHError.teleportPrepareFailed("access denied to deploy connecting to pc-admin"),
            redacting: nil
        )
        #expect(message == "teleportPrepareFailed")
        #expect(!message.contains("deploy"))
        #expect(!message.contains("pc-admin"))
    }
}
