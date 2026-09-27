// SPDX-License-Identifier: MIT
//
//  SSHAgentProtocolCodecTests.swift
//  VVTermTests
//
//  Pinned wire-format coverage for the ssh-agent protocol codec (#269).
//
//  The proxy-recording path makes the app answer the proxy's agent requests,
//  so the request/response bytes and the security binding (sign only for the
//  offered certificate blob) are contracts, not implementation details.
//

import CryptoKit
import Foundation
import Testing
@testable import VVTerm

struct SSHAgentProtocolCodecTests {

    // MARK: - Response bytes (pinned)

    @Test
    func identitiesAnswerPinsTheWireBytes() {
        let identity = SSHAgentProtocolCodec.Identity(
            keyBlob: Data([0xAA, 0xBB]),
            comment: "vvterm"
        )
        let frame = SSHAgentProtocolCodec.identitiesAnswerFrame(identity)

        // uint32(21) | type 0x0C | uint32(1) | string(2 bytes) | string("vvterm")
        let expected = Data([
            0x00, 0x00, 0x00, 0x15,
            0x0C,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB,
            0x00, 0x00, 0x00, 0x06,
            0x76, 0x76, 0x74, 0x65, 0x72, 0x6D,
        ])
        #expect(frame == expected)
    }

    @Test
    func failurePinsTheWireBytes() {
        #expect(SSHAgentProtocolCodec.failureFrame == Data([0x00, 0x00, 0x00, 0x01, 0x05]))
    }

    @Test
    func signResponsePinsTheEd25519SignatureBlob() {
        let signature = Data(repeating: 0xAB, count: 64)
        let frame = SSHAgentProtocolCodec.signResponseFrame(signature: signature)

        let expected = Data([
            // uint32(88): 1 type + uint32(83) + signature blob
            0x00, 0x00, 0x00, 0x58,
            0x0E,
            // string(signature blob) — 83 bytes
            0x00, 0x00, 0x00, 0x53,
            // string("ssh-ed25519")
            0x00, 0x00, 0x00, 0x0B,
        ]) + Data("ssh-ed25519".utf8) + Data([
            // string(64-byte signature)
            0x00, 0x00, 0x00, 0x40,
        ]) + signature

        #expect(frame == expected)
    }

    // MARK: - Decoder

    @Test
    func decoderParsesRequestIdentities() throws {
        var decoder = SSHAgentRequestDecoder()
        let requests = try decoder.ingest(Data([0x00, 0x00, 0x00, 0x01, 0x0B]))
        #expect(requests == [.requestIdentities])
    }

    @Test
    func decoderBuffersAFrameSplitAcrossReads() throws {
        var decoder = SSHAgentRequestDecoder()
        // First read: only the length prefix (and part of it).
        #expect(try decoder.ingest(Data([0x00, 0x00])) == [])
        #expect(try decoder.ingest(Data([0x00, 0x01])) == [])
        // Second read: the type byte completes the frame.
        #expect(try decoder.ingest(Data([0x0B])) == [.requestIdentities])
    }

    @Test
    func decoderEmitsMultipleFramesFromOneRead() throws {
        var decoder = SSHAgentRequestDecoder()
        let twoFrames = Data([
            0x00, 0x00, 0x00, 0x01, 0x0B,
            0x00, 0x00, 0x00, 0x01, 0x0B,
        ])
        #expect(try decoder.ingest(twoFrames) == [.requestIdentities, .requestIdentities])
    }

    @Test
    func decoderParsesASignRequest() throws {
        let keyBlob = Data([0x01, 0x02, 0x03])
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let message = Data([0x0D])
            + SSHAgentProtocolCodec.sshString(keyBlob)
            + SSHAgentProtocolCodec.sshString(data)
            + SSHAgentProtocolCodec.uint32(0)
        let frame = SSHAgentProtocolCodec.frame(message)

        var decoder = SSHAgentRequestDecoder()
        #expect(
            try decoder.ingest(frame)
                == [.signRequest(keyBlob: keyBlob, data: data, flags: 0)]
        )
    }

    @Test
    func decoderTreatsAMalformedSignRequestAsUnsupported() throws {
        // The `data` field declares more bytes than the frame holds.
        let message = Data([0x0D])
            + SSHAgentProtocolCodec.sshString(Data([0x01]))
            + SSHAgentProtocolCodec.uint32(64)
            + Data([0x00, 0x00, 0x00, 0x00])
        var decoder = SSHAgentRequestDecoder()
        #expect(try decoder.ingest(SSHAgentProtocolCodec.frame(message)) == [.unsupported])
    }

    @Test
    func decoderTreatsUnknownRequestTypesAsUnsupported() throws {
        var decoder = SSHAgentRequestDecoder()
        #expect(try decoder.ingest(Data([0x00, 0x00, 0x00, 0x01, 0x63])) == [.unsupported])
    }

    @Test
    func decoderRejectsAnOverLimitFrameLengthBeforeAllocation() throws {
        var decoder = SSHAgentRequestDecoder()
        // uint32(0xFFFFFFFF) declares a 4 GiB frame. The decoder must reject
        // the declared length without buffering anything of that size (and
        // without emitting a request).
        #expect(throws: SSHAgentProtocolCodec.DecodeError.invalidFrameLength(0xFFFF_FFFF)) {
            try decoder.ingest(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x0B]))
        }
    }

    @Test
    func decoderRejectsAZeroLengthFrame() throws {
        var decoder = SSHAgentRequestDecoder()
        #expect(throws: SSHAgentProtocolCodec.DecodeError.invalidFrameLength(0)) {
            try decoder.ingest(Data([0x00, 0x00, 0x00, 0x00]))
        }
    }

    @Test
    func decoderAcceptsAFrameExactlyAtTheCap() throws {
        // The cap is inclusive: a frame whose declared length equals
        // maxFrameLength is buffered and parsed.
        var decoder = SSHAgentRequestDecoder()
        let payload = Data([0x0B]) + Data(repeating: 0x00, count: SSHAgentProtocolCodec.maxFrameLength - 1)
        #expect(try decoder.ingest(SSHAgentProtocolCodec.frame(payload)) == [.requestIdentities])
    }

    // MARK: - Responder (identity binding)

    private func makeSigner() -> (signer: @Sendable (Data) -> Data?, publicKey: Curve25519.Signing.PublicKey) {
        let key = Curve25519.Signing.PrivateKey()
        return (
            { data in try? key.signature(for: data) },
            key.publicKey
        )
    }

    @Test
    func responderSignsTheExactRequestedDataForTheOfferedCertificateBlob() throws {
        let (signer, publicKey) = makeSigner()
        let certBlob = Data("certificate blob".utf8)
        let responder = SSHAgentProtocolResponder(
            identity: SSHAgentProtocolCodec.Identity(keyBlob: certBlob),
            signer: signer
        )
        let data = Data("session id that must be signed".utf8)

        let response = responder.response(for: .signRequest(keyBlob: certBlob, data: data, flags: 0))

        // The response is a SIGN_RESPONSE frame whose final 64 bytes are the
        // ed25519 signature over exactly `data`.
        #expect(SSHAgentProtocolCodec.readUInt32(response, at: 0) == UInt32(response.count - 4))
        #expect(response[response.startIndex + 4] == SSHAgentProtocolCodec.signResponse)
        let signature = Data(response.suffix(64))
        #expect(publicKey.isValidSignature(signature, for: data))
        #expect(!publicKey.isValidSignature(signature, for: Data("other data".utf8)))
    }

    @Test
    func responderRefusesThePlainKeyBlob() {
        let (signer, _) = makeSigner()
        let responder = SSHAgentProtocolResponder(
            identity: SSHAgentProtocolCodec.Identity(keyBlob: Data("certificate blob".utf8)),
            signer: signer
        )
        // A plain-key blob is not the offered certificate blob.
        let response = responder.response(
            for: .signRequest(keyBlob: Data("plain key blob".utf8), data: Data([1]), flags: 0)
        )
        #expect(response == SSHAgentProtocolCodec.failureFrame)
    }

    @Test
    func responderRefusesAForeignCertificateBlob() {
        let (signer, _) = makeSigner()
        let responder = SSHAgentProtocolResponder(
            identity: SSHAgentProtocolCodec.Identity(keyBlob: Data("certificate blob".utf8)),
            signer: signer
        )
        let response = responder.response(
            for: .signRequest(keyBlob: Data("foreign certificate".utf8), data: Data([1]), flags: 0)
        )
        #expect(response == SSHAgentProtocolCodec.failureFrame)
    }

    @Test
    func responderRefusesUnknownFlagBits() {
        let (signer, _) = makeSigner()
        let certBlob = Data("certificate blob".utf8)
        let responder = SSHAgentProtocolResponder(
            identity: SSHAgentProtocolCodec.Identity(keyBlob: certBlob),
            signer: signer
        )
        // The RSA-only flag bits are meaningless for ed25519; unsupported
        // flags MUST be answered with SSH_AGENT_FAILURE (RFC 9987).
        let response = responder.response(
            for: .signRequest(keyBlob: certBlob, data: Data([1]), flags: 2)
        )
        #expect(response == SSHAgentProtocolCodec.failureFrame)
    }

    @Test
    func responderRefusesAnOverLimitSignPayload() {
        let (signer, _) = makeSigner()
        let certBlob = Data("certificate blob".utf8)
        let responder = SSHAgentProtocolResponder(
            identity: SSHAgentProtocolCodec.Identity(keyBlob: certBlob),
            signer: signer
        )
        let data = Data(repeating: 0x00, count: SSHAgentProtocolCodec.maxSignDataLength + 1)
        let response = responder.response(
            for: .signRequest(keyBlob: certBlob, data: data, flags: 0)
        )
        #expect(response == SSHAgentProtocolCodec.failureFrame)
    }

    @Test
    func responderAnswersFailureWhenTheSignerFails() {
        let certBlob = Data("certificate blob".utf8)
        let responder = SSHAgentProtocolResponder(
            identity: SSHAgentProtocolCodec.Identity(keyBlob: certBlob),
            signer: { _ in nil }
        )
        let response = responder.response(
            for: .signRequest(keyBlob: certBlob, data: Data([1]), flags: 0)
        )
        #expect(response == SSHAgentProtocolCodec.failureFrame)
    }

    @Test
    func responderAnswersIdentitiesWithTheCertificateBlob() {
        let certBlob = Data([0x03, 0x04, 0x05])
        let responder = SSHAgentProtocolResponder(
            identity: SSHAgentProtocolCodec.Identity(keyBlob: certBlob, comment: "vvterm"),
            signer: { _ in nil }
        )
        let response = responder.response(for: .requestIdentities)

        // Parse the answer by hand: type 0x0C, one identity, the cert blob.
        #expect(response[response.startIndex + 4] == SSHAgentProtocolCodec.identitiesAnswer)
        #expect(SSHAgentProtocolCodec.readUInt32(response, at: 5) == 1)
        #expect(SSHAgentProtocolCodec.readUInt32(response, at: 9) == UInt32(certBlob.count))
        #expect(response.subdata(in: 13..<(13 + certBlob.count)) == certBlob)
    }
}
