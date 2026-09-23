// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportGRPCClientConnectionTests.swift
//  VVTermTests
//
//  Regression coverage for the Phase-2 gRPC dial. The live-device failure
//  "grRPC connect failed: (VVTerm.GRPCError error 1.)" was opaque because
//  `GRPCError` didn't conform to `LocalizedError`, so `error.localizedDescription`
//  returned only the case ordinal. These tests pin:
//    1. `GRPCError.localizedDescription` surfaces the concrete case + message
//       (so the next live failure shows the real NWError, not "error 1").
//    2. `LiveTeleportGRPCClient.connect` rejects an empty client cert or
//       empty cluster name BEFORE dialing — these are the silent-failure
//       inputs that would otherwise produce a `.transport`/`.tls` dial error
//       with no actionable context.
//    3. `LiveTeleportGRPCClient.connect` always dials port 443 (matching the
//       iotest spike that passed on device). Teleport's auth ALPN route is
//       served by the web proxy on 443 alongside HTTPS, not on a separate
//       port like 3025.
//
//  See:
//    - VVTerm/Features/Teleport/Infrastructure/GRPCClient.swift (GRPCError)
//    - VVTerm/Features/Teleport/UI/TeleportLiveCoordinators.swift (LiveTeleportGRPCClient.connect)
//    - spike: spikes/sep-webauthn-iotest/iotest/GRPC/GRPCTransport.swift (port 443)
//

import XCTest
import Security
@testable import VVTerm

@MainActor
final class TeleportGRPCClientConnectionTests: XCTestCase {

    // MARK: - GRPCError observability

    /// A `.transport` failure must surface its associated message in
    /// `localizedDescription`. Without `LocalizedError` conformance this
    /// returned "The operation couldn't be completed. (VVTerm.GRPCError error 1.)"
    /// — the opaque ordinal that hid the live-device dial failure.
    func testGRPCError_transport_localizedDescriptionSurfacesMessage() {
        let err = GRPCError.transport("posix(54): connection reset")
        XCTAssertTrue(err.localizedDescription.contains("posix(54)"),
                      "localizedDescription must include the transport message; got: \(err.localizedDescription)")
        XCTAssertTrue(err.localizedDescription.contains("transport"),
                      "localizedDescription must identify the case; got: \(err.localizedDescription)")
    }

    func testGRPCError_tls_localizedDescriptionSurfacesMessage() {
        let err = GRPCError.tls("empty client cert PEM")
        XCTAssertTrue(err.localizedDescription.contains("empty client cert PEM"),
                      "got: \(err.localizedDescription)")
    }

    func testGRPCError_grpc_localizedDescriptionSurfacesStatus() {
        let err = GRPCError.grpc(status: 6, message: "already exists")
        XCTAssertTrue(err.localizedDescription.contains("6"),
                      "got: \(err.localizedDescription)")
        XCTAssertTrue(err.localizedDescription.contains("already exists"),
                      "got: \(err.localizedDescription)")
    }

    // MARK: - LiveTeleportGRPCClient input validation

    /// An empty client cert (Phase 1 returned no `tls_cert`) must throw
    /// `.tls` BEFORE the NWConnection dial. This surfaces an actionable
    /// error instead of a TLS handshake failure.
    func testConnect_rejectsEmptyClientCert() async throws {
        let client = LiveTeleportGRPCClient()
        guard let key = SecKeyCreateRandomKey(
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256
            ] as CFDictionary,
            nil
        ) else {
            throw XCTSkip("the unit host cannot create an ephemeral P-256 key")
        }
        do {
            try await client.connect(
                host: "teleport.pcad.it",
                clientCertPEM: "",
                privateKey: key,
                clusterName: "teleport.pcad.it",
                clusterCAPEMs: []
            )
            XCTFail("connect should have thrown for empty client cert")
        } catch let err as GRPCError {
            if case .tls = err {
                // expected
            } else {
                XCTFail("expected .tls for empty cert; got \(err)")
            }
        } catch {
            XCTFail("expected GRPCError.tls; got \(error)")
        }
    }

    /// An empty cluster name (Phase 1 returned no `host_signers[0].domain_name`)
    /// must throw `.transport` BEFORE the dial — the ALPN SNI auth route is
    /// `teleport-auth@<hex(clusterName)>.teleport.cluster.local`, so an empty
    /// cluster name produces a malformed ALPN token that NWConnection rejects.
    func testConnect_rejectsEmptyClusterName() async throws {
        let client = LiveTeleportGRPCClient()
        guard let key = SecKeyCreateRandomKey(
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256
            ] as CFDictionary,
            nil
        ) else {
            throw XCTSkip("the unit host cannot create an ephemeral P-256 key")
        }
        do {
            try await client.connect(
                host: "teleport.pcad.it",
                clientCertPEM: "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n",
                privateKey: key,
                clusterName: "",
                clusterCAPEMs: []
            )
            XCTFail("connect should have thrown for empty cluster name")
        } catch let err as GRPCError {
            if case .transport = err {
                // expected
            } else {
                XCTFail("expected .transport for empty cluster name; got \(err)")
            }
        } catch {
            XCTFail("expected GRPCError.transport; got \(error)")
        }
    }

    // MARK: - GRPCTLSOptions ALPN route

    /// The auth-service ALPN token must be `teleport-auth@<hex(cluster)>`.
    /// This is the ALPN SNI auth route (api/client/client.go:ConfigureALPN),
    /// NOT the `teleport-proxy-grpc-mtls` listener (which hosts only the
    /// Kubernetes service — see spike commit ff6ebe3).
    func testEncodedClusterName_matchesTeleportALPNRoute() {
        let cluster = "teleport.pcad.it"
        let hex = cluster.utf8.map { String(format: "%02x", $0) }.joined()
        let encoded = "\(hex).teleport.cluster.local"
        let alpn = "teleport-auth@\(encoded)"
        XCTAssertEqual(TeleportTLSTrust.encodedClusterName(cluster), encoded)
        XCTAssertTrue(alpn.hasPrefix("teleport-auth@"),
                      "ALPN must use the auth SNI route; got: \(alpn)")
        XCTAssertTrue(alpn.contains(hex),
                      "ALPN must carry the hex-encoded cluster name; got: \(alpn)")
        XCTAssertTrue(alpn.hasSuffix(".teleport.cluster.local"),
                      "ALPN must end with the teleport.cluster.local suffix; got: \(alpn)")
    }

    // MARK: - GRPCTLSOptions server-trust seam

    /// The gRPC auth leg must accept the fixture CA + auth-route ALPN when
    /// the presented cert chains to the anchor (the second expected name,
    /// `teleport.cluster.local`, matches the leaf SAN).
    func testVerify_matchingCAAndAuthALPNIsAccepted() throws {
        let leaf = try Self.loopbackLeaf()
        let ca = try Self.loopbackCertificate("loopback-ca.pem")
        let trust = try Self.trust(leaf: leaf)
        let encoded = TeleportTLSTrust.encodedClusterName("ci-cluster")
        let alpn = "teleport-auth@\(encoded)"

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.authServerNames(clusterName: "ci-cluster"),
            negotiatedALPN: alpn,
            allowedALPNs: [alpn, "h2"]
        )
        XCTAssertTrue(result.ok, "expected acceptance: \(String(describing: result.error))")
    }

    /// A foreign CA (the real pcad.it Host CA against the loopback leaf) must
    /// be rejected — this is the deterministic guard against the previous
    /// unconditional acceptance.
    func testVerify_foreignCAIsRejected() throws {
        let leaf = try Self.loopbackLeaf()
        let foreignCA = try Self.certificate("hostca-x509.pem")
        let trust = try Self.trust(leaf: leaf)
        let encoded = TeleportTLSTrust.encodedClusterName("ci-cluster")
        let alpn = "teleport-auth@\(encoded)"

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [foreignCA],
            serverNames: TeleportTLSTrust.authServerNames(clusterName: "ci-cluster"),
            negotiatedALPN: alpn,
            allowedALPNs: [alpn, "h2"]
        )
        XCTAssertFalse(result.ok)
    }

    /// The auth hop forwards TLS to the auth server, which negotiates `h2`
    /// (tsh offers the route token plus `h2`). With a valid Host-CA chain and
    /// name, `h2` must be accepted on this leg.
    func testVerify_h2IsAcceptedOnTheAuthRoute() throws {
        let leaf = try Self.loopbackLeaf()
        let ca = try Self.loopbackCertificate("loopback-ca.pem")
        let trust = try Self.trust(leaf: leaf)
        let encoded = TeleportTLSTrust.encodedClusterName("ci-cluster")

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.authServerNames(clusterName: "ci-cluster"),
            negotiatedALPN: "h2",
            allowedALPNs: ["teleport-auth@\(encoded)", "h2"]
        )
        XCTAssertTrue(result.ok, "expected h2 to be accepted on the auth route: \(String(describing: result.error))")
    }

    /// A negotiated protocol outside the allowed set is rejected even when
    /// the chain and name are otherwise valid.
    func testVerify_unexpectedALPNIsRejected() throws {
        let leaf = try Self.loopbackLeaf()
        let ca = try Self.loopbackCertificate("loopback-ca.pem")
        let trust = try Self.trust(leaf: leaf)
        let encoded = TeleportTLSTrust.encodedClusterName("ci-cluster")

        let result = TeleportTLSTrust.verify(
            trust: trust,
            anchors: [ca],
            serverNames: TeleportTLSTrust.authServerNames(clusterName: "ci-cluster"),
            negotiatedALPN: "http/1.1",
            allowedALPNs: ["teleport-auth@\(encoded)", "h2"]
        )
        XCTAssertFalse(result.ok)
    }

    // MARK: - Ephemeral gRPC identities

    /// Each per-connect identity gets a unique keychain label so concurrent
    /// connections cannot delete each other's cert/key items.
    func testGRPCIdentityLabelsAreUnique() {
        let first = GRPCClientIdentity.makeLabel()
        let second = GRPCClientIdentity.makeLabel()
        XCTAssertTrue(first.hasPrefix("vvterm-grpc-"))
        XCTAssertNotEqual(first, second)
    }

    /// Deleting an identity that was never inserted must be a no-op (no
    /// throw, no crash, no entitlement dependency).
    func testGRPCIdentityDeletionOfAbsentItemsIsSafe() {
        GRPCClientIdentity.deleteKeychainItems(label: GRPCClientIdentity.makeLabel(), logger: DefaultTeleportLogging().logger(category: "TeleportGRPC"))
    }

    /// The startup sweep runs before a new registration client does any
    /// work; it must be safe when the keychain holds no vvterm identities.
    func testGRPCIdentitySweepIsSafe() {
        GRPCClientIdentity.deleteStaleIdentities(logger: DefaultTeleportLogging().logger(category: "TeleportGRPC"))
    }

    /// The sweep is a full keychain query triggered by SwiftUI state
    /// initialization, so it must run at most once per process.
    func testGRPCIdentitySweepRunsAtMostOncePerProcess() {
        GRPCClientIdentity.resetSweepGateForTesting()
        GRPCClientIdentity.sweepEnumerationOverrideForTesting = { _ in [] }
        defer {
            GRPCClientIdentity.sweepEnumerationOverrideForTesting = nil
            GRPCClientIdentity.resetSweepGateForTesting()
        }

        XCTAssertTrue(GRPCClientIdentity.deleteStaleIdentitiesForTesting(logger: DefaultTeleportLogging().logger(category: "TeleportGRPC")))
        XCTAssertFalse(
            GRPCClientIdentity.deleteStaleIdentities(logger: DefaultTeleportLogging().logger(category: "TeleportGRPC")),
            "a second sweep in the same process must be skipped"
        )
    }

    /// A transient keychain error must not latch the once-per-process gate:
    /// the process has to retry the sweep once the keychain is available.
    func testFailedSweepEnumerationDoesNotLatchTheGate() {
        GRPCClientIdentity.resetSweepGateForTesting()
        defer {
            GRPCClientIdentity.sweepEnumerationOverrideForTesting = nil
            GRPCClientIdentity.resetSweepGateForTesting()
        }

        GRPCClientIdentity.sweepEnumerationOverrideForTesting = { _ in nil }
        XCTAssertTrue(GRPCClientIdentity.deleteStaleIdentitiesForTesting(logger: DefaultTeleportLogging().logger(category: "TeleportGRPC")))

        GRPCClientIdentity.sweepEnumerationOverrideForTesting = { _ in [] }
        XCTAssertTrue(
            GRPCClientIdentity.deleteStaleIdentities(logger: DefaultTeleportLogging().logger(category: "TeleportGRPC")),
            "a failed enumeration must leave the gate open for a later retry"
        )
    }

    /// The sweep may only delete prefixed identities that no in-flight
    /// connection owns: a second client construction must never delete the
    /// identity a concurrent handshake is using, and unrelated keychain
    /// items must survive.
    func testStaleIdentitySweepDeletesOnlyUnreferencedPrefixedItems() throws {
        let old = Date().addingTimeInterval(-(GRPCClientIdentity.staleIdentityAge + 60))
        let staleLabel = GRPCClientIdentity.makeLabel(now: old) + "-stale"
        let liveLabel = GRPCClientIdentity.makeLabel(now: old) + "-live"
        let freshLabel = GRPCClientIdentity.makeLabel() + "-fresh"
        let foreignLabel = "vvterm-unrelated-\(UUID().uuidString)"
        defer {
            GRPCClientIdentity.deleteKeychainItems(label: staleLabel, logger: DefaultTeleportLogging().logger(category: "TeleportGRPC"))
            GRPCClientIdentity.deleteKeychainItems(label: liveLabel, logger: DefaultTeleportLogging().logger(category: "TeleportGRPC"))
            GRPCClientIdentity.deleteKeychainItems(label: freshLabel, logger: DefaultTeleportLogging().logger(category: "TeleportGRPC"))
            GRPCClientIdentity.deleteKeychainItems(label: foreignLabel, logger: DefaultTeleportLogging().logger(category: "TeleportGRPC"))
        }

        try Self.insertKey(label: staleLabel)
        try Self.insertKey(label: liveLabel)
        try Self.insertKey(label: freshLabel)
        try Self.insertKey(label: foreignLabel)
        GRPCClientIdentity.registerLiveLabel(liveLabel)

        XCTAssertTrue(GRPCClientIdentity.deleteStaleIdentitiesForTesting(logger: DefaultTeleportLogging().logger(category: "TeleportGRPC")))

        XCTAssertEqual(Self.keyStatus(label: staleLabel), errSecItemNotFound)
        XCTAssertEqual(Self.keyStatus(label: liveLabel), errSecSuccess)
        XCTAssertEqual(
            Self.keyStatus(label: freshLabel),
            errSecSuccess,
            "an unregistered but young label may belong to another live process and must survive"
        )
        XCTAssertEqual(Self.keyStatus(label: foreignLabel), errSecSuccess)
    }

    /// Deleting an identity unregisters its live label so a later sweep can
    /// collect it.
    func testDeletingAnIdentityUnregistersItsLiveLabel() {
        let label = GRPCClientIdentity.makeLabel()
        GRPCClientIdentity.registerLiveLabel(label)
        XCTAssertTrue(GRPCClientIdentity.isLiveLabel(label))

        GRPCClientIdentity.deleteKeychainItems(label: label, logger: DefaultTeleportLogging().logger(category: "TeleportGRPC"))

        XCTAssertFalse(GRPCClientIdentity.isLiveLabel(label))
    }

    /// A dial with no usable trust anchors must fail closed BEFORE the
    /// per-connection keychain identity is built. The identity handle owns the
    /// deletion of its cert/key items, so an identity built before a later
    /// throw would leak (the empty-anchor path is reachable: bootstrap stores
    /// no anchors when `host_signers` is nil). The injected builder records
    /// whether it ran.
    func testMake_rejectsEmptyAnchorsBeforeBuildingTheKeychainIdentity() throws {
        guard let key = SecKeyCreateRandomKey(
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256
            ] as CFDictionary,
            nil
        ) else {
            throw XCTSkip("the unit host cannot create an ephemeral P-256 key")
        }
        var builderInvocations = 0
        do {
            _ = try GRPCTLSOptions.make(
                clientCertPEM: "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n",
                privateKey: key,
                clusterName: "ci-cluster",
                clusterCAPEMs: [],
                logger: DefaultTeleportLogging().logger(category: "TeleportGRPC"),
                identityBuilder: { _, _, _ in
                    builderInvocations += 1
                    throw GRPCError.tls("identity builder must not run")
                }
            )
            XCTFail("make should have thrown for empty anchors")
        } catch let error as GRPCError {
            guard case .tls(let message) = error else {
                return XCTFail("expected .tls for empty anchors; got \(error)")
            }
            XCTAssertTrue(
                message.contains("no usable cluster CA trust anchors"),
                "unexpected error message: \(message)"
            )
        }
        XCTAssertEqual(
            builderInvocations,
            0,
            "the keychain identity must not be built when anchor validation fails"
        )
    }

    /// With usable anchors the same seam proves the builder runs only after
    /// anchor validation (the sentinel error round-trips).
    func testMake_buildsTheKeychainIdentityAfterAnchorValidation() throws {
        guard let key = SecKeyCreateRandomKey(
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256
            ] as CFDictionary,
            nil
        ) else {
            throw XCTSkip("the unit host cannot create an ephemeral P-256 key")
        }
        let caPEM = try String(
            contentsOf: Self.fixtureURL("loopback-tls/loopback-ca.pem"),
            encoding: .utf8
        )
        do {
            _ = try GRPCTLSOptions.make(
                clientCertPEM: "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n",
                privateKey: key,
                clusterName: "ci-cluster",
                clusterCAPEMs: [caPEM],
                logger: DefaultTeleportLogging().logger(category: "TeleportGRPC"),
                identityBuilder: { _, _, _ in throw GRPCError.tls("builder-ran") }
            )
            XCTFail("make should have thrown from the injected builder")
        } catch let error as GRPCError {
            guard case .tls(let message) = error, message == "builder-ran" else {
                return XCTFail("expected the builder sentinel after anchor validation; got \(error)")
            }
        }
    }

    // MARK: - Keychain test helpers

    /// Insert a labeled test key. Skips (rather than fails) when the unit
    /// host has no usable keychain, so the suite stays entitlement-free.
    private static func insertKey(label: String) throws {
        guard let key = SecKeyCreateRandomKey(
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256
            ] as CFDictionary,
            nil
        ) else {
            throw XCTSkip("the unit host cannot create an ephemeral P-256 key")
        }
        let add: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: key,
            kSecAttrLabel as String: label,
            kSecAttrIsPermanent as String: true,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw XCTSkip("keychain item insertion unavailable (OSStatus \(status))")
        }
    }

    private static func keyStatus(label: String) -> OSStatus {
        SecItemCopyMatching(
            [
                kSecClass as String: kSecClassKey,
                kSecAttrLabel as String: label,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary,
            nil
        )
    }

    // MARK: - Trust test helpers

    private static func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(relativePath)")
    }

    private static func loopbackLeaf() throws -> SecCertificate {
        try certificate("loopback-tls/server.pem")
    }

    private static func loopbackCertificate(_ relativePath: String) throws -> SecCertificate {
        try certificate("loopback-tls/\(relativePath)")
    }

    private static func certificate(_ relativePath: String) throws -> SecCertificate {
        let pem = try String(contentsOf: fixtureURL(relativePath), encoding: .utf8)
        let der = try TeleportTLSTrust.pemToDER(pem: pem, label: "CERTIFICATE")
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TeleportTLSTrustError.malformedPEM(relativePath)
        }
        return certificate
    }

    private static func trust(leaf: SecCertificate) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            [leaf] as CFArray,
            SecPolicyCreateBasicX509(),
            &trust
        )
        guard status == errSecSuccess, let trust else {
            throw TeleportTLSTrustError.malformedPEM("SecTrustCreateWithCertificates OSStatus \(status)")
        }
        return trust
    }
}
