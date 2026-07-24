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
import CryptoKit
import Network

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

    /// The hostname we advertise in the callback URL. We bind NWListener to
    /// `.any` (all interfaces, including loopback) but advertise `localhost`
    /// rather than `127.0.0.1` so Safari's HTTPS-Only mode treats it as a
    /// secure context and doesn't show the "connection is not secure"
    /// banner. ValidateClientRedirect (lib/client/sso/redirector.go) accepts
    /// both `localhost` and `127.0.0.1` for the http scheme.
    private let host = "localhost"

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
                        BrowserMFAListenerLog.logger.info("ready listening on \(self.host):\(self.port, privacy: .public)")
                        cont.resume(returning: self.clientCallbackURL)
                    case .failed(let err):
                        BrowserMFAListenerLog.logger.error("failed \(err.localizedDescription, privacy: .public)")
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
                    BrowserMFAListenerLog.logger.error("timeout no callback after \(self.timeout)s")
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
                BrowserMFAListenerLog.logger.error("recv_error \(error.localizedDescription, privacy: .public)")
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
            BrowserMFAListenerLog.logger.error("callback missing ?response= param")
            respond(conn, status: 400, body: "missing response")
            resume(.failure(BrowserMFAListenerError.noResponseParam))
            return
        }

        // The response param is URL-decoded by URLComponents (it was set by
        // url.Values.Encode in Go, which percent-encodes the JSON). It's the
        // JSON envelope {"ciphertext": <base64>, "nonce": <base64>}.
        do {
            let webauthnResp = try decryptAndDecode(responseParam)
            BrowserMFAListenerLog.logger.info("callback decrypted webauthn response (id=\(webauthnResp.id.prefix(16), privacy: .public)…)")
            // Respond to Safari with a "close this tab" page.
            respond(conn, status: 200, body: closePageHTML)
            resume(.success(webauthnResp))
        } catch {
            BrowserMFAListenerLog.logger.error("callback decrypt/decode failed: \(error.localizedDescription, privacy: .public)")
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
            return webauthn.intoProto()
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

// MARK: - CLILoginResponse Codable types (Go encoding/json decode)

/// The decrypted Browser MFA callback payload. This mirrors the Go
/// `CLILoginResponse` struct (lib/auth/authclient/clt.go:1432) — it is
/// produced by `json.Marshal` (Go encoding/json), NOT proto JSON, so we
/// decode with plain `Codable` structs. We only declare the one field the
/// spike needs; the rest (`username`, `cert`, `host_signers`, …) are
/// silently ignored by `JSONDecoder`.
private struct CLIResponsePayload: Decodable {
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
private struct WebAuthnAssertionResponse: Decodable {
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
private struct AssertionResponse: Decodable {
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
private struct URLSafeBase64Data: Decodable {
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
enum BrowserMFAListenerLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "TeleportBrowserMFA")
}
