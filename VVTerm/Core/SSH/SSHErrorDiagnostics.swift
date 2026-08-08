//
//  SSHErrorDiagnostics.swift
//  VVTerm
//
//  Ring-safe error rendering for the on-device diagnostics spine.
//
//  os_log redacts private interpolations to `<private>` and logd purges
//  info-level entries under memory pressure, so SSH connection failures
//  never reached exported diagnostics reports (the report's early window
//  was ring-only, and the failure string was exactly what was missing).
//  `diagnosticsMessage` renders an error with configured host/port/username
//  and literal IP addresses redacted, so it is safe to persist in the
//  DiagnosticsRecorder ring while still identifying the failing stage.
//

import Foundation

extension SSHError {
    /// Ring-safe rendering of an SSH error: enum case name plus payload,
    /// with configured server tokens and literal IP:port pairs redacted.
    static func diagnosticsMessage(for error: Error, redacting server: Server?) -> String {
        let raw: String
        if let sshError = error as? SSHError {
            raw = String(describing: sshError)
        } else {
            raw = String(describing: error)
        }
        return Self.redacted(raw, server: server)
    }

    /// Redacts configured server tokens and literal IPv4[:port] pairs from a
    /// message. Exposed for tests; `diagnosticsMessage` is the entry point.
    static func redacted(_ message: String, server: Server?) -> String {
        var result = message
        if let server {
            // host:port first so the bare-host replacement cannot corrupt it.
            result = result.replacingOccurrences(
                of: "\(server.host):\(server.port)",
                with: "<host>:<port>"
            )
            result = redactToken(server.host, in: result, as: "<host>")
            result = redactToken(server.username, in: result, as: "<user>")
        }
        // DNS-resolved endpoints embedded by the transport (e.g. "Connection
        // refused (10.0.0.5:22)") are not covered by the configured host.
        result = result.replacingOccurrences(
            of: #"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d{1,5})?\b"#,
            with: "<addr>",
            options: .regularExpression
        )
        return result
    }

    private static func redactToken(_ token: String, in message: String, as replacement: String) -> String {
        guard !token.isEmpty else { return message }
        let escaped = NSRegularExpression.escapedPattern(for: token)
        return message.replacingOccurrences(
            of: "\\b\(escaped)\\b",
            with: replacement,
            options: .regularExpression
        )
    }
}
