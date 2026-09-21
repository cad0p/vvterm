// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  BrowserMFAListenerLoopbackTests.swift
//  VVTermTests
//
//  The Browser MFA callback listener must be reachable on both loopback
//  families: the URL advertises `localhost`, and Safari may resolve it to
//  127.0.0.1 or ::1 first. `BrowserMFAListener` binds both; this test proves
//  a raw TCP + HTTP round-trip succeeds on each family.
//
//  A device re-test remains required — the simulator/CI can pass on IPv4
//  while a device resolves ::1.
//

#if canImport(Network)
import Foundation
import Network
import os
import XCTest
@testable import VVTerm

@MainActor
final class BrowserMFAListenerLoopbackTests: XCTestCase {

    func testListenerReachableOnBothLoopbackFamilies() async throws {
        let listener = BrowserMFAListener()
        let callbackURL = try await listener.start()
        defer { listener.cancel() }

        XCTAssertFalse(callbackURL.contains(":0/"), "callback URL must carry a real port: \(callbackURL)")
        let port = listener.port
        XCTAssertGreaterThan(port, 0)

        let v4 = try await probe(host: .ipv4(.loopback), port: port, secretKey: listener.secretKeyHex)
        XCTAssertTrue(v4, "listener must be reachable on 127.0.0.1")

        let v6 = try await probe(host: .ipv6(.loopback), port: port, secretKey: listener.secretKeyHex)
        XCTAssertTrue(v6, "listener must be reachable on ::1")
    }

    /// Connect, send a minimal HTTP GET, and require at least one response
    /// byte. Uses NWConnection directly (no ATS involvement).
    private func probe(host: NWEndpoint.Host, port: UInt16, secretKey: String) async throws -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: host, port: endpointPort, using: .tcp)
        defer { connection.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func resumeOnce(_ result: Result<Void, Error>) {
                let already = resumed.withLock { isResumed -> Bool in
                    if isResumed { return true }
                    isResumed = true
                    return false
                }
                guard !already else { return }
                cont.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .waiting(let error):
                    resumeOnce(.failure(error))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5) {
                resumeOnce(.failure(BrowserMFAListenerError.listenerFailed("probe connect timed out")))
            }
        }

        let request = "GET /callback?secret_key=\(secretKey) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: !(data ?? Data()).isEmpty)
                }
            }
        }
    }
}

#endif // canImport(Network)
