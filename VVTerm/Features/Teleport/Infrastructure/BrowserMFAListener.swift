// SPDX-License-Identifier: MIT
//
//  BrowserMFAListener.swift
//  VVTerm
//
//  The loopback HTTP endpoint that captures the Browser MFA approval redirect.
//
//  The existing-device registration ceremony opens Safari on the auth
//  server's approval page. That page POSTs the signed WebAuthn assertion back
//  to a loopback URL the client chose before the ceremony started, so the
//  listener must be up (and its port known) before `CreateAuthenticateChallenge`
//  is called. The URL is advertised as `http://localhost:<port>/callback`:
//  a literal loopback IP triggers Safari's "Not Secure Connection Warning",
//  while `localhost` resolves to either family, so both `127.0.0.1` and `::1`
//  are bound when the OS lets them share the port.
//
//  The callback is not trusted just because it arrived on the loopback port —
//  any local process can connect. The URL registered with the auth server
//  advertises a per-run `?secret_key=<hex>` value, but that is a
//  key-delivery parameter carried on the authenticated app→server channel,
//  not an inbound credential: Teleport reads it from the registered URL,
//  seals the assertion under the per-run AES-256-GCM key, and replaces the
//  entire query with `?response=…` before the browser navigates back. The
//  listener therefore authenticates the callback solely with the GCM tag
//  under the per-run key it holds: an envelope that does not open is
//  answered 400 and does not resolve the login, and only a payload that
//  authenticates and then fails to decode is terminal. Requiring the
//  browser-facing callback to echo `secret_key` would reject every genuine
//  redirect (issue #241). The security boundary is the confidentiality of
//  the registered callback URL on the mTLS channel to the auth server.
//
//  The listener never logs the secret key, the full callback URL, the
//  received query values, or the decrypted payload.
//

import Foundation
import CryptoKit
import Network
import os.log

#if canImport(Network)

// MARK: - Errors

/// Errors surfaced by `BrowserMFAListener`.
nonisolated enum BrowserMFAListenerError: Error, LocalizedError {
    case listenerFailed(String)
    case notReady
    case timedOut
    case unauthenticatedCallback(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let message):
            return "listener failed: \(message)"
        case .notReady:
            return "listener not ready"
        case .timedOut:
            return "timed out waiting for browser MFA callback"
        case .unauthenticatedCallback(let message):
            return "unauthenticated callback payload: \(message)"
        case .decodeFailed(let message):
            return "decode failed: \(message)"
        }
    }
}

// MARK: - Listener

/// The Browser MFA loopback callback listener.
///
/// `nonisolated` + `@unchecked Sendable`: every piece of mutable state is
/// guarded by `stateLock`, and the Network callbacks run on the private
/// serial `ioQueue`.
nonisolated final class BrowserMFAListener: NSObject, @unchecked Sendable {

    // MARK: Configuration

    private let logger: Logger
    private let timeout: TimeInterval
    fileprivate let readTimeout: TimeInterval
    private let startTimeout: TimeInterval
    private let maxConcurrentConnections: Int
    private let listenerFactory: (NWEndpoint.Host, NWEndpoint.Port) throws -> NWListener

    // MARK: Constants

    private static let secretKeyByteCount = 32
    /// The largest request the listener buffers. Anything above this is
    /// answered 413 instead of accumulating without bound.
    static let maxRequestBytes = 1 << 20
    /// How many times the IPv4 + IPv6 listener pair is retried on a fresh
    /// port before falling back to IPv4 only.
    private static let maxBindAttempts = 3

    // MARK: Contract defaults

    /// The default wait outlives the server's 180 s approval window, so a slow
    /// approval is never cut off by the client.
    static let defaultWaitTimeout: TimeInterval = 180
    /// How long a connection may take to send its request head before it is
    /// answered and dropped.
    static let defaultReadTimeout: TimeInterval = 10
    /// How long the bind pair may take to report ready before startup fails.
    static let defaultStartTimeout: TimeInterval = 15
    /// The admission cap: connections beyond this are rejected.
    ///
    /// The clean-room rewrite answered them 503 immediately, closing with
    /// unread inbound data, so the kernel could RST the response away before
    /// the client read it (the `#233` class). Over-cap connections are now
    /// drained (discarded, never buffered) and *then* answered 503. That
    /// bounds each over-cap connection (one `readTimeout` timer, at most
    /// `maxRequestBytes` read, no admission slot) but not their count — the
    /// OS fd limit and accept rate are the only bound, so a local flood can
    /// briefly pin sockets. The drain still cannot *accumulate* memory per
    /// connection: every drained byte is thrown away.
    static let defaultMaxConcurrentConnections = 16

    private static let callbackPath = "/callback"
    private static let callbackPage = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>VVTerm</title></head>
        <body>
        <p>Approval received. You can close this tab and return to VVTerm.</p>
        </body>
        </html>
        """

    // MARK: State

    private struct State {
        var secretKey: Data?
        var boundPort: UInt16 = 0
        var hasIPv6 = false
        var activeConnections = 0
        var didResume = false
        var isAwaiting = false
        var cancelled = false
        var pending: Result<Proto_CredentialAssertionResponse, Error>?
        var continuation: CheckedContinuation<Proto_CredentialAssertionResponse, Error>?
        /// Monotonic per-wait token, and the token of the wait that installed
        /// `continuation`. `onCancel` compares its token and no-ops on a
        /// mismatch, so a rejected second waiter cannot resume the installed
        /// first waiter (A4).
        var nextWaitToken: UInt64 = 0
        var activeWaitToken: UInt64?
        var listeners: [NWListener] = []
        var connections: [ObjectIdentifier: BrowserMFAHTTPConnection] = [:]
    }

    private let stateLock = NSLock()
    private var state = State()

    /// Runs `body` with the state lock held. Kept synchronous so the lock
    /// calls stay legal from async contexts (NSLock is unavailable there).
    private func withState<T>(_ body: (inout State) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&state)
    }

    private let ioQueue = DispatchQueue(label: "vvterm.teleport.browser-mfa.listener")
    private let deadlineLock = NSLock()
    private var deadlineTask: Task<Void, Never>?

    // MARK: Init

    init(
        logger: Logger = Logger(subsystem: "Teleport", category: "TeleportBrowserMFA"),
        timeout: TimeInterval = BrowserMFAListener.defaultWaitTimeout,
        readTimeout: TimeInterval = BrowserMFAListener.defaultReadTimeout,
        startTimeout: TimeInterval = BrowserMFAListener.defaultStartTimeout,
        maxConcurrentConnections: Int = BrowserMFAListener.defaultMaxConcurrentConnections,
        listenerFactory: @escaping (NWEndpoint.Host, NWEndpoint.Port) throws -> NWListener = {
            try BrowserMFAListener.makeLoopbackListener(host: $0, port: $1)
        }
    ) {
        self.logger = logger
        self.timeout = timeout
        self.readTimeout = readTimeout
        self.startTimeout = startTimeout
        self.maxConcurrentConnections = maxConcurrentConnections
        self.listenerFactory = listenerFactory
        super.init()
    }

    deinit {
        let (listeners, connections) = withState { state -> ([NWListener], [BrowserMFAHTTPConnection]) in
            let listeners = state.listeners
            state.listeners = []
            let connections = Array(state.connections.values)
            state.connections.removeAll()
            return (listeners, connections)
        }
        for listener in listeners {
            listener.cancel()
        }
        for connection in connections {
            connection.closeFromOwner()
        }
        cancelDeadline()
    }

    // MARK: Test seams

    /// The per-run AES-256-GCM key as lowercase hex (the `secret_key` query
    /// value). Empty until `start()` generates it.
    var secretKeyHex: String {
        guard let key = withState({ $0.secretKey }) else { return "" }
        return Self.hexString(key)
    }

    /// Whether a `waitForResponse()` continuation is currently installed.
    var isAwaitingResponse: Bool {
        withState { $0.isAwaiting }
    }

    /// How many connections are currently admitted (over-cap connections are
    /// answered 503 and never counted).
    var activeConnectionCount: Int {
        withState { $0.activeConnections }
    }

    /// Whether the `::1` companion listener is bound.
    var hasIPv6LoopbackListener: Bool {
        withState { $0.hasIPv6 }
    }

    /// The bound IPv4 loopback port (0 before `start()`).
    var port: UInt16 {
        withState { $0.boundPort }
    }

    /// Whether the login has been resolved (by a callback, the deadline,
    /// cancellation, or a test-driven `resume`).
    var didResume: Bool {
        withState { $0.didResume }
    }

    // MARK: Lifecycle

    /// Generates the per-run key, binds the loopback listener(s), and returns
    /// the client callback URL.
    ///
    /// - Throws: `BrowserMFAListenerError.listenerFailed` if the random key
    ///   cannot be generated or no loopback listener can be bound.
    func start() async throws -> String {
        var keyBytes = [UInt8](repeating: 0, count: Self.secretKeyByteCount)
        let rngStatus = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        guard rngStatus == errSecSuccess else {
            throw BrowserMFAListenerError.listenerFailed(
                "could not generate the callback key (OSStatus \(rngStatus))"
            )
        }
        let secretKey = Data(keyBytes)
        withState { $0.secretKey = secretKey }

        var ipv4Listener: NWListener?
        var ipv6Listener: NWListener?
        var boundPort: UInt16 = 0

        for _ in 0..<Self.maxBindAttempts {
            do {
                let ipv4 = try await startLoopbackListener(host: .ipv4(.loopback), port: .any)
                do {
                    let port = NWEndpoint.Port(rawValue: ipv4.port) ?? .any
                    let ipv6 = try await startLoopbackListener(host: .ipv6(.loopback), port: port)
                    ipv4Listener = ipv4.listener
                    ipv6Listener = ipv6.listener
                    boundPort = ipv4.port
                    break
                } catch {
                    // The pair cannot share the port; discard the IPv4
                    // listener and try the pair again on a fresh port.
                    ipv4.listener.cancel()
                    continue
                }
            } catch {
                continue
            }
        }

        if ipv4Listener == nil {
            let ipv4 = try await startLoopbackListener(host: .ipv4(.loopback), port: .any)
            ipv4Listener = ipv4.listener
            boundPort = ipv4.port
        }

        guard let ipv4Listener else {
            throw BrowserMFAListenerError.listenerFailed("no loopback listener could be bound")
        }

        withState {
            $0.listeners = [ipv4Listener] + (ipv6Listener.map { [$0] } ?? [])
            $0.boundPort = boundPort
            $0.hasIPv6 = ipv6Listener != nil
        }

        logger.info(
            "browser MFA listener ready on localhost:\(boundPort) (ipv6: \(ipv6Listener != nil))"
        )
        return "http://localhost:\(boundPort)\(Self.callbackPath)?secret_key=\(Self.hexString(secretKey))"
    }

    /// Waits for the callback result.
    ///
    /// The wait resolves exactly once, through the same serialized path as
    /// every other resolution (callback, deadline, cancellation, or a
    /// test-driven `resume`). A result that arrived before the wait is
    /// delivered immediately; a task cancelled before the wait throws
    /// `CancellationError` instead of consuming a buffered result.
    ///
    /// A second concurrent wait fails fast with `.listenerFailed` instead of
    /// overwriting the first waiter's continuation (A4). A bare `resume`
    /// buffers into `pending`, so the "already resolved" failure is reached
    /// only by a wait after a resolution whose buffered result was consumed.
    func waitForResponse() async throws -> Proto_CredentialAssertionResponse {
        // The per-wait token lets `onCancel` resolve only the wait this call
        // installed: a rejected second waiter's cancellation must not resume
        // the first waiter's continuation.
        let token = withState { state -> UInt64 in
            state.nextWaitToken &+= 1
            return state.nextWaitToken
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outcome = withState { state -> (immediate: Result<Proto_CredentialAssertionResponse, Error>?, armDeadline: Bool) in
                    // Guard order is deliberate (A4): cancellation, then a
                    // cancelled listener, then a buffered result, then the
                    // two fail-fast guards, then install.
                    if Task.isCancelled {
                        return (.failure(CancellationError()), false)
                    }
                    if state.cancelled {
                        // Recorded retention, not a restore: pre had no
                        // `cancelled` flag and surfaced `.listenerFailed`
                        // here; a cancelled listener reporting cancellation
                        // is the framework-idiomatic signal.
                        return (.failure(CancellationError()), false)
                    }
                    if let pending = state.pending {
                        state.pending = nil
                        return (pending, false)
                    }
                    if state.continuation != nil {
                        return (
                            .failure(BrowserMFAListenerError.listenerFailed("a wait is already in progress")),
                            false
                        )
                    }
                    if state.didResume {
                        return (
                            .failure(BrowserMFAListenerError.listenerFailed("the listener was already resolved")),
                            false
                        )
                    }
                    state.continuation = continuation
                    state.activeWaitToken = token
                    state.isAwaiting = true
                    return (nil, true)
                }

                if let immediate = outcome.immediate {
                    continuation.resume(with: immediate)
                } else if outcome.armDeadline {
                    armDeadline()
                }
            }
        } onCancel: {
            cancelWait(token: token)
        }
    }

    /// Resolves the wait installed by `token` with `CancellationError`; a
    /// no-op when `token` is not the installed wait.
    ///
    /// This closes the second-waiter cancellation hole (A4): a *rejected*
    /// second waiter whose task is cancelled while its cancellation handler
    /// runs must not resume the first waiter's continuation.
    private func cancelWait(token: UInt64) {
        let continuation: CheckedContinuation<Proto_CredentialAssertionResponse, Error>? = withState { state in
            guard state.activeWaitToken == token, let installed = state.continuation else {
                return nil
            }
            state.continuation = nil
            state.activeWaitToken = nil
            state.isAwaiting = false
            state.didResume = true
            return installed
        }
        guard let continuation else { return }
        cancelDeadline()
        continuation.resume(throwing: CancellationError())
    }

    /// Resolves the login with `result` exactly once. Later results are
    /// discarded; a result arriving before `waitForResponse()` is buffered.
    func resume(_ result: Result<Proto_CredentialAssertionResponse, Error>) {
        let continuation: CheckedContinuation<Proto_CredentialAssertionResponse, Error>? = withState { state in
            guard !state.didResume else { return nil }
            state.didResume = true
            if let installed = state.continuation {
                state.continuation = nil
                state.activeWaitToken = nil
                state.isAwaiting = false
                return installed
            }
            state.pending = result
            return nil
        }

        cancelDeadline()
        continuation?.resume(with: result)
    }

    /// Tears the listener down and resolves an installed wait promptly with
    /// `CancellationError`. Later waits fail fast instead of arming a new
    /// deadline.
    func cancel() {
        let teardown = withState { state -> (continuation: CheckedContinuation<Proto_CredentialAssertionResponse, Error>?, listeners: [NWListener], connections: [BrowserMFAHTTPConnection]) in
            state.cancelled = true
            state.didResume = true
            state.pending = nil
            let continuation = state.continuation
            state.continuation = nil
            state.activeWaitToken = nil
            state.isAwaiting = false
            let listeners = state.listeners
            state.listeners = []
            let connections = Array(state.connections.values)
            state.connections.removeAll()
            state.activeConnections = 0
            return (continuation, listeners, connections)
        }

        cancelDeadline()
        for listener in teardown.listeners {
            listener.cancel()
        }
        for connection in teardown.connections {
            connection.closeFromOwner()
        }
        teardown.continuation?.resume(throwing: CancellationError())
    }

    // MARK: Binding

    /// Builds a loopback `NWListener` bound to `host`:`port`. Exposed so
    /// tests can inject a factory that fails a chosen family.
    static func makeLoopbackListener(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port
    ) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: port)
        parameters.allowLocalEndpointReuse = true
        return try NWListener(using: parameters)
    }

    /// Creates, configures, starts, and awaits readiness of one loopback
    /// listener.
    private func startLoopbackListener(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port
    ) async throws -> (listener: NWListener, port: UInt16) {
        let listener: NWListener
        do {
            listener = try listenerFactory(host, port)
        } catch {
            throw BrowserMFAListenerError.listenerFailed("\(error)")
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: ioQueue)

        let deadline = ContinuousClock.now + .seconds(startTimeout)
        while ContinuousClock.now < deadline {
            if let boundPort = listener.port, listener.state == .ready {
                return (listener, boundPort.rawValue)
            }
            switch listener.state {
            case .failed(let error):
                throw BrowserMFAListenerError.listenerFailed("\(error)")
            case .cancelled:
                throw BrowserMFAListenerError.listenerFailed("listener was cancelled while starting")
            default:
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        listener.cancel()
        throw BrowserMFAListenerError.listenerFailed("listener did not become ready in \(startTimeout)s")
    }

    // MARK: Connections

    /// Admits a connection or answers it 503 when the admission cap is hit.
    fileprivate func accept(_ connection: NWConnection) {
        let admitted = withState { state -> Bool in
            if state.cancelled { return false }
            if state.activeConnections >= maxConcurrentConnections { return false }
            state.activeConnections += 1
            return true
        }

        let handler = BrowserMFAHTTPConnection(
            listener: self,
            connection: connection,
            queue: ioQueue,
            admitted: admitted
        )
        // Retain the handler until its connection closes: the receive/send
        // callbacks hold it weakly so a finished connection can be released.
        withState { $0.connections[ObjectIdentifier(handler)] = handler }
        handler.start()
    }

    /// Logs a request that could not even be parsed. The line is static: the
    /// buffered bytes may carry query values, so they are never interpolated.
    fileprivate func logIncompleteRequest() {
        logger.error("browser MFA callback rejected: incomplete request")
    }

    /// Called by a connection once it is done; releases its admission slot
    /// and its retain slot.
    fileprivate func connectionClosed(_ handler: BrowserMFAHTTPConnection) {
        withState { state in
            let wasTracked = state.connections.removeValue(forKey: ObjectIdentifier(handler)) != nil
            if wasTracked, handler.admitted, state.activeConnections > 0 {
                state.activeConnections -= 1
            }
        }
    }

    /// Answers a parsed request. A non-nil `resolution` resolves the login.
    ///
    /// Every rejection logs a static reason so a failure on a live cluster is
    /// diagnosable from the app log alone; query values are sensitive and are
    /// never interpolated (see the file header).
    fileprivate func handle(_ request: BrowserMFARequest) -> BrowserMFACallbackResult {
        // A2 (accepted + recorded): the browser's callback is a GET
        // (`window.location.replace`); `parseRequest` uppercases the method,
        // so HEAD/PUT and mixed case all reach this fail-closed 405. Existing
        // coverage: `testCallbackWithAnUnsupportedMethodIsRejected`.
        guard request.method == "GET" || request.method == "POST" else {
            logger.error("browser MFA callback rejected: unsupported method")
            return BrowserMFACallbackResult(status: 405, body: "Method not allowed", resolution: nil)
        }
        guard request.path == Self.callbackPath else {
            logger.error("browser MFA callback rejected: unrecognized path")
            return BrowserMFACallbackResult(status: 404, body: "Not found", resolution: nil)
        }
        // No `secret_key` check: it is a key-delivery parameter, and Teleport
        // strips it from the browser-facing redirect, which carries
        // `?response=…` alone. The GCM tag below is the gate.
        guard let responseValue = request.query["response"] else {
            // A bare callback is not authenticated and must not terminate the
            // login; the genuine callback (or the deadline) still can.
            logger.error("browser MFA callback rejected: missing response parameter")
            return BrowserMFACallbackResult(status: 400, body: "Missing response", resolution: nil)
        }

        do {
            let assertion = try decrypt(responseValue)
            return BrowserMFACallbackResult(
                status: 200,
                body: Self.callbackPage,
                resolution: .success(assertion)
            )
        } catch BrowserMFACallbackError.unauthenticated {
            logger.error("browser MFA callback rejected: envelope authentication failed")
            return BrowserMFACallbackResult(status: 400, body: "Invalid callback", resolution: nil)
        } catch {
            logger.error("browser MFA callback failed: authenticated payload could not be decoded")
            return BrowserMFACallbackResult(
                status: 500,
                body: "Invalid response",
                resolution: .failure(
                    BrowserMFAListenerError.decodeFailed("browser MFA payload could not be decoded")
                )
            )
        }
    }

    // MARK: Decryption

    private enum BrowserMFACallbackError: Error {
        /// The envelope did not authenticate (or could not even be read).
        /// Answered 400, never terminal.
        case unauthenticated
        /// The envelope authenticated but its plaintext is not a usable login
        /// response. Terminal.
        case malformed
    }

    /// Opens the `{ciphertext, nonce}` envelope under the per-run key and maps
    /// the Go CLI login response into the proto assertion.
    private func decrypt(_ responseValue: String) throws -> Proto_CredentialAssertionResponse {
        guard let secretKey = withState({ $0.secretKey }) else {
            throw BrowserMFACallbackError.unauthenticated
        }

        guard let envelopeData = responseValue.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(BrowserMFASealedEnvelope.self, from: envelopeData),
              let sealed = Data(base64Encoded: envelope.ciphertext),
              let nonceData = Data(base64Encoded: envelope.nonce),
              sealed.count >= 16,
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(
                  nonce: nonce,
                  ciphertext: sealed.dropLast(16),
                  tag: sealed.suffix(16)
              ),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: secretKey))
        else {
            throw BrowserMFACallbackError.unauthenticated
        }

        guard let payload = try? JSONDecoder().decode(BrowserMFACLILoginResponse.self, from: plaintext),
              let assertion = payload.browserMFAWebauthnResponse
        else {
            throw BrowserMFACallbackError.malformed
        }

        var proto = Proto_CredentialAssertionResponse()
        proto.type = assertion.type
        // Only the base64 decode degrades: an authenticated field whose string
        // is not valid base64 becomes empty (`flexibleBase64(...) ?? Data()`),
        // as it did before the rewrite. The pre-rewrite decoder *also* made
        // every key optional; this one does not — a missing `id`/`type`/
        // `rawId`/`response` (or inner `clientDataJSON`/`authenticatorData`/
        // `signature`) key throws and is terminal (500 + `.decodeFailed`),
        // because the payload already passed AES-GCM but the assertion cannot
        // be built (A3, pinned by
        // `testMissingRequiredAssertionFieldIsTerminal` and
        // `testUnparseableBase64FieldDegradesToEmpty`). The server re-verifies
        // the WebAuthn signature over these fields, so an empty field cannot
        // forge an approval.
        proto.rawID = Self.flexibleBase64(assertion.rawId) ?? Data()
        proto.id = assertion.id

        var response = Proto_AuthenticatorAssertionResponse()
        response.clientDataJson = Self.flexibleBase64(assertion.response.clientDataJSON) ?? Data()
        response.authenticatorData = Self.flexibleBase64(assertion.response.authenticatorData) ?? Data()
        response.signature = Self.flexibleBase64(assertion.response.signature) ?? Data()
        if let userHandle = assertion.response.userHandle {
            response.userHandle = Self.flexibleBase64(userHandle) ?? Data()
        }
        proto.response = response
        return proto
    }

    // MARK: Deadline

    private func armDeadline() {
        let timeout = self.timeout
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.resume(.failure(BrowserMFAListenerError.timedOut))
        }

        deadlineLock.lock()
        let previous = deadlineTask
        deadlineTask = task
        deadlineLock.unlock()
        previous?.cancel()
    }

    private func cancelDeadline() {
        deadlineLock.lock()
        let task = deadlineTask
        deadlineTask = nil
        deadlineLock.unlock()
        task?.cancel()
    }

    // MARK: Helpers

    /// Decodes standard or URL-safe base64, with or without padding. The
    /// server's CLI response uses base64url without padding, but accepting
    /// the padded standard alphabet too keeps the listener tolerant of
    /// proxies that re-encode.
    private static func flexibleBase64(_ string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Request parsing

/// One parsed HTTP request. `query` values are percent-decoded.
nonisolated private struct BrowserMFARequest {
    let method: String
    let path: String
    let query: [String: String]
}

/// What the listener answers for a parsed request, plus an optional
/// resolution for the waiting login.
nonisolated private struct BrowserMFACallbackResult {
    let status: Int
    let body: String
    let resolution: Result<Proto_CredentialAssertionResponse, Error>?
}

/// The `{"ciphertext": <std-base64>, "nonce": <std-base64>}` envelope the
/// server produces. `ciphertext` carries the 16-byte GCM tag appended to the
/// ciphertext (Go's `aesgcm.Seal` shape).
nonisolated private struct BrowserMFASealedEnvelope: Decodable {
    let ciphertext: String
    let nonce: String
}

/// The decrypted Go CLI login response, reduced to the fields the listener
/// needs. Go's `webauthntypes` structs flatten the embedded
/// `PublicKeyCredential` + `AuthenticatorAssertionResponse` fields into one
/// JSON object, so `id`/`type`/`rawId`/`response` all live at the top level.
nonisolated private struct BrowserMFACLILoginResponse: Decodable {
    let browserMFAWebauthnResponse: BrowserMFAAssertion?

    enum CodingKeys: String, CodingKey {
        case browserMFAWebauthnResponse = "browser_mfa_webauthn_response"
    }
}

nonisolated private struct BrowserMFAAssertion: Decodable {
    let id: String
    let type: String
    let rawId: String
    let response: BrowserMFAAssertionResponse

    nonisolated struct BrowserMFAAssertionResponse: Decodable {
        let clientDataJSON: String
        let authenticatorData: String
        let signature: String
        let userHandle: String?
    }
}

// MARK: - Connection

/// Handles one admitted loopback connection: accumulates the request, applies
/// the size and read-time limits, then answers and resolves.
nonisolated private final class BrowserMFAHTTPConnection: @unchecked Sendable {

    private let listener: BrowserMFAListener
    private let connection: NWConnection
    private let queue: DispatchQueue
    let admitted: Bool

    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private var deadline: DispatchWorkItem?

    init(
        listener: BrowserMFAListener,
        connection: NWConnection,
        queue: DispatchQueue,
        admitted: Bool
    ) {
        self.listener = listener
        self.connection = connection
        self.queue = queue
        self.admitted = admitted
    }

    /// Starts the connection. Admitted connections arm the non-resetting read
    /// deadline and start reading; over-cap connections drain (and discard)
    /// their request header before the 503, so the kernel's RST cannot discard
    /// the response (the `#233` class; header-scoped — a request body is never
    /// drained). The drain never takes an admission slot and never touches
    /// `buffer`.
    func start() {
        connection.start(queue: queue)

        guard admitted else {
            drainRejectedRequest()
            return
        }

        let item = DispatchWorkItem { [weak self] in
            self?.finish(status: 408, body: "Request timed out", resolution: nil)
        }
        lock.lock()
        deadline = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + listener.readTimeout, execute: item)
        receiveMore()
    }

    /// Cancels the connection when the listener tears down. The connection is
    /// no longer tracked, so this must not touch the listener's counters.
    func closeFromOwner() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let item = deadline
        deadline = nil
        lock.unlock()
        item?.cancel()
        connection.cancel()
    }

    /// Reads and discards an over-cap connection's request header, then
    /// answers 503 through `finish`'s once-guard.
    ///
    /// The pre-rewrite listener drained before answering 503 so the kernel's
    /// RST could not discard the response before the client read it (the
    /// `#233` class). The drain is discard-only — it never touches
    /// `self.buffer`, so an over-cap client cannot pin per-connection memory —
    /// and bounded by the header terminator, `maxRequestBytes`, and
    /// `readTimeout`. A request body is never drained: the closure is
    /// header-scoped. No admission slot is taken (the connection was rejected
    /// before admission) and none is released.
    private func drainRejectedRequest() {
        let item = DispatchWorkItem { [weak self] in
            self?.finish(status: 503, body: "Too many connections", resolution: nil)
        }
        lock.lock()
        deadline = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + listener.readTimeout, execute: item)

        readRejectedHeader(drained: 0, tail: Data())
    }

    /// One discard-only read of an over-cap request. `drained` counts the
    /// discarded bytes and `tail` retains at most the 3 bytes a `\r\n\r\n`
    /// split across fragments could need. `finished` is re-checked before
    /// every read so a deadline `finish` or `closeFromOwner` cannot race a
    /// live read.
    private func readRejectedHeader(drained: Int, tail: Data) {
        lock.lock()
        let isFinished = finished
        lock.unlock()
        guard !isFinished else { return }

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 4096
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                self.finish(status: 503, body: "Too many connections", resolution: nil)
                return
            }
            if let data, !data.isEmpty {
                let total = drained + data.count
                var window = tail
                window.append(data)
                if window.range(of: Data("\r\n\r\n".utf8)) != nil
                    || total >= BrowserMFAListener.maxRequestBytes
                {
                    self.finish(status: 503, body: "Too many connections", resolution: nil)
                    return
                }
                self.readRejectedHeader(
                    drained: total,
                    tail: window.count > 3 ? Data(window.suffix(3)) : window
                )
                return
            }
            if isComplete {
                self.finish(status: 503, body: "Too many connections", resolution: nil)
                return
            }
            self.readRejectedHeader(drained: drained, tail: tail)
        }
    }

    private func receiveMore() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.lock.lock()
                self.buffer.append(data)
                let exceeded = self.buffer.count > BrowserMFAListener.maxRequestBytes
                let hasCompleteHeader = !exceeded
                    && self.buffer.range(of: Data("\r\n\r\n".utf8)) != nil
                let request = exceeded ? nil : Self.parseRequest(self.buffer)
                self.lock.unlock()

                if exceeded {
                    self.finish(status: 413, body: "Request too large", resolution: nil)
                    return
                }
                if let request {
                    let result = self.listener.handle(request)
                    self.finish(status: result.status, body: result.body, resolution: result.resolution)
                    return
                }
                if hasCompleteHeader {
                    // D2 (restored): the header block is complete but the
                    // request line is unparseable. Pre answered 400 as soon as
                    // `\r\n\r\n` arrived; the rewrite kept reading for a
                    // parseable line and answered 408 at `readTimeout`. A
                    // split write without a terminator still keeps reading.
                    self.listener.logIncompleteRequest()
                    self.finish(status: 400, body: "Incomplete request", resolution: nil)
                    return
                }
            }

            if error != nil || isComplete {
                // D1 (accepted + recorded): the pre-rewrite listener answered
                // 500 "recv error" here; the current 400 "Incomplete request"
                // is the same status class and is terminal for this connection
                // only — the connection is dead either way, and the reject is
                // logged through the static line below.
                self.listener.logIncompleteRequest()
                self.finish(status: 400, body: "Incomplete request", resolution: nil)
                return
            }
            self.receiveMore()
        }
    }

    private func finish(
        status: Int,
        body: String,
        resolution: Result<Proto_CredentialAssertionResponse, Error>?
    ) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let item = deadline
        deadline = nil
        lock.unlock()
        item?.cancel()

        let contentType = status == 200 ? "text/html; charset=utf-8" : "text/plain; charset=utf-8"
        let payload = Self.httpResponse(status: status, body: body, contentType: contentType)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })

        if let resolution {
            listener.resume(resolution)
        }
    }

    private func close() {
        connection.cancel()
        listener.connectionClosed(self)
    }

    // MARK: Parsing

    private static func parseRequest(_ data: Data) -> BrowserMFARequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let (path, query) = splitTarget(target)
        return BrowserMFARequest(method: method, path: path, query: query)
    }

    private static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let questionMark = target.firstIndex(of: "?") else {
            return (target, [:])
        }
        let path = String(target[..<questionMark])
        let queryString = String(target[target.index(after: questionMark)...])
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&", omittingEmptySubsequences: true) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = decodePercent(String(pair[..<equals]))
            let value = decodePercent(String(pair[pair.index(after: equals)...]))
            query[name] = value
        }
        return (path, query)
    }

    /// Percent-decodes one query component. `+` is left as a literal plus:
    /// the sealed envelope's standard-base64 value can contain `+`, and the
    /// compact JSON payload has no spaces for a form encoder to turn into
    /// `+` in the first place.
    private static func decodePercent(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    /// Cosmetic rewrite deltas accepted as a group (see #242): the
    /// Content-Type header, the response bodies, duplicate-query last-wins
    /// (`splitTarget`), and request-fragment tolerance all differ from the
    /// pre-rewrite listener in ways that change neither the wire contract nor
    /// any control-flow decision.
    private static func httpResponse(status: Int, body: String, contentType: String) -> Data {
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(bodyData)
        return payload
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

#endif // canImport(Network)
