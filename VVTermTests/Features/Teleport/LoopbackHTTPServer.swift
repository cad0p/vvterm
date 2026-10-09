// SPDX-License-Identifier: MIT
//
//  LoopbackHTTPServer.swift
//  VVTermTests
//
//  The one-shot in-process plain-HTTP server used by the kept
//  `TeleportLoginClientErrorShapeTests`. Split out of the package-covered
//  `HeadlessLoginWireTests` in the swift-teleport cutover (the package owns
//  the wire-contract suite and its own loopback support).
//
//  Host-state tolerance for the `.ready` transition (#260): `NWListener.start`
//  is asynchronous, and a loaded runner can take seconds to reach `.ready`
//  (the 20 s bound below is not retry machinery — the listener must still
//  reach `.ready` or the test throws).
//

import Foundation
#if canImport(Network)
import Network

enum LoopbackHTTPServerError: Error {
    case listenerStart
}

/// Host-state tolerance for `LoopbackHTTPServer`'s `.ready` transition
/// (#260).
///
/// `NWListener.start` is asynchronous, and the simulator's Network.framework
/// can take seconds to reach `.ready` while the runner hosts five concurrent
/// macOS jobs — it logs `nw_listener_socket_inbox_create_socket setsockopt
/// SO_NECP_LISTENUUID failed [2: No such file or directory]` while doing so.
/// A 5 s bound expired in the required `unit-tests` job (first instance:
/// `testPost_postsJSONToTheHeadlessLoginPathAndDecodes200`, run 36212681243).
///
/// This is a host-state tolerance, not retry machinery: the listener must
/// still reach `.ready` within this bound or the test throws
/// `LoopbackHTTPServerError.listenerStart`, so a genuinely unusable listener
/// is not hidden — only the lateness is absorbed. If a `.ready` timeout ever
/// survives this bound, the next step is a fresh-listener retry or an
/// investigation of the NECP socket-create failure, not another increase.
private let listenerReadyWaitSeconds: TimeInterval = 20

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

        guard ready.wait(timeout: .now() + listenerReadyWaitSeconds) == .success,
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
