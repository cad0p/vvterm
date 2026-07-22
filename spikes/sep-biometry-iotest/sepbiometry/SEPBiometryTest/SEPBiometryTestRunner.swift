// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  SEPBiometryTestRunner.swift
//  sepbiometry
//
//  Session 1.6b Option A — the same SEP+biometry flow as the Mac CLI
//  (spikes/sep-webauthn/Sources/sep-spike-cli/main.swift with --biometry),
//  ported to run on iOS with Face ID. Reuses the SEPWebAuthn library verbatim
//  (imported as a local Swift package target) so the wire format is identical.
//
//  The runner is a @MainActor observable that drives the 7-step flow and
//  surfaces each step's status + log line to the UI. The UI shows a
//  "Register + Login" button; the user taps it, gets two Face ID prompts
//  (at steps 5 and 7 — the two SecKeyCreateSignature calls), and sees the
//  cert returned.
//

import Foundation
import OSLog
// The SEPWebAuthn library sources are compiled directly into this target
// (added via the Xcode project's "SEPWebAuthn (from spike)" group), so we
// do NOT `import SEPWebAuthn` — the types are in the same module as this
// file. This keeps the wire format byte-identical to session 1.5/1.6b.
import CryptoKit  // for Curve25519.Signing.PrivateKey (ssh-keygen replacement)

enum SEPBiometryStepStatus: String {
    case pending, inProgress, done, failed
}

struct SEPBiometryStep: Identifiable {
    let id: Int
    let title: String
    var status: SEPBiometryStepStatus = .pending
    var detail: String = ""
}

enum SEPBiometryError: LocalizedError {
    case http(status: Int, body: String)
    case decode(String)
    case noCert
    case missingToken
    case runner(String)

    var errorDescription: String? {
        switch self {
        case .http(let s, let b): return "HTTP \(s): \(b)"
        case .decode(let m):      return "decode: \(m)"
        case .noCert:             return "no cert in response"
        case .missingToken:       return "invite token required"
        case .runner(let m):      return m
        }
    }
}

@MainActor
final class SEPBiometryTestRunner: ObservableObject {
    static let logger = Logger(subsystem: "it.pcad.vvterm.sepbiometry", category: "runner")

    @Published var steps: [SEPBiometryStep] = []
    @Published var certBase64: String = ""
    @Published var overallStatus: String = "idle"   // idle | running | passed | failed
    @Published var error: String?

    private var signer: SecureEnclaveSigner?
    private var credentialID: Data?
    private var userHandle: Data?
    private let origin = "https://teleport.pcad.it"
    private let rpID = "teleport.pcad.it"

    // MARK: - Log

    func log(_ marker: String, _ message: String) {
        Self.logger.notice("[SEPBIOMETRY] \(marker, privacy: .public) \(message, privacy: .public)")
        // Also surface to the UI's log panel.
        if let idx = steps.firstIndex(where: { $0.id == -1 }) {
            steps[idx].detail += message + "\n"
        }
    }

    // MARK: - Run

    func run(token: String, host: String) async {
        guard !token.isEmpty else {
            self.error = SEPBiometryError.missingToken.errorDescription
            overallStatus = "failed"
            return
        }
        overallStatus = "running"
        error = nil
        certBase64 = ""
        steps = [
            SEPBiometryStep(id: -1, title: "log", detail: ""),
            SEPBiometryStep(id: 1, title: "registerchallenge"),
            SEPBiometryStep(id: 2, title: "createKey + WebAuthn.register"),
            SEPBiometryStep(id: 3, title: "PUT /webapi/users/password/token"),
            SEPBiometryStep(id: 4, title: "POST /webapi/mfa/login/begin"),
            SEPBiometryStep(id: 5, title: "WebAuthn.login (Face ID #1)"),
            SEPBiometryStep(id: 6, title: "ssh-keygen ed25519"),
            SEPBiometryStep(id: 7, title: "POST /webapi/mfa/login/finish (Face ID #2)"),
        ]
        signer = SecureEnclaveSigner(biometry: true)

        do {
            try await runFlow(token: token, host: host)
            overallStatus = "passed"
            log("result", "=== PASSED ===")
        } catch {
            self.error = error.localizedDescription
            overallStatus = "failed"
            log("error", error.localizedDescription)
        }
    }

    // MARK: - 7-step flow (ports sep-spike-cli main.swift)

    private func runFlow(token: String, host: String) async throws {
        guard let signer else { throw SEPBiometryError.runner("no signer") }
        let baseURL = URL(string: "https://\(host)")!

        // ── Step 1: registerchallenge ────────────────────────────────────
        try await setStep(1, .inProgress)
        log("step1", "POST /webapi/mfa/token/<token>/registerchallenge")
        let regChalBody = try JSONSerialization.data(withJSONObject: [
            "deviceType": "webauthn",
            "deviceUsage": "passwordless",
        ])
        let (rc1Data, rc1Status) = try await httpPOST(
            baseURL: baseURL,
            path: "/webapi/mfa/token/\(token)/registerchallenge",
            body: regChalBody
        )
        guard rc1Status == 200 else {
            try await failStep(1, rc1Status, rc1Data)
        }
        guard let rc1 = try? JSONDecoder().decode(RegisterChallengeResponse.self, from: rc1Data),
              let challengeB64 = rc1.webauthn?.publicKey.challenge,
              let rpId = rc1.webauthn?.publicKey.rp.id,
              let userName = rc1.webauthn?.publicKey.user.name,
              let userHandleB64 = rc1.webauthn?.publicKey.user.id
        else {
            throw SEPBiometryError.decode("registerchallenge response")
        }
        let challenge = Data(base64URLEncoded: challengeB64) ?? Data(challengeB64.utf8)
        userHandle = Data(base64URLEncoded: userHandleB64) ?? Data(userHandleB64.utf8)
        log("step1", "challenge=\(challengeB64), rpId=\(rpId), user=\(userName)")
        try await setStep(1, .done, "challenge \(challenge.count) bytes, rpId=\(rpId)")

        // ── Step 2: createKey + WebAuthn.register ───────────────────────
        try await setStep(2, .inProgress)
        let (credID, pubKeyRaw) = try signer.createKey()
        credentialID = credID
        let ccr = try WebAuthn.register(
            origin: origin, rpID: rpID, challenge: challenge,
            credentialID: credID, publicKeyRaw: pubKeyRaw, signer: signer
        )
        log("step2", "credentialID=\(credID.base64URLEncodedString()), pubkey=\(pubKeyRaw.count) bytes")
        try await setStep(2, .done, "credentialID \(credID.base64URLEncodedString().prefix(16))…, pubkey \(pubKeyRaw.count)B")

        // ── Step 3: PUT /webapi/users/password/token ────────────────────
        try await setStep(3, .inProgress)
        let changeReq = ChangeUserAuthReq(
            token: token, deviceName: "vvterm-sep-spike-ios",
            password: "", webauthnCreationResponse: ccr
        )
        let changeBody = try JSONEncoder().encode(changeReq)
        let (rc3Data, rc3Status) = try await httpPUT(
            baseURL: baseURL, path: "/webapi/users/password/token", body: changeBody
        )
        guard rc3Status == 200 else { try await failStep(3, rc3Status, rc3Data) }
        log("step3", "device registered")
        try await setStep(3, .done, "device registered (first passwordless device)")

        // ── Step 4: login/begin ─────────────────────────────────────────
        try await setStep(4, .inProgress)
        let beginBody = try JSONSerialization.data(withJSONObject: ["passwordless": true])
        let (rc4Data, rc4Status) = try await httpPOST(
            baseURL: baseURL, path: "/webapi/mfa/login/begin", body: beginBody
        )
        guard rc4Status == 200 else { try await failStep(4, rc4Status, rc4Data) }
        guard let rc4 = try? JSONDecoder().decode(LoginBeginResponse.self, from: rc4Data),
              let assertion = rc4.webauthnChallenge
        else {
            throw SEPBiometryError.decode("login/begin response")
        }
        let loginChallengeB64 = assertion.publicKey.challenge
        let loginChallenge = Data(base64URLEncoded: loginChallengeB64) ?? Data(loginChallengeB64.utf8)
        let loginRpID = assertion.publicKey.rpId ?? rpID
        log("step4", "challenge=\(loginChallengeB64), rpId=\(loginRpID)")
        try await setStep(4, .done, "challenge \(loginChallenge.count) bytes, rpId=\(loginRpID)")

        // ── Step 5: WebAuthn.login — Face ID prompt #1 ─────────────────
        try await setStep(5, .inProgress)
        guard let credID2 = credentialID else { throw SEPBiometryError.runner("no credID") }
        let assertionResp = try WebAuthn.login(
            origin: origin, rpID: loginRpID, challenge: loginChallenge,
            credentialID: credID2, userHandle: userHandle, signer: signer
        )
        log("step5", "assertion sig \(assertionResp.response.signature.prefix(24))…")
        try await setStep(5, .done, "assertion signed (Face ID presented)")

        // ── Step 6: ssh-keygen ──────────────────────────────────────────
        try await setStep(6, .inProgress)
        let sshPubKey = try await generateSSHPubKey()
        log("step6", "ssh_pub_key=\(sshPubKey.prefix(40))…")
        try await setStep(6, .done, "ed25519 keypair generated")

        // ── Step 7: login/finish — Face ID prompt #2 ────────────────────
        try await setStep(7, .inProgress)
        let finishReq = LoginFinishReq(
            webauthnChallengeResponse: assertionResp,
            sshPubKey: Data(sshPubKey.utf8),
            ttl: 3_600_000_000_000  // 1h in ns
        )
        let finishBody = try JSONEncoder().encode(finishReq)
        let (rc7Data, rc7Status) = try await httpPOST(
            baseURL: baseURL, path: "/webapi/mfa/login/finish", body: finishBody
        )
        guard rc7Status == 200 else { try await failStep(7, rc7Status, rc7Data) }
        guard let rc7 = try? JSONDecoder().decode(LoginFinishResponse.self, from: rc7Data),
              let cert = rc7.cert, !cert.isEmpty
        else {
            throw SEPBiometryError.noCert
        }
        certBase64 = cert
        log("step7", "cert returned, \(cert.count) chars")
        try await setStep(7, .done, "cert returned (\(cert.count) chars)")
    }

    // MARK: - Step helpers

    private func setStep(_ id: Int, _ status: SEPBiometryStepStatus, _ detail: String = "") async {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[idx].status = status
        if !detail.isEmpty { steps[idx].detail = detail }
    }

    private func failStep(_ id: Int, _ status: Int, _ data: Data) async throws -> Never {
        let body = String(data: data, encoding: .utf8) ?? "<binary>"
        log("step\(id)", "HTTP \(status): \(body)")
        guard let idx = steps.firstIndex(where: { $0.id == id }) else {
            throw SEPBiometryError.http(status: status, body: body)
        }
        steps[idx].status = .failed
        steps[idx].detail = "HTTP \(status)"
        throw SEPBiometryError.http(status: status, body: body)
    }

    // MARK: - HTTP (async URLSession)

    private func httpPOST(baseURL: URL, path: String, body: Data) async throws -> (Data, Int) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    private func httpPUT(baseURL: URL, path: String, body: Data) async throws -> (Data, Int) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    // MARK: - ssh-keygen via Process (macOS) — but iOS doesn't have Process!
    // For iOS we generate an ed25519 key in pure Swift via CryptoKit.
    // (CryptoKit added ed25519 in iOS 13.)

    private func generateSSHPubKey() async throws -> String {
        // CryptoKit Ed25519 — generate a fresh keypair, emit the OpenSSH
        // authorized_keys string. We only send the pub key; the private key
        // is discarded (the spike doesn't connect with it).
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey.rawRepresentation  // 32 bytes

        // OpenSSH ed25519 public key wire format:
        //   string "ssh-ed25519"
        //   string pubkey (32 bytes)
        // then base64-encoded, prefixed with "ssh-ed25519 ".
        //
        // NOTE: we do NOT use UInt32.bigEndianBytes from CBOR.swift here —
        // that extension is buggy (it does `let be = self.bigEndian` then
        // shifts `be`, which double-swaps on little-endian arm64 and emits
        // little-endian bytes). The bug was latent in the 1.5 spike because
        // the CBOR path never exercises it (all CBOR values are < 256, using
        // the 1-byte form). This is the first code to actually use it, and
        // the server rejected the malformed key with
        // "illegal base64 data at input byte 3".
        //
        // Instead, emit big-endian uint32 length prefixes by shifting `self`
        // directly — `>> 24` always yields the most-significant byte
        // regardless of host endianness.
        var wire = Data()
        let alg = Data("ssh-ed25519".utf8)
        wire.append(beUInt32(UInt32(alg.count)))
        wire.append(alg)
        wire.append(beUInt32(UInt32(pub.count)))
        wire.append(pub)
        let b64 = wire.base64EncodedString()
        return "ssh-ed25519 \(b64) sep-spike-ios"
    }
}

/// Big-endian uint32 → 4 bytes, host-endianness-independent.
/// Shifting `value >> 24` always yields the most-significant byte.
private func beUInt32(_ value: UInt32) -> Data {
    var out = Data(count: 4)
    out[0] = UInt8(truncatingIfNeeded: value >> 24)
    out[1] = UInt8(truncatingIfNeeded: value >> 16)
    out[2] = UInt8(truncatingIfNeeded: value >> 8)
    out[3] = UInt8(truncatingIfNeeded: value & 0xff)
    return out
}

// MARK: - Wire types (mirror sep-spike-cli/main.swift)

struct RegisterChallengeResponse: Decodable {
    let webauthn: WebauthnCC?
    struct WebauthnCC: Decodable {
        let publicKey: PublicKey
        struct PublicKey: Decodable {
            let challenge: String
            let rp: RP
            struct RP: Decodable { let id: String; let name: String }
            let user: User
            struct User: Decodable {
                let name: String; let displayName: String; let id: String
            }
        }
    }
}

struct LoginBeginResponse: Decodable {
    let webauthnChallenge: WebauthnAssertion?
    enum CodingKeys: String, CodingKey {
        case webauthnChallenge = "webauthn_challenge"
    }
    struct WebauthnAssertion: Decodable {
        let publicKey: PublicKey
        struct PublicKey: Decodable {
            let challenge: String
            let rpId: String?
            enum CodingKeys: String, CodingKey {
                case challenge
                case rpId = "rpId"
            }
        }
    }
}

struct LoginFinishResponse: Decodable {
    let cert: String?
    let hostSigners: [HostSigner]?
    enum CodingKeys: String, CodingKey {
        case cert
        case hostSigners = "host_signers"
    }
    struct HostSigner: Decodable {
        let domainName: String
        let checkingKeys: [String]
        enum CodingKeys: String, CodingKey {
            case domainName = "domain_name"
            case checkingKeys = "checking_keys"
        }
    }
}

struct ChangeUserAuthReq: Encodable {
    let token: String
    let deviceName: String
    let password: String
    let webauthnCreationResponse: CredentialCreationResponse
}

struct LoginFinishReq: Encodable {
    let webauthnChallengeResponse: CredentialAssertionResponse
    let sshPubKey: Data
    let ttl: Int64
    enum CodingKeys: String, CodingKey {
        case webauthnChallengeResponse = "webauthn_challenge_response"
        case sshPubKey = "ssh_pub_key"
        case ttl
    }
}

// MARK: - UInt32 big-endian helper for the OpenSSH wire format
//
// NOTE: do NOT re-declare bigEndianBytes here — CBOR.swift (compiled into
// this same target via the relative-path group) already provides it for
// UInt16/UInt32/UInt64. Re-declaring causes 'invalid redeclaration' at
// compile time. The call sites above use the CBOR.swift extension.
