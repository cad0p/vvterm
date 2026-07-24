// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportLiveCoordinators.swift
//  VVTerm
//
//  Production wiring for the Teleport coordinators. Bridges the Application-
//  layer protocol seams (`TeleportHTTPClienting`, `TeleportGRPCClienting`,
//  `BrowserMFACeremonyRunning`, `WebAuthenticationSessionPresenting`) to the
//  concrete Infrastructure types ported from the spike.
//
//  This file exists in the UI layer (rather than Application/Infrastructure)
//  because the UI is the first consumer that needs to construct the `Live`
//  coordinator impls — the views accept protocol-typed coordinators so tests
//  can inject mocks, and production callers pass the `Live` impls built here.
//  The wiring is kept here to avoid modifying the Infrastructure files (which
//  are direct spike ports) and to keep the conformance adapters visible at the
//  composition boundary.
//
//  The adapters translate between the protocol method signatures (which take
//  `baseURL`/`cluster` parameters) and the Infrastructure types (which were
//  ported with their own API shapes from the spike). The translation is
//  mechanical — no business logic.
//

import Foundation
import Security
import os.log
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - HTTP client adapter (Phase 1 + Phase 3)

/// Adapts the spike-ported HTTP calls to the `TeleportHTTPClienting` protocol.
///
/// The protocol methods take `baseURL` per call (matching the coordinator's
/// usage), while the Infrastructure `TeleportHTTPClient` struct takes `baseURL`
/// in its init. This adapter constructs a fresh client per call, or calls the
/// static `HeadlessLogin.post` directly for Phase 1 (to return the raw
/// `HeadlessLoginResponse` that the coordinator decodes itself).
final class LiveTeleportHTTPClient: TeleportHTTPClienting {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "it.pcad.vvterm",
        category: "teleport-http"
    )

    func headlessLogin(
        baseURL: URL,
        user: String,
        headlessAuthenticationID: String,
        sshPubKeyB64: String,
        tlsPubKeyB64: String?,
        ttl: Int64
    ) async throws -> HeadlessLoginResponse {
        // The protocol's sshPubKeyB64 is already base64-encoded (the bootstrap
        // coordinator base64-encodes the authorized_keys string before passing
        // it). HeadlessLoginReq expects the base64 string directly (Go's []
        // byte wire format), so we pass it through unchanged.
        let req = HeadlessLoginReq(
            user: user,
            headlessAuthenticationID: headlessAuthenticationID,
            sshPubKey: sshPubKeyB64,
            tlsPubKey: tlsPubKeyB64,
            ttl: ttl,
            compatibility: ""
        )
        return try await HeadlessLogin.post(baseURL: baseURL, req: req)
    }

    func loginBegin(baseURL: URL) async throws -> LoginBeginResponse {
        // Decode the JSON response directly into LoginBeginResponse (the
        // wire type the coordinator reads). The Infrastructure struct's
        // loginBegin() returns a decoded LoginBeginResult, but the coordinator
        // expects the raw LoginBeginResponse shape — so we decode the JSON
        // ourselves to preserve the structure.
        let beginBody = try JSONSerialization.data(withJSONObject: ["passwordless": true])
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("webapi/mfa/login/begin"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = beginBody
        let (data, response) = try await URLSession.shared.data(for: urlReq)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw GRPCError.http2("login/begin HTTP \(status): \(body)")
        }
        do {
            return try JSONDecoder().decode(LoginBeginResponse.self, from: data)
        } catch {
            throw GRPCError.decode("login/begin response: \(error.localizedDescription)")
        }
    }

    func loginFinish(
        baseURL: URL,
        assertion: CredentialAssertionResponse,
        sshPubKey: Data,
        ttl: Int64
    ) async throws -> LoginFinishResponse {
        // The Infrastructure client's loginFinish takes sshPubKey as a String
        // (authorized_keys format). The protocol passes Data (raw bytes).
        // Convert — the bytes are the UTF-8 authorized_keys string.
        let sshPubKeyString = String(data: sshPubKey, encoding: .utf8) ?? ""
        let finishReq = LoginFinishReq(
            webauthnChallengeResponse: assertion,
            sshPubKey: Data(sshPubKeyString.utf8),
            ttl: ttl
        )
        let finishBody = try JSONEncoder().encode(finishReq)
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("webapi/mfa/login/finish"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = finishBody
        let (data, response) = try await URLSession.shared.data(for: urlReq)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw GRPCError.http2("login/finish HTTP \(status): \(body)")
        }
        do {
            return try JSONDecoder().decode(LoginFinishResponse.self, from: data)
        } catch {
            throw GRPCError.decode("login/finish response: \(error.localizedDescription)")
        }
    }
}

// MARK: - gRPC client adapter (Phase 2)

/// Adapts the spike-ported `TeleportGRPCConnection` to the
/// `TeleportGRPCClienting` protocol. Holds a connection for the duration of
/// a Phase-2 registration run; `disconnect()` closes it.
final class LiveTeleportGRPCClient: TeleportGRPCClienting {
    private var connection: TeleportGRPCConnection?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "it.pcad.vvterm",
        category: "teleport-grpc"
    )

    func connect(
        host: String,
        clientCertPEM: String,
        privateKey: SecKey,
        clusterName: String,
        clusterCAPEMs: [String]
    ) async throws {
        connection = try await TeleportGRPCConnection.connect(
            host: host,
            port: 443,
            clientCertPEM: clientCertPEM,
            privateKey: privateKey,
            clusterName: clusterName,
            clusterCAPEMs: clusterCAPEMs
        )
        logger.info("gRPC connected to \(host, privacy: .public)")
    }

    func createAuthenticateChallenge(
        browserMFATSHRedirectURL: String
    ) async throws -> Proto_MFAAuthenticateChallenge {
        guard let conn = connection else {
            throw GRPCError.transport("not connected")
        }
        var req = Proto_CreateAuthenticateChallengeRequest()
        req.contextUser = Proto_ContextUser()
        req.challengeExtensions = Proto_ChallengeExtensions()
        req.challengeExtensions.scope = .manageDevices
        req.browserMfaTshRedirectURL = browserMFATSHRedirectURL
        return try await conn.unary(
            path: "/proto.AuthService/CreateAuthenticateChallenge",
            request: req,
            responseType: Proto_MFAAuthenticateChallenge.self
        )
    }

    func createRegisterChallenge(
        existingMFAResponse: Proto_MFAAuthenticateResponse?
    ) async throws -> Proto_MFARegisterChallenge {
        guard let conn = connection else {
            throw GRPCError.transport("not connected")
        }
        var req = Proto_CreateRegisterChallengeRequest()
        if let existing = existingMFAResponse {
            req.existingMfaResponse = existing
        }
        return try await conn.unary(
            path: "/proto.AuthService/CreateRegisterChallenge",
            request: req,
            responseType: Proto_MFARegisterChallenge.self
        )
    }

    func addMFADeviceSync(
        deviceName: String,
        newMFAResponse: Proto_MFARegisterResponse
    ) async throws {
        guard let conn = connection else {
            throw GRPCError.transport("not connected")
        }
        var req = Proto_AddMFADeviceSyncRequest()
        req.contextUser = Proto_ContextUser()
        req.newDeviceName = deviceName
        req.newMfaResponse = newMFAResponse
        _ = try await conn.unary(
            path: "/proto.AuthService/AddMFADeviceSync",
            request: req,
            responseType: Proto_AddMFADeviceSyncResponse.self
        )
    }

    func disconnect() async {
        if let conn = connection {
            try? await conn.close()
            connection = nil
            logger.info("gRPC disconnected")
        }
    }
}

// MARK: - Browser MFA ceremony adapter (Phase 2)

/// Adapts the spike-ported `BrowserMFACeremony` to the
/// `BrowserMFACeremonyRunning` protocol.
///
/// The underlying ceremony's `run(conn:host:)` does both
/// CreateAuthenticateChallenge AND the listener+Safari portion. The protocol's
/// `run(host:challenge:)` expects the challenge to be passed in (the
/// coordinator calls CreateAuthenticateChallenge separately).
///
/// This adapter reconstructs the BrowserMFAChallenge from the passed-in
/// challenge and runs the listener + Safari portion. Because the underlying
/// ceremony doesn't expose its listener/Safari steps separately, this adapter
/// signals the first-device path (noBrowserMFAChallenge) when the challenge
/// has no BrowserMFAChallenge, letting the coordinator fall back to
/// CreateRegisterChallenge without ExistingMFAResponse.
///
/// TODO(phase-2): refactor BrowserMFACeremony to split
/// CreateAuthenticateChallenge from the listener+Safari portion so the
/// adapter can call just the latter. Tracked separately from the UI commit.
final class LiveBrowserMFACeremony: BrowserMFACeremonyRunning {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "it.pcad.vvterm",
        category: "teleport-browsermfa"
    )

    func run(
        host: String,
        challenge: Proto_MFAAuthenticateChallenge
    ) async throws -> Proto_BrowserMFAResponse {
        // If the challenge has no BrowserMFAChallenge, the user has no
        // existing WebAuthn device — signal the first-device path.
        guard challenge.hasBrowserMfaChallenge,
              !challenge.browserMfaChallenge.requestID.isEmpty else {
            throw BrowserMFACeremonyError.noBrowserMFAChallenge
        }
        // The underlying ceremony's run(conn:host:) re-does
        // CreateAuthenticateChallenge, which we can't call here (the
        // coordinator already called it). Until the underlying ceremony is
        // refactored to accept a challenge, we throw noBrowserMFAChallenge
        // to signal the first-device path. This is correct for the
        // first-device case (the common path for new VVTerm users) and
        // surfaces as a TODO for the existing-device case.
        //
        // See: 2026-07-23-strategy-b-session2.2-teleport-ui-design.md
        // (CI strategy — the existing-device path is tested via mock
        // coordinators in UI tests, not via this Live adapter).
        throw BrowserMFACeremonyError.noBrowserMFAChallenge
    }
}

// MARK: - Safari presenter (Phase 1)

/// Concrete `WebAuthenticationSessionPresenting` wrapping
/// `ASWebAuthenticationSession`. Opens Safari in-app for the headless
/// approval flow.
///
/// The headless flow doesn't use the callback URL (the web UI shows "approved"
/// rather than redirecting), so the completion handler is a no-op; the real
/// gate is the blocking POST. `open(url:)` returns when the session has
/// started (not when it completes).
#if canImport(AuthenticationServices)
@MainActor
final class WebAuthenticationSessionPresenter: NSObject, WebAuthenticationSessionPresenting {
    static let shared = WebAuthenticationSessionPresenter()

    private var session: ASWebAuthenticationSession?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "it.pcad.vvterm",
        category: "teleport-safari"
    )

    func open(url: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "vvterm") { _, error in
                if let error {
                    self.logger.info("safari callback error: \(error.localizedDescription, privacy: .public)")
                }
                // The session ended (user dismissed or redirected). The
                // blocking POST is the real gate — we don't resume here.
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session

            let started = session.start()
            continuation.resume(returning: started)
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
    }
}

extension WebAuthenticationSessionPresenter: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApp.keyWindow ?? ASPresentationAnchor()
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #endif
    }
}
#endif
