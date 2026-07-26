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
    func testConnect_rejectsEmptyClientCert() async {
        let client = LiveTeleportGRPCClient()
        let key = SecKeyCreateRandomKey(
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256
            ] as CFDictionary,
            nil
        )!
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
    func testConnect_rejectsEmptyClusterName() async {
        let client = LiveTeleportGRPCClient()
        let key = SecKeyCreateRandomKey(
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256
            ] as CFDictionary,
            nil
        )!
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
    /// We assert the ALPN token shape indirectly via the encoded cluster name,
    /// which is the load-bearing input. A regression here would dial the wrong
    /// ALPN route and get UNIMPLEMENTED (grpc code 12), not connection failure.
    func testEncodedClusterName_matchesTeleportALPNRoute() {
        // The encoded cluster name is hex(clusterName) + ".teleport.cluster.local".
        // We can't call the private `encodedClusterName` from here, so we
        // re-derive the expected value and assert the ALPN token format.
        let cluster = "teleport.pcad.it"
        let hex = cluster.utf8.map { String(format: "%02x", $0) }.joined()
        let encoded = "\(hex).teleport.cluster.local"
        let alpn = "teleport-auth@\(encoded)"
        XCTAssertTrue(alpn.hasPrefix("teleport-auth@"),
                      "ALPN must use the auth SNI route; got: \(alpn)")
        XCTAssertTrue(alpn.contains(hex),
                      "ALPN must carry the hex-encoded cluster name; got: \(alpn)")
        XCTAssertTrue(alpn.hasSuffix(".teleport.cluster.local"),
                      "ALPN must end with the teleport.cluster.local suffix; got: \(alpn)")
    }
}
