// SPDX-License-Identifier: MIT
//
//  TeleportKeyRing.swift
//  VVTerm
//
//  The per-cluster credential store for the Teleport SEP-key integration.
//  Mirrors the spike's `RegisteredSEPKey` + UserDefaults persistence
//  (FullFlowRunner.swift's `savedCredentialIDKey` / `savedUserHandleKey`),
//  adapted for VVTerm's `TeleportCredential` domain type.
//
//  What lives where:
//    - The SEP key itself (P-256, non-exportable) lives in the Secure Enclave,
//      persisted via `kSecAttrIsPermanent: true` + `kSecAttrApplicationLabel:
//      credentialID` (proven in session 1.12, PR #29). It is NOT stored here.
//    - The metadata (credentialID, userHandle, publicKeyRaw, deviceName, cert
//      PEM, cert expiry) lives here, in UserDefaults. This type is the
//      index that lets `loadKey(credentialID:)` find the right SEP key.
//
//  NOT CloudKit-synced — the SEP key is per-device by design (each device
//  must run its own Phase 1+2 bootstrap). The parent `Server` record syncs
//  (carrying host/port/username), but the credential never does. A server
//  that arrives via iCloud on a fresh device shows `needsBootstrap` until
//  the user completes the per-device setup — see the design doc's mockup B.
//
//  `@MainActor` because it's observed by SwiftUI views (the readiness pill
//  on the server row recomputes when credentials change). The UserDefaults
//  I/O is cheap enough to do synchronously on the main thread (a few hundred
//  bytes per cluster).
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup B —
//      readiness states)
//    - 2026-07-21-strategy-b-session2.2-vvterm-sep-key-integration-prompt.md
//      (Phase 2 userHandle capture — UTF-8, not base64url)
//

import Foundation
import Security
import Combine
import os.log

/// Stores Teleport credentials (SEP key metadata + derived cert) per cluster.
///
/// The SEP key itself lives in the Secure Enclave (persisted via
/// `kSecAttrIsPermanent`); this type stores the metadata (credentialID,
/// userHandle, cert PEM, expiry) in UserDefaults so the key can be located
/// and the cert can be presented to `SSHClient` without a network round-trip.
///
/// Conforms to the package-movable `TeleportCredentialStore` (the plain
/// `Sendable` seam) in this file; the host-side observation protocol
/// (`TeleportKeyRingStoring`) is declared in `Core/Teleport`.
@MainActor
final class TeleportKeyRing: ObservableObject, TeleportCredentialStore {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    /// The UserDefaults key for the encoded `[UUID: TeleportCredential]` map.
    private let credentialsKey = "vvterm.teleport.credentials"

    /// The UserDefaults key for the encoded `[String: TeleportClusterTLSState]` map
    /// (UUID string keys, same as `credentials`). Stores the cluster name +
    /// TLS CA certs per cluster for the SSH TLS+ALPN transport.
    private let clusterTLSStateKey = "vvterm.teleport.clusterTLSState"

    /// The injected signer — used to probe the Secure Enclave for key presence
    /// (readiness computation). Defaults to a real `SecureEnclaveSigner`;
    /// UI tests inject a `MockSEPKeySigner`.
    private let signer: any TeleportSEPSigning

    /// The persistence config: keychain service + defaults store. The host
    /// passes `TeleportKeychainConfig.vvterm`; package tests pass a
    /// suite-scoped `UserDefaults` and a test service.
    private let config: TeleportKeychainConfig

    @Published private(set) var credentials: [UUID: TeleportCredential] = [:]

    private let logger: Logger

    /// The injectable keychain-write seam for the per-cluster ed25519 private
    /// key. Defaults to the real update-first body
    /// (`writeEd25519PrivateKeyToKeychain`); tests inject a scripted writer to
    /// prove the failure direction (a failed update/add must not commit the
    /// record and must not destroy the prior key).
    typealias Ed25519KeychainWriter = @MainActor (Data, UUID) throws -> Void

    private let keychainWriter: Ed25519KeychainWriter

    init(
        signer: any TeleportSEPSigning = SecureEnclaveSigner(),
        logging: any TeleportLogging,
        config: TeleportKeychainConfig,
        keychainWriter: Ed25519KeychainWriter? = nil
    ) {
        self.signer = signer
        self.logger = logging.logger(category: "teleport-keyring")
        self.config = config
        let logger = self.logger
        let service = config.keychainService
        self.keychainWriter = keychainWriter ?? { pemData, clusterId in
            try Self.writeEd25519PrivateKeyToKeychain(
                pemData,
                service: service,
                account: Self.sshKeyAccount(for: clusterId),
                logger: logger,
                clusterId: clusterId
            )
        }
        load()
    }

    // MARK: - Readiness

    func readiness(for clusterId: UUID) -> TeleportDeviceReadiness {
        // The resolver is a pure function over three injected probes:
        //   - hasBootstrapCert: is there ANY cert (live or expired)?
        //   - hasSEPKey: is the SEP key present in the Secure Enclave?
        //   - certExpiry: when does the live cert expire (if any)?
        //
        // The SEP-key probe goes through the signer so UI tests can script
        // "key present" / "key absent" without a real keychain. A real
        // `loadKey` call is cheap (a single SecItemCopyMatching), but we
        // cache the result in `credentials` so repeated readiness checks
        // don't hit the keychain on every server-row render.
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { [weak self] id in
                self?.hasBootstrapCert(id) == true
            },
            hasSEPKey: { [weak self] id in
                guard let self,
                      let cred = self.credentials[id],
                      !cred.credentialID.isEmpty,
                      let credID = Data(base64URLEncoded: cred.credentialID) else {
                    return false
                }
                // Probe the Secure Enclave. `loadKey` returns nil for
                // "no key" (not an error), so we treat any throw as
                // "key absent" too — the key may have been deleted.
                do {
                    return try self.signer.loadKey(credentialID: credID) != nil
                } catch {
                    self.logger.error(
                        "loadKey failed for cluster \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    return false
                }
            },
            certExpiry: { [weak self] id in
                guard let cred = self?.credentials[id],
                      let certPEM = cred.sshCertPEM,
                      let cert = OpenSSHCertificate.parse(authorizedKeysOrPEM: certPEM),
                      cert.isValid(at: Date()) else {
                    // `.distantPast` is the "no cert" sentinel in
                    // TeleportCredential; map it back to nil so the resolver
                    // treats it as "no expiry". A PEM that does not parse (or
                    // is outside its validity window) also returns nil: a cert
                    // that cannot be read must never resolve `.ready`.
                    return nil
                }
                return cert.validBeforeDate
            },
            hasHostCAKeys: { [weak self] id in
                // Legacy installs (pre-checking-keys) have TLS state without
                // Host CA keys; readiness routes them to Face ID login, and
                // the login response refreshes the pinned keys.
                self?.clusterTLSState[id]?.hostCACheckingKeys.isEmpty == false
            }
        )
        return resolver.resolve(clusterId: clusterId)
    }

    // MARK: - Credential lifecycle

    func storeBootstrapCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) {
        var cred = credentials[clusterId]
            ?? TeleportCredential(clusterId: clusterId, credentialID: "", userHandle: "", publicKeyRaw: "", deviceName: "")
        cred.sshCertPEM = certPEM
        cred.hasLiveCert = true
        cred.certValidBefore = validBefore
        credentials[clusterId] = cred
        save()
        logger.info("stored bootstrap cert for cluster \(clusterId.uuidString, privacy: .public), valid until \(validBefore.debugDescription, privacy: .public)")
    }

    func storeRegisteredSEPKey(
        credentialID: Data,
        userHandle: Data,
        publicKeyRaw: Data,
        deviceName: String,
        for clusterId: UUID
    ) {
        var cred = credentials[clusterId]
            ?? TeleportCredential(clusterId: clusterId, credentialID: "", userHandle: "", publicKeyRaw: "", deviceName: "")
        cred.credentialID = credentialID.base64URLEncodedString()
        // The userHandle is captured from the gRPC CreateRegisterChallenge
        // response's `user.id` field, which is a raw UUID STRING (not
        // base64url — see the 2.2 prompt gotcha). We store it base64url-
        // encoded for transport-safety in UserDefaults, but the login
        // coordinator decodes it back to the raw UTF-8 bytes before
        // passing to WebAuthn.login.
        cred.userHandle = userHandle.base64URLEncodedString()
        cred.publicKeyRaw = publicKeyRaw.base64URLEncodedString()
        cred.deviceName = deviceName
        credentials[clusterId] = cred
        save()
        logger.info("stored SEP key metadata for cluster \(clusterId.uuidString, privacy: .public), device=\(deviceName, privacy: .private)")
    }

    func storeLoginCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) {
        guard var cred = credentials[clusterId] else {
            // No credential record — can't store a login cert without a
            // registered SEP key. This is a programming error (the login
            // coordinator should only run when readiness == .needsLogin,
            // which requires a registered key).
            logger.error("storeLoginCert called with no registered SEP key for cluster \(clusterId.uuidString, privacy: .public)")
            return
        }
        cred.sshCertPEM = certPEM
        cred.hasLiveCert = true
        cred.certValidBefore = validBefore
        credentials[clusterId] = cred
        save()
        logger.info("stored login cert for cluster \(clusterId.uuidString, privacy: .public), valid until \(validBefore.debugDescription, privacy: .public)")
    }

    func liveCertPEM(for clusterId: UUID) -> String? {
        guard let cred = credentials[clusterId], cred.isCertValid else { return nil }
        return cred.sshCertPEM
    }

    /// One consistent read of the live cert + its paired private key. Both
    /// reads happen in this synchronous MainActor body, and the pair write
    /// (`storeCredentialPair`) commits the key and the record in one
    /// non-suspending MainActor body, so no concurrent re-login can interleave
    /// between the halves of a credential. (The single writes remain the
    /// non-atomic seed/test primitives; no coordinator calls them.)
    func liveCredentialSnapshot(for clusterId: UUID) -> (certPEM: String, privateKeyPEM: Data)? {
        guard let certPEM = liveCertPEM(for: clusterId),
              let privateKeyPEM = liveEd25519PrivateKey(for: clusterId) else {
            return nil
        }
        return (certPEM, privateKeyPEM)
    }

    func registeredCredentialID(for clusterId: UUID) -> Data? {
        guard let cred = credentials[clusterId],
              !cred.credentialID.isEmpty,
              let data = Data(base64URLEncoded: cred.credentialID) else {
            return nil
        }
        return data
    }

    func registeredUserHandle(for clusterId: UUID) -> Data? {
        guard let cred = credentials[clusterId],
              !cred.userHandle.isEmpty,
              let data = Data(base64URLEncoded: cred.userHandle) else {
            return nil
        }
        return data
    }

    // MARK: - ed25519 SSH private key (keychain)

    /// The keychain service + account scheme for the per-cluster ed25519
    /// private key. The private key is stored in the keychain (not
    /// UserDefaults) because it's secret. NOT CloudKit-synced — each device
    /// generates its own keypair at bootstrap.
    ///
    /// Format: service = `config.keychainService` (the app passes the same
    /// service `KeychainManager` uses), account =
    /// `vvterm.teleport.sshkey.<clusterId>`. The clusterId is the
    /// `Server.id` (Teleport clusters are stored as Server records).
    private var sshKeyService: String { config.keychainService }
    private static func sshKeyAccount(for clusterId: UUID) -> String {
        "vvterm.teleport.sshkey.\(clusterId.uuidString)"
    }

    func liveEd25519PrivateKey(for clusterId: UUID) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecAttrAccount as String: Self.sshKeyAccount(for: clusterId),
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger.error("loadEd25519PrivateKey SecItemCopyMatching: OSStatus \(status)")
            }
            return nil
        }
        return item as? Data
    }

    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) throws {
        try keychainWriter(pemData, clusterId)
    }

    /// Write a cert and its paired ed25519 private key as one indivisible unit
    /// (the `TeleportCredentialStore` contract). The body is synchronous — it
    /// suspends nowhere — so no supersession can interleave between the key
    /// write and the record commit. Key-first plus the non-destructive keychain
    /// write means a failed write leaves the previous complete pair intact (or,
    /// on a first bootstrap, commits nothing): the body lands a complete new
    /// pair, the previous complete pair, or nothing — never a mixed pair.
    ///
    /// This is interleaving atomicity, not crash durability: the record is in
    /// `UserDefaults` and the key in the Keychain (no shared transaction), so a
    /// crash between the writes can still leave a genuinely mixed pair that
    /// only the server's signature check rejects.
    func storeCredentialPair(
        _ certPEM: String,
        validBefore: Date,
        privateKeyPEM: Data,
        policy: TeleportCredentialWritePolicy,
        for clusterId: UUID
    ) throws {
        // Policy check first: a `.login` pair for a cluster with no record must
        // not write the orphan key below (the reachable concurrent-`clear` case).
        switch policy {
        case .login:
            guard credentials[clusterId] != nil else {
                throw TeleportCredentialStoreError.noRegisteredCredential(clusterId: clusterId)
            }
        case .bootstrap:
            break
        }

        // Key first: a failed key write leaves the previous complete pair intact
        // (or commits nothing on a first bootstrap), so the record below can only
        // ever point at a cert whose key is present.
        try keychainWriter(privateKeyPEM, clusterId)

        // Record commit: cert fields only, so a re-bootstrap preserves the
        // registered SEP metadata. The `??` create path runs only for a
        // `.bootstrap` pair with no existing record (a `.login` pair threw
        // above); `save()` cannot throw, so no in-process error can suspend
        // the body between the key write and the commit. It can still
        // silently fail to persist (an encode error is logged and the
        // UserDefaults blob keeps the old record): a durability tear of the
        // same class as the crash window, not an interleaving one. The
        // interleaving guarantee is unaffected.
        var cred = credentials[clusterId]
            ?? TeleportCredential(clusterId: clusterId, credentialID: "", userHandle: "", publicKeyRaw: "", deviceName: "")
        cred.sshCertPEM = certPEM
        cred.hasLiveCert = true
        cred.certValidBefore = validBefore
        credentials[clusterId] = cred
        save()
        logger.info("stored credential pair for cluster \(clusterId.uuidString, privacy: .public), valid until \(validBefore.debugDescription, privacy: .public)")
    }

    /// The real keychain write: `SecItemUpdate(kSecValueData)`-first,
    /// `SecItemAdd` only on `errSecItemNotFound`; every other status is a
    /// fail-closed throw that deletes nothing. On failure the previous key (if
    /// any) survives, so the pair write's failure direction leaves the previous
    /// complete pair intact. `kSecAttrAccessible` is left untouched on an
    /// existing item (update `kSecValueData` only); a new item gets the
    /// after-first-unlock, this-device-only accessibility.
    private static func writeEd25519PrivateKeyToKeychain(
        _ pemData: Data,
        service: String,
        account: String,
        logger: Logger,
        clusterId: UUID
    ) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [
            kSecValueData as String: pemData
        ] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            // The add is only reached when the update reported not-found, so a
            // concurrent writer's `errSecDuplicateItem` here means the item
            // appeared between the two calls: fail closed, never
            // delete-and-retry (that would destroy a key this writer did not
            // create).
            var attributes = baseQuery
            attributes[kSecValueData as String] = pemData
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                logger.error("storeEd25519PrivateKey SecItemAdd: OSStatus \(addStatus)")
                throw TeleportPackageError.keychain(addStatus)
            }
        default:
            // An update-path status (auth failure, storage pressure, …): fail
            // closed. Never delete-and-retry.
            logger.error("storeEd25519PrivateKey SecItemUpdate: OSStatus \(updateStatus)")
            throw TeleportPackageError.keychain(updateStatus)
        }
        logger.info("stored ed25519 private key for cluster \(clusterId.uuidString, privacy: .public)")
    }

    func clear(for clusterId: UUID) {
        credentials.removeValue(forKey: clusterId)
        clusterTLSState.removeValue(forKey: clusterId)
        // Also delete the ed25519 private key from the keychain.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecAttrAccount as String: Self.sshKeyAccount(for: clusterId)
        ]
        SecItemDelete(query as CFDictionary)
        save()
        saveClusterTLSState()
        logger.info("cleared credentials for cluster \(clusterId.uuidString, privacy: .public)")
    }

    // MARK: - Credential reuse (duplicate server rows)

    /// The completeness precondition for reuse: a credential record with a
    /// non-empty credentialID, the SEP key still present in the Secure
    /// Enclave, a cluster TLS state with non-empty Host CA checking keys (a
    /// complete setup — legacy installs with 0 checking keys are not
    /// offered), and a matching cluster name when one is supplied.
    func isReusableRegistrationSource(for serverId: UUID, clusterName: String?) -> Bool {
        guard let credential = credentials[serverId], !credential.credentialID.isEmpty else {
            return false
        }
        guard let credID = Data(base64URLEncoded: credential.credentialID),
              (try? signer.loadKey(credentialID: credID)) != nil else {
            return false
        }
        guard let state = clusterTLSState[serverId], !state.hostCACheckingKeys.isEmpty else {
            return false
        }
        if let clusterName, !clusterName.isEmpty, state.clusterName != clusterName {
            return false
        }
        return true
    }

    /// Seed the registration metadata (and cluster TLS state) for a duplicate
    /// server row from a complete live registration, then return true. The cert
    /// and the ed25519 private key are deliberately NOT copied: the new row
    /// needs the Face ID login (and the host-login picker) to get its own
    /// certificate.
    @discardableResult
    func seedRegistration(from sourceId: UUID, to targetId: UUID) -> Bool {
        guard sourceId != targetId else { return false }
        guard let source = credentials[sourceId], !source.credentialID.isEmpty else { return false }
        guard let sourceTLSState = clusterTLSState[sourceId], !sourceTLSState.hostCACheckingKeys.isEmpty else {
            return false
        }

        let seeded = TeleportCredential(
            clusterId: targetId,
            credentialID: source.credentialID,
            userHandle: source.userHandle,
            publicKeyRaw: source.publicKeyRaw,
            deviceName: source.deviceName
        )
        credentials[targetId] = seeded
        clusterTLSState[targetId] = sourceTLSState
        save()
        saveClusterTLSState()
        logger.info(
            "seeded the device registration for cluster \(targetId.uuidString, privacy: .public) from \(sourceId.uuidString, privacy: .public)"
        )
        return true
    }

    // MARK: - Cluster TLS state (SSH transport)

    /// The in-memory cache of cluster TLS state, loaded from UserDefaults.
    private var clusterTLSState: [UUID: TeleportClusterTLSState] = [:]

    func clusterTLSState(for clusterId: UUID) -> TeleportClusterTLSState? {
        clusterTLSState[clusterId]
    }

    func storeClusterTLSState(_ state: TeleportClusterTLSState, for clusterId: UUID) {
        clusterTLSState[clusterId] = state
        saveClusterTLSState()
        logger.info(
            "stored cluster TLS state for cluster \(clusterId.uuidString, privacy: .public) name=\(state.clusterName, privacy: .private(mask: .hash)) ca_certs=\(state.clusterCAPEMs.count) checking_keys=\(state.hostCACheckingKeys.count)"
        )
    }

    func updateClusterHostKeys(_ checkingKeys: [String], for clusterId: UUID) -> TeleportHostKeyUpdateResult {
        guard let state = clusterTLSState[clusterId] else {
            logger.error(
                "host key refresh for cluster \(clusterId.uuidString, privacy: .public) has no stored TLS state — ignoring"
            )
            return .noChange
        }
        let outcome = TeleportHostKeyUpdatePolicy.apply(checkingKeys: checkingKeys, to: state)
        if outcome.result == .rejectedWouldDropPinnedKeys {
            logger.error(
                "host key refresh for cluster \(clusterId.uuidString, privacy: .public) would drop a pinned Host CA key — keeping pinned anchors, re-bootstrap required"
            )
        }
        guard let updatedState = outcome.updatedState else {
            return outcome.result
        }
        clusterTLSState[clusterId] = updatedState
        saveClusterTLSState()
        logger.info(
            "refreshed Host CA checking keys for cluster \(clusterId.uuidString, privacy: .public): \(state.hostCACheckingKeys.count) → \(updatedState.hostCACheckingKeys.count)"
        )
        return outcome.result
    }

    // MARK: - Persistence

    private func load() {
        guard let data = config.defaults.data(forKey: credentialsKey) else {
            return
        }
        // Encode as `[String: TeleportCredential]` (UUID keys aren't directly
        // Codable in a dictionary top-level; stringify the keys).
        guard let decoded = try? JSONDecoder().decode(
            [String: TeleportCredential].self,
            from: data
        ) else {
            logger.error("failed to decode persisted credentials — ignoring")
            return
        }
        credentials = Dictionary(
            uniqueKeysWithValues: decoded.compactMap { (key, value) -> (UUID, TeleportCredential)? in
                guard let uuid = UUID(uuidString: key) else { return nil }
                return (uuid, value)
            }
        )

        // Load cluster TLS state too.
        if let tlsData = config.defaults.data(forKey: clusterTLSStateKey),
           let tlsDecoded = try? JSONDecoder().decode(
            [String: TeleportClusterTLSState].self,
            from: tlsData
           ) {
            clusterTLSState = Dictionary(
                uniqueKeysWithValues: tlsDecoded.compactMap { (key, value) -> (UUID, TeleportClusterTLSState)? in
                    guard let uuid = UUID(uuidString: key) else { return nil }
                    return (uuid, value)
                }
            )
        }
    }

    private func save() {
        let encoded = Dictionary(
            uniqueKeysWithValues: credentials.map { ($0.key.uuidString, $0.value) }
        )
        do {
            let data = try JSONEncoder().encode(encoded)
            config.defaults.set(data, forKey: credentialsKey)
        } catch {
            logger.error("failed to encode credentials: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveClusterTLSState() {
        let encoded = Dictionary(
            uniqueKeysWithValues: clusterTLSState.map { ($0.key.uuidString, $0.value) }
        )
        do {
            let data = try JSONEncoder().encode(encoded)
            config.defaults.set(data, forKey: clusterTLSStateKey)
        } catch {
            logger.error("failed to encode cluster TLS state: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// A bootstrap cert is "present" if there's any PEM stored, even if the
    /// SEP key isn't registered yet (the Phase-1-only state). This drives
    /// the `needsBootstrap` ↔ `needsRegistration` distinction.
    private func hasBootstrapCert(_ clusterId: UUID) -> Bool {
        credentials[clusterId]?.sshCertPEM != nil
    }
}
