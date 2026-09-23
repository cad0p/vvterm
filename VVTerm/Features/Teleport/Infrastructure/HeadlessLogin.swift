// SPDX-License-Identifier: MIT
//
//  HeadlessLogin.swift
//  VVTerm
//
//  The Phase-1 blocking headless login call: `POST /webapi/headless/login`.
//
//  The request is unauthenticated and blocks server-side until the user
//  approves the pending request in a browser (or the server's ~180s window
//  expires). The response carries the issued SSH certificate, the TLS
//  certificate for the Phase-2 gRPC dial, and the cluster's host signers.
//
//  Wire shape (Go `encoding/json` on the server):
//    - `ssh_pub_key` / `tls_pub_key` are `[]byte`, i.e. standard base64
//      strings (NOT base64url);
//    - `ttl` is a `time.Duration` in nanoseconds;
//    - `tls_pub_key` is omitted when nil (`omitempty`);
//    - the response's `cert` / `tls_cert` / `tls_certs` / `checking_keys`
//      elements are base64 of the PEM or authorized_keys bytes.
//

import Foundation

/// The `POST /webapi/headless/login` request body.
struct HeadlessLoginReq: Encodable {
    let user: String
    let headlessAuthenticationID: String
    /// Base64 of the authorized_keys line (with its trailing newline).
    let sshPubKey: String
    /// Base64 of the TLS public key PEM; omitted when nil.
    let tlsPubKey: String?
    /// Requested certificate lifetime in nanoseconds.
    let ttl: Int64
    let compatibility: String

    enum CodingKeys: String, CodingKey {
        case user
        case headlessAuthenticationID = "headless_id"
        case sshPubKey = "ssh_pub_key"
        case tlsPubKey = "tls_pub_key"
        case ttl
        case compatibility
    }

    init(
        user: String,
        headlessAuthenticationID: String,
        sshPubKey: String,
        tlsPubKey: String?,
        ttl: Int64,
        compatibility: String
    ) {
        self.user = user
        self.headlessAuthenticationID = headlessAuthenticationID
        self.sshPubKey = sshPubKey
        self.tlsPubKey = tlsPubKey
        self.ttl = ttl
        self.compatibility = compatibility
    }
}

/// The `POST /webapi/headless/login` response body.
struct HeadlessLoginResponse: Decodable {
    /// Base64 of the issued SSH certificate PEM.
    let cert: String?
    /// Base64 of the issued TLS certificate PEM (for the Phase-2 mTLS dial).
    let tlsCert: String?
    /// The cluster's host signers (trust anchors for the gRPC dial).
    let hostSigners: [TrustedCerts]?

    enum CodingKeys: String, CodingKey {
        case cert
        case tlsCert = "tls_cert"
        case hostSigners = "host_signers"
    }

    /// One `host_signers` entry: the cluster name, its host CA checking keys
    /// (base64 of authorized_keys lines), and its TLS CA certificates
    /// (base64 of PEM).
    struct TrustedCerts: Decodable {
        let clusterName: String
        let checkingKeys: [String]
        let tlsCerts: [String]?

        enum CodingKeys: String, CodingKey {
            case clusterName = "domain_name"
            case checkingKeys = "checking_keys"
            case tlsCerts = "tls_certs"
        }
    }
}

/// Errors surfaced by the headless login call.
enum HeadlessError: LocalizedError {
    case transport(String)
    case http(status: Int, body: String)
    case decode(String)
    case noCert
    case missingField(String)

    var errorDescription: String? {
        switch self {
        case .transport(let message):
            return "transport: \(message)"
        case .http(let status, let body):
            return "HTTP \(status): \(body)"
        case .decode(let message):
            return "decode: \(message)"
        case .noCert:
            return "no cert in response"
        case .missingField(let field):
            return "missing field: \(field)"
        }
    }
}

/// The headless login endpoint.
enum HeadlessLogin {

    /// The session used when the caller does not inject one. The shared trust
    /// session carries the 200s timeouts the blocking POST needs; exposing it
    /// keeps the default-invariant testable instead of hidden in the
    /// parameter list.
    static var defaultSession: URLSession { TeleportTrustSession.session }

    /// Posts the headless login request and decodes the response.
    ///
    /// - Parameters:
    ///   - baseURL: the Teleport web proxy base URL.
    ///   - req: the request body.
    ///   - session: the URLSession to use. Production callers rely on the
    ///     default; tests inject a stub to observe the request.
    /// - Throws: `HeadlessError.transport` for URLSession failures,
    ///   `.http` for any non-200 status, `.decode` for an unreadable body.
    static func post(
        baseURL: URL,
        req: HeadlessLoginReq,
        session: URLSession = HeadlessLogin.defaultSession
    ) async throws -> HeadlessLoginResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("webapi/headless/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(req)
        } catch {
            throw HeadlessError.decode(error.localizedDescription)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HeadlessError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw HeadlessError.transport("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw HeadlessError.http(status: http.statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(HeadlessLoginResponse.self, from: data)
        } catch {
            throw HeadlessError.decode(error.localizedDescription)
        }
    }
}
