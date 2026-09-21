// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  BrowserMFAListener.swift
//  VVTerm
//
//  The loopback HTTP listener that receives the Browser MFA callback from
//  Safari.
//
//  Teleport's Browser MFA flow (lib/client/sso/redirector.go) requires the
//  client to pass a `BrowserMFATSHRedirectURL` that validates to a loopback
//  http(s) URL (lib/client/sso/redirector.go:ValidateClientRedirect). The
//  server encrypts the WebAuthn assertion response with an AES-256-GCM key
//  the client generated (lib/auth/internal/browsermfa/browser_mfa.go:
//  EncryptBrowserMFAResponse), embeds the ciphertext in the redirect URL's
//  `?response=` query param, and the Browser MFA SPA does
//  window.location.replace(tshRedirectUrl). On iOS, Safari navigating to
//  http://127.0.0.1:<port>/callback?... routes the request to an in-process
//  NWListener — ASWebAuthenticationSession cannot intercept an http://
//  loopback redirect (it only fires for custom schemes or iOS-17.4+ HTTPS
//  associated-domain callbacks).
//
//  This class mirrors lib/client/sso/redirector.go (NewRedirector +
//  startServer + callback + WaitForResponse):
//    1. Generate an AES-256-GCM key (32 random bytes), hex-encode for the URL.
//    2. Start NWListener on 127.0.0.1, port 0 (OS-assigned).
//    3. Expose clientCallbackURL = "http://localhost:<port>/callback?secret_key=<hex>".
//       (localhost, not 127.0.0.1, so Safari's HTTPS-Only mode doesn't show
//       the "connection is not secure" banner — Safari treats localhost as a
//       secure context but shows the banner for a literal 127.0.0.1 IP.)
//    4. On GET/POST to /callback, read `response` query param, decrypt with
//       the key, decode CLILoginResponse JSON, extract
//       BrowserMFAWebauthnResponse (a CredentialAssertionResponse).
//    5. Respond to Safari with a minimal "close this tab" HTML page.
//    6. Resolve the continuation with the decoded response (or an error).
//
//  The encrypted envelope is a JSON object {"ciphertext": <base64>,
//  "nonce": <base64>} (Go's json.Marshal of []byte = base64). The AES-GCM
//  key is the raw 32 bytes (NOT hex-decoded for crypto — hex is only the URL
//  transport). See lib/secret/secret.go.
//
//  The decrypted plaintext is Go encoding/json output of CLILoginResponse
//  (lib/auth/authclient/clt.go:1432) — NOT proto JSON. The inner
//  BrowserMFAWebauthnResponse is a wantypes.CredentialAssertionResponse
//  (lib/auth/webauthntypes/webauthn.go:112), a plain Go struct with json
//  tags. Its binary fields are protocol.URLEncodedBase64
//  (go-webauthn/webauthn/protocol/base64.go), which marshals as
//  base64.RawURLEncoding (URL-safe, NO padding). We therefore decode with
//  plain Codable structs + a custom base64url-no-padding Data decoder, then
//  map into the proto types the rest of the spike expects.
//

import Foundation
import os.log
import os
import CryptoKit
import Network

// MARK: - Errors

nonisolated enum BrowserMFAListenerError: Error, LocalizedError {
    case listenerFailed(String)
    case notReady
    case timedOut
    /// The callback payload did not authenticate: anything on the loopback
    /// port can send an arbitrary `response` value, so a request that fails
    /// envelope parsing, base64/nonce decoding, the short-ciphertext check,
    /// or the AES-256-GCM tag check carries no proof it came from the server.
    /// Such requests must not terminally resolve the login.
    case unauthenticatedCallback(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let s): return "listener failed: \(s)"
        case .notReady: return "listener not ready"
        case .timedOut: return "timed out waiting for browser MFA callback"
        case .unauthenticatedCallback(let s): return "unauthenticated callback payload: \(s)"
        case .decodeFailed(let s): return "decode failed: \(s)"
        }
    }
}

// MARK: - The sealed envelope (matches lib/secret/secret.go sealedData)

/// Go's json.Marshal of `[]byte` produces a base64 STRING, so both fields are
/// base64-encoded strings in the JSON (not base64url, not raw bytes).
private nonisolated struct SealedEnvelope: Decodable {
    let ciphertext: String  // base64
    let nonce: String       // base64
}

// MARK: - Listener

/// A loopback HTTP listener for the Browser MFA callback.
///
/// Explicitly `nonisolated`: the app target defaults to MainActor
/// isolation, which would otherwise make every member main-actor and route
/// `waitForResponse()` (and its deadline) through the main run loop. The
/// NWListener runs on its own queue and the callbacks (stateUpdateHandler,
/// newConnectionHandler, connection.receive) fire on background queues, so
/// the listener and its state are thread-safe independently of the main
/// actor (`resumeLock` + `@unchecked Sendable`). The ceremony (which is
/// @MainActor) creates it and awaits it via async functions; the only
/// shared mutable state is the continuation, which is `Sendable`
/// (CheckedContinuation is Sendable when the return type is Sendable —
/// Proto_CredentialAssertionResponse is a struct of Data/String, hence
/// Sendable).
nonisolated final class BrowserMFAListener: NSObject, @unchecked Sendable {

    /// The secret key (32 random bytes). Hex-encoded for the URL transport.
    private(set) var secretKeyHex: String = ""
    /// The raw 32 bytes (for AES-GCM).
    private let secretKey: SymmetricKey

    /// True while a `waitForResponse()` waiter has installed its
    /// continuation. Read-only and lock-guarded so tests can synchronize a
    /// cancellation handshake without a fixed sleep.
    var isAwaitingResponse: Bool {
        resumeLock.lock()
        defer { resumeLock.unlock() }
        return continuation != nil
    }

    /// The number of connections currently holding an admission slot.
    /// Read-only and lock-guarded so tests can synchronize admission without
    /// a fixed sleep.
    var activeConnectionCount: Int {
        activeConnections.withLock { $0 }
    }

    /// The callback URL to send to the server
    /// (http://127.0.0.1:<port>/callback?secret_key=<hex>).
    private(set) var clientCallbackURL: String = ""

    /// The bound port (read after the listener is ready).
    private(set) var port: UInt16 = 0

    private var listener: NWListener?
    /// The companion IPv6 loopback listener (same port as `listener`), so
    /// `localhost` resolves on either family. Nil when the ::1 bind was
    /// unavailable (the URL then advertises 127.0.0.1).
    private var listenerV6: NWListener?
    private var continuation: CheckedContinuation<Proto_CredentialAssertionResponse, Error>?
    /// The first resolution observed before `waitForResponse()` installed a
    /// continuation. Delivered as soon as a waiter arrives, so a callback
    /// (or the deadline) that beats the wait is not lost.
    private var pendingResult: Result<Proto_CredentialAssertionResponse, Error>?
    private let resumeLock = NSLock()
    /// True once a terminal resolution has been recorded (delivered to a
    /// waiter or buffered for the next one). Guards the exactly-once
    /// semantics; readable so the resolution paths are testable.
    private(set) var didResume = false

    /// The response deadline (defaults.SSOCallbackTimeout is 120s in Teleport;
    /// we use 180s to match the headless flow's blocking-POST timeout).
    ///
    /// A sleeping `Task`, not a `Timer`: `waitForResponse()` is nonisolated
    /// async, so its body runs on a cooperative-pool thread whose
    /// `RunLoop.current` is never pumped — a scheduled `Timer` would never
    /// fire there. `Task.sleep` is executor-independent.
    private var timeoutTask: Task<Void, Never>?
    private let timeout: TimeInterval

    /// The hostname we advertise in the callback URL. The listener binds
    /// loopback only (127.0.0.1 + ::1) and advertises `localhost` rather than
    /// `127.0.0.1` so Safari's HTTPS-Only mode treats it as a secure context
    /// and doesn't show the "connection is not secure" banner.
    /// ValidateClientRedirect (lib/client/sso/redirector.go) accepts both
    /// `localhost` and `127.0.0.1` for the http scheme. If the ::1 bind is
    /// unavailable, the v4 listener is kept and this falls back to
    /// `127.0.0.1`.
    private var host = "localhost"

    /// The largest request we buffer before rejecting the connection. The
    /// genuine callback is a small GET whose payload lives in the
    /// `response=` query param; CA-heavy clusters can push a sealed envelope
    /// past the old single 64 KB read, so the ceiling is generous but
    /// bounded.
    private static let maxRequestBytes = 1 << 20

    /// The HTTP header terminator: the real parse boundary. The response
    /// payload lives in the request line's query string, so a GET is parsed
    /// exactly when its headers complete (any `Content-Length` body is not
    /// needed).
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// The total read deadline for a single connection, armed when the
    /// connection is accepted: a client that connects and then goes silent
    /// (or stalls mid-request) must not pin the connection. The genuine
    /// loopback callback arrives in one burst well inside this window.
    private let readTimeout: TimeInterval

    /// The maximum number of connections buffered at once. The genuine
    /// callback is a single small GET; a burst of connections is not part of
    /// the ceremony and must not accumulate per-connection buffers.
    private let maxConcurrentConnections: Int
    /// The number of connections currently holding an admission slot.
    /// Released exactly once per admitted connection by `respond`.
    private let activeConnections = OSAllocatedUnfairLock(initialState: 0)

    init(
        timeout: TimeInterval = 180,
        readTimeout: TimeInterval = 10,
        maxConcurrentConnections: Int = 16
    ) {
        self.timeout = timeout
        self.readTimeout = readTimeout
        self.maxConcurrentConnections = maxConcurrentConnections
        // Generate 32 random bytes for AES-256-GCM.
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        if status == errSecSuccess {
            secretKey = SymmetricKey(data: Data(keyBytes))
        } else {
            // Fallback: CryptoKit's SymmetricKey(generator:) would be better,
            // but Data(random bytes) + SymmetricKey(data:) is fine.
            secretKey = SymmetricKey(size: .bits256)
        }
        super.init()
        // Pre-compute the hex representation of the key for the URL.
        secretKeyHex = keyBytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Start the listener. Returns the client callback URL to send to the
    /// server. Throws if the loopback listener fails to start.
    ///
    /// Binds 127.0.0.1 first on an OS-assigned port, then ::1 on the same
    /// port, so the advertised `localhost` URL works whichever family Safari
    /// resolves first (CI can pass on IPv4 while a device resolves ::1). If
    /// the ::1 bind is unavailable (race / port reuse), the v4 listener is
    /// kept and the URL advertises `127.0.0.1`.
    func start() async throws -> String {
        let v4 = try makeLoopbackListener(host: .ipv4(.loopback), port: .any)
        let boundPort: NWEndpoint.Port
        do {
            boundPort = try await awaitListenerReady(v4, timeout: 5)
        } catch {
            // Do not leak the not-yet-published v4 listener when the first
            // await fails (timeout / start failure).
            v4.cancel()
            throw error
        }
        self.listener = v4

        var advertisedHost = "localhost"
        do {
            let v6 = try makeLoopbackListener(host: .ipv6(.loopback), port: boundPort)
            do {
                _ = try await awaitListenerReady(v6, timeout: 5)
            } catch {
                // The local listener is not yet published to `listenerV6`;
                // cancel it here so a failed ::1 bind does not leak it.
                v6.cancel()
                throw error
            }
            self.listenerV6 = v6
        } catch {
            BrowserMFAListenerLog.logger.error(
                "ipv6_loopback_bind_failed \(error.localizedDescription, privacy: .public) — advertising 127.0.0.1"
            )
            self.listenerV6?.cancel()
            self.listenerV6 = nil
            advertisedHost = "127.0.0.1"
        }

        self.host = advertisedHost
        self.port = boundPort.rawValue
        self.clientCallbackURL = "http://\(self.host):\(self.port)/callback?secret_key=\(self.secretKeyHex)"
        BrowserMFAListenerLog.logger.info(
            "ready listening on \(self.host, privacy: .public):\(self.port, privacy: .public) v6=\(self.listenerV6 != nil)"
        )
        return self.clientCallbackURL
    }

    /// Build an NWListener bound to the given loopback endpoint.
    private func makeLoopbackListener(host: NWEndpoint.Host, port: NWEndpoint.Port) throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: host, port: port)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        return listener
    }

    /// Start the listener and await `.ready` (or a failure / timeout).
    private func awaitListenerReady(_ listener: NWListener, timeout: TimeInterval) async throws -> NWEndpoint.Port {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWEndpoint.Port, Error>) in
            func resumeOnce(_ result: Result<NWEndpoint.Port, Error>) {
                let already = resumed.withLock { isResumed -> Bool in
                    if isResumed { return true }
                    isResumed = true
                    return false
                }
                guard !already else { return }
                cont.resume(with: result)
            }

            listener.stateUpdateHandler = { listenerState in
                switch listenerState {
                case .ready:
                    if let port = listener.port {
                        resumeOnce(.success(port))
                    } else {
                        resumeOnce(.failure(BrowserMFAListenerError.listenerFailed("listener ready without a port")))
                    }
                case .failed(let error):
                    resumeOnce(.failure(BrowserMFAListenerError.listenerFailed(error.localizedDescription)))
                case .cancelled:
                    resumeOnce(.failure(BrowserMFAListenerError.listenerFailed("listener cancelled")))
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            // `DispatchQueue.asyncAfter` is a dispatch timer on the global
            // concurrent queue, so this deadline is run-loop independent
            // (unlike `Timer.scheduledTimer`).
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                resumeOnce(.failure(BrowserMFAListenerError.listenerFailed("listener start timed out after \(timeout)s")))
            }
        }
    }

    /// Wait for the callback to arrive. Resolves with the WebAuthn assertion
    /// response, or an error on timeout.
    ///
    /// Cancellation-aware: cancelling the awaiting task resolves the wait
    /// with `CancellationError` through the serialized `resume`, so the
    /// ceremony does not have to run out its deadline. The listener itself
    /// stays up until the ceremony calls `cancel()`.
    func waitForResponse() async throws -> Proto_CredentialAssertionResponse {
        try await withTaskCancellationHandler {
            try await waitForResponseIgnoringCancellation()
        } onCancel: {
            resume(.failure(CancellationError()))
        }
    }

    private func waitForResponseIgnoringCancellation() async throws -> Proto_CredentialAssertionResponse {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Proto_CredentialAssertionResponse, Error>) in
            resumeLock.lock()
            // A callback or the deadline may already have resolved the
            // listener before this call (a local process can reach the port
            // first, or the deadline can fire while the ceremony is still
            // starting). Deliver the buffered result instead of waiting for
            // a second resolution that will never come.
            if let pending = pendingResult {
                pendingResult = nil
                resumeLock.unlock()
                // A cancellation that raced the buffered resolution must
                // win: a cancelled login must not complete from a result
                // that arrived before the wait started.
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                } else {
                    cont.resume(with: pending)
                }
                return
            }
            guard !didResume, continuation == nil else {
                // Already terminally resolved with no buffered result (a
                // previous waiter consumed it), or a second concurrent wait:
                // fail closed instead of overwriting and leaking the first
                // continuation.
                resumeLock.unlock()
                cont.resume(throwing: BrowserMFAListenerError.listenerFailed(
                    "the listener was already resolved"
                ))
                return
            }
            continuation = cont
            // Install the deadline while still holding the lock, so a
            // callback cannot resolve the wait between the continuation and
            // the task that `resume`/`cancel` later disarm. If Safari never
            // redirects (user cancels, HTTPS-Only blocks it, etc.), fail
            // gracefully.
            let timeout = self.timeout
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(timeout))
                } catch {
                    // Disarmed by `resume`/`cancel`: a resolution won.
                    return
                }
                guard let self else { return }
                BrowserMFAListenerLog.logger.error("timeout no callback after \(timeout)s")
                // Route through the serialized `resume`: a callback racing
                // the deadline must not resume the continuation twice.
                self.resume(.failure(BrowserMFAListenerError.timedOut))
                self.cancel()
            }
            resumeLock.unlock()
        }
    }

    /// Stop the listeners + cancel the timeout. Idempotent; callers resolve
    /// the wait before cancelling, so an installed continuation is left for
    /// `resume` to resolve.
    func cancel() {
        resumeLock.lock()
        timeoutTask?.cancel()
        timeoutTask = nil
        // Resolve an installed waiter now: after cancel there is no callback
        // and no deadline left, so leaving the continuation installed would
        // hang the caller. Latch the terminal state so a later
        // `waitForResponse()` fails fast instead of arming a deadline on a
        // torn-down listener.
        let continuation = self.continuation
        self.continuation = nil
        didResume = true
        // Drop any buffered result: a cancelled listener must not deliver a
        // resolution from a different ceremony.
        pendingResult = nil
        resumeLock.unlock()
        continuation?.resume(throwing: CancellationError())
        listener?.cancel()
        listener = nil
        listenerV6?.cancel()
        listenerV6 = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: NWConnection) {
        // Admission control: bound the number of per-connection buffers a
        // local caller can pin during the ceremony. The listener is
        // loopback-only, but another process on the same host can still
        // connect; excess connections get 503 and are dropped immediately.
        let admitted = activeConnections.withLock { count -> Bool in
            guard count < maxConcurrentConnections else { return false }
            count += 1
            return true
        }
        guard admitted else {
            BrowserMFAListenerLog.logger.error(
                "connection rejected: max \(self.maxConcurrentConnections) concurrent requests in flight"
            )
            conn.start(queue: .global(qos: .userInitiated))
            writeResponse(conn, status: 503, body: "too many concurrent requests")
            return
        }

        conn.start(queue: .global(qos: .userInitiated))
        // Exactly one exit path answers each connection: the request parser,
        // the idle deadline, and a listener teardown race to claim it. The
        // loser is discarded instead of sending a second response.
        let claimed = OSAllocatedUnfairLock(initialState: false)

        // A client that connects and then goes silent (or stalls mid-request)
        // must not pin the connection.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + readTimeout) { [weak self] in
            guard Self.claimConnection(claimed) else { return }
            guard let self else {
                conn.cancel()
                return
            }
            BrowserMFAListenerLog.logger.error("request read timed out after \(self.readTimeout)s")
            self.respond(conn, status: 408, body: "request timed out")
        }

        readRequest(on: conn, accumulated: Data(), claimed: claimed)
    }

    /// Read the request in fragments and parse it only once the HTTP header
    /// terminator (`\r\n\r\n`) has arrived. The callback URL lives in the
    /// request line, so parsing a partial buffer previously misclassified a
    /// genuine callback as unauthenticated whenever a TCP split or a
    /// CA-heavy envelope crossed the single 64 KB read.
    private func readRequest(
        on conn: NWConnection,
        accumulated: Data,
        claimed: OSAllocatedUnfairLock<Bool>
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                // The listener was torn down mid-handler; close the
                // connection instead of leaving it dangling.
                if Self.claimConnection(claimed) {
                    conn.cancel()
                }
                return
            }
            if let error {
                BrowserMFAListenerLog.logger.error("recv_error \(error.localizedDescription, privacy: .public)")
                if Self.claimConnection(claimed) {
                    self.respond(conn, status: 500, body: "recv error")
                }
                return
            }
            var accumulated = accumulated
            if let data, !data.isEmpty {
                accumulated.append(data)
            }
            guard accumulated.count <= Self.maxRequestBytes else {
                BrowserMFAListenerLog.logger.error("request exceeds \(Self.maxRequestBytes) bytes; rejecting")
                if Self.claimConnection(claimed) {
                    self.respond(conn, status: 413, body: "request too large")
                }
                return
            }
            if let headerEnd = accumulated.range(of: Self.headerTerminator) {
                // Headers are complete: the request line is the real
                // boundary. Parse only the header bytes, so a trailing body
                // cannot affect request-line extraction.
                guard Self.claimConnection(claimed) else { return }
                self.parseRequest(Data(accumulated[..<headerEnd.lowerBound]), conn: conn)
                return
            }
            if isComplete {
                // The peer closed before finishing the headers.
                if Self.claimConnection(claimed) {
                    self.respond(conn, status: 400, body: "incomplete request")
                }
                return
            }
            self.readRequest(on: conn, accumulated: accumulated, claimed: claimed)
        }
    }

    /// Parse the request line out of a complete header block and dispatch
    /// the `/callback` URL. The first claimer of the connection owns the
    /// response on every path (404/400/…).
    private func parseRequest(_ headers: Data, conn: NWConnection) {
        guard let request = String(data: headers, encoding: .utf8) else {
            respond(conn, status: 400, body: "bad request")
            return
        }
        // Parse the request line + headers. We only need the URL.
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? Substring(request)
        // "GET /callback?response=...&secret_key=... HTTP/1.1"
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(conn, status: 400, body: "bad request line")
            return
        }
        let pathAndQuery = String(parts[1])
        handleCallback(pathAndQuery: pathAndQuery, conn: conn)
    }

    /// Atomically claims the one terminal action for a connection. Returns
    /// true exactly once: the first caller owns the response, later exit
    /// paths are discarded.
    private static func claimConnection(_ claimed: OSAllocatedUnfairLock<Bool>) -> Bool {
        claimed.withLock { isClaimed -> Bool in
            if isClaimed { return false }
            isClaimed = true
            return true
        }
    }

    private func handleCallback(pathAndQuery: String, conn: NWConnection) {
        // We expect: /callback?response=<ciphertext>&secret_key=<hex>
        // (or ?secret_key=...&response=... — order may vary.)
        guard let questionIdx = pathAndQuery.firstIndex(of: "?") else {
            respond(conn, status: 404, body: "not found")
            return
        }
        let path = String(pathAndQuery[pathAndQuery.startIndex..<questionIdx])
        guard path == "/callback" else {
            respond(conn, status: 404, body: "not found")
            return
        }
        let query = String(pathAndQuery[pathAndQuery.index(after: questionIdx)...])
        // URLComponents(query:) doesn't exist; parse the query string by
        // prefixing with "?" so URLComponents treats it as a relative URL
        // with a query component.
        let params = URLComponents(string: "?" + query)?.queryItems ?? []
        let responseParam = params.first(where: { $0.name == "response" })?.value

        guard let responseParam, !responseParam.isEmpty else {
            // Anything on the loopback port can send this request. A missing
            // `response` param carries no authenticated payload, so answer
            // 400 and keep waiting: the genuine AES-GCM callback or the
            // deadline decides the login.
            BrowserMFAListenerLog.logger.error("callback ignored: missing ?response= param")
            respond(conn, status: 400, body: "missing response")
            return
        }

        // The response param is URL-decoded by URLComponents (it was set by
        // url.Values.Encode in Go, which percent-encodes the JSON). It's the
        // JSON envelope {"ciphertext": <base64>, "nonce": <base64>}.
        Task { [weak self] in
            guard let self else {
                conn.cancel()
                return
            }
            do {
                let webauthnResp = try await self.decryptAndDecode(responseParam)
                BrowserMFAListenerLog.logger.info("callback decrypted webauthn response (id=\(webauthnResp.id.prefix(16), privacy: .public)…)")
                // Respond to Safari with a "close this tab" page.
                self.respond(conn, status: 200, body: self.closePageHTML)
                self.resume(.success(webauthnResp))
            } catch BrowserMFAListenerError.unauthenticatedCallback(let reason) {
                // The payload did not authenticate against our per-run key, so
                // it carries no proof it came from the server: any local
                // process can send an arbitrary `response` value. Answer 400
                // and keep waiting (same policy as the missing-param branch);
                // the genuine callback or the deadline decides the login.
                BrowserMFAListenerLog.logger.error("callback ignored: unauthenticated payload (\(reason, privacy: .private(mask: .hash)))")
                self.respond(conn, status: 400, body: "unauthenticated response")
            } catch {
                // The plaintext was sealed under our per-run key but could not
                // be decoded: the server produced it, so the failure is
                // terminal and the wait must observe it.
                BrowserMFAListenerLog.logger.error("callback decrypt/decode failed: \(error.localizedDescription, privacy: .public)")
                self.respond(conn, status: 500, body: "decrypt failed")
                self.resume(.failure(error))
            }
        }
    }

    /// Decrypt the AES-256-GCM envelope and decode the CLILoginResponse +
    /// BrowserMFAWebauthnResponse inside.
    ///
    /// Failures split into two classes: everything up to and including the
    /// AES-256-GCM open throws `.unauthenticatedCallback` (the payload was
    /// not produced by the server holding our per-run key), while a decode
    /// failure *after* a successful open throws `.decodeFailed` (the server
    /// sealed a malformed plaintext). Only the authenticated class is
    /// terminal for the login.
    ///
    /// The final mapping into the generated proto message runs on the main
    /// actor: those types are main-actor isolated under the app target's
    /// default isolation. The hop is one per callback and keeps this
    /// listener's I/O and crypto off the main actor.
    private func decryptAndDecode(_ responseParam: String) async throws -> Proto_CredentialAssertionResponse {
        // 1. Parse the JSON envelope {ciphertext: base64, nonce: base64}.
        //    Go's json.Marshal of []byte = base64 string.
        guard let envelopeData = responseParam.data(using: .utf8) else {
            throw BrowserMFAListenerError.unauthenticatedCallback("envelope not utf8")
        }
        let envelope: SealedEnvelope
        do {
            envelope = try JSONDecoder().decode(SealedEnvelope.self, from: envelopeData)
        } catch {
            throw BrowserMFAListenerError.unauthenticatedCallback("envelope JSON: \(error.localizedDescription)")
        }
        guard let ciphertextPlusTag = Data(base64Encoded: envelope.ciphertext),
              let nonceData = Data(base64Encoded: envelope.nonce) else {
            throw BrowserMFAListenerError.unauthenticatedCallback("ciphertext/nonce not base64")
        }
        // 2. AES-256-GCM decrypt.
        //    Go's aesgcm.Seal(nil, nonce, plaintext, nil) returns
        //    ciphertext || tag (the 16-byte GCM tag is appended to the
        //    ciphertext). The envelope stores this concatenated blob in the
        //    "ciphertext" field, and the nonce separately. CryptoKit's
        //    AES.GCM.SealedBox(nonce:ciphertext:tag:) expects them
        //    separately, so we split the last 16 bytes off as the tag.
        let gcmTagLength = 16
        guard ciphertextPlusTag.count > gcmTagLength else {
            throw BrowserMFAListenerError.unauthenticatedCallback("ciphertext too short")
        }
        let ciphertext = ciphertextPlusTag.prefix(ciphertextPlusTag.count - gcmTagLength)
        let tag = ciphertextPlusTag.suffix(gcmTagLength)
        let plaintext: Data
        do {
            let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData),
                                               ciphertext: ciphertext,
                                               tag: tag)
            plaintext = try AES.GCM.open(sealed, using: secretKey)
        } catch {
            throw BrowserMFAListenerError.unauthenticatedCallback("open: \(error.localizedDescription)")
        }
        // 3. Decode the decrypted CLILoginResponse JSON.
        //
        //    IMPORTANT: this is Go encoding/json output of the
        //    CLILoginResponse struct (lib/auth/authclient/clt.go:1432),
        //    NOT proto JSON. The inner BrowserMFAWebauthnResponse is a
        //    wantypes.CredentialAssertionResponse (a plain Go struct),
        //    and its binary fields are protocol.URLEncodedBase64, which
        //    marshals as base64.RawURLEncoding (URL-safe, no padding).
        //    SwiftProtobuf JSON decoding cannot handle either of these
        //    (it expects proto field names + padded base64), so we decode
        //    with plain Codable structs and map into the proto type.
        do {
            let loginResp = try JSONDecoder().decode(CLIResponsePayload.self, from: plaintext)
            guard let webauthn = loginResp.browserMFAWebauthnResponse else {
                throw BrowserMFAListenerError.decodeFailed("no browser_mfa_webauthn_response field")
            }
            return await MainActor.run { webauthn.intoProto() }
        } catch {
            throw BrowserMFAListenerError.decodeFailed("CLILoginResponse: \(error.localizedDescription)")
        }
    }

    /// The single serialized resolution entry point. The first result wins:
    /// it is delivered to a waiting continuation, or buffered until
    /// `waitForResponse()` installs one. Later results (a second callback, a
    /// deadline after a callback, a success after a failure) are discarded,
    /// so the wait can never observe two resolutions.
    ///
    /// Internal rather than private so tests can drive the state machine
    /// without a socket.
    func resume(_ result: Result<Proto_CredentialAssertionResponse, Error>) {
        resumeLock.lock()
        guard !didResume else {
            resumeLock.unlock()
            return
        }
        didResume = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        resumeLock.unlock()
        guard let continuation else { return }
        switch result {
        case .success(let resp): continuation.resume(returning: resp)
        case .failure(let err): continuation.resume(throwing: err)
        }
    }

    // MARK: - HTTP response

    private func respond(_ conn: NWConnection, status: Int, body: String) {
        // Every admitted connection answers exactly once (guarded by
        // `claimConnection`), so this is the single point that releases its
        // admission slot.
        defer { releaseAdmission() }
        writeResponse(conn, status: status, body: body)
    }

    /// Write an HTTP response without touching the admission counter: used
    /// for the over-cap rejection, which never acquired a slot.
    private func writeResponse(_ conn: NWConnection, status: Int, body: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 408: reason = "Request Timeout"
        case 413: reason = "Payload Too Large"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "OK"
        }
        let response = "HTTP/1.1 \(status) \(reason)\r\n" +
                       "Content-Type: text/html; charset=utf-8\r\n" +
                       "Content-Length: \(body.utf8.count)\r\n" +
                       "Connection: close\r\n" +
                       "Access-Control-Allow-Origin: *\r\n" +
                       "\r\n\(body)"
        let data = response.data(using: .utf8) ?? Data()
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// Release one admission slot. Called exactly once per admitted
    /// connection from `respond`; the over-cap rejection path never
    /// acquires a slot and never releases one.
    private func releaseAdmission() {
        activeConnections.withLock { count in
            if count > 0 { count -= 1 }
        }
    }

    private let closePageHTML = """
    <!DOCTYPE html>
    <html><head><title>VVTerm</title></head>
    <body style="font-family:-apple-system,sans-serif;text-align:center;padding:2em">
    <h2>✅ Done</h2>
    <p>You can close this tab and return to VVTerm.</p>
    </body></html>
    """
}

// MARK: - CLILoginResponse Codable types (Go encoding/json decode)

/// The decrypted Browser MFA callback payload. This mirrors the Go
/// `CLILoginResponse` struct (lib/auth/authclient/clt.go:1432) — it is
/// produced by `json.Marshal` (Go encoding/json), NOT proto JSON, so we
/// decode with plain `Codable` structs. We only declare the one field the
/// spike needs; the rest (`username`, `cert`, `host_signers`, …) are
/// silently ignored by `JSONDecoder`.
private nonisolated struct CLIResponsePayload: Decodable {
    /// `browser_mfa_webauthn_response` in the JSON (Go struct tag).
    let browserMFAWebauthnResponse: WebAuthnAssertionResponse?

    enum CodingKeys: String, CodingKey {
        case browserMFAWebauthnResponse = "browser_mfa_webauthn_response"
    }
}

/// Mirrors `wantypes.CredentialAssertionResponse`
/// (lib/auth/webauthntypes/webauthn.go:112). The embedding mirrors the Go
/// struct: `PublicKeyCredential` (which embeds `Credential`) + `response`.
/// Binary fields are `protocol.URLEncodedBase64` (base64.RawURLEncoding —
/// URL-safe, no padding), decoded via `URLSafeBase64Data` below.
private nonisolated struct WebAuthnAssertionResponse: Decodable {
    let id: String?
    let type: String?
    let rawID: URLSafeBase64Data?
    let response: AssertionResponse?

    enum CodingKeys: String, CodingKey {
        // Go json tags: id, type, rawId, response.
        case id, type, rawID = "rawId", response
    }
}

/// Mirrors `wantypes.AuthenticatorAssertionResponse`
/// (lib/auth/webauthntypes/webauthn.go:127). Embeds `AuthenticatorResponse`
/// (which carries `clientDataJSON`) + the assertion-specific binary fields.
private nonisolated struct AssertionResponse: Decodable {
    let clientDataJSON: URLSafeBase64Data?
    let authenticatorData: URLSafeBase64Data?
    let signature: URLSafeBase64Data?
    let userHandle: URLSafeBase64Data?
}

/// A base64url-no-padding `Data` wrapper matching Go's
/// `protocol.URLEncodedBase64` (go-webauthn/webauthn/protocol/base64.go:
/// `base64.RawURLEncoding`). Swift's `Data(base64Encoded:)` only accepts
/// padded standard base64, so we add padding (if needed) before decoding.
/// We also accept standard base64 (with `+`/`/`) as a fallback, since older
/// Teleport builds may emit it.
private nonisolated struct URLSafeBase64Data: Decodable {
    let data: Data

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        data = URLSafeBase64Data.decode(raw) ?? Data()
    }

    /// Decode a base64url (no padding) or standard base64 string to `Data`.
    static func decode(_ string: String) -> Data? {
        // First try base64url without padding (Go's RawURLEncoding).
        // `Data(base64Encoded:options:)` with `.urlSafe` accepts unpadded
        // input on Apple platforms, but we add padding defensively so the
        // decode is robust across OS versions.
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        let mod = s.count % 4
        if mod != 0 {
            s.append(String(repeating: "=", count: 4 - mod))
        }
        return Data(base64Encoded: s)
    }
}

// MARK: - Mapping to the proto types the ceremony/runner consume

extension WebAuthnAssertionResponse {
    /// Map the Codable-decoded response into the proto type
    /// (`Proto_CredentialAssertionResponse`) the rest of the spike expects.
    /// Missing fields default to empty (matching proto3 semantics).
    ///
    /// Main-actor because the generated proto messages are main-actor
    /// isolated under the app target's default isolation.
    @MainActor
    func intoProto() -> Proto_CredentialAssertionResponse {
        var p = Proto_CredentialAssertionResponse()
        p.id = id ?? ""
        p.type = type ?? ""
        p.rawID = rawID?.data ?? Data()
        if let response {
            var r = Proto_AuthenticatorAssertionResponse()
            r.clientDataJson = response.clientDataJSON?.data ?? Data()
            r.authenticatorData = response.authenticatorData?.data ?? Data()
            r.signature = response.signature?.data ?? Data()
            r.userHandle = response.userHandle?.data ?? Data()
            p.response = r
        }
        return p
    }
}

// MARK: - Logging

/// Shared logger for the Browser MFA listener. Uses VVTerm's logging convention
/// (subsystem = bundle id, category = feature).
nonisolated enum BrowserMFAListenerLog {
    static let logger = Logger.forCategory("TeleportBrowserMFA")
}
