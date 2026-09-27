// SPDX-License-Identifier: MIT
//
//  TeleportSubsystemFailureMessage.swift
//  VVTerm
//
//  Bounded capture + sanitization of the proxy's channel stderr for a
//  rejected `proxy:<node>:0` subsystem (#268).
//
//  Teleport's proxy writes the rejection reason to the subsystem channel's
//  stderr before replying CHANNEL_FAILURE (`replyError`). That text — e.g.
//  `agent forwarding has not been requested`, or
//  `access denied to <login> connecting to <node>` — is the actionable error.
//  Before this, the app read stderr once on a non-blocking outer session,
//  decoded it with `String(cString:)` (an out-of-bounds read on a full
//  4096-byte buffer) and threw it away, surfacing `.notConnected` instead.
//
//  Capture contract:
//    - bounded in bytes (4096) and wall-clock;
//    - decoded by the actual byte count, never by a NUL scan;
//    - C0, DEL and C1 control bytes are stripped before the text reaches the
//      terminal banner (C1 includes 8-bit CSI U+009B, which Ghostty would
//      interpret as an escape introducer);
//    - the display text is capped and trimmed.
//
//  The sanitized text is transient UI only (`SSHError.errorDescription`). The
//  diagnostics spine renders the error case name instead: the text is
//  arbitrary server output that can embed the node name or the host login and
//  cannot be token-redacted reliably.

import Foundation

enum TeleportSubsystemFailureMessage {
    /// Hard cap on captured stderr bytes (the old read buffer's size).
    static let byteLimit = 4096
    /// Hard cap on displayed characters after sanitization.
    static let characterLimit = 512

    /// Decode + sanitize captured stderr; nil when nothing printable remains.
    static func sanitize(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        // Decode by the actual byte count. `String(cString:)` on a full,
        // non-NUL-terminated buffer reads past the captured bytes.
        let decoded = String(decoding: data, as: UTF8.self)
        var output = String.UnicodeScalarView()
        for scalar in decoded.unicodeScalars {
            // Strip C0 (0x00–0x1F), DEL (0x7F) and C1 (0x80–0x9F) controls.
            // U+FFFD is the decoder's replacement for an invalid UTF-8 byte:
            // the proxy's text is UTF-8, so a malformed byte is noise and
            // must not reach the terminal.
            if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) {
                continue
            }
            if scalar == "\u{FFFD}" {
                continue
            }
            output.append(scalar)
            if output.count >= characterLimit { break }
        }
        let sanitized = String(output).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    /// The user-visible reason for a rejected subsystem: the sanitized proxy
    /// text when there is any, otherwise a static fallback naming the code.
    static func display(code: Int32, stderr: Data) -> String {
        if let text = sanitize(stderr) {
            return text
        }
        return "proxy subsystem rejected (code \(code))"
    }
}

/// Bounded, length-aware stderr capture loop with injected I/O so the
/// deadline/EAGAIN/cap behavior is unit-testable without a live channel.
enum TeleportSubsystemStderrCapture {
    /// One `libssh2_channel_read_ex`-shaped call into the provided buffer.
    typealias Read = @Sendable (UnsafeMutableBufferPointer<UInt8>) -> Int

    /// Read stderr until EOF, a hard error, the byte limit, or the deadline.
    static func capture(
        byteLimit: Int = TeleportSubsystemFailureMessage.byteLimit,
        deadline: ContinuousClock.Instant,
        read: Read,
        sleep: @Sendable () async -> Void
    ) async -> Data {
        var captured = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while captured.count < byteLimit, ContinuousClock.now < deadline {
            let count = buffer.withUnsafeMutableBufferPointer { read($0) }
            if count > 0 {
                let remaining = byteLimit - captured.count
                captured.append(contentsOf: buffer.prefix(min(count, buffer.count, remaining)))
                continue
            }
            if count == Int(LIBSSH2_ERROR_EAGAIN) {
                // Non-blocking outer session: yield outside the read, then
                // retry until the deadline. The proxy's text is already in
                // the channel buffer by the time CHANNEL_FAILURE arrives, so
                // this is a short grace window, not a wait for new data.
                await sleep()
                continue
            }
            break  // EOF (0) or a hard error
        }
        return captured
    }
}
