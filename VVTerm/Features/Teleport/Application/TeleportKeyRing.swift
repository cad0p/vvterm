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

    init(
        signer: any TeleportSEPSigning = SecureEnclaveSigner(),
        logging: any TeleportLogging,
        config: TeleportKeychainConfig
    ) {
        self.signer = signer
        self.logger = logging.logger(category: "teleport-keyring")
        self.config = config
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
                guard let cred = self?.credentials[id] else { return nil }
                // `.distantPast` is the "no cert" sentinel in TeleportCredential;
                // map it back to nil so the resolver treats it as "no expiry".
                if cred.certValidBefore == .distantPast { return nil }
                return cred.certValidBefore
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
        logger.info("stored SEP key metadata for cluster \(clusterId.uuidString, privacy: .public), device=\(deviceName, privacy: .public)")
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
        let account = Self.sshKeyAccount(for: clusterId)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecAttrAccount as String: account
        ]
        // Delete any prior key first (idempotent).
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = pemData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("storeEd25519PrivateKey SecItemAdd: OSStatus \(status)")
            throw TeleportPackageError.keychain(status)
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
            "stored cluster TLS state for cluster \(clusterId.uuidString, privacy: .public) name=\(state.clusterName, privacy: .public) ca_certs=\(state.clusterCAPEMs.count) checking_keys=\(state.hostCACheckingKeys.count)"
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
