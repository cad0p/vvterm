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
//  can echo a redirect URL and its per-run `secret_key`),
//  `GRPCError.http2` embeds the raw HTTP body, and
//  `HeadlessError.http(status:body:)` embeds the raw response body. The
//  renderings here keep the case — and the status where it is structurally
//  available — and drop the payload. `.http2` keeps the case only: its
//  message packs the status and the body into one free-form string, so the
//  status cannot be recovered without parsing a payload-carrying string.
//
//  Local errors (a gRPC *connect* failure, a `SignerError`, a WebAuthn
//  builder error) keep their descriptive `localizedDescription`: case-only
//  rendering would discard the errno/`OSStatus` signal they carry.
//

import Foundation

extension GRPCError {
    /// A redaction-safe rendering of a gRPC failure: the case (and status,
    /// where present) without the server's message, which can echo the
    /// redirect URL and its per-run `secret_key`. `.http2` carries its status
    /// inside the same free-form string as the body, so only the case survives.
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
    ///
    /// Use at sites whose errors are known to come from the gRPC client.
    static func grpcFailure(_ error: Error) -> String {
        (error as? GRPCError)?.redactedDescription
            ?? String(describing: type(of: error))
    }

    /// A wire-derived failure's shape at sites that can receive **either**
    /// error family. The login path's live client throws
    /// `GRPCError.http2("<op> HTTP <status>: <body>")` — the raw body again —
    /// while the bootstrap path's client wraps every failure in
    /// `HeadlessError`. Both families are matched explicitly, so the
    /// `localizedDescription` fallback is reached only by the genuinely local
    /// errors those paths also produce (keychain, Safari, signer), whose text
    /// carries the triage signal.
    static func wireFailure(_ error: Error) -> String {
        if let grpc = error as? GRPCError {
            return grpc.redactedDescription
        }
        if case HeadlessError.http(let status, _) = error {
            return "HTTP \(status)"
        }
        if case HeadlessError.transport(_, let code) = error {
            return "transport code=\(code?.rawValue ?? 0)"
        }
        if let urlError = error as? URLError {
            // A raw URLSession failure — the trust session's `data(for:)` does
            // not wrap — keeps its locale-stable code, never the OS message.
            return "url code=\(urlError.code.rawValue)"
        }
        return error.localizedDescription
    }
}
