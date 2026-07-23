// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  BrowserMFAListener.swift
//  iotest
//
//  Session 1.11 — the loopback HTTP listener that receives the Browser MFA
//  callback from Safari.
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
//    3. Expose clientCallbackURL = "http://127.0.0.1:<port>/callback?secret_key=<hex>".
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

import Foundation
import OSLog
import CryptoKit
import Network
import SwiftProtobuf

// MARK: - Log markers

enum BrowserMFAListenerLog {
    static let logger = Logger(subsystem: "it.pcad.vvterm.iotest", category: "browser-mfa-listener")

    static func step(_ step: String, _ message: String) {
        logger.notice("[IOTEST] bmfa_listener_\(step, privacy: .public) \(message, privacy: .public)")
    }
}

// MARK: - Errors

enum BrowserMFAListenerError: Error, LocalizedError {
    case listenerFailed(String)
    case notReady
    case timedOut
    case noResponseParam
    case decryptFailed(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let s): return "listener failed: \(s)"
        case .notReady: return "listener not ready"
        case .timedOut: return "timed out waiting for browser MFA callback"
        case .noResponseParam: return "callback URL missing ?response= param"
        case .decryptFailed(let s): return "decrypt failed: \(s)"
        case .decodeFailed(let s): return "decode failed: \(s)"
        }
    }
}

// MARK: - The sealed envelope (matches lib/secret/secret.go sealedData)

/// Go's json.Marshal of `[]byte` produces a base64 STRING, so both fields are
/// base64-encoded strings in the JSON (not base64url, not raw bytes).
private struct SealedEnvelope: Decodable {
    let ciphertext: String  // base64
    let nonce: String       // base64
}

/// The CLILoginResponse (lib/auth/authclient/clt.go:1448) — we only need the
/// BrowserMFAWebauthnResponse field. The JSON tag is
/// "browser_mfa_webauthn_response". We decode this via
/// Proto_CLILoginResponseWrapper (a SwiftProtobuf.Message) so SwiftProtobuf
/// handles the JSON decoding + the nested CredentialAssertionResponse proto.


// MARK: - Listener

/// A loopback HTTP listener for the Browser MFA callback.
///
/// NOT @MainActor — the NWListener runs on its own queue and the callbacks
/// (stateUpdateHandler, newConnectionHandler, connection.receive) fire on
/// background queues. The ceremony (which is @MainActor) creates it and
/// awaits it via async functions. The only shared mutable state is the
/// continuation, which is `Sendable` (CheckedContinuation is Sendable when
/// the return type is Sendable — Proto_CredentialAssertionResponse is a
/// struct of Data/String, hence Sendable).
final class BrowserMFAListener: NSObject, @unchecked Sendable {

    /// The secret key (32 random bytes). Hex-encoded for the URL transport.
    private(set) var secretKeyHex: String = ""
    /// The raw 32 bytes (for AES-GCM).
    private let secretKey: SymmetricKey

    /// The callback URL to send to the server
    /// (http://127.0.0.1:<port>/callback?secret_key=<hex>).
    private(set) var clientCallbackURL: String = ""

    /// The bound port (read after the listener is ready).
    private(set) var port: UInt16 = 0

    private var listener: NWListener?
    private var continuation: CheckedContinuation<Proto_CredentialAssertionResponse, Error>?
    private let resumeLock = NSLock()
    private var didResume = false  // guard against double-resume (timeout vs. callback race)

    /// A timeout timer (defaults.SSOCallbackTimeout is 120s in Teleport; we
    /// use 180s to match the headless flow's blocking-POST timeout).
    private var timeoutTimer: Timer?
    private let timeout: TimeInterval = 180

    /// The host address we bind to. 127.0.0.1 is the only universally-safe
    /// loopback on iOS (127.x.x.x other than .0.0.1 is not supported,
    /// per Apple Developer Forums thread 724864).
    private let host = "127.0.0.1"

    override init() {
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
    /// server. Throws if the listener fails to start.
    func start() async throws -> String {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            do {
                // Port 0 = OS-assigned. NWListener binds to all interfaces
                // by default; on iOS, only the loopback address (127.0.0.1)
                // can reach an in-process listener from Safari (127.x.x.x
                // other than .0.0.1 is unsupported — see Apple Developer
                // Forums thread 724864).
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        // Read the bound port.
                        if let port = listener.port {
                            self.port = UInt16(port.rawValue)
                        }
                        self.clientCallbackURL = "http://\(self.host):\(self.port)/callback?secret_key=\(self.secretKeyHex)"
                        BrowserMFAListenerLog.step("ready", "listening on \(self.host):\(self.port)")
                        cont.resume(returning: self.clientCallbackURL)
                    case .failed(let err):
                        BrowserMFAListenerLog.step("failed", "\(err)")
                        cont.resume(throwing: BrowserMFAListenerError.listenerFailed(err.localizedDescription))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] conn in
                    self?.handleConnection(conn)
                }
                listener.start(queue: .global(qos: .userInitiated))
            } catch {
                cont.resume(throwing: BrowserMFAListenerError.listenerFailed(error.localizedDescription))
            }
        }
    }

    /// Wait for the callback to arrive. Resolves with the WebAuthn assertion
    /// response, or an error on timeout.
    func waitForResponse() async throws -> Proto_CredentialAssertionResponse {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Proto_CredentialAssertionResponse, Error>) in
            self.continuation = cont
            // Start a timeout — if Safari never redirects (user cancels,
            // HTTPS-Only blocks it, etc.), fail gracefully.
            self.timeoutTimer = Timer.scheduledTimer(withTimeInterval: self.timeout, repeats: false) { [weak self] _ in
                guard let self else { return }
                if self.continuation != nil {
                    BrowserMFAListenerLog.step("timeout", "no callback after \(self.timeout)s")
                    self.continuation?.resume(throwing: BrowserMFAListenerError.timedOut)
                    self.continuation = nil
                }
                self.cancel()
            }
        }
    }

    /// Stop the listener + cancel the timeout.
    func cancel() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        // Read the request. We accept any size up to 64KB (the callback is a
        // small GET with a query param).
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                BrowserMFAListenerLog.step("recv_error", "\(error)")
                self.respond(conn, status: 500, body: "recv error")
                return
            }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                self.respond(conn, status: 400, body: "bad request")
                return
            }
            // Parse the request line + headers. We only need the URL.
            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? Substring(request)
            // "GET /callback?response=...&secret_key=... HTTP/1.1"
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.respond(conn, status: 400, body: "bad request line")
                return
            }
            let pathAndQuery = String(parts[1])
            self.handleCallback(pathAndQuery: pathAndQuery, conn: conn)
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
            BrowserMFAListenerLog.step("callback", "missing ?response= param")
            respond(conn, status: 400, body: "missing response")
            resume(.failure(BrowserMFAListenerError.noResponseParam))
            return
        }

        // The response param is URL-decoded by URLComponents (it was set by
        // url.Values.Encode in Go, which percent-encodes the JSON). It's the
        // JSON envelope {"ciphertext": <base64>, "nonce": <base64>}.
        do {
            let webauthnResp = try decryptAndDecode(responseParam)
            BrowserMFAListenerLog.step("callback", "decrypted webauthn response (\(webauthnResp.id.prefix(16))…)")
            // Respond to Safari with a "close this tab" page.
            respond(conn, status: 200, body: closePageHTML)
            resume(.success(webauthnResp))
        } catch {
            BrowserMFAListenerLog.step("callback", "decrypt/decode failed: \(error.localizedDescription)")
            respond(conn, status: 500, body: "decrypt failed")
            resume(.failure(error))
        }
    }

    /// Decrypt the AES-256-GCM envelope and decode the CLILoginResponse +
    /// BrowserMFAWebauthnResponse inside.
    private func decryptAndDecode(_ responseParam: String) throws -> Proto_CredentialAssertionResponse {
        // 1. Parse the JSON envelope {ciphertext: base64, nonce: base64}.
        //    Go's json.Marshal of []byte = base64 string.
        guard let envelopeData = responseParam.data(using: .utf8) else {
            throw BrowserMFAListenerError.decodeFailed("envelope not utf8")
        }
        let envelope: SealedEnvelope
        do {
            envelope = try JSONDecoder().decode(SealedEnvelope.self, from: envelopeData)
        } catch {
            throw BrowserMFAListenerError.decodeFailed("envelope JSON: \(error.localizedDescription)")
        }
        guard let ciphertextPlusTag = Data(base64Encoded: envelope.ciphertext),
              let nonceData = Data(base64Encoded: envelope.nonce) else {
            throw BrowserMFAListenerError.decodeFailed("ciphertext/nonce not base64")
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
            throw BrowserMFAListenerError.decryptFailed("ciphertext too short")
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
            throw BrowserMFAListenerError.decryptFailed("open: \(error.localizedDescription)")
        }
        // 3. Decode CLILoginResponse JSON → BrowserMFAWebauthnResponse.
        //    The inner response is a webauthn.CredentialAssertionResponse,
        //    serialized with the proto JSON tags. We decode it into the
        //    proto type directly (SwiftProtobuf supports JSON decoding).
        do {
            let loginResp = try Proto_CLILoginResponseWrapper(jsonUTF8Data: plaintext)
            guard loginResp.hasBrowserMfaWebauthnResponse else {
                throw BrowserMFAListenerError.decodeFailed("no browser_mfa_webauthn_response field")
            }
            return loginResp.browserMfaWebauthnResponse
        } catch {
            throw BrowserMFAListenerError.decodeFailed("CLILoginResponse: \(error.localizedDescription)")
        }
    }

    private func resume(_ result: Result<Proto_CredentialAssertionResponse, Error>) {
        resumeLock.lock()
        guard !didResume else {
            resumeLock.unlock()
            return
        }
        didResume = true
        let continuation = self.continuation
        self.continuation = nil
        resumeLock.unlock()
        guard let continuation else { return }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        switch result {
        case .success(let resp): continuation.resume(returning: resp)
        case .failure(let err): continuation.resume(throwing: err)
        }
    }

    // MARK: - HTTP response

    private func respond(_ conn: NWConnection, status: Int, body: String) {
        let response = "HTTP/1.1 \(status) OK\r\n" +
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

    private let closePageHTML = """
    <!DOCTYPE html>
    <html><head><title>VVTerm</title></head>
    <body style="font-family:-apple-system,sans-serif;text-align:center;padding:2em">
    <h2>✅ Done</h2>
    <p>You can close this tab and return to VVTerm.</p>
    </body></html>
    """
}

// MARK: - CLILoginResponse proto wrapper (for JSON decode)

/// A minimal proto wrapper to decode the CLILoginResponse JSON the server
/// produces. We only need the `browser_mfa_webauthn_response` field. We
/// define it as a SwiftProtobuf message so we get JSON decoding for free.
///
/// The JSON tag matches lib/auth/authclient/clt.go:1451
/// (`browser_mfa_webauthn_response`). The inner CredentialAssertionResponse
/// is the same proto type we already have (Proto_CredentialAssertionResponse).
struct Proto_CLILoginResponseWrapper: SwiftProtobuf.Message {
    var browserMfaWebauthnResponse: Proto_CredentialAssertionResponse {
        get {return _browserMfaWebauthnResponse ?? Proto_CredentialAssertionResponse()}
        set {_browserMfaWebauthnResponse = newValue}
    }
    var hasBrowserMfaWebauthnResponse: Bool {return _browserMfaWebauthnResponse != nil}
    mutating func clearBrowserMfaWebauthnResponse() {_browserMfaWebauthnResponse = nil}

    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}

    fileprivate var _browserMfaWebauthnResponse: Proto_CredentialAssertionResponse? = nil
}

// SwiftProtobuf.Message conformance for the wrapper. This is the minimal
// boilerplate to get JSON decoding (we only read one field). The field
// number is irrelevant for JSON decoding (JSON uses field names), but we
// pick 1 to be consistent with the real CLILoginResponse (which has many
// fields — we just ignore the rest via unknownFields).
extension Proto_CLILoginResponseWrapper: SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
    static let protoMessageName: String = "proto.CLILoginResponse"
    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        1: .standard(proto: "browser_mfa_webauthn_response"),
    ]

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularMessageField(value: &self._browserMfaWebauthnResponse)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if let v = self._browserMfaWebauthnResponse {
            try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    static func ==(lhs: Proto_CLILoginResponseWrapper, rhs: Proto_CLILoginResponseWrapper) -> Bool {
        if lhs._browserMfaWebauthnResponse != rhs._browserMfaWebauthnResponse {return false}
        if lhs.unknownFields != rhs.unknownFields {return false}
        return true
    }
}
