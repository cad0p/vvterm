// SPDX-License-Identifier: MIT
//
//  TeleportAgentForwardingTests.swift
//  VVTermTests
//
//  Behavior coverage for the forwarded-agent service (#269): the session-keyed
//  callback registry, the serving gate (successful `auth-agent-req` + started
//  transport), the request/response loop over a fake channel, and the
//  synchronous drain/free ownership.
//
//  The libssh2 channel itself is not available in-process, so the channel I/O
//  is injected exactly like `SSHProxySubsystemTransportTests` does for the
//  bridge pump.
//

import CryptoKit
import Foundation
import os
import Testing
@testable import VVTerm

/// In-memory stand-in for a server-initiated agent channel. Reads return
/// EAGAIN while the channel is open and empty, 0 after `endOfStream()`.
final class FakeAgentChannel: @unchecked Sendable {
    private struct State {
        var inbound: [UInt8] = []
        var eof = false
        var readCount = 0
        var writes: [UInt8] = []
        var closeCount = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func enqueue(_ bytes: [UInt8]) {
        lock.withLock { $0.inbound.append(contentsOf: bytes) }
    }

    func endOfStream() {
        lock.withLock { $0.eof = true }
    }

    var readCount: Int { lock.withLock { $0.readCount } }
    var writtenBytes: [UInt8] { lock.withLock { $0.writes } }
    var closeCount: Int { lock.withLock { $0.closeCount } }

    func read(_ buffer: UnsafeMutablePointer<UInt8>, _ maxLen: Int) -> Int {
        lock.withLock { state in
            state.readCount += 1
            if !state.inbound.isEmpty {
                let count = min(maxLen, state.inbound.count)
                for index in 0..<count {
                    buffer[index] = state.inbound[index]
                }
                state.inbound.removeFirst(count)
                return count
            }
            return state.eof ? 0 : Int(LIBSSH2_ERROR_EAGAIN)
        }
    }

    func write(_ buffer: UnsafePointer<UInt8>, _ count: Int) -> Int {
        lock.withLock { state in
            for index in 0..<count {
                state.writes.append(buffer[index])
            }
            return count
        }
    }

    func close(_ channel: OpaquePointer) {
        lock.withLock { $0.closeCount += 1 }
    }
}

struct TeleportAgentForwardingTests {

    // MARK: - Fixtures

    private func makeIdentityMaterial() throws -> TeleportAgentIdentityMaterial {
        let pair = SSHPubKey.generateEd25519KeyPair(comment: "agent-test")
        let key = try OpenSSHEd25519PrivateKey.parse(pem: pair.privateKeyPEM)
        return TeleportAgentIdentityMaterial(certBlob: Data("vvterm-cert-blob".utf8), signingKey: key)
    }

    private func makeService(
        fake: FakeAgentChannel,
        material: TeleportAgentIdentityMaterial
    ) -> TeleportAgentForwardingService {
        TeleportAgentForwardingService(
            identityMaterial: material,
            readChannel: { _, buffer, maxLen in fake.read(buffer, maxLen) },
            writeChannel: { _, buffer, count in fake.write(buffer, count) },
            closeChannel: { channel in fake.close(channel) },
            cancelToken: PumpCancelToken()
        )
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval = 3,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() >= deadline {
                throw SSHError.timeout
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Callback registry

    @Test
    func registryRoutesAServerInitiatedChannelToItsSessionService() throws {
        let material = try makeIdentityMaterial()
        let fake = FakeAgentChannel()
        let service = makeService(fake: fake, material: material)
        let session = OpaquePointer(bitPattern: 0x1000)!
        let channel = OpaquePointer(bitPattern: 0x2000)!

        TeleportAgentCallbackRegistry.shared.register(service, for: session)
        defer { TeleportAgentCallbackRegistry.shared.remove(for: session) }

        #expect(TeleportAgentCallbackRegistry.dispatch(session: session, channel: channel))
        #expect(service.cancelAndDrain() == [channel])
    }

    @Test
    func registryIgnoresSessionsWithoutAService() {
        let session = OpaquePointer(bitPattern: 0x3000)!
        let channel = OpaquePointer(bitPattern: 0x4000)!
        #expect(!TeleportAgentCallbackRegistry.dispatch(session: session, channel: channel))
        #expect(!TeleportAgentCallbackRegistry.dispatch(session: nil, channel: channel))
    }

    @Test
    func registryRemovalStopsRouting() throws {
        let material = try makeIdentityMaterial()
        let fake = FakeAgentChannel()
        let service = makeService(fake: fake, material: material)
        let session = OpaquePointer(bitPattern: 0x5000)!
        let channel = OpaquePointer(bitPattern: 0x6000)!
        defer { _ = service.cancelAndDrain() }

        TeleportAgentCallbackRegistry.shared.register(service, for: session)
        TeleportAgentCallbackRegistry.shared.remove(for: session)
        #expect(!TeleportAgentCallbackRegistry.dispatch(session: session, channel: channel))
    }

    // MARK: - Serving gate

    @Test
    func serviceWithholdsServingUntilRequestAndTransportAreResolved() async throws {
        let material = try makeIdentityMaterial()
        let fake = FakeAgentChannel()
        let service = makeService(fake: fake, material: material)
        let channel = OpaquePointer(bitPattern: 0x7000)!
        defer { _ = service.cancelAndDrain() }

        service.start()
        service.enqueue(channel)
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(fake.readCount == 0, "must not read the agent channel before the serving decision")

        service.resolveRequest(succeeded: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(fake.readCount == 0, "must not read before the transport has started")

        service.markTransportStarted()
        fake.endOfStream()
        try await waitUntil { fake.readCount > 0 }
    }

    @Test
    func failedRequestNeverServesAQueuedChannel() async throws {
        let material = try makeIdentityMaterial()
        let fake = FakeAgentChannel()
        let service = makeService(fake: fake, material: material)
        let channel = OpaquePointer(bitPattern: 0x8000)!
        defer { _ = service.cancelAndDrain() }

        service.start()
        service.enqueue(channel)
        service.resolveRequest(succeeded: false)
        service.markTransportStarted()

        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(fake.readCount == 0, "a refused auth-agent request must never be served")
        // The unserved channel is owned by the teardown.
        #expect(service.cancelAndDrain() == [channel])
        #expect(fake.closeCount == 0, "the serving task must not free channels; teardown does")
    }

    // MARK: - Protocol serving

    @Test
    func serviceAnswersIdentitiesWithTheCertificateBlob() async throws {
        let material = try makeIdentityMaterial()
        let fake = FakeAgentChannel()
        let service = makeService(fake: fake, material: material)
        let channel = OpaquePointer(bitPattern: 0x9000)!
        defer { _ = service.cancelAndDrain() }

        service.start()
        service.enqueue(channel)
        fake.enqueue(Array(SSHAgentProtocolCodec.frame(Data([SSHAgentProtocolCodec.requestIdentities]))))
        fake.endOfStream()
        service.resolveRequest(succeeded: true)
        service.markTransportStarted()

        let expected = SSHAgentProtocolCodec.identitiesAnswerFrame(
            SSHAgentProtocolCodec.Identity(keyBlob: material.certBlob)
        )
        try await waitUntil { fake.writtenBytes.count >= expected.count }
        #expect(Data(fake.writtenBytes) == expected)
    }

    @Test
    func serviceSignsOnlyForTheOfferedCertificateBlob() async throws {
        let material = try makeIdentityMaterial()
        let fake = FakeAgentChannel()
        let service = makeService(fake: fake, material: material)
        let channel = OpaquePointer(bitPattern: 0xA000)!
        defer { _ = service.cancelAndDrain() }

        let signedData = Data("inner session authentication data".utf8)
        // A request carrying the plain key blob (not the offered certificate).
        let plainKeyRequest = SSHAgentProtocolCodec.frame(
            Data([SSHAgentProtocolCodec.signRequest])
                + SSHAgentProtocolCodec.sshString(material.signingKey.publicKeyBlob)
                + SSHAgentProtocolCodec.sshString(signedData)
                + SSHAgentProtocolCodec.uint32(0)
        )
        // A request carrying the offered certificate blob.
        let certRequest = SSHAgentProtocolCodec.frame(
            Data([SSHAgentProtocolCodec.signRequest])
                + SSHAgentProtocolCodec.sshString(material.certBlob)
                + SSHAgentProtocolCodec.sshString(signedData)
                + SSHAgentProtocolCodec.uint32(0)
        )

        service.start()
        service.enqueue(channel)
        fake.enqueue(Array(plainKeyRequest) + Array(certRequest))
        fake.endOfStream()
        service.resolveRequest(succeeded: true)
        service.markTransportStarted()

        let expectedSignatureCount = SSHAgentProtocolCodec.failureFrame.count
        try await waitUntil {
            fake.writtenBytes.count >= expectedSignatureCount + SSHAgentProtocolCodec.signResponseFrame(
                signature: Data(repeating: 0, count: 64)
            ).count
        }

        let written = Data(fake.writtenBytes)
        #expect(written.prefix(SSHAgentProtocolCodec.failureFrame.count) == SSHAgentProtocolCodec.failureFrame)
        let signResponse = written.suffix(
            SSHAgentProtocolCodec.signResponseFrame(signature: Data(repeating: 0, count: 64)).count
        )
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: material.signingKey.publicKeyRaw)
        #expect(publicKey.isValidSignature(Data(signResponse.suffix(64)), for: signedData))
    }

    @Test
    func serviceBuffersAFrameSplitAcrossReads() async throws {
        let material = try makeIdentityMaterial()
        let fake = FakeAgentChannel()
        let service = makeService(fake: fake, material: material)
        let channel = OpaquePointer(bitPattern: 0xB000)!
        defer { _ = service.cancelAndDrain() }

        service.start()
        service.enqueue(channel)
        // First read stops mid-frame; the second completes it.
        fake.enqueue([0x00, 0x00])
        fake.enqueue([0x00, 0x01, SSHAgentProtocolCodec.requestIdentities])
        fake.endOfStream()
        service.resolveRequest(succeeded: true)
        service.markTransportStarted()

        let expected = SSHAgentProtocolCodec.identitiesAnswerFrame(
            SSHAgentProtocolCodec.Identity(keyBlob: material.certBlob)
        )
        try await waitUntil { fake.writtenBytes.count >= expected.count }
        #expect(Data(fake.writtenBytes) == expected)
    }

    @Test
    func serviceEndsOnEOFWithoutFreeingTheChannel() async throws {
        let material = try makeIdentityMaterial()
        let fake = FakeAgentChannel()
        let service = makeService(fake: fake, material: material)
        let channel = OpaquePointer(bitPattern: 0xC000)!
        defer { _ = service.cancelAndDrain() }

        service.start()
        service.enqueue(channel)
        fake.endOfStream()
        service.resolveRequest(succeeded: true)
        service.markTransportStarted()

        try await waitUntil { fake.readCount > 0 }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(fake.closeCount == 0, "the serving task must not free the channel on EOF")
        #expect(service.cancelAndDrain() == [channel])
    }

    @Test
    func cancelAndDrainReturnsEveryChannelExactlyOnce() throws {
        let material = try makeIdentityMaterial()
        let fake = FakeAgentChannel()
        let service = makeService(fake: fake, material: material)
        let first = OpaquePointer(bitPattern: 0xD000)!
        let second = OpaquePointer(bitPattern: 0xD001)!
        defer { _ = service.cancelAndDrain() }

        service.enqueue(first)
        service.enqueue(second)
        #expect(Set(service.cancelAndDrain()) == Set([first, second]))
        #expect(service.cancelAndDrain().isEmpty)
    }

    // MARK: - Identity factory

    @Test
    func identityFactoryRejectsAKeyThatDoesNotMatchTheCertificate() throws {
        let pair = SSHPubKey.generateEd25519KeyPair(comment: "agent-test")
        let mismatched = Data([0x00, 0x01, 0x02])
        #expect(throws: TeleportAgentIdentityError.publicKeyMismatch) {
            try TeleportAgentIdentity.make(
                certPEM: OpenSSHCertificateTests.userCert,
                privateKeyPEM: Data(pair.privateKeyPEM.utf8)
            )
        }
        #expect(throws: TeleportAgentIdentityError.unreadableCertificate) {
            try TeleportAgentIdentity.make(certPEM: "not a certificate", privateKeyPEM: mismatched)
        }
    }

    @Test
    func identityFactoryReportsAnUnreadablePrivateKeyWithoutThePEM() throws {
        do {
            _ = try TeleportAgentIdentity.make(
                certPEM: OpenSSHCertificateTests.userCert,
                privateKeyPEM: Data("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----".utf8)
            )
            Issue.record("expected an unreadablePrivateKey error")
        } catch let error as TeleportAgentIdentityError {
            guard case .unreadablePrivateKey(let parseError) = error else {
                Issue.record("expected unreadablePrivateKey, got \(error)")
                return
            }
            #expect(parseError == .invalidMagic)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
