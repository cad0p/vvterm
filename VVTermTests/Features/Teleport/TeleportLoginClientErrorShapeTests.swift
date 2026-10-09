// SPDX-License-Identifier: MIT
//
//  TeleportLoginClientErrorShapeTests.swift
//  VVTermTests
//
//  Host-only coverage for issue #236: the kept production adapter
//  (`LiveTeleportHTTPClient`, constructed by `TeleportComposition`) must throw
//  the structured `HeadlessError.http(status:body:)` for a non-200
//  `login/begin` / `login/finish` — never degrades into a free-form
//  `GRPCError.http2("<op> HTTP <status>: <body>")` string, which loses the
//  status in the log and routes the UI to `.unknown` instead of `.server`
//  with the server's message.
//
//  The package owns the twin/coordinator suites (`TeleportPackageTests`,
//  including the wire-failure rendering); this file drives the **real** host
//  client over an in-process `LoopbackHTTPServer` so a reintroduced packing
//  reddens a host test, and keeps the host-source tripwire.
//
//  The coordinator-driven end-to-end variant is infeasible and not
//  attempted: `TeleportLoginCoordinator.begin` hardcodes
//  `URL(string: "https://\(cluster.host)")`, so the plain-HTTP loopback
//  harness cannot be reached through it.
//

#if DEBUG
import Foundation
import XCTest
import TeleportCore
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

    // MARK: - The real host client over the loopback harness

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
        } catch {
            XCTFail("expected HeadlessError.http, got \(type(of: error)): \(error)")
        }
    }

    /// A non-UTF-8 body must not crash or leak raw bytes: it becomes the
    /// `<binary>` marker the host client already shares with `HeadlessLogin.post`.
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

    /// A 200 with a non-JSON body keeps the decode branch (`.decode`), not
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

    // MARK: - Tripwire

    /// A tripwire, not a proof: the literal `GRPCError.http2("` must not
    /// reappear anywhere in the host `VVTerm/Features/Teleport`. The quote
    /// anchor admits a variable-arg construction (where `.http2` is the right
    /// case for a genuine HTTP/2-layer failure) and catches a reintroduced
    /// literal status+body packing.
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
}

#endif
#endif
