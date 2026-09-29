// SPDX-License-Identifier: MIT
//
//  TeleportLoginClientErrorShapeTests.swift
//  VVTermTests
//
//  Issue #236: a non-200 `login/begin` / `login/finish` must surface as a
//  structured `HeadlessError.http(status:body:)` — never as a free-form
//  `GRPCError.http2("<op> HTTP <status>: <body>")` string, which loses the
//  status in the log (`wireFailure` renders the bare case `http2`) and routes
//  the UI to `.unknown` instead of `.server` with the server's message.
//
//  Why the loopback section is the discriminating evidence: the
//  mock-scripted tests script `HeadlessError.http` *into* the mock — the
//  shape production should throw — so they are green while the live client
//  packs both fields into one string. That is exactly how the defect
//  survived. The `…RealClient…` tests below drive the **real**
//  `LiveTeleportHTTPClient` (the client `TeleportComposition` injects) and
//  the Infrastructure `TeleportHTTPClient` twin over the in-process
//  `LoopbackHTTPServer` from `HeadlessLoginWireTests`, so a reintroduced
//  `GRPCError.http2` packing reddens them.
//
//  The coordinator-driven end-to-end variant is infeasible and not
//  attempted: `TeleportLoginCoordinator.begin` hardcodes
//  `URL(string: "https://\(cluster.host)")`, so the plain-HTTP loopback
//  harness cannot be reached through it. The chain is bracketed by
//  (1) these real-client tests — the client throws the structured type,
//  (2) the `…CoordinatorMaps…` tests below — the structured type maps to
//  `.failed(.server("HTTP <status>: <body>"))`, and (3) the redaction tests
//  — the coordinator's catch renders the status without the body.
//

#if DEBUG
import Foundation
import XCTest
@testable import VVTerm

#if canImport(Network)

@MainActor
final class TeleportLoginClientErrorShapeTests: XCTestCase {

    // MARK: - Fixtures

    private func loopbackURL(_ server: LoopbackHTTPServer) -> URL {
        URL(string: "http://127.0.0.1:\(server.port)")!
    }

    /// A publicly constructible WebAuthn assertion — the only input the
    /// clients need for the `login/finish` POST body.
    private func makeAssertion() -> CredentialAssertionResponse {
        CredentialAssertionResponse(
            id: "aWQ",
            type: "public-key",
            rawId: "cmF3",
            response: AuthenticatorAssertionResponse(
                clientDataJSON: "Y2Rq",
                authenticatorData: "YWRhdGE",
                signature: "c2ln",
                userHandle: nil
            )
        )
    }

    private func makeServer(
        status: Int,
        body: Data
    ) throws -> LoopbackHTTPServer {
        try LoopbackHTTPServer(
            response: LoopbackHTTPServer.Response(statusCode: status, body: body)
        )
    }

    // MARK: - Real clients over the loopback harness (§4.3)

    /// The production client (`TeleportComposition` injects
    /// `LiveTeleportHTTPClient`) must throw the structured error, keeping the
    /// status and the body separate.
    func testRealLiveClientLoginBegin403_throwsStructuredHTTPFailure() async throws {
        let marker = "login-begin-server-body-marker"
        let server = try makeServer(status: 403, body: Data(marker.utf8))
        defer { server.stop() }

        do {
            _ = try await LiveTeleportHTTPClient().loginBegin(baseURL: loopbackURL(server))
            XCTFail("a non-200 login/begin must throw")
        } catch let error as HeadlessError {
            guard case .http(let status, let body) = error else {
                XCTFail("expected HeadlessError.http, got \(error)")
                return
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(body, marker, "the server body must survive in the structured error")

            // The exact log payload the coordinator renders from this thrown
            // error (`TeleportLoginCoordinator`'s `login/begin` catch calls
            // `TeleportErrorRedaction.wireFailure`): status present, body
            // absent. This is the loopback 403 → log-line check.
            XCTAssertEqual(TeleportErrorRedaction.wireFailure(error), "HTTP 403")
            XCTAssertFalse(
                TeleportErrorRedaction.wireFailure(error).contains(marker),
                "the server body must not reach a log payload"
            )
        } catch {
            XCTFail("expected HeadlessError.http, got \(type(of: error)): \(error)")
        }
    }

    /// The production client's `login/finish` site.
    func testRealLiveClientLoginFinish500_throwsStructuredHTTPFailure() async throws {
        let marker = "login-finish-server-body-marker"
        let server = try makeServer(status: 500, body: Data(marker.utf8))
        defer { server.stop() }

        do {
            _ = try await LiveTeleportHTTPClient().loginFinish(
                baseURL: loopbackURL(server),
                assertion: makeAssertion(),
                sshPubKey: Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedKey ci\n".utf8),
                ttl: 3_600_000_000_000
            )
            XCTFail("a non-200 login/finish must throw")
        } catch let error as HeadlessError {
            guard case .http(let status, let body) = error else {
                XCTFail("expected HeadlessError.http, got \(error)")
                return
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, marker)
            XCTAssertEqual(TeleportErrorRedaction.wireFailure(error), "HTTP 500")
        } catch {
            XCTFail("expected HeadlessError.http, got \(type(of: error)): \(error)")
        }
    }

    /// The Infrastructure twin (`TeleportHTTPClient`), for consistency: its
    /// login helpers must throw the same structured shape.
    func testRealTwinClientLoginBegin403_throwsStructuredHTTPFailure() async throws {
        let marker = "twin-login-begin-server-body-marker"
        let server = try makeServer(status: 403, body: Data(marker.utf8))
        defer { server.stop() }

        do {
            _ = try await TeleportHTTPClient(baseURL: loopbackURL(server)).loginBegin()
            XCTFail("a non-200 login/begin must throw")
        } catch let error as HeadlessError {
            guard case .http(let status, let body) = error else {
                XCTFail("expected HeadlessError.http, got \(error)")
                return
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(body, marker)
        } catch {
            XCTFail("expected HeadlessError.http, got \(type(of: error)): \(error)")
        }
    }

    /// The twin's `login/finish` site.
    func testRealTwinClientLoginFinish500_throwsStructuredHTTPFailure() async throws {
        let marker = "twin-login-finish-server-body-marker"
        let server = try makeServer(status: 500, body: Data(marker.utf8))
        defer { server.stop() }

        do {
            _ = try await TeleportHTTPClient(baseURL: loopbackURL(server)).loginFinish(
                assertion: makeAssertion(),
                sshPubKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedKey ci",
                ttl: 3_600_000_000_000
            )
            XCTFail("a non-200 login/finish must throw")
        } catch let error as HeadlessError {
            guard case .http(let status, let body) = error else {
                XCTFail("expected HeadlessError.http, got \(error)")
                return
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, marker)
        } catch {
            XCTFail("expected HeadlessError.http, got \(type(of: error)): \(error)")
        }
    }

    /// A non-UTF-8 body must not crash or leak raw bytes: it becomes the
    /// `<binary>` marker both clients already share with `HeadlessLogin.post`.
    func testRealLiveClientLoginBegin403WithNonUTF8Body_reportsBinaryBody() async throws {
        let server = try makeServer(status: 403, body: Data([0xFF, 0xFE, 0xFD]))
        defer { server.stop() }

        do {
            _ = try await LiveTeleportHTTPClient().loginBegin(baseURL: loopbackURL(server))
            XCTFail("a non-200 login/begin must throw")
        } catch let error as HeadlessError {
            guard case .http(let status, let body) = error else {
                XCTFail("expected HeadlessError.http, got \(error)")
                return
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(body, "<binary>")
        } catch {
            XCTFail("expected HeadlessError.http, got \(type(of: error)): \(error)")
        }
    }

    /// The twin's non-UTF-8 body, same marker.
    func testRealTwinClientLoginBegin403WithNonUTF8Body_reportsBinaryBody() async throws {
        let server = try makeServer(status: 403, body: Data([0xFF, 0xFE, 0xFD]))
        defer { server.stop() }

        do {
            _ = try await TeleportHTTPClient(baseURL: loopbackURL(server)).loginBegin()
            XCTFail("a non-200 login/begin must throw")
        } catch let error as HeadlessError {
            guard case .http(let status, let body) = error else {
                XCTFail("expected HeadlessError.http, got \(error)")
                return
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(body, "<binary>")
        } catch {
            XCTFail("expected HeadlessError.http, got \(type(of: error)): \(error)")
        }
    }

    /// A 200 with a non-JSON body keeps the decode branch (`.`decode`), not
    /// the status branch: the fix must not repack a decode failure as an
    /// HTTP-status failure.
    func testRealLiveClientLoginBegin200NonJSON_throwsGRPCErrorDecode() async throws {
        let server = try makeServer(status: 200, body: Data("not json".utf8))
        defer { server.stop() }

        do {
            _ = try await LiveTeleportHTTPClient().loginBegin(baseURL: loopbackURL(server))
            XCTFail("a non-JSON login/begin response must throw")
        } catch let error as GRPCError {
            guard case .decode(let message) = error else {
                XCTFail("expected GRPCError.decode, got \(error)")
                return
            }
            XCTAssertTrue(
                message.hasPrefix("login/begin response"),
                "the decode message must stay descriptive: \(message)"
            )
        } catch {
            XCTFail("expected GRPCError.decode, got \(type(of: error)): \(error)")
        }
    }

    /// Site 5 (#236): the twin's 200-with-empty-cert decode failure is
    /// body-free — it must not embed a server-supplied body snippet.
    func testRealTwinClientLoginFinish200EmptyCert_throwsBodyFreeDecodeError() async throws {
        let marker = "no-cert-body-marker"
        let body = Data(#"{"cert":"","marker":"\#(marker)"}"#.utf8)
        let server = try makeServer(status: 200, body: body)
        defer { server.stop() }

        do {
            _ = try await TeleportHTTPClient(baseURL: loopbackURL(server)).loginFinish(
                assertion: makeAssertion(),
                sshPubKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedKey ci",
                ttl: 3_600_000_000_000
            )
            XCTFail("a 200 with an empty cert must throw")
        } catch let error as HeadlessError {
            guard case .decode(let message) = error else {
                XCTFail("expected HeadlessError.decode, got \(error)")
                return
            }
            XCTAssertEqual(message, "login/finish: no cert")
            XCTAssertFalse(
                message.contains(marker),
                "the decode message must not embed the response body: \(message)"
            )
        } catch {
            XCTFail("expected HeadlessError.decode, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - State mapping through the coordinator's public surface (§4.2)
    //
    // `mapHTTPError` is private, so these drive `begin(cluster:)` and read
    // `state`. They are contract tests: they script the structured error the
    // real client now throws and pin the mapping the UI relies on
    // ("Teleport Server Error" + the server's message verbatim). They are
    // green before the fix too — the loopback section above is the
    // discriminating evidence.

    func testCoordinatorLoginBeginHTTPFailure_mapsToServerStateWithTheVerbatimBody() async throws {
        let marker = "login-begin-mapping-marker"
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = Self.makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginError = HeadlessError.http(status: 403, body: marker)

        let coordinator = TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: signer,
            webAuthnBuilder: ScriptedWebAuthnBuilderStub(),
            keyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .failed(.server("HTTP 403: \(marker)")))
    }

    func testCoordinatorLoginFinishHTTPFailure_mapsToServerStateWithTheVerbatimBody() async throws {
        let marker = "login-finish-mapping-marker"
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = Self.makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginFinishError = HeadlessError.http(status: 500, body: marker)

        let coordinator = TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: signer,
            webAuthnBuilder: ScriptedWebAuthnBuilderStub(),
            keyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .failed(.server("HTTP 500: \(marker)")))
    }

    // MARK: - Tripwire (§4.4)

    /// A tripwire, not a proof: the literal `GRPCError.http2("` must not
    /// reappear anywhere in `VVTerm/Features/Teleport`. The quote anchor
    /// admits `GRPCClient.swift`'s variable-arg construction (where `.http2`
    /// is the right case for a genuine HTTP/2-layer failure) and catches a
    /// reintroduced literal status+body packing.
    ///
    /// Known defeats (why this is a tripwire): an aliased factory, a renamed
    /// helper, a multi-line call (the quote lands on the next line), or a
    /// packing helper hoisted out of the feature. The scan asserts it found
    /// the feature's files first, so a wrong path derivation fails loudly
    /// instead of passing vacuously.
    func testNoLiteralGRPCErrorHTTP2PackingRemainsInTheTeleportFeature() throws {
        let needle = "GRPCError.http2(\""
        let files = try Self.teleportFeatureSourceFiles()
        // Coverage guard: a path-derivation mistake must fail loudly instead
        // of scanning nothing and passing vacuously.
        XCTAssertTrue(
            files.contains { $0.lastPathComponent == "TeleportLiveCoordinators.swift" },
            "the tripwire scan must cover VVTerm/Features/Teleport"
        )
        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains(needle) {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(
            offenders,
            [],
            "a literal GRPCError.http2(\"…) status+body packing reappeared; the login path must throw HeadlessError.http (#236)"
        )
    }

    private static func teleportFeatureSourceFiles() throws -> [URL] {
        // Four deletions: file → Teleport/ → Features/ → VVTermTests/ → repo root.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let featureRoot = repositoryRoot.appendingPathComponent("VVTerm/Features/Teleport")
        let enumerator = FileManager.default.enumerator(
            at: featureRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        return files
    }

    // MARK: - Helpers

    private static func makeRegisteredKeyRing(
        clusterId: UUID,
        credentialID: Data
    ) -> MockTeleportKeyRing {
        let keyRing = MockTeleportKeyRing()
        keyRing.seed(
            clusterId: clusterId,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: credentialID,
                userHandle: Data("user-handle".utf8),
                deviceName: "test-device"
            )
        )
        return keyRing
    }

    /// A WebAuthn builder that returns a plausible scripted assertion so the
    /// coordinator reaches `login/finish`.
    private final class ScriptedWebAuthnBuilderStub: TeleportWebAuthnBuilding {
        func register(
            origin: String,
            rpID: String,
            challenge: Data,
            credentialID: Data,
            publicKeyRaw: Data,
            signer: any WebAuthnSigner
        ) throws -> CredentialCreationResponse {
            CredentialCreationResponse(
                id: "credential-id",
                type: "public-key",
                rawId: Data([1, 2, 3, 4]).base64URLEncodedString(),
                response: AuthenticatorAttestationResponse(
                    clientDataJSON: Data([1, 2, 3]).base64URLEncodedString(),
                    attestationObject: Data([4, 5, 6]).base64URLEncodedString()
                )
            )
        }

        func login(
            origin: String,
            rpID: String,
            challenge: Data,
            credentialID: Data,
            userHandle: Data?,
            signer: any WebAuthnSigner
        ) throws -> CredentialAssertionResponse {
            CredentialAssertionResponse(
                id: "credential-id",
                type: "public-key",
                rawId: Data([1, 2, 3, 4]).base64URLEncodedString(),
                response: AuthenticatorAssertionResponse(
                    clientDataJSON: Data([1, 2, 3]).base64URLEncodedString(),
                    authenticatorData: Data([4, 5, 6]).base64URLEncodedString(),
                    signature: Data([7, 8, 9]).base64URLEncodedString(),
                    userHandle: Data("user-handle".utf8).base64URLEncodedString()
                )
            )
        }
    }
}

#endif
#endif
