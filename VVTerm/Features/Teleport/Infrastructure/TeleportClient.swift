//
//  TeleportClient.swift
//  VVTerm
//
//  HTTP client for Teleport passwordless login (v18.9.1 wire shapes).
//  Three calls: Ping (discovery), mfa/login/begin (challenge), mfa/login/finish (cert issuance).
//  No auth on any call — the WebAuthn assertion IS the authentication.
//
//  Reference: Goldmine open-source/github/vvterm/2026-07-12-strategy-b-teleport-client-spec.md §2
//

import Foundation
import CryptoKit

enum TeleportClientError: LocalizedError {
    case invalidProxyHost(String)
    case pingFailed(String)
    case passwordlessDisabled
    case beginFailed(String)
    case invalidChallenge(String)
    case finishFailed(String)
    case noHostSigners
    case unexpectedHTTP(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidProxyHost(let host):
            return "Invalid Teleport proxy host: \(host)"
        case .pingFailed(let detail):
            return "Teleport Ping failed: \(detail)"
        case .passwordlessDisabled:
            return "Teleport cluster does not allow passwordless login."
        case .beginFailed(let detail):
            return "Teleport login begin failed: \(detail)"
        case .invalidChallenge(let detail):
            return "Invalid WebAuthn challenge from server: \(detail)"
        case .finishFailed(let detail):
            return "Teleport login finish failed: \(detail)"
        case .noHostSigners:
            return "Teleport login response contained no host signers (Host CA bundle)."
        case .unexpectedHTTP(let code, let body):
            return "Unexpected HTTP \(code) from Teleport: \(body)"
        }
    }
}

/// HTTP client for the Teleport passwordless login flow.
final class TeleportClient {

    /// Configuration for the login flow.
    struct Configuration {
        /// Proxy host (e.g. "teleport.pcad.it"). Must match the WebAuthn RP ID.
        let proxyHost: String
        /// Whether to trust the system CA store (true for production ACME certs).
        let validateTLS: Bool
        /// Optional request timeout (default 30s).
        var requestTimeout: TimeInterval = 30

        var baseURL: URL {
            var components = URLComponents()
            components.scheme = "https"
            components.host = proxyHost
            return components.url!
        }
    }

    let configuration: Configuration
    private let session: URLSession

    init(configuration: Configuration) {
        self.configuration = configuration
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfig.timeoutIntervalForResource = configuration.requestTimeout * 2
        // Note: validateTLS=false (dev only) would require a custom URLSession delegate
        // that trusts the server. pcad.it uses ACME certs, so the default system CA
        // validation (validateTLS=true) is correct for production and is the only
        // path exercised here.
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Endpoint 0: Ping

    /// GET /webapi/ping — discover cluster auth settings.
    func ping() async throws -> TeleportPingResponse {
        let url = configuration.baseURL.appendingPathComponent("webapi/ping")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TeleportClientError.pingFailed("no HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TeleportClientError.unexpectedHTTP(http.statusCode, body)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(TeleportPingResponse.self, from: data)
        } catch {
            throw TeleportClientError.pingFailed("decode error: \(error)")
        }
    }

    // MARK: - Endpoint 1: mfa/login/begin

    /// POST /webapi/mfa/login/begin with {"passwordless": true}.
    /// Returns the W3C PublicKeyCredentialRequestOptions for the assertion ceremony.
    func beginPasswordlessLogin() async throws -> TeleportMFAAuthenticateChallenge {
        let url = configuration.baseURL.appendingPathComponent("webapi/mfa/login/begin")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"passwordless":true}"#.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TeleportClientError.beginFailed("no HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TeleportClientError.unexpectedHTTP(http.statusCode, body)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(TeleportMFAAuthenticateChallenge.self, from: data)
        } catch {
            throw TeleportClientError.beginFailed("decode error: \(error)")
        }
    }

    // MARK: - Endpoint 2: mfa/login/finish

    /// POST /webapi/mfa/login/finish with the assertion + client keypairs → CLILoginResponse.
    func finishPasswordlessLogin(
        assertion: WebAuthnAssertionResponse,
        sshPublicKey: String,
        tlsPublicKey: String,
        ttlNanoseconds: Int64
    ) async throws -> TeleportCLILoginResponse {
        let url = configuration.baseURL.appendingPathComponent("webapi/mfa/login/finish")

        // Build the request body.
        // client.AuthenticateSSHUserRequest (lib/client/weblogin.go:263):
        //   user, password (empty for passwordless), webauthn_challenge_response,
        //   totp_code (empty), ssh_pub_key, tls_pub_key, ttl, compatibility, scope,
        //   route_to_cluster, kubernetes_cluster (all empty for V1).
        let requestBody: [String: Any] = [
            "user": "",
            "password": "",
            "webauthn_challenge_response": [
                "rawId": assertion.rawId,
                "response": [
                    "authenticatorData": assertion.response.authenticatorData,
                    "clientDataJSON": assertion.response.clientDataJSON,
                    "signature": assertion.response.signature,
                    "userHandle": assertion.response.userHandle,
                ],
                "type": assertion.type,
            ],
            "ssh_pub_key": sshPublicKey,
            "tls_pub_key": tlsPublicKey,
            "ttl": ttlNanoseconds,
            "compatibility": "",
            "scope": "",
            "route_to_cluster": "",
            "kubernetes_cluster": "",
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TeleportClientError.finishFailed("no HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TeleportClientError.unexpectedHTTP(http.statusCode, body)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(TeleportCLILoginResponse.self, from: data)
        } catch {
            throw TeleportClientError.finishFailed("decode error: \(error)")
        }
    }
}
