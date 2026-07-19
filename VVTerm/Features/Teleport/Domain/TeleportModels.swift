//
//  TeleportModels.swift
//  VVTerm
//
//  Teleport passwordless login domain models.
//  Wire shapes verified against Teleport v18.9.1 (lib/client/weblogin.go,
//  lib/auth/authclient/clt.go, api/client/webclient/webclient.go).
//
//  See: Goldmine open-source/github/vvterm/2026-07-12-strategy-b-teleport-client-spec.md
//

import Foundation
import CryptoKit

// MARK: - Ping response (webclient.PingResponse, partial)

/// Subset of `webclient.PingResponse` relevant to passwordless login.
struct TeleportPingResponse: Decodable {
    struct Auth: Decodable {
        struct WebAuthn: Decodable {
            let rpId: String
        }
        let allowPasswordless: Bool
        let webauthn: WebAuthn
        let defaultSessionTTL: String
        let signatureAlgorithmSuite: String
        let privateKeyPolicy: String?

        enum CodingKeys: String, CodingKey {
            case allowPasswordless = "allow_passwordless"
            case webauthn
            case defaultSessionTTL = "default_session_ttl"
            case signatureAlgorithmSuite = "signature_algorithm_suite"
            case privateKeyPolicy = "private_key_policy"
        }
    }

    struct Proxy: Decodable {
        let tlsRoutingEnabled: Bool
        enum CodingKeys: String, CodingKey {
            case tlsRoutingEnabled = "tls_routing_enabled"
        }
    }

    let auth: Auth
    let proxy: Proxy
    let clusterName: String

    enum CodingKeys: String, CodingKey {
        case auth, proxy
        case clusterName = "cluster_name"
    }

    /// Cert TTL in nanoseconds (time.Duration JSON-marshals as an integer).
    /// `default_session_ttl` is a Go duration string ("12h0m0s"); parse it to nanoseconds.
    var defaultSessionTTLNanoseconds: Int64 {
        TeleportDuration.nanoseconds(from: auth.defaultSessionTTL) ?? 12 * 3600 * 1_000_000_000
    }
}

// MARK: - MFA begin challenge (client.MFAAuthenticateChallenge, partial)

struct TeleportMFAAuthenticateChallenge: Decodable {
    struct WebAuthnChallenge: Decodable {
        /// W3C PublicKeyCredentialRequestOptions, base64url-encoded fields.
        let publicKey: PublicKeyAssertionOptions
    }
    let webauthnChallenge: WebAuthnChallenge

    enum CodingKeys: String, CodingKey {
        case webauthnChallenge = "webauthn_challenge"
    }
}

/// W3C PublicKeyCredentialRequestOptions as returned by Teleport's begin endpoint.
/// `challenge` is base64url; `allowCredentials` is empty for passwordless (discoverable).
struct PublicKeyAssertionOptions: Decodable {
    let challenge: String
    let rpId: String
    let allowCredentials: [JSONAny]?
    let userVerification: String
    let timeout: Int?

    enum CodingKeys: String, CodingKey {
        case challenge, rpId = "rpId"
        case allowCredentials = "allowCredentials"
        case userVerification
        case timeout
    }
}

// MARK: - CLILoginResponse (authclient.CLILoginResponse, partial)

struct TeleportCLILoginResponse: Decodable {
    struct HostSigner: Decodable {
        let domainName: String
        let checkingKeys: [String]
        let tlsCerts: [String]?

        enum CodingKeys: String, CodingKey {
            case domainName = "domain_name"
            case checkingKeys = "checking_keys"
            case tlsCerts = "tls_certs"
        }
    }

    let username: String
    /// PEM-encoded OpenSSH certificate (ssh-ed25519-cert-v01@openssh.com).
    let cert: String
    /// PEM-encoded TLS client certificate (ECDSA-P256). Unused in V1 (no gRPC).
    let tlsCert: String
    let hostSigners: [HostSigner]

    enum CodingKeys: String, CodingKey {
        case username, cert
        case tlsCert = "tls_cert"
        case hostSigners = "host_signers"
    }
}

// MARK: - KeyRing

/// The output of a successful Teleport passwordless login: the SSH cert + keypairs
/// + Host CA bundle needed to connect to a cluster node.
struct TeleportKeyRing: Sendable {
    let username: String
    let clusterName: String
    let proxyHost: String

    /// ed25519 private key in OpenSSH PEM format (for libssh2 cert auth).
    let sshPrivateKeyPEM: Data
    /// ed25519 public key in OpenSSH authorized_keys format (sent to server in /finish).
    let sshPublicKeyAuthorized: String
    /// PEM-encoded OpenSSH certificate signed by the cluster User SSH CA.
    let sshCertificatePEM: String

    /// ECDSA-P256 private key (PEM PKCS#8). Unused in V1 (no gRPC); stored for V2.
    let tlsPrivateKeyPEM: Data
    /// ECDSA-P256 public key (PEM PKIX).
    let tlsPublicKeyPEM: String
    /// PEM-encoded TLS client certificate. Unused in V1; stored for V2.
    let tlsCertificatePEM: String

    /// Host CA bundle: SSH CA public keys (authorized_keys format) for host-key verification.
    let hostCheckingKeys: [String]
    /// Host CA TLS certs. Unused in V1; stored for V2.
    let hostTLSCerts: [String]

    let expiry: Date

    var isValid: Bool { Date() < expiry }
}

// MARK: - Signature algorithm suite

/// `auth.signature_algorithm_suite` from Ping. Determines the key types to generate.
enum TeleportSignatureSuite: String, Decodable, Sendable {
    case legacy       // RSA-2048 (SSH) + RSA-2048 (TLS)
    case balancedV1   // ed25519 (SSH) + ECDSA-P256 (TLS)  — pcad.it default
    case fipsV1       // ECDSA-P256 (SSH) + ECDSA-P256 (TLS)

    static func from(_ raw: String) -> TeleportSignatureSuite {
        Self(rawValue: raw) ?? .balancedV1
    }
}

// MARK: - Go duration parsing (default_session_ttl is "12h0m0s")

enum TeleportDuration {
    /// Parse a Go time.Duration string ("12h0m0s", "1h30m", "30m", "45s") to nanoseconds.
    static func nanoseconds(from string: String) -> Int64? {
        var total: Int64 = 0
        var num = ""
        for ch in string {
            if ch.isNumber {
                num.append(ch)
            } else {
                guard let value = Int64(num), !num.isEmpty else {
                    if ch == "µ" || ch == "n" || ch == "m" || ch == "h" || ch == "s" {
                        num = ""
                        continue
                    }
                    continue
                }
                switch ch {
                case "h": total += value * 3_600_000_000_000
                case "m": total += value * 60_000_000_000
                case "s": total += value * 1_000_000_000
                default: break
                }
                num = ""
            }
        }
        return total > 0 ? total : nil
    }
}

// MARK: - JSONAny (decode-any for ignored fields like allowCredentials)

/// A type-erased JSON value, for fields we don't need to model (e.g. empty `allowCredentials`).
struct JSONAny: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(Int.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
        if (try? container.decode([JSONAny].self)) != nil { return }
        if (try? container.decode([String: JSONAny].self)) != nil { return }
    }
}
