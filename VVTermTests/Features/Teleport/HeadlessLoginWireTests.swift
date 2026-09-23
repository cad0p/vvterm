// SPDX-License-Identifier: MIT
//
//  HeadlessLoginWireTests.swift
//  VVTermTests
//
//  Locks the Phase-1 headless login wire contract:
//    - the POST body shape (Go JSON tags, std-base64 []byte fields, ns TTL,
//      compatibility);
//    - the response decode (domain_name / checking_keys / tls_certs);
//    - the HeadlessError mapping (transport / http / decode / noCert /
//      missingField);
//    - the URLSession behavior of `HeadlessLogin.post` (URL path, 200-only,
//      `.transport(localizedDescription)`, `.decode`) against a real loopback
//      HTTP server, so the actual shared `TeleportTrustSession.session` path
//      is exercised;
//    - the shared trust session's request/resource timeout constants
//      (200 s >= the 180 s server-side block). This pins the shared session
//      configuration, not which session `post` uses — making that link
//      observable is a rewrite acceptance item.
//
//  Note: `URLProtocol.registerClass` does NOT intercept `URLSession` on this
//  OS (verified: a fresh ephemeral session still hit the network, while an
//  explicit `configuration.protocolClasses` stub works). Since
//  `HeadlessLogin.post` uses the shared session — which has no custom
//  protocolClasses — the post tests run a loopback NWListener HTTP server
//  instead of a URLProtocol stub. That exercises the real network path.
//
//  `HeadlessLogin.post` creates a local `URLSessionConfiguration` that is dead
//  code today (it never builds a session from it) — the tests pin the
//  effective behavior of the shared session instead of that dead config.

import XCTest
@testable import VVTerm
import Foundation
#if canImport(Network)
import Network
#endif

// MARK: - Loopback HTTP server

#if canImport(Network)

enum LoopbackHTTPServerError: Error {
    case listenerStart
}

/// A one-shot in-process plain-HTTP server for the shared-session post tests.
/// Accepts a single request, captures it, and replies with the scripted
/// response.
final class LoopbackHTTPServer {

    struct Response {
        var statusCode: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()
    }

    struct CapturedRequest {
        var method: String = ""
        var path: String = ""
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private(set) var port: UInt16 = 0

    private let listener: NWListener
    private let response: Response
    private let queue = DispatchQueue(label: "vvterm.tests.loopback-http")
    private let lock = NSLock()
    private var captured: CapturedRequest?
    private var connections: [NWConnection] = []

    init(response: Response) throws {
        self.response = response
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock()
            self.connections.append(connection)
            self.lock.unlock()
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success,
              listener.state == .ready,
              let assignedPort = listener.port else {
            listener.cancel()
            throw LoopbackHTTPServerError.listenerStart
        }
        self.port = assignedPort.rawValue
    }

    var request: CapturedRequest? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let openConnections = connections
        connections.removeAll()
        lock.unlock()
        for connection in openConnections {
            connection.cancel()
        }
    }

    deinit {
        listener.cancel()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let request = Self.parse(buffer) {
                self.lock.lock()
                self.captured = request
                self.lock.unlock()
                self.sendResponse(on: connection)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private static func parse(_ data: Data) -> CapturedRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let availableBody = Data(data[bodyStart...])
        guard availableBody.count >= contentLength else { return nil }

        return CapturedRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: availableBody.prefix(contentLength)
        )
    }

    private func sendResponse(on connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        var head = "HTTP/1.1 \(response.statusCode) \(Self.reason(response.statusCode))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 201: return "Created"
        case 401: return "Unauthorized"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

#endif

// MARK: - URLProtocol stub (explicit protocolClasses only)

/// Records requests and returns a scripted 200 response. `URLProtocol`
/// registration via `URLProtocol.registerClass` does not intercept
/// `URLSession` on this OS, but an explicit `configuration.protocolClasses`
/// stub does — which is exactly how a stub session is built here.
final class HeadlessLoginRecordingProtocol: URLProtocol {
    static let lock = NSLock()
    static var recordedURLs: [URL] = []

    static func reset() {
        lock.lock()
        recordedURLs = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.lock()
            Self.recordedURLs.append(url)
            Self.lock.unlock()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"cert\":\"Q0VSVA==\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class HeadlessLoginWireTests: XCTestCase {

    /// Newline-free authorized_keys line — the shape the app passes in. Its
    /// UTF-8 + "\n" base64 contains `+` and `==` padding, which pins std
    /// base64 (URL-safe would be `-`/`_` and unpadded).
    static let authorizedKeyLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedKey >"
    static let authorizedKeyB64 =
        "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUdlbmVyYXRlZEtleSA+Cg=="

    private let baseURL = URL(string: "https://teleport.example.test")!

    // MARK: - Request JSON

    func testRequestJSON_matchesTheTeleportGoWireShape() throws {
        let req = HeadlessLoginReq(
            user: "pier",
            headlessAuthenticationID: "2c2c2c2c-1111-5555-8888-abcdefabcdef",
            sshPubKey: Self.authorizedKeyB64,
            tlsPubKey: nil,
            ttl: 3_600_000_000_000,
            compatibility: ""
        )
        let data = try JSONEncoder().encode(req)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Go's `json:"tls_pub_key,omitempty"` omits the key when nil.
        XCTAssertEqual(
            Set(object.keys),
            ["user", "headless_id", "ssh_pub_key", "ttl", "compatibility"]
        )
        XCTAssertEqual(object["user"] as? String, "pier")
        XCTAssertEqual(
            object["headless_id"] as? String,
            "2c2c2c2c-1111-5555-8888-abcdefabcdef"
        )
        XCTAssertEqual(object["ssh_pub_key"] as? String, Self.authorizedKeyB64)
        // std base64, not base64url: `+`/`=` survive and the std decoder
        // round-trips the raw authorized_keys bytes (with the trailing \n).
        XCTAssertTrue(Self.authorizedKeyB64.contains("+"))
        XCTAssertTrue(Self.authorizedKeyB64.hasSuffix("=="))
        XCTAssertEqual(
            Data(base64Encoded: Self.authorizedKeyB64),
            Data((Self.authorizedKeyLine + "\n").utf8)
        )
        XCTAssertEqual(object["ttl"] as? NSNumber, NSNumber(value: 3_600_000_000_000))
        XCTAssertEqual(object["compatibility"] as? String, "")
    }

    func testRequestJSON_includesTlsPubKeyWhenProvided() throws {
        let req = HeadlessLoginReq(
            user: "pier",
            headlessAuthenticationID: "id",
            sshPubKey: Self.authorizedKeyB64,
            tlsPubKey: "VExTLVBFTQ==",
            ttl: 1,
            compatibility: "0"
        )
        let data = try JSONEncoder().encode(req)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["tls_pub_key"] as? String, "VExTLVBFTQ==")
        XCTAssertEqual(object["compatibility"] as? String, "0")
    }

    // MARK: - Response decode

    func testResponseDecode_mapsTheGoJSONTags() throws {
        let json = """
        {
          "cert": "Q0VSVA==",
          "tls_cert": "VExT",
          "host_signers": [
            {
              "domain_name": "teleport.pcad.it",
              "checking_keys": ["Y2hlY2s="],
              "tls_certs": ["dGxz"]
            }
          ]
        }
        """
        let resp = try JSONDecoder().decode(HeadlessLoginResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.cert, "Q0VSVA==")
        XCTAssertEqual(resp.tlsCert, "VExT")
        let signer = try XCTUnwrap(resp.hostSigners?.first)
        XCTAssertEqual(signer.clusterName, "teleport.pcad.it")
        XCTAssertEqual(signer.checkingKeys, ["Y2hlY2s="])
        XCTAssertEqual(signer.tlsCerts, ["dGxz"])
    }

    func testResponseDecode_leavesAbsentOptionalsNil() throws {
        let resp = try JSONDecoder().decode(
            HeadlessLoginResponse.self,
            from: Data("{}".utf8)
        )
        XCTAssertNil(resp.cert)
        XCTAssertNil(resp.tlsCert)
        XCTAssertNil(resp.hostSigners)
    }

    // MARK: - Error mapping

    func testErrorDescriptions_areTheFrozenStrings() {
        XCTAssertEqual(HeadlessError.transport("boom").errorDescription, "transport: boom")
        XCTAssertEqual(
            HeadlessError.http(status: 401, body: "denied").errorDescription,
            "HTTP 401: denied"
        )
        XCTAssertEqual(HeadlessError.decode("bad json").errorDescription, "decode: bad json")
        XCTAssertEqual(HeadlessError.noCert.errorDescription, "no cert in response")
        XCTAssertEqual(
            HeadlessError.missingField("cert").errorDescription,
            "missing field: cert"
        )
    }

    // MARK: - Real-session post tests (loopback HTTP server)

    func testPost_postsJSONToTheHeadlessLoginPathAndDecodes200() async throws {
        let server = try makeServer(
            .init(statusCode: 200, body: Data(#"{"cert":"Q0VSVA=="}"#.utf8))
        )
        defer { server.stop() }

        let resp = try await HeadlessLogin.post(
            baseURL: loopbackURL(server),
            req: HeadlessLoginReq(
                user: "pier",
                headlessAuthenticationID: "id-1",
                sshPubKey: Self.authorizedKeyB64,
                tlsPubKey: nil,
                ttl: 3_600_000_000_000,
                compatibility: ""
            )
        )
        XCTAssertEqual(resp.cert, "Q0VSVA==")

        let captured = try XCTUnwrap(server.request)
        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.path, "/webapi/headless/login")
        XCTAssertEqual(captured.headers["content-type"], "application/json")

        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
        XCTAssertEqual(sent["user"] as? String, "pier")
        XCTAssertEqual(sent["headless_id"] as? String, "id-1")
        XCTAssertEqual(sent["ssh_pub_key"] as? String, Self.authorizedKeyB64)
        XCTAssertEqual(sent["ttl"] as? NSNumber, NSNumber(value: 3_600_000_000_000))
    }

    func testPost_is200Only() async throws {
        let created = try makeServer(
            .init(statusCode: 201, body: Data(#"{"cert":"Q0VSVA=="}"#.utf8))
        )
        defer { created.stop() }
        do {
            _ = try await HeadlessLogin.post(baseURL: loopbackURL(created), req: Self.makeRequest())
            XCTFail("expected HeadlessError.http for a 201 response")
        } catch let error as HeadlessError {
            guard case .http(let status, let body) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(status, 201)
            XCTAssertEqual(body, #"{"cert":"Q0VSVA=="}"#)
        }

        let denied = try makeServer(.init(statusCode: 401, body: Data("denied".utf8)))
        defer { denied.stop() }
        do {
            _ = try await HeadlessLogin.post(baseURL: loopbackURL(denied), req: Self.makeRequest())
            XCTFail("expected HeadlessError.http for a 401 response")
        } catch let error as HeadlessError {
            XCTAssertEqual(error.errorDescription, "HTTP 401: denied")
        }
    }

    func testPost_mapsURLSessionErrorsToTransport() async throws {
        // Nothing listens on 127.0.0.1:1 (privileged port), so URLSession
        // fails. Assert the `.transport` case shape and that the underlying
        // URLSession message is surfaced; the exact text is locale- and
        // session-configuration-sensitive, so it is deliberately not pinned.
        let deadURL = URL(string: "http://127.0.0.1:1")!
        do {
            _ = try await HeadlessLogin.post(baseURL: deadURL, req: Self.makeRequest())
            XCTFail("expected HeadlessError.transport")
        } catch let error as HeadlessError {
            guard case .transport(let message) = error else {
                return XCTFail("expected .transport, got \(error)")
            }
            XCTAssertFalse(
                message.isEmpty,
                "transport must carry the underlying URLSession message"
            )
        }
    }

    func testPost_mapsInvalidJSONToDecode() async throws {
        let server = try makeServer(.init(statusCode: 200, body: Data("{not json".utf8)))
        defer { server.stop() }
        do {
            _ = try await HeadlessLogin.post(baseURL: loopbackURL(server), req: Self.makeRequest())
            XCTFail("expected HeadlessError.decode")
        } catch let error as HeadlessError {
            guard case .decode = error else {
                return XCTFail("expected .decode, got \(error)")
            }
        }
    }

    // MARK: - Session selection (the Phase-1b seam)

    func testPost_usesTheInjectedSession() async throws {
        HeadlessLoginRecordingProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeadlessLoginRecordingProtocol.self]
        let stubSession = URLSession(configuration: configuration)
        defer { stubSession.invalidateAndCancel() }

        let resp = try await HeadlessLogin.post(
            baseURL: baseURL,
            req: Self.makeRequest(),
            session: stubSession
        )

        XCTAssertEqual(resp.cert, "Q0VSVA==")
        XCTAssertEqual(
            HeadlessLoginRecordingProtocol.recordedURLs.map(\.absoluteString),
            ["https://teleport.example.test/webapi/headless/login"],
            "post must send the request through the injected session"
        )
    }

    func testPost_defaultsToTheSharedTrustSession() {
        // The production default must stay the shared trust session: it owns
        // the 200s timeouts the 180s blocking POST needs. Pinning the default
        // value keeps a swap to URLSession.shared from passing unnoticed.
        XCTAssertTrue(
            HeadlessLogin.defaultSession === TeleportTrustSession.session,
            "post's default session must be TeleportTrustSession.session"
        )
    }

    // MARK: - Shared trust session configuration

    func testSharedTrustSessionConfiguration_pinsThe200sTimeouts() {
        // This pins the shared trust session's configuration (200 s > the
        // 180 s blocking window the server holds), not which session
        // `HeadlessLogin.post` uses — see the rewrite acceptance list.
        let config = TeleportTrustSession.session.configuration
        XCTAssertGreaterThanOrEqual(config.timeoutIntervalForRequest, 180)
        XCTAssertGreaterThanOrEqual(config.timeoutIntervalForResource, 180)
        // Pin the chosen value (200 s > 180 s server timeout) so a future
        // change is deliberate.
        XCTAssertEqual(config.timeoutIntervalForRequest, 200)
        XCTAssertEqual(config.timeoutIntervalForResource, 200)
    }

    func testTeleportHTTPClientHeadlessLogin_encodesStdBase64SSHPubKeyWithNewline() async throws {
        // End-to-end through the app-facing client: the raw authorized_keys
        // line is std-base64-encoded with exactly one trailing "\n" (Go's
        // ssh.MarshalAuthorizedKey shape).
        let server = try makeServer(
            .init(statusCode: 200, body: Data(#"{"cert":"Q0VSVA=="}"#.utf8))
        )
        defer { server.stop() }

        let client = TeleportHTTPClient(baseURL: loopbackURL(server))
        _ = try await client.headlessLogin(
            id: "id-1",
            user: "pier",
            sshPubKey: Self.authorizedKeyLine,
            tlsPubKey: nil,
            ttl: 3_600_000_000_000
        )

        let captured = try XCTUnwrap(server.request)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
        XCTAssertEqual(sent["ssh_pub_key"] as? String, Self.authorizedKeyB64)
        XCTAssertNil(sent["tls_pub_key"], "nil tls_pub_key must be omitted")
    }

    // MARK: - Helpers

    private static func makeRequest() -> HeadlessLoginReq {
        HeadlessLoginReq(
            user: "pier",
            headlessAuthenticationID: "id-1",
            sshPubKey: authorizedKeyB64,
            tlsPubKey: nil,
            ttl: 1,
            compatibility: ""
        )
    }

    private func makeServer(_ response: LoopbackHTTPServer.Response) throws -> LoopbackHTTPServer {
        try LoopbackHTTPServer(response: response)
    }

    private func loopbackURL(_ server: LoopbackHTTPServer) -> URL {
        URL(string: "http://127.0.0.1:\(server.port)")!
    }
}
