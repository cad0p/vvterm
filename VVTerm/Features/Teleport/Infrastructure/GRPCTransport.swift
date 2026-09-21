// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  GRPCTransport.swift
//  VVTerm
//
//  The TLS+ALPN+mTLS transport for the gRPC client.
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
import os.log

// MARK: - TLS options (ALPN + client cert)

/// The ephemeral per-connection mTLS identity: the `sec_identity_t` plus the
/// keychain label of the cert/key items it was built from.
///
/// Per-connect identities must not accumulate in the keychain: the connection
/// deletes its items in `close()` and on every failure path.
struct GRPCClientIdentity {
    let identity: sec_identity_t
    let label: String

    /// A unique keychain label for one connection's cert + key.
    static func makeLabel() -> String {
        "vvterm-grpc-\(UUID().uuidString)"
    }

    func deleteKeychainItems() {
        Self.deleteKeychainItems(label: label)
    }

    /// Delete the cert + key items with the given label. Safe to call when
    /// the items are absent (returns `errSecItemNotFound`).
    static func deleteKeychainItems(label: String) {
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: label,
        ] as CFDictionary)
        GRPCTransportLog.logger.info("grpc_identity_deleted label=\(label, privacy: .public)")
    }
}

enum GRPCTLSOptions {

    /// Build NWProtocolTLS.Options for dialing the Teleport AUTH service via
    /// the ALPN SNI auth route.
    ///
    /// The auth service (AuthService/CreateRegisterChallenge etc.) is NOT on
    /// the `teleport-proxy-grpc-mtls` ALPN listener (that hosts only the
    /// Kubernetes service). It's reached via the ALPN SNI auth protocol:
    ///   - ALPN: "teleport-auth@<hex(clusterName)>.teleport.cluster.local"
    ///   - SNI: "<hex(clusterName)>.teleport.cluster.local"
    ///   - Client cert: the Phase 1 TLS cert (mTLS)
    ///   - Server verification: the cluster Host CA certs
    ///
    /// Returns the options AND the ephemeral identity handle: the per-connect
    /// certificate/key are removed from the keychain when the connection
    /// closes (see `TeleportGRPCConnection.close`).
    static func make(clientCertPEM: String,
                     privateKey: SecKey,
                     clusterName: String,
                     clusterCAPEMs: [String]) throws -> (options: NWProtocolTLS.Options, identity: GRPCClientIdentity) {
        let tlsOpts = NWProtocolTLS.Options()
        let secOpts = tlsOpts.securityProtocolOptions

        // ALPN: teleport-auth@<hex(cluster)>.teleport.cluster.local
        let encodedCluster = encodedClusterName(clusterName)
        let alpnProto = "teleport-auth@\(encodedCluster)"
        alpnProto.withCString { cStr in
            sec_protocol_options_add_tls_application_protocol(secOpts, cStr)
        }
        // Also offer h2 as a fallback (the auth listener serves h2 too).
        "h2".withCString { cStr in
            sec_protocol_options_add_tls_application_protocol(secOpts, cStr)
        }
        // SNI: <hex(cluster)>.teleport.cluster.local
        encodedCluster.withCString { cStr in
            sec_protocol_options_set_tls_server_name(secOpts, cStr)
        }
        // Client cert (mTLS) — ephemeral identity, deleted on close.
        let identityHandle = try buildSecIdentity(certPEM: clientCertPEM, privateKey: privateKey)
        sec_protocol_options_set_local_identity(secOpts, identityHandle.identity)

        // Server verification: the cluster Host CA certs (from
        // host_signers.tls_certs) are the only trust anchors; the trust is
        // evaluated against explicit SSL policies for the encoded auth route
        // name + teleport.cluster.local, and accepted only when the
        // negotiated ALPN is the auth route.
        let certRefs = TeleportTLSTrust.anchors(fromPEMs: clusterCAPEMs)
        guard !certRefs.isEmpty else {
            throw GRPCError.tls(
                "no usable cluster CA trust anchors (input \(clusterCAPEMs.count) PEMs)"
            )
        }
        GRPCTransportLog.logger.info("tls_setup cluster=\(clusterName, privacy: .public) alpn=\(alpnProto, privacy: .public) ca_certs=\(certRefs.count)")
        sec_protocol_options_set_verify_block(
            secOpts,
            TeleportTLSTrust.makeVerifyBlock(
                anchors: certRefs,
                serverNames: TeleportTLSTrust.authServerNames(clusterName: clusterName),
                requiredALPN: alpnProto,
                logger: GRPCTransportLog.logger
            ),
            .global()
        )
        sec_protocol_options_set_challenge_block(secOpts, { _, complete in
            GRPCTransportLog.logger.info("tls_challenge server requested client cert — presenting identity")
            complete(identityHandle.identity)
        }, .global())
        return (tlsOpts, identityHandle)
    }

    /// Encode a cluster name the way Teleport does: hex(name) + ".teleport.cluster.local".
    /// See api/utils/cluster.go:EncodeClusterName.
    private static func encodedClusterName(_ name: String) -> String {
        TeleportTLSTrust.encodedClusterName(name)
    }

    /// Build a sec_identity_t from a PEM-encoded cert + a SecKey.
    ///
    /// Network.framework's `sec_protocol_options_set_local_identity` wants a
    /// `sec_identity_t`, which wraps a `SecIdentity` (cert + key pair in a
    /// keychain). We:
    ///   1. Parse the cert from PEM → SecCertificate.
    ///   2. Add cert + key to the keychain with a unique label.
    ///   3. SecItemCopyMatching to get the SecIdentity.
    ///   4. Wrap in sec_identity_t.
    ///
    /// The returned handle owns the keychain items: `TeleportGRPCConnection`
    /// calls `deleteKeychainItems()` on close and on every failure path.
    private static func buildSecIdentity(certPEM: String, privateKey: SecKey) throws -> GRPCClientIdentity {
        // 1. Parse cert.
        let certDER = try TeleportTLSTrust.pemToDER(pem: certPEM, label: "CERTIFICATE")
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw GRPCError.tls("failed to create SecCertificate from PEM")
        }

        // 2. Add cert + key to keychain with a unique label.
        let label = GRPCClientIdentity.makeLabel()

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
            kSecValueRef as String: privateKey,
            kSecAttrLabel as String: label,
            kSecAttrIsPermanent as String: true,
        ]
        let keyStatus = SecItemAdd(keyAdd as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            // Do not leak the cert item when the key insert fails.
            SecItemDelete([
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: label,
            ] as CFDictionary)
            throw GRPCError.tls("SecItemAdd key: \(keyStatus)")
        }

        // 3. Copy the matching SecIdentity.
        let idQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var idRef: CFTypeRef?
        let idStatus = SecItemCopyMatching(idQuery as CFDictionary, &idRef)
        guard idStatus == errSecSuccess, let identity = idRef else {
            GRPCClientIdentity.deleteKeychainItems(label: label)
            throw GRPCError.tls("SecItemCopyMatching identity: \(idStatus)")
        }

        // 4. Wrap in sec_identity_t.
        guard let secIdentity = sec_identity_create(identity as! SecIdentity) else {
            GRPCClientIdentity.deleteKeychainItems(label: label)
            throw GRPCError.tls("sec_identity_create failed")
        }
        return GRPCClientIdentity(identity: secIdentity, label: label)
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
    private let identity: GRPCClientIdentity

    private init(channel: Channel,
                 multiplexer: NIOHTTP2Handler.StreamMultiplexer,
                 authority: String,
                 group: NIOTSEventLoopGroup,
                 identity: GRPCClientIdentity) {
        self.channel = channel
        self.multiplexer = multiplexer
        self.authority = authority
        self.group = group
        self.identity = identity
    }

    /// Dial the Teleport proxy gRPC endpoint with a client cert.
    ///
    /// - Parameters:
    ///   - host: the proxy hostname (e.g. "teleport.pcad.it")
    ///   - port: the proxy port (443)
    ///   - clientCertPEM: PEM TLS cert (Phase 1 tls_cert)
    ///   - privateKey: SecKey for the private key
    /// - Returns: a connected TeleportGRPCConnection.
    static func connect(host: String,
                        port: Int = 443,
                        clientCertPEM: String,
                        privateKey: SecKey,
                        clusterName: String,
                        clusterCAPEMs: [String]) async throws -> TeleportGRPCConnection {
        let (tlsOpts, identity) = try GRPCTLSOptions.make(
            clientCertPEM: clientCertPEM,
            privateKey: privateKey,
            clusterName: clusterName,
            clusterCAPEMs: clusterCAPEMs
        )

        let group = NIOTSEventLoopGroup()
        var capturedMultiplexer: NIOHTTP2Handler.StreamMultiplexer?
        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .tlsOptions(tlsOpts)
            .channelInitializer { channel in
                // Add a state handler first so we can log the real TLS/NWError
                // (otherwise ChannelError error 0 is opaque).
                let stateHandler = GRPCConnectionStateHandler(host: host)
                return channel.pipeline.addHandler(stateHandler).flatMap {
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
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            // Dial failed: remove this connection's keychain identity.
            identity.deleteKeychainItems()
            try? await group.shutdownGracefully()
            throw error
        }
        guard let multiplexer = capturedMultiplexer else {
            identity.deleteKeychainItems()
            try? await group.shutdownGracefully()
            throw GRPCError.transport("HTTP/2 multiplexer not captured")
        }
        return TeleportGRPCConnection(channel: channel,
                                       multiplexer: multiplexer,
                                       authority: host,
                                       group: group,
                                       identity: identity)
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
        // Delete the per-connect keychain identity even if the graceful
        // channel shutdown fails.
        defer { identity.deleteKeychainItems() }
        try await channel.close().get()
        try await group.shutdownGracefully()
    }
}

// MARK: - Connection state handler (diagnostic)

/// Logs TLS handshake + connection errors with the real underlying NWError,
/// so Phase 2 failures aren't opaque 'ChannelError error 0'.
final class GRPCConnectionStateHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private let host: String

    init(host: String) {
        self.host = host
    }

    func channelActive(context: ChannelHandlerContext) {
        GRPCTransportLog.logger.info("conn_active channel active for \(self.host, privacy: .public)")
        context.fireChannelActive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        GRPCTransportLog.logger.error("conn_error \(error.localizedDescription, privacy: .public) [type: \(String(describing: type(of: error)), privacy: .public)]")
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        GRPCTransportLog.logger.info("conn_inactive channel closed for \(self.host, privacy: .public)")
        context.fireChannelInactive()
    }
}

// MARK: - Logging

/// Shared logger for the gRPC transport layer. Uses VVTerm's logging convention
/// (subsystem = bundle id, category = feature).
enum GRPCTransportLog {
    static let logger = Logger.forCategory("TeleportGRPC")
}

#endif // canImport(Network)
