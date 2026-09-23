// SPDX-License-Identifier: MIT
//
//  BrowserMFAListenerLoopbackTests.swift
//  VVTermTests
//
//  The Browser MFA callback listener must be reachable on both loopback
//  families: the URL advertises `localhost`, and Safari may resolve it to
//  127.0.0.1 or ::1 first. `BrowserMFAListener` binds both; this test proves
//  a raw TCP + HTTP round-trip succeeds on each family. The advertised URL
//  must always be `localhost` — a literal `127.0.0.1` triggers Safari's Not
//  Secure Connection Warning (iOS 18.2+) on a real device, even though the
//  callback still completes.
//
//  A device re-test remains required — the simulator/CI can pass on IPv4
//  while a device resolves ::1.
//

#if canImport(Network)
import CryptoKit
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
        XCTAssertTrue(
            callbackURL.hasPrefix("http://localhost:"),
            "callback URL must advertise localhost, never a literal loopback IP: \(callbackURL)"
        )
        let port = listener.port
        XCTAssertGreaterThan(port, 0)

        let v4 = try await probe(host: .ipv4(.loopback), port: port, secretKey: listener.secretKeyHex)
        XCTAssertTrue(v4, "listener must be reachable on 127.0.0.1")

        // The product retries the pair on a fresh port, then falls back to
        // IPv4-only when ::1 stays unavailable on the runner. Only assert the
        // v6 leg when the dual-family bind was kept.
        guard listener.hasIPv6LoopbackListener else {
            throw XCTSkip("IPv6 loopback bind unavailable on this runner; the IPv4-only fallback was taken")
        }

        let v6 = try await probe(host: .ipv6(.loopback), port: port, secretKey: listener.secretKeyHex)
        XCTAssertTrue(v6, "listener must be reachable on ::1")
    }

    /// A device run showed the `::1` bind losing the OS-assigned IPv4 port to
    /// an existing IPv6 listener (EADDRINUSE) and the old fallback advertising
    /// `http://127.0.0.1:…` — which triggers Safari's Not Secure Connection
    /// Warning. Pin the invariant deterministically: every `::1` bind fails,
    /// the pair is retried, and the URL still advertises `localhost` while the
    /// IPv4 listener serves the callback.
    func testIPv6BindFailureStillAdvertisesLocalhost() async throws {
        let v6Attempts = OSAllocatedUnfairLock(initialState: 0)
        let listener = BrowserMFAListener(listenerFactory: { host, port in
            if case .ipv6 = host {
                v6Attempts.withLock { $0 += 1 }
                throw BrowserMFAListenerError.listenerFailed("forced ::1 bind failure")
            }
            return try BrowserMFAListener.makeLoopbackListener(host: host, port: port)
        })
        let callbackURL = try await listener.start()
        defer { listener.cancel() }

        XCTAssertTrue(
            callbackURL.hasPrefix("http://localhost:"),
            "the IPv4-only fallback must still advertise localhost: \(callbackURL)"
        )
        XCTAssertFalse(callbackURL.contains("127.0.0.1"))
        XCTAssertFalse(listener.hasIPv6LoopbackListener)
        XCTAssertEqual(
            v6Attempts.withLock { $0 },
            3,
            "the 127.0.0.1 + ::1 pair must be retried before the IPv4-only fallback"
        )

        let v4 = try await probe(host: .ipv4(.loopback), port: listener.port, secretKey: listener.secretKeyHex)
        XCTAssertTrue(v4, "the IPv4-only fallback must still serve the callback")
    }

    /// The timeout path must resolve through the same serialization as the
    /// callback path; a later callback must be discarded instead of resuming
    /// the continuation twice.
    func testTimeoutResolvesOnceThroughTheSerializedResumePath() async throws {
        let listener = BrowserMFAListener(timeout: 0.1)
        _ = try await listener.start()
        defer { listener.cancel() }

        do {
            _ = try await listener.waitForResponse()
            XCTFail("waitForResponse must time out when no callback arrives")
        } catch let error as BrowserMFAListenerError {
            guard case .timedOut = error else {
                return XCTFail("expected .timedOut; got \(error)")
            }
        }

        XCTAssertTrue(
            listener.didResume,
            "the timeout must mark the continuation resolved through the serialized path"
        )
        // A callback racing the deadline (or arriving after it) must not
        // touch the already-resolved continuation.
        listener.resume(.success(Proto_CredentialAssertionResponse()))
        XCTAssertTrue(listener.didResume)
    }

    /// The response deadline must not depend on a run loop. `waitForResponse()`
    /// is nonisolated async, so it runs on a cooperative-pool thread whose
    /// `RunLoop.current` is never pumped; drive the wait from a detached task
    /// and require the executor-independent deadline to fire.
    func testDeadlineFiresOffTheMainExecutor() async throws {
        let listener = BrowserMFAListener(timeout: 0.2)
        _ = try await listener.start()
        defer { listener.cancel() }

        let captured = OSAllocatedUnfairLock<BrowserMFAListenerError?>(initialState: nil)
        let resumedOffMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let resolved = expectation(description: "waitForResponse resolves off the main executor")
        let waiter = Task.detached {
            do {
                _ = try await listener.waitForResponse()
                captured.withLock { $0 = .listenerFailed("unexpected success") }
            } catch let error as BrowserMFAListenerError {
                captured.withLock { $0 = error }
            } catch {
                captured.withLock { $0 = .listenerFailed(String(describing: error)) }
            }
            resumedOffMain.withLock { $0 = !Thread.isMainThread }
            resolved.fulfill()
        }
        defer { waiter.cancel() }

        await fulfillment(of: [resolved], timeout: 15)

        guard case .timedOut? = captured.withLock({ $0 }) else {
            return XCTFail(
                "expected the deadline to fire off the main executor; got "
                    + String(describing: captured.withLock { $0 })
            )
        }
        XCTAssertEqual(
            resumedOffMain.withLock { $0 },
            true,
            "the waiter must resume off the main executor (run-loop-independent deadline)"
        )
    }

    /// Cancelling the awaiting task must resolve the wait promptly through
    /// the serialized `resume` path instead of running out the deadline.
    func testCancelledWaiterResolvesPromptly() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let clock = ContinuousClock()
        let started = clock.now
        let waiter = Task.detached { () -> Bool in
            do {
                _ = try await listener.waitForResponse()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        // Deterministic handshake: wait (bounded) until the waiter has
        // installed its continuation, so the cancellation exercises the
        // installed wait instead of racing the install.
        let installDeadline = ContinuousClock.now + .seconds(15)
        while !listener.isAwaitingResponse, ContinuousClock.now < installDeadline {
            await Task.yield()
        }
        XCTAssertTrue(
            listener.isAwaitingResponse,
            "the waiter must install its continuation before cancellation"
        )
        waiter.cancel()
        let cancelledAsExpected = await waiter.value
        let elapsed = clock.now - started

        XCTAssertTrue(cancelledAsExpected, "a cancelled wait must throw CancellationError")
        XCTAssertLessThan(elapsed, .seconds(5), "cancellation must not wait out the 60s deadline")
        XCTAssertTrue(
            listener.didResume,
            "cancellation must resolve through the serialized resume path"
        )
    }

    /// Cancelling the listener itself with an installed waiter must resolve
    /// the wait immediately instead of hanging: after `cancel()` there is no
    /// callback and no deadline left. A later wait must also fail fast
    /// rather than arm a new deadline on a torn-down listener.
    func testCancelWithInstalledWaiterResolvesPromptly() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()

        let clock = ContinuousClock()
        let started = clock.now
        let waiter = Task.detached { () -> Bool in
            do {
                _ = try await listener.waitForResponse()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let installDeadline = ContinuousClock.now + .seconds(15)
        while !listener.isAwaitingResponse, ContinuousClock.now < installDeadline {
            await Task.yield()
        }
        XCTAssertTrue(listener.isAwaitingResponse, "the waiter must install before cancel")

        listener.cancel()
        let cancelledAsExpected = await waiter.value
        let elapsed = clock.now - started
        XCTAssertTrue(cancelledAsExpected, "cancel must resolve an installed waiter with CancellationError")
        XCTAssertLessThan(elapsed, .seconds(5), "cancel must not wait out the 60s deadline")
        XCTAssertTrue(listener.didResume)

        do {
            _ = try await listener.waitForResponse()
            XCTFail("a wait on a cancelled listener must fail fast")
        } catch {
            // expected: the listener is terminally resolved
        }
    }

    /// A cancellation that races a buffered result must win: a cancelled
    /// login must not complete from a result that arrived before the wait.
    func testCancellationWinsOverABufferedResult() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        defer { listener.cancel() }

        var buffered = Proto_CredentialAssertionResponse()
        buffered.id = "buffered"
        listener.resume(.success(buffered))

        // Cancel from inside the task before awaiting, so `Task.isCancelled`
        // is deterministically true when the buffered branch runs.
        let waiter = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await listener.waitForResponse()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let cancelled = await waiter.value
        XCTAssertTrue(cancelled, "cancellation must beat the buffered success")
    }

    /// A burst of connections must not accumulate per-connection buffers:
    /// connections over the admission cap are answered 503 immediately and
    /// do not resolve the login.
    func testAdmissionCapRejectsExcessConnections() async throws {
        let listener = BrowserMFAListener(timeout: 60, readTimeout: 30, maxConcurrentConnections: 1)
        _ = try await listener.start()
        defer { listener.cancel() }

        guard let endpointPort = NWEndpoint.Port(rawValue: listener.port) else {
            return XCTFail("listener must expose a bound port")
        }
        let silent = NWConnection(host: .ipv4(.loopback), port: endpointPort, using: .tcp)
        defer { silent.cancel() }
        try await connect(silent)

        let admitDeadline = ContinuousClock.now + .seconds(15)
        while listener.activeConnectionCount < 1, ContinuousClock.now < admitDeadline {
            await Task.yield()
        }
        XCTAssertEqual(listener.activeConnectionCount, 1, "the first connection must hold the only slot")

        let response = try await probeRawResponse(
            host: .ipv4(.loopback),
            port: listener.port,
            secretKey: listener.secretKeyHex
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 503"),
            "an over-cap connection must get 503; got: \(response)"
        )
        XCTAssertFalse(listener.didResume, "an over-cap connection must not resolve the login")
    }

    /// A request that exceeds the buffered ceiling is answered 413 instead of
    /// accumulating unboundedly.
    func testOversizedRequestIsAnswered413() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        var request = Data("GET /callback?secret_key=\(listener.secretKeyHex)&response=".utf8)
        // No header terminator: the size guard must trip before the parser
        // ever sees a complete request.
        request.append(Data(repeating: 0x41, count: (1 << 20) + 1))
        let response = try await sendRawRequest(
            request,
            host: .ipv4(.loopback),
            port: listener.port
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 413"),
            "an oversized request must get 413; got: \(response)"
        )
        XCTAssertFalse(listener.didResume)
    }

    /// A `/callback` request without the authenticated `response` param must
    /// not terminate the login: any local process can reach the loopback
    /// port, so the listener answers 400 and keeps waiting for the genuine
    /// callback (or the deadline).
    func testCallbackWithoutResponseParamDoesNotResolveTheListener() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let response = try await probeRawResponse(
            host: .ipv4(.loopback),
            port: listener.port,
            secretKey: listener.secretKeyHex
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 400"),
            "an unauthenticated callback must be answered 400; got: \(response)"
        )
        XCTAssertFalse(listener.didResume, "an unauthenticated callback must not resolve the login")

        // The genuine (AES-GCM-authenticated) callback is still free to
        // resolve the wait.
        var expected = Proto_CredentialAssertionResponse()
        expected.id = "genuine-callback"
        listener.resume(.success(expected))
        let resolvedResponse = try await listener.waitForResponse()
        XCTAssertEqual(resolvedResponse.id, "genuine-callback")
    }

    /// A `/callback` request whose `response` value is present but does not
    /// authenticate must not terminate the login either: it was not produced
    /// by the server holding our per-run key, and any local process can send
    /// it. The listener answers 400, keeps waiting, and the genuine callback
    /// still resolves the wait.
    func testCallbackWithUnauthenticatedResponseDoesNotResolveTheListener() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let response = try await probeRawResponse(
            host: .ipv4(.loopback),
            port: listener.port,
            secretKey: listener.secretKeyHex,
            response: "AAAA"
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 400"),
            "an unauthenticated callback payload must be answered 400; got: \(response)"
        )
        XCTAssertFalse(
            listener.didResume,
            "an unauthenticated callback payload must not resolve the login"
        )

        // The genuine (AES-GCM-authenticated) callback is still free to
        // resolve the wait.
        var expected = Proto_CredentialAssertionResponse()
        expected.id = "genuine-callback"
        listener.resume(.success(expected))
        let resolvedResponse = try await listener.waitForResponse()
        XCTAssertEqual(resolvedResponse.id, "genuine-callback")
    }

    /// A well-formed envelope whose ciphertext/nonce fail base64 decoding is
    /// still unauthenticated: it cannot contain a valid GCM tag. Same policy
    /// as the other pre-authentication failures.
    func testCallbackWithMalformedCiphertextDoesNotResolveTheListener() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let response = try await probeRawResponse(
            host: .ipv4(.loopback),
            port: listener.port,
            secretKey: listener.secretKeyHex,
            response: #"{"ciphertext":"!!!","nonce":"AAAA"}"#
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 400"),
            "a payload that cannot even decode must be answered 400; got: \(response)"
        )
        XCTAssertFalse(listener.didResume)
    }

    /// The authenticated half of the split: plaintext that AES-GCM opens
    /// under our per-run key but that does not decode is a malformed server
    /// response, so it stays terminal (a retry cannot fix it).
    func testAuthenticatedButMalformedPlaintextResolvesTerminally() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let envelope = try Self.encryptedEnvelope(
            plaintext: Data("not-json".utf8),
            secretKeyHex: listener.secretKeyHex
        )
        let response = try await probeRawResponse(
            host: .ipv4(.loopback),
            port: listener.port,
            secretKey: listener.secretKeyHex,
            response: envelope
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 500"),
            "an authenticated payload that cannot be decoded must fail terminally; got: \(response)"
        )

        do {
            _ = try await listener.waitForResponse()
            XCTFail("waitForResponse must resolve with the decode failure")
        } catch let error as BrowserMFAListenerError {
            guard case .decodeFailed = error else {
                return XCTFail("expected .decodeFailed; got \(error)")
            }
        }
        XCTAssertTrue(
            listener.didResume,
            "a post-authentication decode failure must resolve the wait terminally"
        )
    }

    /// A resolution that happens before `waitForResponse()` starts (a local
    /// process can reach the loopback port first, or the deadline can fire
    /// while the ceremony is still starting) must be buffered: the later
    /// wait returns it instead of hanging on a resolution that already
    /// happened.
    func testResolutionBeforeWaitIsBufferedAndDelivered() async throws {
        let listener = BrowserMFAListener()
        defer { listener.cancel() }

        listener.resume(.failure(BrowserMFAListenerError.decodeFailed("buffered")))

        do {
            _ = try await listener.waitForResponse()
            XCTFail("waitForResponse must resolve with the buffered failure")
        } catch let error as BrowserMFAListenerError {
            guard case .decodeFailed = error else {
                return XCTFail("expected .decodeFailed; got \(error)")
            }
        }
    }

    /// The first resolution is terminal: later results (a second callback,
    /// the deadline, a success after an early failure) are discarded rather
    /// than resolving the same wait twice.
    func testFirstResolutionWinsAndLaterResultsAreDiscarded() async throws {
        let listener = BrowserMFAListener()
        defer { listener.cancel() }

        listener.resume(.failure(BrowserMFAListenerError.decodeFailed("first")))
        listener.resume(.success(Proto_CredentialAssertionResponse()))
        listener.resume(.failure(BrowserMFAListenerError.timedOut))
        XCTAssertTrue(listener.didResume, "the first result must mark the listener resolved")

        do {
            _ = try await listener.waitForResponse()
            XCTFail("waitForResponse must resolve with the first (failure) result")
        } catch let error as BrowserMFAListenerError {
            guard case .decodeFailed = error else {
                return XCTFail("expected the buffered .decodeFailed; got \(error)")
            }
        }
    }

    /// The buffered path carries a successful callback too: the wait returns
    /// the payload exactly once when later results arrive.
    func testBufferedSuccessResolvesExactlyOnce() async throws {
        let listener = BrowserMFAListener()
        defer { listener.cancel() }

        var expected = Proto_CredentialAssertionResponse()
        expected.id = "assertion-1"
        listener.resume(.success(expected))
        listener.resume(.failure(BrowserMFAListenerError.timedOut))

        let response = try await listener.waitForResponse()
        XCTAssertEqual(response.id, "assertion-1")
        XCTAssertTrue(listener.didResume)
    }

    /// A real `/callback` request without the `response` param must leave the
    /// listener pending instead of latching it terminally; the later wait
    /// resolves once a genuine callback arrives.
    func testSocketCallbackBeforeWaitKeepsWaiting() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let reachable = try await probe(
            host: .ipv4(.loopback),
            port: listener.port,
            secretKey: listener.secretKeyHex
        )
        XCTAssertTrue(reachable)
        XCTAssertFalse(listener.didResume, "an unauthenticated callback must not resolve the listener")

        var expected = Proto_CredentialAssertionResponse()
        expected.id = "after-probe"
        listener.resume(.success(expected))

        let response = try await listener.waitForResponse()
        XCTAssertEqual(response.id, "after-probe")
    }

    /// A genuine callback whose GET line is split across two TCP writes
    /// must resolve: the listener accumulates until the HTTP header
    /// terminator arrives and parses only then, instead of parsing the first
    /// fragment as a truncated (and therefore unauthenticated) payload.
    func testCallbackSplitAcrossWritesResolvesSuccessfully() async throws {
        let listener = BrowserMFAListener(timeout: 2)
        _ = try await listener.start()
        defer { listener.cancel() }

        let envelope = try Self.encryptedEnvelope(
            plaintext: try Self.loginResponsePlaintext(id: "split-callback"),
            secretKeyHex: listener.secretKeyHex
        )
        let request = Self.callbackRequest(secretKey: listener.secretKeyHex, response: envelope)

        let response = try await sendRawRequest(
            request,
            splitAt: request.count / 2,
            host: .ipv4(.loopback),
            port: listener.port
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 200"),
            "a fragmented genuine callback must be answered 200; got: \(response)"
        )

        let resolved = try await listener.waitForResponse()
        XCTAssertEqual(resolved.id, "split-callback")
    }

    /// A genuine callback whose request line exceeds the old single 64 KB
    /// read must resolve: the listener accumulates the full request instead
    /// of parsing a truncated (and therefore unauthenticated) payload.
    func testOversizedAuthenticatedCallbackIsNotMisclassified() async throws {
        let listener = BrowserMFAListener(timeout: 2)
        _ = try await listener.start()
        defer { listener.cancel() }

        // ~96 KB of padding inside the decodeable payload, so the sealed
        // envelope and its percent-encoded request line are comfortably
        // larger than the old 64 KB read but under the 1 MB cap.
        let padding = Data((0..<(96 * 1024)).map { _ in UInt8.random(in: 0...255) })
        let envelope = try Self.encryptedEnvelope(
            plaintext: try Self.loginResponsePlaintext(id: "oversized-callback", clientDataJSON: padding),
            secretKeyHex: listener.secretKeyHex
        )
        let request = Self.callbackRequest(secretKey: listener.secretKeyHex, response: envelope)
        XCTAssertGreaterThan(
            request.count,
            65_536,
            "the test request must exceed the old single 64 KB read"
        )

        let response = try await sendRawRequest(request, host: .ipv4(.loopback), port: listener.port)
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 200"),
            "an oversized genuine callback must be answered 200; got: \(response)"
        )

        let resolved = try await listener.waitForResponse()
        XCTAssertEqual(resolved.id, "oversized-callback")
    }

    /// A client that connects and never sends must not pin the connection:
    /// the bounded idle deadline answers 408 without resolving the login.
    func testSilentConnectionIsAnsweredAndDoesNotResolveTheListener() async throws {
        let listener = BrowserMFAListener(timeout: 60, readTimeout: 1)
        _ = try await listener.start()
        defer { listener.cancel() }

        guard let endpointPort = NWEndpoint.Port(rawValue: listener.port) else {
            return XCTFail("listener port is invalid")
        }
        let connection = NWConnection(host: .ipv4(.loopback), port: endpointPort, using: .tcp)
        defer { connection.cancel() }
        try await connect(connection)

        // Send nothing: the read deadline must answer on its own.
        let response = try await receiveResponse(connection)
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 408"),
            "a silent connection must be answered 408; got: \(response)"
        )
        XCTAssertFalse(listener.didResume, "a silent connection must not resolve the login")
    }

    /// A callback sealed under a *different* key must not authenticate: the
    /// listener's per-run key is the proof the payload came from the server,
    /// and a local process that never saw it must not resolve the login.
    func testCallbackSealedUnderADifferentKeyIsRejected() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let otherKeyHex = String(repeating: "ab", count: 32)
        let envelope = try Self.encryptedEnvelope(
            plaintext: try Self.loginResponsePlaintext(id: "cross-key"),
            secretKeyHex: otherKeyHex
        )
        let response = try await probeRawResponse(
            host: .ipv4(.loopback),
            port: listener.port,
            secretKey: listener.secretKeyHex,
            response: envelope
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 400"),
            "a cross-key replay must be answered 400; got: \(response)"
        )
        XCTAssertFalse(
            listener.didResume,
            "a cross-key replay must not resolve the login"
        )
    }

    /// The `secret_key` query value is the per-run proof the callback came
    /// from the server. A genuine envelope sent under a wrong key must be
    /// answered 400 and must not resolve the login — without this vector the
    /// guard could be deleted and every other callback test would stay green.
    func testCallbackWithAWrongSecretKeyIsRejected() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let envelope = try Self.encryptedEnvelope(
            plaintext: try Self.loginResponsePlaintext(id: "wrong-secret"),
            secretKeyHex: listener.secretKeyHex
        )
        let response = try await probeRawResponse(
            host: .ipv4(.loopback),
            port: listener.port,
            secretKey: String(repeating: "cd", count: 32),
            response: envelope
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 400"),
            "a wrong secret_key must be answered 400; got: \(response)"
        )
        XCTAssertFalse(listener.didResume, "a wrong secret_key must not resolve the login")
    }

    /// The same guard must reject a callback with no `secret_key` at all
    /// (the pre-rewrite code documented the parameter but never checked it).
    func testCallbackWithoutASecretKeyIsRejected() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let envelope = try Self.encryptedEnvelope(
            plaintext: try Self.loginResponsePlaintext(id: "missing-secret"),
            secretKeyHex: listener.secretKeyHex
        )
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "response", value: envelope)]
        let query = components.percentEncodedQuery ?? ""
        let request = Data(
            "GET /callback?\(query) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8
        )
        let response = try await sendRawRequest(request, host: .ipv4(.loopback), port: listener.port)
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 400"),
            "a missing secret_key must be answered 400; got: \(response)"
        )
        XCTAssertFalse(listener.didResume, "a missing secret_key must not resolve the login")
    }

    /// Only the browser's GET/POST are callback methods; anything else must be
    /// answered 405 without touching the query or the envelope.
    func testCallbackWithAnUnsupportedMethodIsRejected() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let envelope = try Self.encryptedEnvelope(
            plaintext: try Self.loginResponsePlaintext(id: "bad-method"),
            secretKeyHex: listener.secretKeyHex
        )
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "secret_key", value: listener.secretKeyHex),
            URLQueryItem(name: "response", value: envelope),
        ]
        let query = components.percentEncodedQuery ?? ""
        let request = Data(
            "PUT /callback?\(query) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8
        )
        let response = try await sendRawRequest(request, host: .ipv4(.loopback), port: listener.port)
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 405"),
            "a PUT must be answered 405; got: \(response)"
        )
        XCTAssertFalse(listener.didResume, "a PUT must not resolve the login")
    }

    /// A bit flip inside the GCM tag must fail authentication. Without this
    /// vector a refactor could construct the sealed box without opening it and
    /// keep every other callback test green.
    func testCallbackWithATagBitFlipIsRejected() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let parts = try Self.sealedParts(
            plaintext: try Self.loginResponsePlaintext(id: "bit-flip"),
            secretKeyHex: listener.secretKeyHex
        )
        var tampered = parts.sealed
        tampered[tampered.count - 1] ^= 0x01
        let envelope = try Self.envelopeJSON(sealed: tampered, nonce: parts.nonce)

        let response = try await probeRawResponse(
            host: .ipv4(.loopback),
            port: listener.port,
            secretKey: listener.secretKeyHex,
            response: envelope
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 400"),
            "a tampered tag must be answered 400; got: \(response)"
        )
        XCTAssertFalse(listener.didResume, "a tampered tag must not resolve the login")
    }

    /// `ciphertext‖tag` must carry at least one plaintext byte: exactly the
    /// 16 tag bytes is the boundary the listener rejects before opening.
    func testCiphertextOfExactlyTheTagLengthIsRejected() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let parts = try Self.sealedParts(
            plaintext: try Self.loginResponsePlaintext(id: "boundary"),
            secretKeyHex: listener.secretKeyHex
        )
        let envelope = try Self.envelopeJSON(
            sealed: parts.sealed.suffix(16),
            nonce: parts.nonce
        )
        let response = try await probeRawResponse(
            host: .ipv4(.loopback),
            port: listener.port,
            secretKey: listener.secretKeyHex,
            response: envelope
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 400"),
            "a tag-only payload must be answered 400; got: \(response)"
        )
        XCTAssertFalse(listener.didResume, "a tag-only payload must not resolve the login")
    }

    /// Go marshals the assertion's binary fields as `base64.RawURLEncoding`
    /// (URL-safe alphabet, no padding). The listener must decode that form,
    /// not only the padded standard alphabet.
    func testUrlSafeUnpaddedBase64FieldsDecode() async throws {
        let listener = BrowserMFAListener(timeout: 60)
        _ = try await listener.start()
        defer { listener.cancel() }

        let clientData = Data([0xfb, 0xef, 0xbe, 0x01, 0x02, 0x03])
        let envelope = try Self.encryptedEnvelope(
            plaintext: try Self.loginResponsePlaintextUrlSafe(id: "url-safe", clientDataJSON: clientData),
            secretKeyHex: listener.secretKeyHex
        )
        let response = try await probeRawResponse(
            host: .ipv4(.loopback),
            port: listener.port,
            secretKey: listener.secretKeyHex,
            response: envelope
        )
        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 200"),
            "a url-safe unpadded payload must be accepted; got: \(response)"
        )

        let resolved = try await listener.waitForResponse()
        XCTAssertEqual(resolved.id, "url-safe")
        XCTAssertEqual(
            resolved.response.clientDataJson,
            clientData,
            "the url-safe (no padding) field must decode to the same bytes"
        )
    }

    /// Connect, send a minimal HTTP GET, and require at least one response
    /// byte. Uses NWConnection directly (no ATS involvement).
    private func probe(host: NWEndpoint.Host, port: UInt16, secretKey: String) async throws -> Bool {
        let response = try await probeRawResponse(host: host, port: port, secretKey: secretKey)
        return !response.isEmpty
    }

    /// Connect, send a minimal HTTP GET, and return the raw response text.
    ///
    /// `response` is the optional `?response=` value appended to the query
    /// (form-encoded like Go's `url.Values.Encode`).
    private func probeRawResponse(
        host: NWEndpoint.Host,
        port: UInt16,
        secretKey: String,
        response: String? = nil
    ) async throws -> String {
        let request = Self.callbackRequest(secretKey: secretKey, response: response)
        return try await sendRawRequest(request, host: host, port: port)
    }

    /// The raw HTTP/1.1 GET the browser sends to the loopback listener.
    /// `response` is the optional `?response=` value appended to the query
    /// (form-encoded like Go's `url.Values.Encode`).
    private static func callbackRequest(secretKey: String, response: String?) -> Data {
        var queryItems = [URLQueryItem(name: "secret_key", value: secretKey)]
        if let response {
            queryItems.append(URLQueryItem(name: "response", value: response))
        }
        var components = URLComponents()
        components.queryItems = queryItems
        let query = components.percentEncodedQuery ?? ""
        let request = "GET /callback?\(query) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        return Data(request.utf8)
    }

    /// Connect and send `request` as one or two writes, then return the raw
    /// response text. `splitAt` splits the request into two TCP writes at a
    /// byte offset (a proxy for the fragmentation the listener must
    /// tolerate).
    private func sendRawRequest(
        _ request: Data,
        splitAt splitIndex: Int? = nil,
        host: NWEndpoint.Host,
        port: UInt16
    ) async throws -> String {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return "" }
        let connection = NWConnection(host: host, port: endpointPort, using: .tcp)
        defer { connection.cancel() }
        try await connect(connection)

        if let splitIndex {
            let firstFragment = request.prefix(splitIndex)
            let secondFragment = request.suffix(from: splitIndex)
            try await send(connection, Data(firstFragment))
            // Short bounded delay: give the listener queue a chance to read
            // the first fragment before the second is written. TCP may still
            // coalesce the two writes; the accumulation path handles both.
            try await Task.sleep(for: .milliseconds(20))
            try await send(connection, Data(secondFragment))
        } else {
            try await send(connection, request)
        }

        return try await receiveResponse(connection)
    }

    /// Start `connection` and await `.ready` (or a failure / 15s timeout).
    private func connect(_ connection: NWConnection) async throws {
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
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 15) {
                resumeOnce(.failure(BrowserMFAListenerError.listenerFailed("probe connect timed out")))
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Await the first response bytes (or a failure / 15s timeout).
    private func receiveResponse(_ connection: NWConnection) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func resumeOnce(_ result: Result<String, Error>) {
                let already = resumed.withLock { isResumed -> Bool in
                    if isResumed { return true }
                    isResumed = true
                    return false
                }
                guard !already else { return }
                cont.resume(with: result)
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error {
                    resumeOnce(.failure(error))
                } else {
                    resumeOnce(.success(String(data: data ?? Data(), encoding: .utf8) ?? ""))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 15) {
                resumeOnce(.failure(BrowserMFAListenerError.timedOut))
            }
        }
    }

    /// The decrypted plaintext the server seals: a minimal
    /// `CLILoginResponse` JSON carrying the `browser_mfa_webauthn_response`
    /// the listener maps into proto types.
    private static func loginResponsePlaintext(
        id: String,
        clientDataJSON: Data = Data("client-data".utf8)
    ) throws -> Data {
        let payload: [String: Any] = [
            "browser_mfa_webauthn_response": [
                "id": id,
                "type": "public-key",
                "rawId": "cmF3LWlk",
                "response": [
                    "clientDataJSON": clientDataJSON.base64EncodedString(),
                    "authenticatorData": Data("auth-data".utf8).base64EncodedString(),
                    "signature": Data("signature".utf8).base64EncodedString(),
                    "userHandle": Data("user".utf8).base64EncodedString(),
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Build the `{"ciphertext": …, "nonce": …}` envelope the server
    /// produces, sealed under the listener's per-run key, so tests can
    /// exercise the post-authentication decode path. Test-only helper.
    private static func encryptedEnvelope(plaintext: Data, secretKeyHex: String) throws -> String {
        let parts = try sealedParts(plaintext: plaintext, secretKeyHex: secretKeyHex)
        return try envelopeJSON(sealed: parts.sealed, nonce: parts.nonce)
    }

    /// The raw `ciphertext‖tag` and nonce for a payload sealed under
    /// `secretKeyHex` — the parts a tamper/cross-key test mutates before
    /// rebuilding the envelope.
    private static func sealedParts(plaintext: Data, secretKeyHex: String) throws -> (sealed: Data, nonce: Data) {
        let key = SymmetricKey(data: Data(try keyBytes(secretKeyHex)))
        let nonce = try AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        // Go's aesgcm.Seal appends the 16-byte tag to the ciphertext; the
        // listener splits it back off.
        return (box.ciphertext + box.tag, Data(nonce))
    }

    /// Rebuild the `{"ciphertext": …, "nonce": …}` JSON from raw parts.
    private static func envelopeJSON(sealed: Data, nonce: Data) throws -> String {
        let envelope = [
            "ciphertext": sealed.base64EncodedString(),
            "nonce": nonce.base64EncodedString(),
        ]
        let json = try JSONSerialization.data(withJSONObject: envelope)
        guard let string = String(data: json, encoding: .utf8) else {
            throw BrowserMFAListenerError.decodeFailed("envelope not utf8")
        }
        return string
    }

    private static func keyBytes(_ secretKeyHex: String) throws -> [UInt8] {
        var keyBytes: [UInt8] = []
        var index = secretKeyHex.startIndex
        while index < secretKeyHex.endIndex {
            let next = secretKeyHex.index(index, offsetBy: 2)
            guard let byte = UInt8(secretKeyHex[index..<next], radix: 16) else {
                throw BrowserMFAListenerError.listenerFailed("test key is not hex")
            }
            keyBytes.append(byte)
            index = next
        }
        return keyBytes
    }

    /// The same plaintext with every binary field in Go's
    /// `base64.RawURLEncoding` form (URL-safe alphabet, no padding).
    private static func loginResponsePlaintextUrlSafe(id: String, clientDataJSON: Data) throws -> Data {
        func rawURL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload: [String: Any] = [
            "browser_mfa_webauthn_response": [
                "id": id,
                "type": "public-key",
                "rawId": rawURL(Data("raw-id".utf8)),
                "response": [
                    "clientDataJSON": rawURL(clientDataJSON),
                    "authenticatorData": rawURL(Data("auth-data".utf8)),
                    "signature": rawURL(Data("signature".utf8)),
                    "userHandle": rawURL(Data("user".utf8)),
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

#endif // canImport(Network)
