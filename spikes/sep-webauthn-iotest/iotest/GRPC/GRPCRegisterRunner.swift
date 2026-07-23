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
    /// The WebAuthn user handle (user.id from the register challenge). Required
    /// by the server's passwordless login verify path (login.go:268 —
    /// "webauthn user handle required for passwordless"). The server uses it
    /// to resolve which Teleport user is logging in (discoverable credential).
    /// Captured from CreateRegisterChallenge's webauthn.publicKey.user.id.
    let userHandle: Data
}

extension GRPCError {
    /// gRPC status code 6 = ALREADY_EXISTS. Teleport returns this from
    /// AddMFADeviceSync when a device with the requested name already
    /// exists for the user. The raw message ("grpc(6): MFA device with
    /// name \"X\" already exists") is accurate but not actionable —
    /// surface a hint to delete the old device in the portal.
    var isAlreadyExists: Bool {
        if case .grpc(let status, _) = self, status == 6 { return true }
        return false
    }
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

    /// The SecureEnclaveSigner used in Phase 2. The SEP key is persisted to
    /// the keychain (kSecAttrIsPermanent:true + kSecAttrApplicationLabel:
    /// credentialID), so it survives app relaunch. Phase 3 can re-use the
    /// in-memory signer in the same session, or load the key from the
    /// keychain via SecureEnclaveSigner.loadKey(credentialID:) in a later
    /// session (see FullFlowRunner.runPhase3Only).
    private(set) var signer: SecureEnclaveSigner?

    func resetSteps() {
        steps = [
            GRPCRegisterStep(id: 1, title: "Connect gRPC (TLS+ALPN+mTLS)"),
            GRPCRegisterStep(id: 2, title: "CreateAuthenticateChallenge (+BrowserMFATSHRedirectURL)"),
            GRPCRegisterStep(id: 3, title: "Browser MFA assertion (Safari + Face ID)"),
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
    ///   - privateKey: the Phase 1 TLS private key (SecKey)
    ///   - deviceName: the name to register the SEP key under (must be unique
    ///     per Teleport user; ALREADY_EXISTS is surfaced as an actionable error)
    func run(host: String, clientCertPEM: String, privateKey: SecKey, clusterName: String, clusterCAPEMs: [String], deviceName: String) async {
        resetSteps()
        overallStatus = "running"
        appendLog("Starting Phase 2: gRPC SEP-key registration (device name=\(deviceName))…")
        GRPCRegisterLog.result("started host=\(host) device=\(deviceName)")

        #if canImport(Network)
        do {
            try await runFlow(host: host, certPEM: clientCertPEM, privateKey: privateKey, clusterName: clusterName, clusterCAPEMs: clusterCAPEMs, deviceName: deviceName)
            overallStatus = "passed"
            GRPCRegisterLog.result("PASSED — SEP key registered via gRPC")
            appendLog("=== PASSED — SEP key registered via gRPC ===")
        } catch let e as GRPCError {
            self.error = GRPCRegisterRunner.actionableMessage(for: e, deviceName: deviceName)
            overallStatus = "failed"
            GRPCRegisterLog.result("FAILED: \(e.description)")
            appendLog("FAILED: \(GRPCRegisterRunner.actionableMessage(for: e, deviceName: deviceName))")
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
    private func runFlow(host: String, certPEM: String, privateKey: SecKey, clusterName: String, clusterCAPEMs: [String], deviceName: String) async throws {
        // ── Step 1: connect gRPC ──────────────────────────────────────────
        try await setStep(1, .inProgress)
        appendLog("[1/6] Dialing \(host):443 with TLS+ALPN(teleport-auth@<cluster>)+client cert…")
        GRPCRegisterLog.step("dial", "host=\(host) cluster=\(clusterName) ca_certs=\(clusterCAPEMs.count)")
        let conn = try await TeleportGRPCConnection.connect(
            host: host, port: 443,
            clientCertPEM: certPEM,
            privateKey: privateKey,
            clusterName: clusterName,
            clusterCAPEMs: clusterCAPEMs
        )
        GRPCRegisterLog.step("dial", "connected")
        appendLog("[1/6] gRPC connected (ALPN negotiated)")
        try await setStep(1, .done, "connected")

        defer { Task { try? await conn.close() } }

        // ── Steps 2 + 3: Browser MFA ceremony (CreateAuthenticateChallenge +
        //    the existing-device assertion). The ceremony owns both: it starts
        //    a loopback NWListener, calls CreateAuthenticateChallenge with
        //    BrowserMFATSHRedirectURL, opens Safari to /web/mfa/browser/<id>,
        //    awaits the loopback callback, and returns ExistingMFAResponse.Browser.
        //    If the user has no existing MFA device, the ceremony throws
        //    noBrowserMFAChallenge and we fall back to the first-device path
        //    (ExistingMFAResponse = nil).
        try await setStep(2, .inProgress)
        appendLog("[2/6] CreateAuthenticateChallenge (ContextUser, MANAGE_DEVICES, +BrowserMFATSHRedirectURL)…")
        GRPCRegisterLog.step("create_auth_challenge", "ContextUser MANAGE_DEVICES + BrowserMFATSHRedirectURL")

        let ceremony = BrowserMFACeremony()
        ceremony.onLog = { [weak self] line in self?.appendLog(line) }

        var existingMfaResponse: Proto_MFAAuthenticateResponse? = nil
        do {
            try await setStep(3, .inProgress)
            appendLog("[3/6] Browser MFA: solving existing-device challenge (Safari + Face ID)…")
            GRPCRegisterLog.step("solve_existing", "Browser MFA ceremony")
            let browserResp = try await ceremony.run(conn: conn, host: host)
            GRPCRegisterLog.step("solve_existing", "got BrowserMFAResponse request_id=\(browserResp.requestID.prefix(16))…")
            appendLog("[3/6] Browser MFA: assertion complete")
            var mfaResp = Proto_MFAAuthenticateResponse()
            mfaResp.browser = browserResp
            existingMfaResponse = mfaResp
            try await setStep(2, .done, "BrowserMFAChallenge")
            try await setStep(3, .done, "Browser MFA assertion")
        } catch BrowserMFACeremonyError.noBrowserMFAChallenge {
            // The user has no existing MFA device — first-device path.
            appendLog("[2/6] No BrowserMFAChallenge (first MFA device path)")
            GRPCRegisterLog.step("solve_existing", "skipped (first-device path)")
            try await setStep(2, .done, "no BrowserMFAChallenge (first device)")
            try await setStep(3, .done, "skipped (first device)")
        }

        // ── Step 4: CreateRegisterChallenge ───────────────────────────────
        try await setStep(4, .inProgress)
        var regReq = Proto_CreateRegisterChallengeRequest()
        regReq.deviceType = .webauthn
        regReq.deviceUsage = .passwordless
        if let existingMfaResponse {
            regReq.existingMfaResponse = existingMfaResponse
        }
        GRPCRegisterLog.step("create_register_challenge", "WEBAUTHN PASSWORDLESS")
        appendLog("[4/6] CreateRegisterChallenge (WEBAUTHN, PASSWORDLESS)…")
        let regChal: Proto_MFARegisterChallenge = try await conn.unary(
            path: "/proto.AuthService/CreateRegisterChallenge",
            request: regReq,
            responseType: Proto_MFARegisterChallenge.self
        )
        GRPCRegisterLog.step("create_register_challenge", "got challenge")
        let webauthnCC = regChal.webauthn.publicKey
        guard !webauthnCC.challenge.isEmpty else {
            throw GRPCError.decode("no webauthn register challenge")
        }
        let rpID = webauthnCC.rp.id.isEmpty ? host : webauthnCC.rp.id
        let challenge = webauthnCC.challenge
        // Capture the WebAuthn user handle (user.id) — the server requires it
        // for passwordless login verify (login.go:268). It's a base64url-
        // encoded byte string in the proto (UserEntity.id is a string).
        // Capture the WebAuthn user handle (user.id) — the server requires it
        // for passwordless login verify (login.go:268). The proto's
        // UserEntity.id is a STRING carrying the raw UUID (e.g.
        // "ffd6d859-6ba3-4cc7-9432-55c8e7e59b6b") — NOT base64url-encoded,
        // unlike the HTTP /webapi/mfa/registerchallenge response where
        // user.id is a base64url Buffer. The 1.6b HTTP runner used
        // Data(base64URLEncoded:); that's correct for HTTP but WRONG here:
        // the UUID string happens to be valid base64url, so it silently decodes
        // to garbage bytes that don't match the server's stored webID
        // (server error: 'key /webauthn/users/<uuid> is not found'). Use the
        // UTF-8 bytes directly so the userHandle matches the server's
        // []byte(uuid.New().String()) storage.
        let userHandle = Data(webauthnCC.user.id.utf8)
        GRPCRegisterLog.step("create_register_challenge", "got challenge userHandle=\(userHandle.count)B user.id=\(webauthnCC.user.id.prefix(16))")
        appendLog("[4/6] Got register challenge (\(challenge.count) bytes, rpID=\(rpID), userHandle=\(userHandle.count)B)")
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
        addReq.newDeviceName = deviceName
        addReq.newMfaResponse = Proto_MFARegisterResponse()
        // Build the WebAuthn registration response into the proto type.
        addReq.newMfaResponse.webauthn = Proto_CredentialCreationResponse()
        // The SEPWebAuthn.CredentialCreationResponse fields are base64url-
        // encoded STRINGS; the proto expects raw BYTES (raw_id) + a string id.
        addReq.newMfaResponse.webauthn.id = ccr.id
        addReq.newMfaResponse.webauthn.rawID = Data(base64URLEncoded: ccr.rawId) ?? Data(ccr.rawId.utf8)
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

        registeredKey = RegisteredSEPKey(credentialID: credID, publicKeyRaw: pubKeyRaw, userHandle: userHandle)
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

    // MARK: - Actionable error messages

    /// Turn a gRPC error into a user-facing message with a suggested next step.
    /// For ALREADY_EXISTS (code 6), hint that the user delete the old device
    /// in the Teleport web portal (or pick a new name).
    static func actionableMessage(for error: GRPCError, deviceName: String) -> String {
        if error.isAlreadyExists {
            return """
            A device named \"\(deviceName)\" already exists for this user. \
            Delete it in the Teleport web portal (Settings → Management → Devices / \
            Add MFA Device), then retry — or pick a new name in the Device field above.
            """
        }
        return error.description
    }
}
