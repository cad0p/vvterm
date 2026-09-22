import Foundation

/// The derived readiness state for a Teleport cluster on this device.
/// Computed locally from keychain presence — NO network call, NO stored state.
/// Per the parent decision's "derived readiness state" section, refined to 4 states
/// (splits needsRegistration from needsBootstrap).
///
/// See: 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup B)
enum TeleportDeviceReadiness: Equatable {
    /// No Phase-1 cert in keychain. New device via iCloud, or never bootstrapped.
    case needsBootstrap
    /// Phase-1 cert present, but no SEP key registered for this cluster.
    /// The device-name pause between the two Safari trips is a natural resume point.
    case needsRegistration
    /// SEP key present, but cert missing or expired (now >= cert.ValidBefore).
    /// Re-auth is native Face ID — no Safari.
    case needsLogin
    /// Live cert, not expired. Connect immediately.
    case ready

    /// Whether setup is required (any non-ready state).
    var needsSetup: Bool {
        switch self {
        case .ready: return false
        case .needsBootstrap, .needsRegistration, .needsLogin: return true
        }
    }

    /// Whether the Safari bootstrap flow is needed (vs. just native Face ID).
    var needsSafari: Bool {
        switch self {
        case .ready, .needsLogin: return false
        case .needsBootstrap, .needsRegistration: return true
        }
    }
}

/// Pure function to compute readiness from keychain state.
/// The keychain queries are injected so this is unit-testable without a real keychain.
struct TeleportDeviceReadinessResolver {
    /// Returns true if a Phase-1 bootstrap cert exists for this cluster.
    typealias HasBootstrapCert = (UUID) -> Bool
    /// Returns true if a SEP key is registered for this cluster.
    typealias HasSEPKey = (UUID) -> Bool
    /// Returns the live cert's ValidBefore, or nil if no cert.
    typealias CertExpiry = (UUID) -> Date?
    /// Returns true if Host CA checking keys are persisted for this cluster.
    /// Missing keys on an otherwise-registered device route to `.needsLogin`
    /// (the login response refreshes them) — legacy installs never capture
    /// checking keys until their next login.
    typealias HasHostCAKeys = (UUID) -> Bool

    let hasBootstrapCert: HasBootstrapCert
    let hasSEPKey: HasSEPKey
    let certExpiry: CertExpiry
    let hasHostCAKeys: HasHostCAKeys

    init(
        hasBootstrapCert: @escaping HasBootstrapCert,
        hasSEPKey: @escaping HasSEPKey,
        certExpiry: @escaping CertExpiry,
        hasHostCAKeys: @escaping HasHostCAKeys = { _ in true }
    ) {
        self.hasBootstrapCert = hasBootstrapCert
        self.hasSEPKey = hasSEPKey
        self.certExpiry = certExpiry
        self.hasHostCAKeys = hasHostCAKeys
    }

    func resolve(clusterId: UUID, now: Date = Date()) -> TeleportDeviceReadiness {
        guard hasBootstrapCert(clusterId) else { return .needsBootstrap }
        guard hasSEPKey(clusterId) else { return .needsRegistration }
        guard hasHostCAKeys(clusterId) else { return .needsLogin }
        guard let expiry = certExpiry(clusterId), expiry > now else {
            return .needsLogin
        }
        return .ready
    }
}
