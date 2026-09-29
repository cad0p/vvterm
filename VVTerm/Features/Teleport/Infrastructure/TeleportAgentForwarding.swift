// SPDX-License-Identifier: MIT
//
//  TeleportAgentForwarding.swift
//  VVTerm
//
//  Serves the ssh-agent protocol on a server-initiated `auth-agent@openssh.com`
//  channel (#269).
//
//  Why this exists
//  ---------------
//  On a Teleport cluster whose `session_recording` mode records at the proxy
//  (`proxy` / `proxy-sync`), the legacy `proxy:<node>:0` subsystem takes
//  Teleport's `dialAndForward` path: the proxy terminates the client's SSH in
//  its in-memory forwarding server and dials the target node itself,
//  authenticating with the SSH agent the client must forward. Without it the
//  proxy's `StartAgentChannel()` returns
//  `AccessDenied("agent forwarding has not been requested")` and the subsystem
//  request is rejected (libssh2 -22).
//
//  The app requests the agent channel on the outer (proxy) session and serves
//  the proxy's REQUEST_IDENTITIES / SIGN_REQUEST messages using the same
//  Teleport certificate + ed25519 key it already holds. Signatures cover the
//  inner session's authentication only; the identity offered is the full
//  certificate blob.
//
//  Concurrency contract (pinned by the tests and the source pins)
//  --------------------------------------------------------------
//  - libssh2 invokes `LIBSSH2_CALLBACK_AUTHAGENT` from inside the packet-
//    receive path (`_libssh2_packet_add` -> `packet_authagent_open`) — i.e.
//    possibly while the bridge pump holds the non-reentrant `SessionMutex`.
//    The callback therefore only queues the channel (a plain lock); it never
//    performs libssh2 I/O, never takes `SessionMutex`, and never awaits.
//  - `session->abstract` is already owned by the keyboard-interactive
//    context, so the callback finds its per-session service through
//    `TeleportAgentCallbackRegistry` instead.
//  - The serving task is dedicated: it is NOT part of the bridge pump's
//    first-exit task group (an agent-channel EOF must not tear down the
//    tunnel). It has its own cancel token and stops synchronously in the
//    same pre-`libssh2_session_free` window as `cancelPumpSync`.
//  - Reading the agent channel touches the outer session, which the prepare
//    path also uses without the mutex up to the point the transport starts.
//    Serving is gated on (a) a successful `auth-agent-req@openssh.com` and
//    (b) the transport having started; libssh2 confirms the server-initiated
//    channel on callback registration alone, so the app itself must enforce
//    the request outcome.
//  - Ownership: the serving task never frees a channel. It retires the
//    channel from the handoff store when its serve loop ends (EOF, a hard
//    error, or cancellation); `cancelAndDrain` returns every channel still
//    queued or in flight and the synchronous teardown frees those before the
//    outer session is freed. A retired channel is reaped by
//    `libssh2_session_free`. That removes the free-vs-session-free race for a
//    cancelled task.
//
//  Logging contract: this file logs lifecycle counts only — never the
//  identity blob, a signature, the request `data`, or key material.

#if canImport(Darwin)
import Foundation
import os.log
import os

// MARK: - Identity

/// The identity the forwarded agent offers: the exact certificate blob the
/// inner session will also authenticate with, and its parsed signing key.
struct TeleportAgentIdentityMaterial: Sendable {
    let certBlob: Data
    let signingKey: OpenSSHEd25519PrivateKey
}

enum TeleportAgentIdentityError: Error, Equatable {
    /// The stored certificate PEM did not parse as an OpenSSH certificate.
    case unreadableCertificate
    /// The stored private key PEM did not parse as an `openssh-key-v1`
    /// ed25519 key (encrypted, malformed, or truncated).
    case unreadablePrivateKey(OpenSSHEd25519PrivateKey.ParseError)
    /// The key does not belong to the certificate. Serving this pair would
    /// produce signatures the node rejects.
    case publicKeyMismatch
}

enum TeleportAgentIdentity {
    /// Build the agent identity from one cert+key pair.
    ///
    /// Callers pass the exact `liveCredentialSnapshot` material the inner
    /// session authenticates with: an agent certificate that differs from the
    /// inner-auth certificate would sign for an identity the node does not
    /// accept.
    ///
    /// The returned error carries case names only — never the PEM bytes.
    static func make(certPEM: String, privateKeyPEM: Data) throws -> TeleportAgentIdentityMaterial {
        guard let certificate = OpenSSHCertificate.parse(authorizedKeysOrPEM: certPEM) else {
            throw TeleportAgentIdentityError.unreadableCertificate
        }
        let signingKey: OpenSSHEd25519PrivateKey
        do {
            signingKey = try OpenSSHEd25519PrivateKey.parse(pemData: privateKeyPEM)
        } catch let parseError as OpenSSHEd25519PrivateKey.ParseError {
            throw TeleportAgentIdentityError.unreadablePrivateKey(parseError)
        } catch {
            throw TeleportAgentIdentityError.unreadablePrivateKey(.malformed)
        }
        guard signingKey.publicKeyBlob == certificate.publicKeyBlob else {
            throw TeleportAgentIdentityError.publicKeyMismatch
        }
        return TeleportAgentIdentityMaterial(certBlob: certificate.rawBlob, signingKey: signingKey)
    }
}

// MARK: - Session-keyed callback registry

/// Maps an outer libssh2 session to the agent service that serves it.
///
/// `LIBSSH2_CALLBACK_AUTHAGENT` is a `@convention(c)` function that cannot
/// capture state, and libssh2 passes `&session->abstract`, which the
/// keyboard-interactive context already owns (see `KeyboardInteractiveContext`
/// in `SSHClient.swift`). This registry is the lookup instead. Every method is
/// synchronous and lock-protected; the callback path performs no I/O.
final class TeleportAgentCallbackRegistry: @unchecked Sendable {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    static let shared = TeleportAgentCallbackRegistry()

    private let lock = OSAllocatedUnfairLock(
        initialState: [OpaquePointer: TeleportAgentForwardingService]()
    )

    func register(_ service: TeleportAgentForwardingService, for session: OpaquePointer) {
        lock.withLock { $0[session] = service }
    }

    func remove(for session: OpaquePointer) {
        lock.withLock { $0[session] = nil }
    }

    func service(for session: OpaquePointer) -> TeleportAgentForwardingService? {
        lock.withLock { $0[session] }
    }

    /// Route a server-initiated channel open exactly like the C callback.
    ///
    /// Deterministic seam for the registry unit test (the C callback itself
    /// cannot be invoked with a real libssh2 channel in-process).
    ///
    /// - Returns: `true` when a registered service queued the channel.
    @discardableResult
    static func dispatch(session: OpaquePointer?, channel: OpaquePointer?) -> Bool {
        guard let session, let channel,
              let service = shared.service(for: session) else {
            return false
        }
        service.enqueue(channel)
        return true
    }
}

/// libssh2 `LIBSSH2_CALLBACK_AUTHAGENT`: the proxy opened
/// `auth-agent@openssh.com` and libssh2 already sent CHANNEL_OPEN_CONFIRMATION.
///
/// Queue only — no libssh2 I/O, no `SessionMutex`, no await. This runs on the
/// session's I/O thread inside the packet-receive path.
nonisolated(unsafe) private let teleportAuthAgentCallback: @convention(c) (
    OpaquePointer?,                                     // LIBSSH2_SESSION *
    OpaquePointer?,                                     // LIBSSH2_CHANNEL *
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?     // void **abstract
) -> Void = { session, channel, _ in
    _ = TeleportAgentCallbackRegistry.dispatch(session: session, channel: channel)
}

// MARK: - Channel handoff

/// Lock-protected handoff of server-initiated channels from the libssh2
/// callback to the serving task.
///
/// Ownership: `next()` moves a channel from `pending` to `inFlight`, and
/// `push()` puts a channel it hands directly to a parked `next()` straight
/// into `inFlight`; the serving task retires the channel once its serve loop
/// ends. The synchronous `cancelAndDrain()` takes everything that is still
/// queued or in flight, and the teardown frees it. The serving task never
/// frees, so a cancelled task cannot free a channel after
/// `libssh2_session_free` reaped it; a retired channel is reaped by that
/// session free.
final class TeleportAgentChannelStore: @unchecked Sendable {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    private struct State {
        var pending: [OpaquePointer] = []
        var inFlight: [OpaquePointer] = []
        var waiter: CheckedContinuation<OpaquePointer?, Never>?
        var cancelled = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Queue a channel. Called from the packet-receive path: no I/O, no wait.
    func push(_ channel: OpaquePointer) {
        lock.withLock { state in
            guard !state.cancelled else { return }
            if let waiter = state.waiter {
                state.waiter = nil
                // Track the channel before handing it to the parked `next()`:
                // the teardown must still be able to drain it while the
                // serving task owns it.
                state.inFlight.append(channel)
                waiter.resume(returning: channel)
            } else {
                state.pending.append(channel)
            }
        }
    }

    /// Next queued channel, or nil when the store is cancelled.
    func next() async -> OpaquePointer? {
        await withCheckedContinuation { continuation in
            lock.withLock { state in
                if state.cancelled {
                    continuation.resume(returning: nil)
                } else if !state.pending.isEmpty {
                    let channel = state.pending.removeFirst()
                    state.inFlight.append(channel)
                    continuation.resume(returning: channel)
                } else {
                    state.waiter = continuation
                }
            }
        }
    }

    /// Remove a channel whose serve loop has ended from `inFlight`. The
    /// serving task calls this after `serve`; if the teardown already drained
    /// the channel it is a no-op (the teardown owns the free), and a retired
    /// channel is left for `libssh2_session_free` to reap.
    func retire(_ channel: OpaquePointer) {
        lock.withLock { state in
            if let index = state.inFlight.firstIndex(of: channel) {
                state.inFlight.remove(at: index)
            }
        }
    }

    /// Test-observability seam: true while a `next()` caller is parked on the
    /// continuation (the waiter path). Never used by production code.
    var isWaitingForChannel: Bool {
        lock.withLock { $0.waiter != nil }
    }

    /// Cancel the store and return every channel the service still owns.
    func cancelAndDrain() -> [OpaquePointer] {
        lock.withLock { state in
            state.cancelled = true
            let drained = state.pending + state.inFlight
            state.pending.removeAll()
            state.inFlight.removeAll()
            if let waiter = state.waiter {
                state.waiter = nil
                waiter.resume(returning: nil)
            }
            return drained
        }
    }
}

// MARK: - Serving decision

/// One-shot serving gate: serve only when `auth-agent-req@openssh.com`
/// succeeded AND the bridge transport has started.
///
/// libssh2 accepts the server-initiated channel whenever the AUTHAGENT
/// callback is registered, and it confirms the channel before invoking the
/// callback — the app cannot refuse at open, so it must refuse to serve. The
/// transport gate keeps the serving task from calling into the outer session
/// while `prepareTeleportInnerSession` still uses it without the mutex.
final class TeleportAgentServingDecision: @unchecked Sendable {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    private struct State {
        var requestSucceeded: Bool?
        var transportStarted = false
        var decision: Bool?
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func resolveRequest(succeeded: Bool) {
        lock.withLock { state in
            state.requestSucceeded = succeeded
            Self.resolveIfDecided(&state)
        }
    }

    func markTransportStarted() {
        lock.withLock { state in
            state.transportStarted = true
            Self.resolveIfDecided(&state)
        }
    }

    /// Resolve to "do not serve" (teardown).
    func cancel() {
        lock.withLock { state in
            state.decision = false
            Self.resumeWaiterIfNeeded(&state)
        }
    }

    /// Wait for the decision. Returns false when cancelled.
    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.withLock { state in
                if let decision = state.decision {
                    continuation.resume(returning: decision)
                } else {
                    state.waiter = continuation
                }
            }
        }
    }

    private static func resolveIfDecided(_ state: inout State) {
        guard state.decision == nil else { return }
        if state.requestSucceeded == false {
            state.decision = false
        } else if state.requestSucceeded == true, state.transportStarted {
            state.decision = true
        }
        resumeWaiterIfNeeded(&state)
    }

    private static func resumeWaiterIfNeeded(_ state: inout State) {
        guard let decision = state.decision, let waiter = state.waiter else { return }
        state.waiter = nil
        waiter.resume(returning: decision)
    }
}

// MARK: - Serving task

/// The dedicated agent-serving task: pops queued channels, reads the
/// proxy's requests off them, answers, and stops on EOF/cancel without
/// touching the bridge tunnel.
final class TeleportAgentForwardingService: @unchecked Sendable {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    typealias ChannelRead = @Sendable (_ channel: OpaquePointer, _ buffer: UnsafeMutablePointer<UInt8>, _ maxLen: Int) -> Int
    typealias ChannelWrite = @Sendable (_ channel: OpaquePointer, _ buffer: UnsafePointer<UInt8>, _ len: Int) -> Int
    typealias ChannelClose = @Sendable (_ channel: OpaquePointer) -> Void

    /// Read buffer per channel iteration. The proxy's requests are a few
    /// hundred bytes; the codec's frame cap bounds what an over-limit peer
    /// can make the decoder buffer.
    private static let readBufferSize = 16 * 1024

    private let responder: SSHAgentProtocolResponder
    private let readChannel: ChannelRead
    private let writeChannel: ChannelWrite
    private let closeChannel: ChannelClose
    private let cancelToken: PumpCancelToken
    private let channels = TeleportAgentChannelStore()
    private let decision = TeleportAgentServingDecision()
    private let logger = Logger.forCategory("Teleport-Agent-Forwarding")
    private let taskState = OSAllocatedUnfairLock(initialState: Task<Void, Never>?(nil))

    init(
        identityMaterial: TeleportAgentIdentityMaterial,
        readChannel: @escaping ChannelRead,
        writeChannel: @escaping ChannelWrite,
        closeChannel: @escaping ChannelClose,
        cancelToken: PumpCancelToken
    ) {
        self.responder = SSHAgentProtocolResponder(
            identity: SSHAgentProtocolCodec.Identity(keyBlob: identityMaterial.certBlob),
            signer: { data in identityMaterial.signingKey.signature(for: data) }
        )
        self.readChannel = readChannel
        self.writeChannel = writeChannel
        self.closeChannel = closeChannel
        self.cancelToken = cancelToken
    }

    /// Production factory: libssh2 I/O over the outer session, serialized
    /// through the shared `SessionMutex`. Every call re-checks the cancel
    /// token *inside* the mutex, so a call that races the synchronous
    /// teardown either completes before the teardown's free or becomes a
    /// no-op.
    static func makeForSession(
        identityMaterial: TeleportAgentIdentityMaterial,
        mutex: any TeleportSessionMutex
    ) -> TeleportAgentForwardingService {
        let cancelToken = PumpCancelToken()
        return TeleportAgentForwardingService(
            identityMaterial: identityMaterial,
            readChannel: { channel, buffer, maxLen in
                mutex.withLock {
                    guard !cancelToken.isCancelled else { return 0 }
                    return Int(libssh2_channel_read_ex(channel, 0, buffer, maxLen))
                }
            },
            writeChannel: { channel, buffer, len in
                mutex.withLock {
                    guard !cancelToken.isCancelled else { return 0 }
                    return Int(libssh2_channel_write_ex(channel, 0, buffer, len))
                }
            },
            closeChannel: { channel in
                mutex.withLock {
                    _ = libssh2_channel_close(channel)
                    _ = libssh2_channel_free(channel)
                }
            },
            cancelToken: cancelToken
        )
    }

    /// The libssh2 session callback to install before the auth-agent request.
    static var sessionCallback: @convention(c) (
        OpaquePointer?,
        OpaquePointer?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> Void {
        teleportAuthAgentCallback
    }

    /// Start the dedicated serving task. Started before the auth-agent request
    /// so a channel opened during that request has a queue to land in; the
    /// task blocks on the serving decision until the outcome is known.
    func start() {
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.run()
        }
        taskState.withLock { $0 = task }
    }

    /// Queue a server-initiated channel. Called from the libssh2 packet-receive
    /// path (possibly while `SessionMutex` is held): no I/O, no await, no
    /// `SessionMutex`.
    func enqueue(_ channel: OpaquePointer) {
        channels.push(channel)
    }

    /// Record the `auth-agent-req@openssh.com` outcome (non-fatal: a failed
    /// request still allows a non-recording cluster to connect).
    func resolveRequest(succeeded: Bool) {
        decision.resolveRequest(succeeded: succeeded)
    }

    /// Open the serving gate once the bridge pump is running.
    func markTransportStarted() {
        decision.markTransportStarted()
    }

    /// Synchronous teardown for the pre-`libssh2_session_free` window: flips
    /// the cancel token, cancels the task, unblocks the decision, and returns
    /// every channel the service still owns. The caller frees them (under the
    /// outer-session mutex) before the session is freed.
    nonisolated func cancelAndDrain() -> [OpaquePointer] {
        cancelToken.cancel()
        decision.cancel()
        let task = taskState.withLock { state -> Task<Void, Never>? in
            let task = state
            state = nil
            return task
        }
        task?.cancel()
        return channels.cancelAndDrain()
    }

    /// Close + free a channel returned by `cancelAndDrain`. Only teardown
    /// calls this; the serving task never frees.
    nonisolated func closeAndFree(_ channel: OpaquePointer) {
        closeChannel(channel)
    }

    // MARK: - Serving

    private func run() async {
        let enabled = await decision.wait()
        guard enabled else {
            logger.info("teleport_agent_service_serving_disabled")
            return
        }
        logger.info("teleport_agent_service_started")
        while !cancelToken.isCancelled {
            guard let channel = await channels.next() else { break }
            await serve(channel)
            channels.retire(channel)
        }
        logger.info("teleport_agent_service_stopped")
    }

    private func serve(_ channel: OpaquePointer) async {
        var decoder = SSHAgentRequestDecoder()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.readBufferSize)
        defer { buffer.deallocate() }

        var byteCount = 0
        while !cancelToken.isCancelled {
            let count = readChannel(channel, buffer, Self.readBufferSize)
            if count == Int(LIBSSH2_ERROR_EAGAIN) {
                // Non-blocking session: wait outside the mutex, then retry.
                try? await Task.sleep(nanoseconds: 1_000_000)
                continue
            }
            // 0 = the proxy closed the channel; < 0 is a hard error. Either
            // way this channel is done — never the tunnel (M10).
            guard count > 0 else { break }
            byteCount += count

            let requests: [SSHAgentProtocolCodec.Request]
            do {
                requests = try decoder.ingest(Data(bytes: buffer, count: count))
            } catch {
                // Invalid frame length: the stream cannot be resynchronized.
                // Answer SSH_AGENT_FAILURE and end this channel.
                logger.info("teleport_agent_channel_decode_failed bytes=\(byteCount)")
                _ = await writeAll(channel: channel, data: SSHAgentProtocolCodec.failureFrame)
                break
            }

            var writeFailed = false
            for request in requests {
                let response = responder.response(for: request)
                if !(await writeAll(channel: channel, data: response)) {
                    writeFailed = true
                    break
                }
            }
            if writeFailed { break }
        }
        logger.info("teleport_agent_channel_ended bytes=\(byteCount)")
    }

    private func writeAll(channel: OpaquePointer, data: Data) async -> Bool {
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return writeChannel(channel, base.advanced(by: written), data.count - written)
            }
            if count == Int(LIBSSH2_ERROR_EAGAIN) {
                try? await Task.sleep(nanoseconds: 1_000_000)
                continue
            }
            guard count > 0 else { return false }
            written += count
        }
        return true
    }
}

#endif // canImport(Darwin)
