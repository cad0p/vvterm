// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  GRPCTransport.swift
//  iotest
//
//  Session 1.10 — the TLS+ALPN+mTLS transport for the gRPC client.
//
//  Uses NIOTS (Network.framework via swift-nio-transport-services) for the
//  system TLS stack, which gives us:
//    - ALPN negotiation (sec_protocol_options_add_tls_application_protocol)
//    - client certificate (sec_protocol_options_set_local_identity)
//    - system trust store for server verification (default)
//
//  Apple-only: requires the Network + Security frameworks (iOS/macOS).
//  The platform-independent gRPC logic (HTTP/2 framing, message encode/decode,
//  unary handler) is in GRPCClient.swift.
//

#if canImport(Network)
import NIOCore
import NIOTransportServices
import NIOHTTP2
import SwiftProtobuf
import Foundation
import Network
import Security

// MARK: - TLS options (ALPN + client cert)

enum GRPCTLSOptions {

    /// The Teleport ALPN protocol string for gRPC mTLS.
    /// Constant name is `ProtocolProxyGRPCSecure` but its *value* is
    /// "teleport-proxy-grpc-mtls" (lib/srv/alpnproxy/common/protocols.go:109).
    static let teleportProxyGRPCSecure = "teleport-proxy-grpc-mtls"

    /// Build NWProtocolTLS.Options for the Teleport gRPC mTLS endpoint.
    ///
    /// - ALPN: ["teleport-proxy-grpc-mtls", "h2"] — matches Teleport's
    ///   `ProtocolProxyGRPCSecure` (the gRPC mTLS ALPN token) + the standard
    ///   HTTP/2 token as a fallback. Teleport's DialALPN uses
    ///   `ProtocolToStringsWithPing(ProtocolProxyGRPCSecure)` which is
    ///   ["teleport-proxy-grpc-mtls"] for the non-ping path
    ///   (lib/client/api.go:5526-5553).
    /// - Client cert: the Phase 1 TLS cert (PEM) + private key (raw 32-byte
    ///   EC P-256 scalar).
    /// - Server verification: default (system trust store). Teleport's web
    ///   proxy cert is signed by a public CA, so the system validates it.
    static func make(clientCertPEM: String,
                     privateKeyRaw: Data,
                     serverName: String) throws -> NWProtocolTLS.Options {
        let tlsOpts = NWProtocolTLS.Options()
        let secOpts = tlsOpts.securityProtocolOptions

        // ALPN.
        for proto in [teleportProxyGRPCSecure, "h2"] {
            proto.withCString { cStr in
                sec_protocol_options_add_tls_application_protocol(secOpts, cStr)
            }
        }
        // SNI.
        serverName.withCString { cStr in
            sec_protocol_options_set_tls_server_name(secOpts, cStr)
        }
        // Client cert (mTLS).
        let secIdentity = try buildSecIdentity(certPEM: clientCertPEM, privateKeyRaw: privateKeyRaw)
        sec_protocol_options_set_local_identity(secOpts, secIdentity)
        return tlsOpts
    }

    /// Build a sec_identity_t from a PEM-encoded cert + the raw private key.
    ///
    /// Network.framework's `sec_protocol_options_set_local_identity` wants a
    /// `sec_identity_t`, which wraps a `SecIdentity` (cert + key pair in a
    /// keychain). We:
    ///   1. Parse the cert from PEM → SecCertificate.
    ///   2. Create the SecKey from the raw 32-byte EC P-256 scalar via
    ///      SecKeyCreateWithData (kSecAttrKeyTypeECSECPrimeRandom expects
    ///      the raw scalar for private keys, NOT PKCS#8 DER).
    ///   3. Add both to the keychain with a unique label.
    ///   4. SecItemCopyMatching to get the SecIdentity.
    ///   5. Wrap in sec_identity_t.
    private static func buildSecIdentity(certPEM: String, privateKeyRaw: Data) throws -> sec_identity_t {
        // 1. Parse cert.
        let certDER = try pemToDER(pem: certPEM, label: "CERTIFICATE")
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw GRPCError.tls("failed to create SecCertificate from PEM")
        }

        // 2. Create the private key from the raw 32-byte scalar.
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var keyError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(privateKeyRaw as CFData, keyAttrs as CFDictionary, &keyError) else {
            let msg = (keyError?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw GRPCError.tls("SecKeyCreateWithData failed: \(msg)")
        }

        // 3. Add cert + key to keychain with a unique label.
        let label = "vvterm-1.10-grpc-\(UUID().uuidString)"

        let certAdd: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: label,
        ]
        let certStatus = SecItemAdd(certAdd as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw GRPCError.tls("SecItemAdd cert: \(certStatus)")
        }
        let keyAdd: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: secKey,
            kSecAttrLabel as String: label,
            kSecAttrIsPermanent as String: true,
        ]
        let keyStatus = SecItemAdd(keyAdd as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw GRPCError.tls("SecItemAdd key: \(keyStatus)")
        }

        // 4. Copy the matching SecIdentity.
        let idQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var idRef: CFTypeRef?
        let idStatus = SecItemCopyMatching(idQuery as CFDictionary, &idRef)
        guard idStatus == errSecSuccess, let identity = idRef else {
            throw GRPCError.tls("SecItemCopyMatching identity: \(idStatus)")
        }
        // 5. Wrap in sec_identity_t.
        guard let secIdentity = sec_identity_create(identity as! SecIdentity) else {
            throw GRPCError.tls("sec_identity_create failed")
        }
        return secIdentity
    }

    /// Strip PEM headers and base64-decode the DER body.
    private static func pemToDER(pem: String, label: String) throws -> Data {
        let lines = pem.split(separator: "\n", omittingEmptySubsequences: true)
        let b64 = lines.filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: b64) else {
            throw GRPCError.tls("failed to base64-decode PEM (\(label))")
        }
        return data
    }
}

// MARK: - gRPC connection (Apple: NIOTS-backed)

/// An established HTTP/2 connection to the Teleport proxy gRPC mTLS endpoint.
///
/// Created with a Phase 1 TLS cert. Use `unary(...)` to make gRPC calls.
final class TeleportGRPCConnection: @unchecked Sendable {
    private let channel: Channel
    private let multiplexer: NIOHTTP2Handler.StreamMultiplexer
    private let authority: String
    private let group: NIOTSEventLoopGroup

    private init(channel: Channel,
                 multiplexer: NIOHTTP2Handler.StreamMultiplexer,
                 authority: String,
                 group: NIOTSEventLoopGroup) {
        self.channel = channel
        self.multiplexer = multiplexer
        self.authority = authority
        self.group = group
    }

    /// Dial the Teleport proxy gRPC endpoint with a client cert.
    ///
    /// - Parameters:
    ///   - host: the proxy hostname (e.g. "teleport.pcad.it")
    ///   - port: the proxy port (443)
    ///   - clientCertPEM: PEM TLS cert (Phase 1 tls_cert)
    ///   - privateKeyRaw: raw 32-byte EC P-256 scalar for the private key
    /// - Returns: a connected TeleportGRPCConnection.
    static func connect(host: String,
                        port: Int = 443,
                        clientCertPEM: String,
                        privateKeyRaw: Data) async throws -> TeleportGRPCConnection {
        let tlsOpts = try GRPCTLSOptions.make(
            clientCertPEM: clientCertPEM,
            privateKeyRaw: privateKeyRaw,
            serverName: host
        )

        let group = NIOTSEventLoopGroup()
        var capturedMultiplexer: NIOHTTP2Handler.StreamMultiplexer?
        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .tlsOptions(tlsOpts)
            .channelInitializer { channel in
                channel.configureHTTP2Pipeline(
                    mode: .client,
                    connectionConfiguration: .init(),
                    streamConfiguration: .init()
                ) { streamChannel in
                    streamChannel.eventLoop.makeSucceededFuture(())
                }.map { multiplexer -> Void in
                    capturedMultiplexer = multiplexer
                }
            }

        let channel = try await bootstrap.connect(host: host, port: port).get()
        guard let multiplexer = capturedMultiplexer else {
            throw GRPCError.transport("HTTP/2 multiplexer not captured")
        }
        return TeleportGRPCConnection(channel: channel,
                                       multiplexer: multiplexer,
                                       authority: host,
                                       group: group)
    }

    /// Make a unary gRPC call.
    ///
    /// - Parameters:
    ///   - path: the gRPC method path, e.g. "/proto.AuthService/CreateRegisterChallenge"
    ///   - request: the protobuf request message
    ///   - responseType: the protobuf response message type
    /// - Returns: the decoded response.
    func unary<R: SwiftProtobuf.Message, S: SwiftProtobuf.Message>(
        path: String, request: R, responseType: S.Type
    ) async throws -> S {
        try await grpcUnaryCallTyped(
            multiplexer: multiplexer,
            path: path,
            authority: authority,
            request: request,
            responseType: responseType
        )
    }

    func close() async throws {
        try await channel.close().get()
        try await group.shutdownGracefully()
    }
}

#endif // canImport(Network)
