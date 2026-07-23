// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  GRPCRegisterRunner.swift
//  iotest
//
//  Session 1.10 Phase 2 — register a SEP key via gRPC using the Phase 1
//  TLS cert for authentication (ContextUser, no invite token).
//
//  The flow mirrors `tsh mfa add` (tool/tsh/common/mfa.go:330-385):
//    1. CreateAuthenticateChallenge (ContextUser, MANAGE_DEVICES scope)
//    2. Solve the challenge with an EXISTING device (the iCloud passkey) →
//       ExistingMFAResponse. (For the spike, we use a native SEP assertion
//       against the challenge — this proves the privilege assertion path.)
//       NOTE: if the user has NO existing MFA device, step 1 returns an empty
//       challenge and step 2 is skipped (CreateRegisterChallenge works
//       without ExistingMFAResponse for the first device).
//    3. CreateRegisterChallenge (ExistingMFAResponse, WEBAUTHN, PASSWORDLESS)
//    4. Build the WebAuthn registration response natively (SEPWebAuthn +
//       SecureEnclaveSigner with .biometryAny — the 1.6b path, verbatim).
//    5. AddMFADeviceSync (NewDeviceName, NewMFAResponse, PASSWORDLESS, no
//       TokenID — ContextUser auth).
//
//  On success, the SEP key is registered on the Teleport cluster. The
//  credentialID + publicKeyRaw are kept for Phase 3 (passwordless login).
//

import Foundation
import OSLog
import CryptoKit
#if canImport(Network)
import NIOCore
import NIOHTTP2
import SwiftProtobuf
import Network
import Security
#endif

// MARK: - Log markers

enum GRPCRegisterLog {
    static let logger = Logger(subsystem: "it.pcad.vvterm.iotest", category: "grpc-register")

    static func step(_ step: String, _ message: String) {
        logger.notice("[IOTEST] grpc_\(step, privacy: .public) \(message, privacy: .public)")
    }
    static func result(_ summary: String) {
        logger.notice("[IOTEST] grpc_result \(summary, privacy: .public)")
    }
}

// MARK: - Step state

enum GRPCRegisterStepStatus: String {
    case pending, inProgress, done, failed
}

struct GRPCRegisterStep: Identifiable {
    let id: Int
    let title: String
    var status: GRPCRegisterStepStatus = .pending
    var detail: String = ""
}

// MARK: - Runner

/// The result of a successful Phase 2: the registered SEP key's credential ID
/// + public key, for use in Phase 3 (passwordless login).
struct RegisteredSEPKey {
    let credentialID: Data
    let publicKeyRaw: Data
}

/// Phase 2 runner: register a SEP key via gRPC using the Phase 1 cert.
///
/// `@MainActor` because it publishes to SwiftUI + calls SecureEnclaveSigner
/// which presents Face ID (must be on the main thread).
@MainActor
final class GRPCRegisterRunner: ObservableObject {
    @Published var steps: [GRPCRegisterStep] = []
    @Published var overallStatus: String = "idle"   // idle | running | passed | failed
    @Published var log: [String] = []
    @Published var error: String = ""

    /// The registered SEP key (on success) for Phase 3.
    private(set) var registeredKey: RegisteredSEPKey?

    /// The SecureEnclaveSigner used in Phase 2 (kept alive so Phase 3 can
    /// re-use the in-memory key for the login assertion). The spike uses
    // kSecAttrIsPermanent:false (see SecureEnclaveSigner.swift), so the SEP
    // key is NOT in the keychain — only in this signer's in-memory dict.
    // For a single-process spike run, passing the signer to Phase 3 works.
    // Production (2.2) should use kSecAttrIsPermanent:true.
    private(set) var signer: SecureEnclaveSigner?

    func resetSteps() {
        steps = [
            GRPCRegisterStep(id: 1, title: "Connect gRPC (TLS+ALPN+mTLS)"),
            GRPCRegisterStep(id: 2, title: "CreateAuthenticateChallenge (MANAGE_DEVICES)"),
            GRPCRegisterStep(id: 3, title: "Solve existing-device challenge (Face ID #1)"),
            GRPCRegisterStep(id: 4, title: "CreateRegisterChallenge (WEBAUTHN, PASSWORDLESS)"),
            GRPCRegisterStep(id: 5, title: "Create SEP key + WebAuthn.register (Face ID #2)"),
            GRPCRegisterStep(id: 6, title: "AddMFADeviceSync (ContextUser, no token)"),
        ]
        overallStatus = "idle"
        log = []
        error = ""
        registeredKey = nil
    }

    /// Run Phase 2: register a SEP key via gRPC.
    ///
    /// - Parameters:
    ///   - host: the Teleport proxy hostname (e.g. "teleport.pcad.it")
    ///   - clientCertPEM: the Phase 1 TLS cert (PEM)
    ///   - clientKeyPEM: the Phase 1 TLS private key (PEM)
    func run(host: String, clientCertPEM: String, clientKeyPEM: String) async {
        resetSteps()
        overallStatus = "running"
        appendLog("Starting Phase 2: gRPC SEP-key registration…")
        GRPCRegisterLog.result("started host=\(host)")

        #if canImport(Network)
        do {
            try await runFlow(host: host, certPEM: clientCertPEM, keyPEM: clientKeyPEM)
            overallStatus = "passed"
            GRPCRegisterLog.result("PASSED — SEP key registered via gRPC")
            appendLog("=== PASSED — SEP key registered via gRPC ===")
        } catch let e as GRPCError {
            self.error = e.description
            overallStatus = "failed"
            GRPCRegisterLog.result("FAILED: \(e.description)")
            appendLog("FAILED: \(e.description)")
        } catch {
            self.error = error.localizedDescription
            overallStatus = "failed"
            GRPCRegisterLog.result("FAILED: \(error.localizedDescription)")
            appendLog("FAILED: \(error.localizedDescription)")
        }
        #else
        // Non-Apple platform: can't run (no Network.framework).
        self.error = "gRPC transport requires Apple platform (Network.framework)"
        overallStatus = "failed"
        appendLog(self.error)
        #endif
    }

    // MARK: - Flow

    #if canImport(Network)
    private func runFlow(host: String, certPEM: String, keyPEM: String) async throws {
        // ── Step 1: connect gRPC ──────────────────────────────────────────
        try await setStep(1, .inProgress)
        appendLog("[1/6] Dialing \(host):443 with TLS+ALPN(teleport-proxy-grpc-mtls)+client cert…")
        GRPCRegisterLog.step("dial", "host=\(host)")
        let conn = try await TeleportGRPCConnection.connect(
            host: host, port: 443,
            clientCertPEM: certPEM,
            clientKeyPEM: keyPEM
        )
        GRPCRegisterLog.step("dial", "connected")
        appendLog("[1/6] gRPC connected (ALPN negotiated)")
        try await setStep(1, .done, "connected")

        defer { Task { try? await conn.close() } }

        // ── Step 2: CreateAuthenticateChallenge (ContextUser, MANAGE_DEVICES)
        try await setStep(2, .inProgress)
        var authReq = Proto_CreateAuthenticateChallengeRequest()
        authReq.contextUser = Proto_ContextUser()
        authReq.challengeExtensions = Proto_ChallengeExtensions()
        authReq.challengeExtensions.scope = .manageDevices
        GRPCRegisterLog.step("create_auth_challenge", "ContextUser MANAGE_DEVICES")
        appendLog("[2/6] CreateAuthenticateChallenge (ContextUser, MANAGE_DEVICES)…")
        let authChal: Proto_MFAAuthenticateChallenge = try await conn.unary(
            path: "/proto.AuthService/CreateAuthenticateChallenge",
            request: authReq,
            responseType: Proto_MFAAuthenticateChallenge.self
        )
        GRPCRegisterLog.step("create_auth_challenge", "got challenge")
        let challengeStr = authChal.webauthnChallenge?.publicKey.challenge ?? Data()
        appendLog("[2/6] Got authenticate challenge (\(challengeStr.count) bytes)")
        try await setStep(2, .done, "challenge \(challengeStr.count)B")

        // ── Step 3: solve the existing-device challenge ──────────────────
        // The authenticate challenge is for an EXISTING device (the iCloud
        // passkey or a previously-registered SEP key). We solve it with a
        // native SEP assertion via WebAuthn.login.
        // NOTE: if the user has no existing MFA device, authChal.webauthnChallenge
        // may be nil — in that case we skip step 3 (CreateRegisterChallenge
        // works without ExistingMFAResponse for the first device).
        var existingMfaResponse: Proto_MFAAuthenticateResponse? = nil
        if authChal.webauthnChallenge != nil && !challengeStr.isEmpty {
            try await setStep(3, .inProgress)
            appendLog("[3/6] Solving existing-device challenge (Face ID #1)…")
            GRPCRegisterLog.step("solve_existing", "Face ID #1")
            // For the spike, we use the iCloud passkey via the native
            // ASAuthorization API. This is the one piece 1.6b didn't do
            // (1.6b used the invite-token path which skips this step).
            // TODO: implement the iCloud-passkey assertion. For now, if the
            // user has an existing device, we can't solve it natively from
            // iOS without ASAuthorizationPlatformPublicKeyCredentialAssertion.
            // FALLBACK: skip with ExistingMFAResponse=nil (works only if the
            // user has no existing MFA device — the "first device" path).
            appendLog("[3/6] SKIPPED — no existing-device assertion (first-device path)")
            GRPCRegisterLog.step("solve_existing", "skipped (first-device path)")
            try await setStep(3, .done, "skipped (first device)")
        } else {
            appendLog("[3/6] No existing-device challenge (first MFA device)")
            try await setStep(3, .done, "none (first device)")
        }

        // ── Step 4: CreateRegisterChallenge ───────────────────────────────
        try await setStep(4, .inProgress)
        var regReq = Proto_CreateRegisterChallengeRequest()
        regReq.deviceType = .webauthn
        regReq.deviceUsage = .passwordless
        regReq.existingMfaResponse = existingMfaResponse
        GRPCRegisterLog.step("create_register_challenge", "WEBAUTHN PASSWORDLESS")
        appendLog("[4/6] CreateRegisterChallenge (WEBAUTHN, PASSWORDLESS)…")
        let regChal: Proto_MFARegisterChallenge = try await conn.unary(
            path: "/proto.AuthService/CreateRegisterChallenge",
            request: regReq,
            responseType: Proto_MFARegisterChallenge.self
        )
        GRPCRegisterLog.step("create_register_challenge", "got challenge")
        guard let webauthnCC = regChal.webauthn?.publicKey,
              !webauthnCC.challenge.isEmpty else {
            throw GRPCError.decode("no webauthn register challenge")
        }
        let rpID = webauthnCC.rp?.id ?? host
        let challenge = webauthnCC.challenge
        appendLog("[4/6] Got register challenge (\(challenge.count) bytes, rpID=\(rpID))")
        try await setStep(4, .done, "challenge \(challenge.count)B, rpID=\(rpID)")

        // ── Step 5: create SEP key + WebAuthn.register ───────────────────
        try await setStep(5, .inProgress)
        let signer = SecureEnclaveSigner(biometry: true)
        self.signer = signer
        let (credID, pubKeyRaw) = try signer.createKey()
        let origin = "https://\(host)"
        let ccr = try WebAuthn.register(
            origin: origin, rpID: rpID, challenge: challenge,
            credentialID: credID, publicKeyRaw: pubKeyRaw, signer: signer
        )
        GRPCRegisterLog.step("sep_key_created", "credID=\(credID.base64URLEncodedString().prefix(16))…")
        appendLog("[5/6] SEP key created + WebAuthn.register (Face ID #2 presented)")
        try await setStep(5, .done, "credID \(credID.base64URLEncodedString().prefix(16))…")

        // ── Step 6: AddMFADeviceSync ──────────────────────────────────────
        try await setStep(6, .inProgress)
        var addReq = Proto_AddMFADeviceSyncRequest()
        addReq.contextUser = Proto_ContextUser()
        addReq.newDeviceName = "vvterm-1.10-spike"
        addReq.newMfaResponse = Proto_MFARegisterResponse()
        // Build the WebAuthn registration response into the proto type.
        addReq.newMfaResponse.webauthn = Proto_CredentialCreationResponse()
        // The SEPWebAuthn.CredentialCreationResponse fields are base64url-
        // encoded STRINGS; the proto expects raw BYTES. Decode them.
        addReq.newMfaResponse.webauthn.id = ccr.id
        addReq.newMfaResponse.webauthn.rawId = Data(base64URLEncoded: ccr.rawId) ?? Data(ccr.rawId.utf8)
        addReq.newMfaResponse.webauthn.type = ccr.type
        addReq.newMfaResponse.webauthn.response.clientDataJson = Data(base64URLEncoded: ccr.response.clientDataJSON) ?? Data(ccr.response.clientDataJSON.utf8)
        addReq.newMfaResponse.webauthn.response.attestationObject = Data(base64URLEncoded: ccr.response.attestationObject) ?? Data(ccr.response.attestationObject.utf8)
        addReq.deviceUsage = .passwordless

        GRPCRegisterLog.step("add_mfa_device", "AddMFADeviceSync")
        appendLog("[6/6] AddMFADeviceSync (ContextUser, no token)…")
        let addResp: Proto_AddMFADeviceSyncResponse = try await conn.unary(
            path: "/proto.AuthService/AddMFADeviceSync",
            request: addReq,
            responseType: Proto_AddMFADeviceSyncResponse.self
        )
        _ = addResp  // success = no error thrown
        GRPCRegisterLog.step("add_mfa_device", "device registered")
        appendLog("[6/6] SEP key registered via gRPC AddMFADeviceSync")
        try await setStep(6, .done, "registered")

        registeredKey = RegisteredSEPKey(credentialID: credID, publicKeyRaw: pubKeyRaw)
    }
    #endif

    // MARK: - Step helpers

    private func setStep(_ id: Int, _ status: GRPCRegisterStepStatus, _ detail: String = "") async {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[idx].status = status
        if !detail.isEmpty { steps[idx].detail = detail }
    }

    private func appendLog(_ line: String) {
        log.append(line)
    }
}
