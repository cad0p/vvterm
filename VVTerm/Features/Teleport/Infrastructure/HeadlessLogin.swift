// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  HeadlessLogin.swift
//  VVTerm
//
//  The blocking POST /webapi/headless/login and its request/response types.
//  Ports the shape of Teleport's `lib/client/weblogin.go`:
//
//    - HeadlessLoginReq  (weblogin.go:207) — the POST body
//    - CLILoginResponse  (auth/authclient/clt.go:1432) — the response
//
//  The POST blocks until the headless request is approved (up to 180s,
//  defaults.HeadlessLoginTimeout). The cert + host_signers come back in
//  the response body when Safari approves.
//
//  This is the load-bearing HTTP call for the 5d bootstrap. On iOS it
//  must survive the app backgrounding when Safari (via ASWebAuthenticationSession
//  or UIApplication.open) comes to the foreground for the user to approve.
//  That survival is the device-only unknown de-risked in session 1.9.
//

import Foundation

// MARK: - Request

/// The POST /webapi/headless/login body. Mirrors Teleport's HeadlessLoginReq
/// (lib/client/weblogin.go:207). Field names match the Go JSON tags exactly.
///
/// IMPORTANT: `ssh_pub_key` and `tls_pub_key` are `[]byte` in Go, which
/// JSON-marshals as **base64-encoded** strings. So the Swift side must
/// base64-encode the raw authorized_keys string before sending. (Go's
/// `json.Marshal` on `[]byte` calls `base64.StdEncoding.EncodeToString`.)
/// The raw bytes are the UTF-8 bytes of the authorized_keys string
/// (ssh.MarshalAuthorizedKey output, with trailing newline).
struct HeadlessLoginReq: Encodable {
    /// The Teleport username.
    let user: String
    /// The headless authentication ID (UUID v5 derived from the SSH pub key).
    let headlessAuthenticationID: String
    /// The SSH public key in authorized_keys format, base64-encoded (because
    /// Go's `[]byte` marshals as base64). The raw bytes are the UTF-8 bytes
    /// of `ssh.MarshalAuthorizedKey` output (with trailing newline).
    let sshPubKey: String
    /// The TLS public key (PEM), base64-encoded. Optional for the spike —
    /// we only need the SSH cert to prove the bootstrap. Teleport requires
    /// ssh_pub_key OR tls_pub_key; we send ssh_pub_key only.
    let tlsPubKey: String?
    /// The requested cert TTL, in nanoseconds. tsh sends time.Duration in
    /// ns (e.g. 3600000000000 for 1h). Go's time.Duration marshals as an
    /// integer number of nanoseconds.
    let ttl: Int64
    /// OpenSSH compatibility flags. tsh sends tc.CertificateFormat (usually
    /// empty or "0"). Empty string is omitted by Go's omitempty; we send "".
    let compatibility: String

    enum CodingKeys: String, CodingKey {
        case user
        case headlessAuthenticationID = "headless_id"
        case sshPubKey = "ssh_pub_key"
        case tlsPubKey = "tls_pub_key"
        case ttl
        case compatibility
    }
}

// MARK: - Response

/// The POST /webapi/headless/login response. Mirrors Teleport's
/// CLILoginResponse (lib/auth/authclient/clt.go:1432). We only decode the
/// fields the spike needs (cert + host_signers); the rest are ignored.
struct HeadlessLoginResponse: Decodable {
    /// The PEM-encoded SSH certificate.
    let cert: String?
    /// The PEM-encoded TLS certificate (not needed for the spike, but
    /// decoded for logging).
    let tlsCert: String?
    /// The host signers (trusted cluster CAs).
    let hostSigners: [TrustedCerts]?

    enum CodingKeys: String, CodingKey {
        case cert
        case tlsCert = "tls_cert"
        case hostSigners = "host_signers"
    }

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

// MARK: - HTTP

/// Performs the blocking POST /webapi/headless/login.
///
/// This call blocks until the headless request is approved (or the 180s
/// timeout fires). On iOS, the URLSession task must survive the app
/// backgrounding when Safari comes to the foreground — that's the
/// device-only unknown de-risked in session 1.9.
///
/// - Parameters:
///   - baseURL: The Teleport web proxy base URL (e.g. "https://teleport.pcad.it").
///   - req: The HeadlessLoginReq body.
/// - Returns: The decoded HeadlessLoginResponse (cert + host_signers).
/// - Throws: `HeadlessError.http` on non-200, `HeadlessError.decode` on
///   bad JSON, or the underlying URLSession error (including timeout).
enum HeadlessLogin {
    static func post(baseURL: URL, req: HeadlessLoginReq) async throws -> HeadlessLoginResponse {
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("webapi/headless/login"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The POST blocks up to 180s. Set a generous timeout on the URLSession
        // so iOS doesn't kill it before the server-side timeout fires.
        // (URLSessionConfiguration.timeoutIntervalForRequest defaults to 60s,
        // which is too short for a 180s-blocking POST.)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 200  // 200s > 180s server timeout
        config.timeoutIntervalForResource = 200
        urlReq.httpBody = try JSONEncoder().encode(req)

        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlReq)
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

// MARK: - Errors

enum HeadlessError: LocalizedError {
    case transport(String)
    case http(status: Int, body: String)
    case decode(String)
    case noCert
    case missingField(String)

    var errorDescription: String? {
        switch self {
        case .transport(let m):      return "transport: \(m)"
        case .http(let s, let b):     return "HTTP \(s): \(b)"
        case .decode(let m):         return "decode: \(m)"
        case .noCert:                return "no cert in response"
        case .missingField(let f):   return "missing field: \(f)"
        }
    }
}
