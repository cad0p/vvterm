// SPDX-License-Identifier: MIT
//
//  SSHAgentProtocolCodec.swift
//  VVTerm
//
//  Pure ssh-agent protocol codec (RFC 9987 / OpenSSH PROTOCOL.agent) for the
//  subset VVTerm serves over a server-initiated `auth-agent@openssh.com`
//  channel. This is the message layer used by the Teleport proxy-recording
//  path (#269): the proxy's forwarding server authenticates to the target
//  node with the SSH agent the client forwards, so the app must answer
//  REQUEST_IDENTITIES and SIGN_REQUEST on that channel.
//
//  Layout (PROTOCOL.agent):
//    - Every message is a uint32 length prefix (big-endian) covering the
//      message-type byte plus the payload, followed by the type byte and the
//      payload itself.
//    - Strings inside a message are uint32 length-prefixed.
//    - libssh2_channel_read_ex returns arbitrary byte counts, so a request
//      can be split across reads: `SSHAgentRequestDecoder` is stateful and
//      accumulates bytes until a whole frame is present.
//
//  Security contract (pinned by the unit tests):
//    - The single identity is the full certificate blob. A SIGN_REQUEST is
//      answered only when its `key_blob` matches that blob byte-for-byte;
//      the plain-key blob, a foreign certificate, an unknown flag bit, or an
//      over-limit payload all get SSH_AGENT_FAILURE. The authenticated peer
//      gets a key-scoped agent, never a signing oracle over the raw key.
//    - Frame lengths are capped before any allocation, so a hostile peer
//      cannot make the app allocate an attacker-chosen size.
//    - Nothing in this file logs, and no request bytes are ever returned to
//      a log/diagnostics sink by its callers.
//
//  The signer is injected as a closure, so this file carries no CryptoKit and
//  no Teleport types.

import Foundation

enum SSHAgentProtocolCodec {
    // MARK: - Message types (PROTOCOL.agent)

    static let requestIdentities: UInt8 = 11
    static let identitiesAnswer: UInt8 = 12
    static let signRequest: UInt8 = 13
    static let signResponse: UInt8 = 14
    static let failure: UInt8 = 5

    /// Upper bound on one length-prefixed frame (OpenSSH's
    /// `AGENT_MAX_MSGLEN`, which caps the whole message including the type
    /// byte). A declared length above this is rejected before allocation.
    static let maxFrameLength = 256 * 1024

    /// Upper bound on the `data` a SIGN_REQUEST may ask to sign. OpenSSH's
    /// ssh-agent caps the whole message at 256 KiB; this makes the sign
    /// payload bound explicit (and the responder answers SSH_AGENT_FAILURE,
    /// never signs, above it).
    static let maxSignDataLength = 256 * 1024

    /// The single identity the agent offers. `keyBlob` is the full
    /// certificate blob (`OpenSSHCertificate.rawBlob`) — never the plain
    /// public key and never the CA-signed prefix.
    struct Identity: Sendable, Equatable {
        let keyBlob: Data
        let comment: String

        init(keyBlob: Data, comment: String = "vvterm") {
            self.keyBlob = keyBlob
            self.comment = comment
        }
    }

    /// A decoded agent request. `unsupported` covers every well-formed
    /// message type the app does not implement (including a malformed
    /// SIGN_REQUEST whose fields run past the end of its frame); both map to
    /// SSH_AGENT_FAILURE.
    enum Request: Sendable, Equatable {
        case requestIdentities
        case signRequest(keyBlob: Data, data: Data, flags: UInt32)
        case unsupported
    }

    enum DecodeError: Error, Equatable {
        /// The declared frame length is zero or exceeds `maxFrameLength`.
        /// The byte stream cannot be resynchronized after this, so the
        /// serving loop answers SSH_AGENT_FAILURE and ends the channel.
        case invalidFrameLength(UInt32)
    }

    // MARK: - Wire helpers

    /// SSH wire helper: `uint32_be(length) || payload`.
    static func sshString(_ data: Data) -> Data {
        var out = Data(capacity: 4 + data.count)
        out.append(uint32(UInt32(data.count)))
        out.append(data)
        return out
    }

    static func sshString(_ string: String) -> Data {
        sshString(Data(string.utf8))
    }

    /// Big-endian uint32.
    static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    /// Wrap a message (type byte + payload) in its `uint32` length prefix.
    static func frame(_ message: Data) -> Data {
        var out = Data(capacity: 4 + message.count)
        out.append(uint32(UInt32(message.count)))
        out.append(message)
        return out
    }

    /// Read a big-endian uint32 at `offset`, or nil when the buffer is short.
    static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, data.count - offset >= 4 else { return nil }
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24
            | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8
            | UInt32(data[base + 3])
    }

    // MARK: - Responses

    static var failureFrame: Data {
        frame(Data([failure]))
    }

    /// `SSH_AGENT_IDENTITIES_ANSWER`: one identity (the certificate blob).
    static func identitiesAnswerFrame(_ identity: Identity) -> Data {
        var message = Data([identitiesAnswer])
        message.append(uint32(1))
        message.append(sshString(identity.keyBlob))
        message.append(sshString(Data(identity.comment.utf8)))
        return frame(message)
    }

    /// `SSH_AGENT_SIGN_RESPONSE` with an ed25519 signature blob:
    /// `string( string("ssh-ed25519") || string(signature) )`.
    static func signResponseFrame(signature: Data) -> Data {
        var signatureBlob = sshString("ssh-ed25519")
        signatureBlob.append(sshString(signature))
        var message = Data([signResponse])
        message.append(sshString(signatureBlob))
        return frame(message)
    }
}

/// Stateful decoder: accumulates raw channel bytes and emits whole requests.
///
/// A request can arrive split across reads (and several requests can arrive
/// in one read); the reader buffers only up to the currently declared frame
/// length, and rejects an over-limit declared length before allocating
/// anything.
struct SSHAgentRequestDecoder {
    private var buffer = Data()

    /// Feed the bytes read from the agent channel; returns every complete
    /// request now available.
    ///
    /// - Throws: `SSHAgentProtocolCodec.DecodeError.invalidFrameLength` when
    ///   the stream declares a zero/over-limit frame. The stream cannot be
    ///   resynchronized reliably after this, so the caller should answer
    ///   SSH_AGENT_FAILURE and end the channel.
    mutating func ingest(_ bytes: Data) throws -> [SSHAgentProtocolCodec.Request] {
        buffer.append(bytes)
        var requests: [SSHAgentProtocolCodec.Request] = []

        while true {
            guard let declaredLength = SSHAgentProtocolCodec.readUInt32(buffer, at: 0) else {
                break  // fewer than 4 bytes of length prefix so far
            }
            guard declaredLength > 0,
                  declaredLength <= UInt32(SSHAgentProtocolCodec.maxFrameLength) else {
                throw SSHAgentProtocolCodec.DecodeError.invalidFrameLength(declaredLength)
            }
            let frameLength = Int(declaredLength)
            let totalLength = 4 + frameLength
            guard buffer.count >= totalLength else {
                break  // whole frame not here yet
            }

            // Slice relative to the buffer's own indices: `removeFirst`
            // advances `startIndex`, and `Data.subdata(in:)` interprets its
            // range in absolute indices (it traps once the buffer has been
            // consumed from the front). `Data(_:)` normalizes the slice.
            let frameStart = buffer.startIndex + 4
            let message = Data(buffer[frameStart..<(frameStart + frameLength)])
            buffer.removeFirst(totalLength)
            requests.append(Self.parse(message))
        }

        return requests
    }

    private static func parse(_ message: Data) -> SSHAgentProtocolCodec.Request {
        guard let type = message.first else { return .unsupported }
        switch type {
        case SSHAgentProtocolCodec.requestIdentities:
            return .requestIdentities
        case SSHAgentProtocolCodec.signRequest:
            return parseSignRequest(message)
        default:
            return .unsupported
        }
    }

    private static func parseSignRequest(_ message: Data) -> SSHAgentProtocolCodec.Request {
        // message[0] is the type byte; the payload is three fields:
        // string key_blob, string data, uint32 flags.
        var reader = BlobReader(data: message, offset: 1)
        guard let keyBlob = reader.readString(maxLength: SSHAgentProtocolCodec.maxFrameLength),
              let data = reader.readString(maxLength: SSHAgentProtocolCodec.maxSignDataLength),
              let flags = reader.readUInt32(),
              reader.remaining == 0 else {
            return .unsupported
        }
        return .signRequest(keyBlob: keyBlob, data: data, flags: flags)
    }

    /// Offset-tracking reader over one already length-capped frame. String
    /// lengths are validated against the remaining bytes before slicing, so a
    /// malformed length cannot allocate or read past the frame.
    private struct BlobReader {
        let data: Data
        var offset: Int

        var remaining: Int { data.count - offset }

        mutating func readUInt32() -> UInt32? {
            guard let value = SSHAgentProtocolCodec.readUInt32(data, at: offset) else { return nil }
            offset += 4
            return value
        }

        mutating func readString(maxLength: Int) -> Data? {
            guard let length = readUInt32() else { return nil }
            let count = Int(length)
            guard count <= maxLength, count <= remaining else { return nil }
            let start = data.startIndex + offset
            offset += count
            return Data(data[start..<(start + count)])
        }
    }
}

/// Answers decoded requests from one identity and one injected signer.
///
/// The signer is pure CryptoKit provided by the caller (it must not touch
/// libssh2, the Keychain, or the main actor — it runs on the serving task
/// without any `await`).
struct SSHAgentProtocolResponder: Sendable {
    let identity: SSHAgentProtocolCodec.Identity
    /// Raw ed25519 signature over the request `data`, or nil on failure.
    let signer: @Sendable (Data) -> Data?

    func response(for request: SSHAgentProtocolCodec.Request) -> Data {
        switch request {
        case .requestIdentities:
            return SSHAgentProtocolCodec.identitiesAnswerFrame(identity)

        case .signRequest(let keyBlob, let data, let flags):
            // Bind the sign request to the certificate blob this agent
            // offered. A plain-key blob, a foreign certificate, or an
            // unsupported flag bit is refused with SSH_AGENT_FAILURE — the
            // peer must never get a signature over arbitrary data from the
            // raw key. ed25519 has no flag bits (RFC 9987: unsupported flags
            // MUST be answered with SSH_AGENT_FAILURE).
            guard keyBlob == identity.keyBlob else {
                return SSHAgentProtocolCodec.failureFrame
            }
            guard flags == 0 else {
                return SSHAgentProtocolCodec.failureFrame
            }
            guard data.count <= SSHAgentProtocolCodec.maxSignDataLength else {
                return SSHAgentProtocolCodec.failureFrame
            }
            guard let signature = signer(data) else {
                return SSHAgentProtocolCodec.failureFrame
            }
            return SSHAgentProtocolCodec.signResponseFrame(signature: signature)

        case .unsupported:
            return SSHAgentProtocolCodec.failureFrame
        }
    }
}
