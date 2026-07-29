// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportDeviceReadinessTests.swift
//  VVTermTests
//
//  Layer 1 unit tests for `TeleportDeviceReadinessResolver`.
//
//  The resolver is a pure function over three injected probes (hasBootstrapCert,
//  hasSEPKey, certExpiry). This file covers all 4 states × cert-valid/cert-expired
//  × key-present/key-absent, plus the cross-device case (server record present,
//  empty keychain → needsBootstrap).
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup B — the
//      readiness-state matrix; CI strategy Layer 1)
//    - VVTerm/Features/Teleport/Domain/TeleportDeviceReadiness.swift
//

import XCTest
@testable import VVTerm

final class TeleportDeviceReadinessTests: XCTestCase {

    // MARK: - needsBootstrap (no cert)

    func testNeedsBootstrap_whenNoCertAndNoSEPKey() {
        // New device via iCloud, or never bootstrapped. No cert, no SEP key.
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in false },
            hasSEPKey: { _ in false },
            certExpiry: { _ in nil }
        )
        XCTAssertEqual(
            resolver.resolve(clusterId: UUID()),
            .needsBootstrap
        )
    }

    func testNeedsBootstrap_whenNoCertButSEPKeySomehowPresent() {
        // Edge case: SEP key present but no cert. This shouldn't happen in
        // practice (the SEP key is only created after a bootstrap cert is
        // obtained), but the resolver is defensive: no cert → needsBootstrap
        // regardless of SEP key state. (The registration coordinator requires
        // the Phase-1 cert to authenticate Phase 2; without it, bootstrap must
        // re-run.)
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in false },
            hasSEPKey: { _ in true },
            certExpiry: { _ in nil }
        )
        XCTAssertEqual(
            resolver.resolve(clusterId: UUID()),
            .needsBootstrap
        )
    }

    // MARK: - needsRegistration (cert, no SEP key)

    func testNeedsRegistration_whenCertPresentButNoSEPKey() {
        // Phase-1 cert present, Phase-2 SEP key not yet registered. The user
        // cancelled between the two Safari trips (the device-name pause is the
        // natural resume point).
        let now = Date()
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in true },
            hasSEPKey: { _ in false },
            certExpiry: { _ in now.addingTimeInterval(3600) }
        )
        XCTAssertEqual(
            resolver.resolve(clusterId: UUID(), now: now),
            .needsRegistration
        )
    }

    func testNeedsRegistration_whenCertPresentButNoSEPKey_evenIfCertExpired() {
        // Even if the bootstrap cert has expired, if there's no SEP key the
        // state is needsRegistration (the user still needs to register the SEP
        // key; re-running bootstrap alone won't help). The cert expiry only
        // matters once the SEP key is present (needsLogin).
        let now = Date()
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in true },
            hasSEPKey: { _ in false },
            certExpiry: { _ in now.addingTimeInterval(-3600) }  // expired
        )
        XCTAssertEqual(
            resolver.resolve(clusterId: UUID(), now: now),
            .needsRegistration
        )
    }

    // MARK: - needsLogin (SEP key present, cert missing or expired)

    func testNeedsLogin_whenSEPKeyPresentButNoCert() {
        // SEP key is registered, but no live cert. Re-auth is native Face ID
        // (no Safari) — the user taps "Sign in" and the login coordinator
        // issues a fresh cert.
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in true },
            hasSEPKey: { _ in true },
            certExpiry: { _ in nil }  // no cert at all
        )
        XCTAssertEqual(
            resolver.resolve(clusterId: UUID()),
            .needsLogin
        )
    }

    func testNeedsLogin_whenSEPKeyPresentButCertExpired() {
        // SEP key + cert present, but the cert has expired (now >= ValidBefore).
        // Same recovery as "no cert" — native Face ID re-auth.
        let now = Date()
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in true },
            hasSEPKey: { _ in true },
            certExpiry: { _ in now.addingTimeInterval(-1) }  // expired 1s ago
        )
        XCTAssertEqual(
            resolver.resolve(clusterId: UUID(), now: now),
            .needsLogin
        )
    }

    func testNeedsLogin_whenCertExpiryExactlyEqualsNow() {
        // Boundary: expiry == now is treated as expired (now >= ValidBefore).
        // The cert is invalid the instant it expires.
        let now = Date()
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in true },
            hasSEPKey: { _ in true },
            certExpiry: { _ in now }  // exactly now
        )
        XCTAssertEqual(
            resolver.resolve(clusterId: UUID(), now: now),
            .needsLogin
        )
    }

    // MARK: - ready (SEP key + valid cert)

    func testReady_whenSEPKeyPresentAndCertValid() {
        // Live cert, not expired. Connect immediately via the cert seam.
        let now = Date()
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in true },
            hasSEPKey: { _ in true },
            certExpiry: { _ in now.addingTimeInterval(3600) }  // 1h in future
        )
        XCTAssertEqual(
            resolver.resolve(clusterId: UUID(), now: now),
            .ready
        )
    }

    func testReady_whenCertExpiryOneSecondInFuture() {
        // Boundary: expiry 1s in the future is still valid (now < ValidBefore).
        let now = Date()
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in true },
            hasSEPKey: { _ in true },
            certExpiry: { _ in now.addingTimeInterval(1) }
        )
        XCTAssertEqual(
            resolver.resolve(clusterId: UUID(), now: now),
            .ready
        )
    }

    // MARK: - Cross-device case (server record present, empty keychain)

    func testCrossDevice_whenServerRecordArrivesViaICloudButKeychainEmpty() {
        // The parent `Server` record arrives via CloudKit on a fresh device.
        // The Teleport credential (SEP key + cert) is NOT synced — it's
        // per-device by design. So on the new device, hasBootstrapCert /
        // hasSEPKey / certExpiry all return false/false/nil → needsBootstrap.
        //
        // This is the "prompt-on-connect offers setup" case from mockup B.
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in false },  // empty keychain
            hasSEPKey: { _ in false },          // empty keychain
            certExpiry: { _ in nil }            // empty keychain
        )
        XCTAssertEqual(
            resolver.resolve(clusterId: UUID()),
            .needsBootstrap
        )
    }

    // MARK: - Cluster isolation (probes are keyed by cluster ID)

    func testProbesAreKeyedByClusterID() {
        // Two clusters: one ready, one needsBootstrap. The probes must
        // distinguish them by cluster ID — a ready state on cluster A must
        // not leak to cluster B.
        let clusterA = UUID()
        let clusterB = UUID()
        let now = Date()

        let readyState: Set<UUID> = [clusterA]
        let sepKeys: Set<UUID> = [clusterA]
        let expiries: [UUID: Date] = [clusterA: now.addingTimeInterval(3600)]

        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { readyState.contains($0) },
            hasSEPKey: { sepKeys.contains($0) },
            certExpiry: { expiries[$0] }
        )

        XCTAssertEqual(resolver.resolve(clusterId: clusterA, now: now), .ready)
        XCTAssertEqual(resolver.resolve(clusterId: clusterB, now: now), .needsBootstrap)
    }

    // MARK: - needsSetup / needsSafari derived helpers

    func testNeedsSetup_trueForAllNonReadyStates() {
        // needsBootstrap, needsRegistration, needsLogin all require setup;
        // only ready doesn't.
        XCTAssertEqual(TeleportDeviceReadiness.needsBootstrap.needsSetup, true)
        XCTAssertEqual(TeleportDeviceReadiness.needsRegistration.needsSetup, true)
        XCTAssertEqual(TeleportDeviceReadiness.needsLogin.needsSetup, true)
        XCTAssertEqual(TeleportDeviceReadiness.ready.needsSetup, false)
    }

    func testNeedsSafari_trueOnlyForBootstrapAndRegistration() {
        // needsBootstrap + needsRegistration require the Safari trip;
        // needsLogin + ready don't (needsLogin is native Face ID only).
        XCTAssertEqual(TeleportDeviceReadiness.needsBootstrap.needsSafari, true)
        XCTAssertEqual(TeleportDeviceReadiness.needsRegistration.needsSafari, true)
        XCTAssertEqual(TeleportDeviceReadiness.needsLogin.needsSafari, false)
        XCTAssertEqual(TeleportDeviceReadiness.ready.needsSafari, false)
    }

    // MARK: - Full matrix: 4 states × cert-valid/expired × key-present/absent

    /// Exhaustive matrix covering every combination of the three probes.
    /// This is the "all keychain combos" coverage from the design doc's
    /// Layer 1 CI strategy.
    func testFullMatrix_allCombinations() {
        let now = Date()
        let validExpiry = now.addingTimeInterval(3600)
        let expiredExpiry = now.addingTimeInterval(-3600)

        // (hasBootstrapCert, hasSEPKey, certExpiry) → expected state
        let cases: [(Bool, Bool, Date?, TeleportDeviceReadiness)] = [
            // No cert → needsBootstrap regardless of SEP key / expiry.
            (false, false, nil,            .needsBootstrap),
            (false, false, validExpiry,    .needsBootstrap),
            (false, false, expiredExpiry,  .needsBootstrap),
            (false, true,  nil,            .needsBootstrap),
            (false, true,  validExpiry,    .needsBootstrap),
            (false, true,  expiredExpiry,  .needsBootstrap),
            // Cert present, no SEP key → needsRegistration (regardless of expiry).
            (true,  false, nil,            .needsRegistration),
            (true,  false, validExpiry,    .needsRegistration),
            (true,  false, expiredExpiry,  .needsRegistration),
            // Cert present, SEP key present → needsLogin (no/expired cert) or ready (valid cert).
            (true,  true,  nil,            .needsLogin),
            (true,  true,  validExpiry,    .ready),
            (true,  true,  expiredExpiry,  .needsLogin),
        ]

        for (i, testCase) in cases.enumerated() {
            let (hasCert, hasKey, expiry, expected) = testCase
            let resolver = TeleportDeviceReadinessResolver(
                hasBootstrapCert: { _ in hasCert },
                hasSEPKey: { _ in hasKey },
                certExpiry: { _ in expiry }
            )
            let actual = resolver.resolve(clusterId: UUID(), now: now)
            XCTAssertEqual(
                actual, expected,
                "matrix case \(i) (hasCert=\(hasCert), hasKey=\(hasKey), expiry=\(String(describing: expiry))) failed: expected \(expected), got \(actual)"
            )
        }
    }
}
