// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportHTTPClient.swift
//  VVTerm
//
//  The HTTP client for the Teleport web API. Extracted from the spike's
//  HeadlessLogin.swift + FullFlowRunner.swift HTTP calls.
//
//  Four methods cover the three phases:
//    - ping() — health check (GET /webapi/ping)
//    - headlessLogin(id:sshPubKey:tlsPubKey:ttl:) — Phase 1 blocking POST
//      (/webapi/headless/login, unauthenticated, blocks up to 180s)
//    - loginBegin() — Phase 3 step 1 (POST /webapi/mfa/login/begin, passwordless)
//    - loginFinish(assertion:sshPubKey:ttl:) — Phase 3 step 2
//      (POST /webapi/mfa/login/finish)
//
//  Wire-format gotchas preserved from the spike (see 2.2 prompt Phase 1/3):
//    - headlessLogin: ssh_pub_key + tls_pub_key are Go []byte → base64-encoded
//      strings. The raw bytes are the UTF-8 bytes of the authorized_keys
//      string (with trailing newline for ssh_pub_key, matching
//      ssh.MarshalAuthorizedKey output).
//    - headlessLogin: the POST blocks up to 180s; the URLSession timeout
//      is set to 200s so iOS doesn't kill it before the server-side timeout.
//    - headlessLogin: the response's tls_cert + host_signers.tls_certs +
//      host_signers.checking_keys are base64(PEM), not PEM — Go's json.Marshal
//      of []byte base64-encodes. The client decodes them to PEM strings.
//    - loginBegin: the response's webauthn_challenge.challenge is base64url-
//      encoded (Go protocol.URLEncodedBase64). Decoded via Data(base64URLEncoded:).
//    - loginFinish: the request's webauthn_challenge_response is a
//      CredentialAssertionResponse (the SEPWebAuthn library type), and
//      ssh_pub_key is a Go []byte → base64-encoded. The ttl is in nanoseconds.
//

import Foundation
import os.log

/// The HTTP client for the Teleport web API.
///
/// Plain type (no @Published / ObservableObject) — the Application layer
/// coordinators wrap this. All methods are async and throw on non-2xx.
struct TeleportHTTPClient {

    /// The Teleport web proxy base URL (e.g. "https://teleport.pcad.it").
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    // MARK: - Ping (health check)

    /// GET /webapi/ping — health check. Returns true if the server responds 200.
    func ping() async throws -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("webapi/ping"))
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HeadlessError.transport("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw HeadlessError.http(status: http.statusCode, body: body)
        }
        return true
    }

    // MARK: - Phase 1: headless login (blocking POST)

    /// The result of a successful headless login: the SSH cert + TLS cert +
    /// cluster CA certs needed for Phase 2's gRPC dial.
    struct HeadlessLoginResult {
        /// The PEM-encoded SSH certificate (base64-decoded from the response's
        /// `cert` field, which is base64(PEM)).
        let sshCertPEM: String
        /// The PEM-encoded TLS certificate (base64-decoded from `tls_cert`).
        let tlsCertPEM: String
        /// The cluster name (from host_signers[0].domain_name).
        let clusterName: String
        /// The cluster's TLS CA certs (base64-decoded from
        /// host_signers[0].tls_certs), for Phase 2's auth-service ALPN dial.
        let clusterCAPEMs: [String]
        /// The cluster's checking keys (base64-decoded from
        /// host_signers[0].checking_keys), for SSH host-key verification.
        let checkingKeys: [String]
    }

    /// POST /webapi/headless/login — the blocking Phase 1 bootstrap call.
    ///
    /// This call blocks until the headless request is approved (or the 180s
    /// server timeout fires). On iOS, the URLSession task must survive the
    /// app backgrounding when Safari comes to the foreground.
    ///
    /// - Parameters:
    ///   - id: the headless authentication ID (UUID v5 derived from the SSH pub key)
    ///   - user: the Teleport username
    ///   - sshPubKey: the SSH public key in authorized_keys format (WITHOUT
    ///     trailing newline — the client adds it to match
    ///     ssh.MarshalAuthorizedKey output). Base64-encoded for the POST body.
    ///   - tlsPubKey: the TLS public key PEM (base64-encoded for the POST body),
    ///     or nil to omit (Teleport requires ssh_pub_key OR tls_pub_key).
    ///   - ttl: the requested cert TTL in nanoseconds (e.g. 3_600_000_000_000 for 1h)
    /// - Returns: the decoded HeadlessLoginResult (certs + cluster CAs).
    func headlessLogin(
        id: String,
        user: String,
        sshPubKey: String,
        tlsPubKey: String?,
        ttl: Int64
    ) async throws -> HeadlessLoginResult {
        // The POST body's ssh_pub_key is base64-encoded (Go's []byte
        // marshals as base64). The raw bytes are the authorized_keys string
        // WITH a trailing newline (ssh.MarshalAuthorizedKey output).
        let sshPubKeyBytes = Data((sshPubKey + "\n").utf8)
        let sshPubKeyB64 = sshPubKeyBytes.base64EncodedString()
        let req = HeadlessLoginReq(
            user: user,
            headlessAuthenticationID: id,
            sshPubKey: sshPubKeyB64,
            tlsPubKey: tlsPubKey,
            ttl: ttl,
            compatibility: ""
        )
        let resp = try await HeadlessLogin.post(baseURL: baseURL, req: req)

        guard let cert = resp.cert, !cert.isEmpty else {
            throw HeadlessError.noCert
        }

        // The TLS cert (resp.tlsCert) is a Go []byte marshaled as base64,
        // so it's base64(PEM). Decode to the actual PEM string for Phase 2.
        // (Same for resp.cert — it's base64(PEM) too.)
        let tlsCertPEM: String
        if let tlsB64 = resp.tlsCert,
           let tlsPEMData = Data(base64Encoded: tlsB64),
           let tlsPEM = String(data: tlsPEMData, encoding: .utf8) {
            tlsCertPEM = tlsPEM
        } else {
            tlsCertPEM = ""
        }

        // Capture the cluster name + TLS CA certs from host_signers for
        // Phase 2's auth-service ALPN dial (cluster CA verification).
        var clusterName = ""
        var clusterCAPEMs: [String] = []
        var checkingKeys: [String] = []
        if let hostSigners = resp.hostSigners, let first = hostSigners.first {
            clusterName = first.clusterName
            // tls_certs are Go []byte → base64(PEM). Decode to PEM strings.
            clusterCAPEMs = (first.tlsCerts ?? []).compactMap { b64 in
                guard let der = Data(base64Encoded: b64),
                      let pem = String(data: der, encoding: .utf8) else { return nil }
                return pem
            }
            // checking_keys are Go []byte → base64(PEM). Decode to PEM strings.
            checkingKeys = first.checkingKeys.compactMap { b64 in
                guard let der = Data(base64Encoded: b64),
                      let pem = String(data: der, encoding: .utf8) else { return nil }
                return pem
            }
        }

        return HeadlessLoginResult(
            sshCertPEM: cert,
            tlsCertPEM: tlsCertPEM,
            clusterName: clusterName,
            clusterCAPEMs: clusterCAPEMs,
            checkingKeys: checkingKeys
        )
    }

    // MARK: - Phase 3: passwordless login

    /// The result of login/begin: the WebAuthn challenge + rpID to sign.
    struct LoginBeginResult {
        /// The WebAuthn challenge (decoded from base64url).
        let challenge: Data
        /// The WebAuthn RP ID (defaults to the host if absent).
        let rpID: String
    }

    /// POST /webapi/mfa/login/begin — Phase 3 step 1. Starts a passwordless
    /// login. Returns the WebAuthn challenge to sign with the SEP key.
    func loginBegin() async throws -> LoginBeginResult {
        let beginBody = try JSONSerialization.data(withJSONObject: ["passwordless": true])
        let (data, status) = try await httpPOST(path: "/webapi/mfa/login/begin", body: beginBody)
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw GRPCError.http2("login/begin HTTP \(status): \(body)")
        }
        guard let resp = try? JSONDecoder().decode(LoginBeginResponse.self, from: data),
              let assertion = resp.webauthnChallenge else {
            throw GRPCError.decode("login/begin response")
        }
        let challenge = Data(base64URLEncoded: assertion.publicKey.challenge)
            ?? Data(assertion.publicKey.challenge.utf8)
        let rpID = assertion.publicKey.rpID ?? baseURL.host ?? ""
        return LoginBeginResult(challenge: challenge, rpID: rpID)
    }

    /// POST /webapi/mfa/login/finish — Phase 3 step 2. Submits the signed
    /// WebAuthn assertion + SSH pub key, returns the issued SSH cert (PEM).
    ///
    /// - Parameters:
    ///   - assertion: the WebAuthn assertion response (signed by the SEP key)
    ///   - sshPubKey: the SSH public key in authorized_keys format (the raw
    ///     UTF-8 bytes are sent — Go's []byte marshals as base64, but
    ///     JSONEncoder encodes Data as base64 automatically)
    ///   - ttl: the requested cert TTL in nanoseconds
    /// - Returns: the PEM-encoded SSH certificate.
    func loginFinish(
        assertion: CredentialAssertionResponse,
        sshPubKey: String,
        ttl: Int64
    ) async throws -> String {
        let finishReq = LoginFinishReq(
            webauthnChallengeResponse: assertion,
            sshPubKey: Data(sshPubKey.utf8),
            ttl: ttl
        )
        let finishBody = try JSONEncoder().encode(finishReq)
        let (data, status) = try await httpPOST(path: "/webapi/mfa/login/finish", body: finishBody)
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw GRPCError.http2("login/finish HTTP \(status): \(body)")
        }
        guard let resp = try? JSONDecoder().decode(LoginFinishResponse.self, from: data),
              let cert = resp.cert, !cert.isEmpty else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw GRPCError.decode("login/finish: no cert (body=\(body.prefix(256)))")
        }
        return cert
    }

    // MARK: - HTTP helper

    /// POST to a path under baseURL with a JSON body. Returns (data, status).
    private func httpPOST(path: String, body: Data) async throws -> (Data, Int) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        return (data, (response as! HTTPURLResponse).statusCode)
    }
}
