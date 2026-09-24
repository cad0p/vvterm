// SPDX-License-Identifier: MIT
//
//  TeleportErrorRedaction.swift
//  VVTerm
//
//  Redaction-safe renderings of errors that can carry server-supplied
//  payloads, for `.public` log interpolations.
//
//  Invariant: a `.public` log payload may never be a value that came off the
//  wire. `GRPCError.grpc(status:message:)` embeds the server's message (which
//  can echo a redirect URL and its per-run `secret_key`) and
//  `HeadlessError.http(status:body:)` embeds the raw response body. The
//  renderings here keep the case/status — the triage signal — and drop the
//  payload.
//
//  Local errors (a gRPC *connect* failure, a `SignerError`, a WebAuthn
//  builder error, an rpID rejection) keep their descriptive
//  `localizedDescription`: case-only rendering would discard the
//  errno/`OSStatus` signal they carry.
//

import Foundation

extension GRPCError {
    /// A redaction-safe rendering of a gRPC failure: the case (and status,
    /// where present) without the server's message, which can echo the
    /// redirect URL and its per-run `secret_key`.
    var redactedDescription: String {
        switch self {
        case .transport: return "transport"
        case .tls: return "tls"
        case .http2: return "http2"
        case .grpc(let status, _): return "grpc(status: \(status))"
        case .decode: return "decode"
        case .timeout: return "timeout"
        }
    }
}

/// Shared redaction-safe error renderings for `.public` log payloads.
enum TeleportErrorRedaction {

    /// A gRPC failure's shape: the case (and status, where present) without
    /// the server's message. A non-`GRPCError` falls back to its type name —
    /// never `localizedDescription`, which can carry a wire payload.
    static func grpcFailure(_ error: Error) -> String {
        (error as? GRPCError)?.redactedDescription
            ?? String(describing: type(of: error))
    }

    /// A headless web-api failure's shape: status only for `.http` (the body
    /// is the raw server response), locale-stable `URLError.Code` for
    /// `.transport` (never the OS message, whose `userInfo` can print
    /// `NSErrorFailingURLKey`). A non-`HeadlessError` keeps its
    /// `localizedDescription` — the local errors on this path are the
    /// descriptive ones.
    static func headlessFailure(_ error: Error) -> String {
        if case HeadlessError.http(let status, _) = error {
            return "HTTP \(status)"
        }
        if case HeadlessError.transport(_, let code) = error {
            return "transport code=\(code?.rawValue ?? 0)"
        }
        return error.localizedDescription
    }
}
