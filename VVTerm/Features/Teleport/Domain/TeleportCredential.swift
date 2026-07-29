import Foundation

/// The persisted state for a registered Teleport SEP key + its derived cert.
/// Stored in the keychain (SEP key) and UserDefaults/TeleportKeyRing (cert + metadata).
/// NOT CloudKit-synced — the SEP key is per-device by design.
struct TeleportCredential: Codable, Hashable, Identifiable {
    let id: UUID
    /// The cluster this credential belongs to.
    var clusterId: UUID
    /// The WebAuthn credential ID (raw bytes, base64-encoded for storage).
    var credentialID: String
    /// The WebAuthn user handle (raw bytes, base64-encoded). Required for
    /// passwordless login (server's verify path needs it). Captured at Phase 2
    /// registration, decoded as UTF-8 (NOT base64url — see the 2.2 prompt gotcha).
    var userHandle: String
    /// The SEP key's public key in raw form (for attestation/verification).
    var publicKeyRaw: String
    /// The MFA device name registered with Teleport (e.g. "vvterm-pier-iphone").
    var deviceName: String
    /// The issued SSH certificate (PEM). nil if no live cert.
    var sshCertPEM: String?
    /// The ed25519 private key for the cert (PEM). nil if no live cert.
    /// Stored in keychain, not here — this is just a flag for "cert present".
    var hasLiveCert: Bool
    /// The cert's ValidBefore (Unix timestamp). 0 if no cert.
    var certValidBefore: Date

    init(
        id: UUID = UUID(),
        clusterId: UUID,
        credentialID: String,
        userHandle: String,
        publicKeyRaw: String,
        deviceName: String,
        sshCertPEM: String? = nil,
        hasLiveCert: Bool = false,
        certValidBefore: Date = .distantPast
    ) {
        self.id = id
        self.clusterId = clusterId
        self.credentialID = credentialID
        self.userHandle = userHandle
        self.publicKeyRaw = publicKeyRaw
        self.deviceName = deviceName
        self.sshCertPEM = sshCertPEM
        self.hasLiveCert = hasLiveCert
        self.certValidBefore = certValidBefore
    }

    /// Whether the cert is currently valid (present and not expired).
    var isCertValid: Bool {
        hasLiveCert && sshCertPEM != nil && Date() < certValidBefore
    }
}
