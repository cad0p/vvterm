// SPDX-License-Identifier: MIT
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
// `nonisolated`: a value type with lock-protected static state and pure
// keychain helpers, called from the gRPC transport's nonisolated paths (and
// from `TeleportGRPCConnection.deleteKeychainIdentity`'s nonisolated deinit
// chain).
nonisolated struct GRPCClientIdentity {
    let identity: sec_identity_t
    let label: String

    /// The shared prefix for per-connect identity labels: used when creating
    /// labels and when sweeping leftovers at startup.
    static let labelPrefix = "vvterm-grpc-"

    private static let registryLock = NSLock()
    /// Labels whose cert/key items belong to an in-flight connection. The
    /// sweep must never delete one of these: a second client construction
    /// (SwiftUI evaluates `StateObject(wrappedValue:)` on every sheet init)
    /// can otherwise delete the first client's identity mid-handshake.
    private static var liveLabels: Set<String> = []
    private static var hasSweptStaleIdentities = false

    /// A unique keychain label for one connection's cert + key.
    ///
    /// The label embeds the creation time (`<prefix><unixMillis>-<uuid>`) so
    /// the startup sweep can age-gate leftovers from a crashed process: a
    /// second process must never delete another process's in-flight identity
    /// (macOS can run a debug and a release instance at once).
    static func makeLabel(now: Date = Date()) -> String {
        let millis = Int64((now.timeIntervalSince1970 * 1000).rounded())
        return "\(labelPrefix)\(millis)-\(UUID().uuidString)"
    }

    /// How old an unregistered identity label must be before the sweep may
    /// delete it. Per-connect identities live for the duration of one gRPC
    /// call; a label younger than this window may still belong to another
    /// live process, so the sweep skips it. Legacy labels without an
    /// embedded timestamp are treated as stale (they predate this scheme).
    static let staleIdentityAge: TimeInterval = 30 * 60

    /// The creation instant embedded in a label, or nil when the label has
    /// no timestamp (legacy) or is malformed.
    static func timestamp(inLabel label: String) -> Date? {
        guard label.hasPrefix(labelPrefix) else { return nil }
        let remainder = label.dropFirst(labelPrefix.count)
        guard let separator = remainder.firstIndex(of: "-"),
              let millis = Int64(remainder[remainder.startIndex..<separator]) else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    /// Claim a label before its items are written, so a concurrent sweep
    /// cannot delete them while the identity is being built.
    static func registerLiveLabel(_ label: String) {
        registryLock.lock()
        liveLabels.insert(label)
        registryLock.unlock()
    }

    static func unregisterLiveLabel(_ label: String) {
        registryLock.lock()
        liveLabels.remove(label)
        registryLock.unlock()
    }

    static func isLiveLabel(_ label: String) -> Bool {
        registryLock.lock()
        defer { registryLock.unlock() }
        return liveLabels.contains(label)
    }

    func deleteKeychainItems(logger: Logger) {
        Self.deleteKeychainItems(label: label, logger: logger)
    }

    /// Delete the cert + key items with the given label. Safe to call when
    /// the items are absent (returns `errSecItemNotFound`).
    static func deleteKeychainItems(label: String, logger: Logger) {
        unregisterLiveLabel(label)
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: label,
        ] as CFDictionary)
        logger.info("grpc_identity_deleted label=\(label, privacy: .public)")
    }

    /// Delete leftover cert/key items from a previous process that never
    /// reached `close()` / `disconnect()` (crash or force-quit).
    ///
    /// The sweep runs at most once per process, and only once every keychain
    /// class enumerated successfully: a transient keychain error (locked or
    /// entitlement-less host) must not silently skip the sweep forever.
    /// Labels registered as live are skipped, so a concurrent connection's
    /// identity is never deleted mid-handshake. Labels without an embedded
    /// timestamp (legacy) or older than `staleIdentityAge` are collected even
    /// when this process does not know them: they belong to a process that
    /// never reached `close()`.
    ///
    /// The Security framework does not honor `kSecAttrService` on
    /// key/certificate classes, so the query scopes by class and filters by
    /// the per-connect label prefix (the app's generic-password service
    /// scoping is not available here).
    ///
    /// - Returns: `true` when this call attempted the sweep.
    @discardableResult
    static func deleteStaleIdentities(logger: Logger) -> Bool {
        sweepStaleIdentities(force: false, logger: logger)
    }

    #if DEBUG
    /// Test-only variant that bypasses the once-per-process gate. Not
    /// compiled into release builds, so production cannot defeat the gate.
    @discardableResult
    static func deleteStaleIdentitiesForTesting(logger: Logger) -> Bool {
        sweepStaleIdentities(force: true, logger: logger)
    }

    /// Test seam: overrides the keychain enumeration for the next sweep.
    /// Returning nil simulates a transient keychain error.
    static var sweepEnumerationOverrideForTesting: ((String) -> [[String: Any]]?)?

    /// Test seam: clears the once-per-process gate so the retry behavior can
    /// be exercised deterministically.
    static func resetSweepGateForTesting() {
        registryLock.lock()
        hasSweptStaleIdentities = false
        registryLock.unlock()
    }
    #endif

    private static func sweepStaleIdentities(force: Bool, logger: Logger) -> Bool {
        registryLock.lock()
        guard force || !hasSweptStaleIdentities else {
            registryLock.unlock()
            return false
        }
        registryLock.unlock()

        var enumeratedEveryClass = true
        for className in [kSecClassCertificate as String, kSecClassKey as String] {
            guard let items = enumerateItems(ofClass: className) else {
                enumeratedEveryClass = false
                continue
            }
            for item in items {
                guard let label = item[kSecAttrLabel as String] as? String,
                      label.hasPrefix(labelPrefix),
                      !isLiveLabel(label) else { continue }
                // Age gate: a label younger than the window may belong to a
                // different live process, whose identities this process does
                // not know about. Legacy labels (no timestamp) are stale.
                if let created = timestamp(inLabel: label),
                   Date().timeIntervalSince(created) < staleIdentityAge {
                    continue
                }
                deleteKeychainItems(label: label, logger: logger)
            }
        }
        if enumeratedEveryClass {
            // Latch only after every class enumerated: a transient failure
            // leaves the gate open so a later call retries the sweep.
            registryLock.lock()
            hasSweptStaleIdentities = true
            registryLock.unlock()
        }
        return true
    }

    /// Enumerate all keychain items of one class for the sweep.
    ///
    /// - Returns: the items, or nil when the enumeration failed (a transient
    ///   keychain error). `errSecItemNotFound` is a successful empty result.
    private static func enumerateItems(ofClass className: String) -> [[String: Any]]? {
        #if DEBUG
        if let override = sweepEnumerationOverrideForTesting {
            return override(className)
        }
        #endif
        let query: [String: Any] = [
            kSecClass as String: className,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { return nil }
        return result as? [[String: Any]]
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
    ///
    /// The identity builder is injectable so the fail-closed ordering can be
    /// pinned: every input validation must happen BEFORE the builder runs.
    /// `buildSecIdentity` inserts the cert + key items into the keychain and
    /// only the returned handle can delete them, so this function must not
    /// throw after the identity has been built (nothing below the builder
    /// call throws).
    typealias IdentityBuilder = (String, SecKey, Logger) throws -> GRPCClientIdentity

    static func make(clientCertPEM: String,
                     privateKey: SecKey,
                     clusterName: String,
                     clusterCAPEMs: [String],
                     logger: Logger,
                     identityBuilder: IdentityBuilder = { try GRPCTLSOptions.buildSecIdentity(certPEM: $0, privateKey: $1, logger: $2) }) throws -> (options: NWProtocolTLS.Options, identity: GRPCClientIdentity) {
        let tlsOpts = NWProtocolTLS.Options()
        let secOpts = tlsOpts.securityProtocolOptions

        // ALPN: the auth route plus `h2`, mirroring tsh's
        // `configureTLS` (the route token is what the ALPN-SNI router
        // matches; the auth server then negotiates `h2` on the forwarded
        // TLS). Offering only the route token is rejected by the auth
        // server with `no_application_protocol` on strict-ALPN versions.
        let encodedCluster = encodedClusterName(clusterName)
        let alpnProto = "teleport-auth@\(encodedCluster)"
        alpnProto.withCString { cStr in
            sec_protocol_options_add_tls_application_protocol(secOpts, cStr)
        }
        "h2".withCString { cStr in
            sec_protocol_options_add_tls_application_protocol(secOpts, cStr)
        }
        // SNI: <hex(cluster)>.teleport.cluster.local
        encodedCluster.withCString { cStr in
            sec_protocol_options_set_tls_server_name(secOpts, cStr)
        }
        // Server verification anchors: validate them BEFORE the keychain is
        // touched. A throw here would otherwise bypass the returned identity
        // handle and leak its cert/key items.
        let certRefs = TeleportTLSTrust.anchors(fromPEMs: clusterCAPEMs)
        guard !certRefs.isEmpty else {
            throw GRPCError.tls(
                "no usable cluster CA trust anchors (input \(clusterCAPEMs.count) PEMs)"
            )
        }

        // Client cert (mTLS) — ephemeral identity, deleted on close. This is
        // the first keychain mutation; no code after it throws.
        let identityHandle = try identityBuilder(clientCertPEM, privateKey, logger)
        sec_protocol_options_set_local_identity(secOpts, identityHandle.identity)

        // The cluster Host CA certs (from host_signers.tls_certs) are the only
        // trust anchors; the trust is evaluated against explicit SSL policies
        // for the encoded auth route name + teleport.cluster.local, and
        // accepted only when the negotiated ALPN is the auth route or `h2`
        // (or absent — servers without a NextProtos list).
        logger.info("tls_setup cluster=\(clusterName, privacy: .public) alpn=\(alpnProto, privacy: .public) ca_certs=\(certRefs.count)")
        sec_protocol_options_set_verify_block(
            secOpts,
            TeleportTLSTrust.makeVerifyBlock(
                anchors: certRefs,
                serverNames: TeleportTLSTrust.authServerNames(clusterName: clusterName),
                allowedALPNs: [alpnProto, "h2"],
                logger: logger
            ),
            .global()
        )
        sec_protocol_options_set_challenge_block(secOpts, { _, complete in
            logger.info("tls_challenge server requested client cert — presenting identity")
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
    static func buildSecIdentity(certPEM: String, privateKey: SecKey, logger: Logger) throws -> GRPCClientIdentity {
        // 1. Parse cert.
        let certDER = try TeleportTLSTrust.pemToDER(pem: certPEM, label: "CERTIFICATE")
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw GRPCError.tls("failed to create SecCertificate from PEM")
        }

        // 2. Add cert + key to keychain with a unique label. The label is
        // registered live before the first write so a concurrent sweep
        // cannot delete the items while the identity is being built.
        let label = GRPCClientIdentity.makeLabel()
        GRPCClientIdentity.registerLiveLabel(label)

        let certAdd: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: label,
        ]
        let certStatus = SecItemAdd(certAdd as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            GRPCClientIdentity.unregisterLiveLabel(label)
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
            GRPCClientIdentity.deleteKeychainItems(label: label, logger: logger)
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
            GRPCClientIdentity.deleteKeychainItems(label: label, logger: logger)
            throw GRPCError.tls("SecItemCopyMatching identity: \(idStatus)")
        }

        // 4. Wrap in sec_identity_t.
        guard let secIdentity = sec_identity_create(identity as! SecIdentity) else {
            GRPCClientIdentity.deleteKeychainItems(label: label, logger: logger)
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
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    private let channel: Channel
    private let multiplexer: NIOHTTP2Handler.StreamMultiplexer
    private let authority: String
    private let group: NIOTSEventLoopGroup
    private let identity: GRPCClientIdentity
    private let logger: Logger

    private init(channel: Channel,
                 multiplexer: NIOHTTP2Handler.StreamMultiplexer,
                 authority: String,
                 group: NIOTSEventLoopGroup,
                 identity: GRPCClientIdentity,
                 logger: Logger) {
        self.channel = channel
        self.multiplexer = multiplexer
        self.authority = authority
        self.group = group
        self.identity = identity
        self.logger = logger
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
                        clusterCAPEMs: [String],
                        logger: Logger) async throws -> TeleportGRPCConnection {
        let (tlsOpts, identity) = try GRPCTLSOptions.make(
            clientCertPEM: clientCertPEM,
            privateKey: privateKey,
            clusterName: clusterName,
            clusterCAPEMs: clusterCAPEMs,
            logger: logger
        )

        let group = NIOTSEventLoopGroup()
        var capturedMultiplexer: NIOHTTP2Handler.StreamMultiplexer?
        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .tlsOptions(tlsOpts)
            .channelInitializer { channel in
                // Add a state handler first so we can log the real TLS/NWError
                // (otherwise ChannelError error 0 is opaque).
                let stateHandler = GRPCConnectionStateHandler(host: host, logger: logger)
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
            identity.deleteKeychainItems(logger: logger)
            try? await group.shutdownGracefully()
            throw error
        }
        guard let multiplexer = capturedMultiplexer else {
            identity.deleteKeychainItems(logger: logger)
            try? await group.shutdownGracefully()
            throw GRPCError.transport("HTTP/2 multiplexer not captured")
        }
        return TeleportGRPCConnection(channel: channel,
                                       multiplexer: multiplexer,
                                       authority: host,
                                       group: group,
                                       identity: identity,
                                       logger: logger)
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
        defer { identity.deleteKeychainItems(logger: logger) }
        try await channel.close().get()
        try await group.shutdownGracefully()
    }

    /// Remove the per-connect keychain identity without waiting for the
    /// asynchronous channel teardown. `close()` is the normal path; this
    /// bounds the leak when the owning client is deallocated without
    /// `disconnect()`. Safe to call more than once. `nonisolated` so it can
    /// be called from `LiveTeleportGRPCClient`'s nonisolated deinit.
    nonisolated func deleteKeychainIdentity() {
        identity.deleteKeychainItems(logger: logger)
    }
}

// MARK: - Connection state handler (diagnostic)

/// Logs TLS handshake + connection errors with the real underlying NWError,
/// so Phase 2 failures aren't opaque 'ChannelError error 0'.
final class GRPCConnectionStateHandler: ChannelInboundHandler, @unchecked Sendable {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    typealias InboundIn = Any
    private let host: String
    private let logger: Logger

    init(host: String, logger: Logger) {
        self.host = host
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        logger.info("conn_active channel active for \(self.host, privacy: .public)")
        context.fireChannelActive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("conn_error \(error.localizedDescription, privacy: .public) [type: \(String(describing: type(of: error)), privacy: .public)]")
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.info("conn_inactive channel closed for \(self.host, privacy: .public)")
        context.fireChannelInactive()
    }
}

#endif // canImport(Network)
