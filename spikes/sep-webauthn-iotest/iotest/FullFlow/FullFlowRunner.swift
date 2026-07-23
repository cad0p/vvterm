// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  FullFlowRunner.swift
//  iotest
//
//  Session 1.10 — orchestrates the full cert→gRPC→SEP-key→login chain:
//    Phase 1: headless bootstrap (reuse HeadlessRunner) → cert + TLS cert
//    Phase 2: gRPC register SEP key (GRPCRegisterRunner) → registered key
//    Phase 3: passwordless login with the SEP key (reuse 1.6b login flow)
//

import Foundation
import OSLog
import CryptoKit

enum FullFlowLog {
    static let logger = Logger(subsystem: "it.pcad.vvterm.iotest", category: "fullflow")
    static func step(_ phase: String, _ message: String) {
        logger.notice("[IOTEST] fullflow_\(phase, privacy: .public) \(message, privacy: .public)")
    }
}

/// The overall phase state.
enum FullFlowPhase: String, CaseIterable {
    case phase1 = "Phase 1: Headless bootstrap"
    case phase2 = "Phase 2: gRPC register SEP key"
    case phase3 = "Phase 3: Passwordless login"
}

struct FullFlowPhaseState: Identifiable {
    let id: Int
    let phase: FullFlowPhase
    var status: String = "pending"  // pending | running | passed | failed
    var detail: String = ""
}

@MainActor
final class FullFlowRunner: ObservableObject {
    @Published var phases: [FullFlowPhaseState] = []
    @Published var overallStatus: String = "idle"  // idle | running | passed | failed
    @Published var log: [String] = []
    @Published var error: String = ""

    /// Phase 1 result (for display).
    @Published var phase1CertLength: Int = 0
    @Published var phase1TLSCertLength: Int = 0
    @Published var phase1Duration: Double = 0

    /// Phase 2 result.
    @Published var phase2CredentialID: String = ""

    /// Phase 3 result.
    @Published var phase3CertLength: Int = 0

    /// Whether a SEP key from a previous run is available in the keychain
    /// (persisted credentialID in UserDefaults). When true, the UI offers a
    /// "Phase 3 only" button that skips Phase 1+2.
    @Published var hasSavedKey: Bool = false

    private let headless = HeadlessRunner()
    private let grpcRegister = GRPCRegisterRunner()

    /// UserDefaults key for the last-registered SEP credentialID (base64url).
    /// The credentialID is the kSecAttrApplicationLabel on the persistent
    /// SecureEnclave key, so we can reload it across app launches.
    private let savedCredentialIDKey = "vvterm.iotest.phase2.credentialID"
    /// UserDefaults key for the registered SEP key's WebAuthn user handle
    /// (base64url). Required by the server's passwordless login verify path.
    private let savedUserHandleKey = "vvterm.iotest.phase2.userHandle"

    init() {
        hasSavedKey = UserDefaults.standard.string(forKey: savedCredentialIDKey) != nil
    }

    func resetPhases() {
        phases = [
            FullFlowPhaseState(id: 1, phase: .phase1),
            FullFlowPhaseState(id: 2, phase: .phase2),
            FullFlowPhaseState(id: 3, phase: .phase3),
        ]
        overallStatus = "idle"
        log = []
        error = ""
        phase1CertLength = 0
        phase1TLSCertLength = 0
        phase1Duration = 0
        phase2CredentialID = ""
        phase3CertLength = 0
    }

    /// Run the full chain.
    ///
    /// - Parameters:
    ///   - user: the Teleport username
    ///   - host: the Teleport proxy hostname (e.g. "teleport.pcad.it")
    ///   - deviceName: the name to register the SEP key under (must be unique
    ///     per Teleport user; collisions return ALREADY_EXISTS from
    ///     AddMFADeviceSync — delete the old device in the portal and retry)
    func run(user: String, host: String, deviceName: String) async {
        resetPhases()
        overallStatus = "running"
        appendLog("=== Starting full chain: cert → gRPC → SEP-key → login ===")
        FullFlowLog.step("started", "user=\(user) host=\(host) device=\(deviceName)")

        // ── Phase 1: headless bootstrap ───────────────────────────────────
        setPhase(1, "running")
        appendLog("\n--- Phase 1: Headless bootstrap ---")
        // Subscribe to HeadlessRunner's log to mirror into our log.
        let headlessLogTask = Task { @MainActor in
            for await _ in headless.$log.values {
                // Mirror the last line.
                if let last = headless.log.last {
                    // Only append if not already there (simple dedup).
                    if self.log.last != last {
                        // Don't append — would duplicate. Just trigger refresh.
                    }
                }
            }
        }
        headlessLogTask.cancel()

        await headless.runBootstrap(user: user, useASWebAuth: true)

        if headless.overallStatus != "passed" {
            setPhase(1, "failed", headless.postError.isEmpty ? "bootstrap failed" : headless.postError)
            overallStatus = "failed"
            error = "Phase 1 failed: \(headless.postError.isEmpty ? "no cert" : headless.postError)"
            appendLog("FAILED at Phase 1: \(error)")
            FullFlowLog.step("failed", "phase 1")
            return
        }

        phase1CertLength = headless.certBase64.count
        phase1TLSCertLength = headless.tlsCertPEM.count
        phase1Duration = headless.postDuration
        setPhase(1, "passed", "cert \(phase1CertLength) chars, tls_cert \(phase1TLSCertLength) chars, \(String(format: "%.1f", phase1Duration))s")
        appendLog("Phase 1 PASSED: cert \(phase1CertLength) chars, tls_cert \(phase1TLSCertLength) chars (\(String(format: "%.1f", phase1Duration))s)")
        FullFlowLog.step("phase1_passed", "cert=\(phase1CertLength) tls=\(phase1TLSCertLength)")

        guard let tlsKeyPair = headless.tlsKeyPair,
              !headless.tlsCertPEM.isEmpty else {
            setPhase(2, "failed", "no TLS cert/key from Phase 1")
            overallStatus = "failed"
            error = "Phase 1 succeeded but no TLS cert/key available for Phase 2"
            appendLog("FAILED: \(error)")
            return
        }

        // ── Phase 2: gRPC register SEP key ────────────────────────────────
        setPhase(2, "running")
        appendLog("\n--- Phase 2: gRPC register SEP key ---")
        await grpcRegister.run(host: host, clientCertPEM: headless.tlsCertPEM, privateKey: tlsKeyPair.privateKey, clusterName: headless.clusterName, clusterCAPEMs: headless.clusterCAPEMs, deviceName: deviceName)

        if grpcRegister.overallStatus != "passed" {
            setPhase(2, "failed", grpcRegister.error)
            overallStatus = "failed"
            error = "Phase 2 failed: \(grpcRegister.error)"
            appendLog("FAILED at Phase 2: \(grpcRegister.error)")
            FullFlowLog.step("failed", "phase 2")
            return
        }

        if let key = grpcRegister.registeredKey {
            phase2CredentialID = key.credentialID.base64URLEncodedString()
            // Persist the credentialID + userHandle so Phase 3 can run
            // standalone next launch (the SEP key itself is in the keychain
            // via kSecAttrIsPermanent:true + kSecAttrApplicationLabel).
            UserDefaults.standard.set(phase2CredentialID, forKey: savedCredentialIDKey)
            UserDefaults.standard.set(key.userHandle.base64URLEncodedString(), forKey: savedUserHandleKey)
            hasSavedKey = true
        }
        setPhase(2, "passed", "SEP key registered, credID \(phase2CredentialID.prefix(16))…")
        appendLog("Phase 2 PASSED: SEP key registered via gRPC (credID \(phase2CredentialID.prefix(16))…)")
        FullFlowLog.step("phase2_passed", "credID=\(phase2CredentialID)")

        // ── Phase 3: passwordless login with the SEP key ─────────────────
        setPhase(3, "running")
        appendLog("\n--- Phase 3: Passwordless login with SEP key ---")
        do {
            guard let signer = grpcRegister.signer else {
                throw GRPCError.transport("no signer from Phase 2")
            }
            let cert = try await runPhase3Login(host: host, registeredKey: grpcRegister.registeredKey!, signer: signer)
            phase3CertLength = cert.count
            setPhase(3, "passed", "login cert \(cert.count) chars")
            appendLog("Phase 3 PASSED: passwordless login returned cert (\(cert.count) chars)")
            FullFlowLog.step("phase3_passed", "cert=\(cert.count)")
        } catch {
            setPhase(3, "failed", error.localizedDescription)
            overallStatus = "failed"
            self.error = "Phase 3 failed: \(error.localizedDescription)"
            appendLog("FAILED at Phase 3: \(error.localizedDescription)")
            FullFlowLog.step("failed", "phase 3: \(error.localizedDescription)")
            return
        }

        overallStatus = "passed"
        appendLog("\n=== FULL CHAIN PASSED: cert → gRPC → SEP-key → login → cert ===")
        FullFlowLog.step("passed", "full chain")
    }

    // MARK: - Phase 3 only (reuses a previously-registered SEP key)

    /// Run ONLY Phase 3 (passwordless login) using a SEP key registered in a
    /// previous run + persisted to the keychain. Skips Phase 1 (headless
    /// bootstrap) + Phase 2 (gRPC register). Used for fast Phase 3 iteration:
    /// register once, then re-run login as many times as needed.
    ///
    /// - Parameter host: the Teleport proxy hostname (e.g. "teleport.pcad.it")
    func runPhase3Only(host: String) async {
        resetPhases()
        overallStatus = "running"
        appendLog("=== Phase 3 only: passwordless login with saved SEP key ===")
        FullFlowLog.step("phase3_only_started", "host=\(host)")

        // Mark Phase 1 + 2 as skipped (already done in a prior run).
        setPhase(1, "done", "skipped (Phase 3 only)")
        setPhase(2, "done", "skipped (Phase 3 only)")

        guard let credIDB64 = UserDefaults.standard.string(forKey: savedCredentialIDKey),
              let credID = Data(base64URLEncoded: credIDB64) else {
            setPhase(3, "failed", "no saved credentialID")
            overallStatus = "failed"
            self.error = "Phase 3 only: no saved SEP key. Run the full chain first to register a key."
            appendLog("FAILED: no saved SEP key — run the full chain first.")
            FullFlowLog.step("failed", "phase 3 only: no saved key")
            return
        }
        // Load the saved userHandle (required for passwordless login verify).
        let userHandle: Data
        if let uhB64 = UserDefaults.standard.string(forKey: savedUserHandleKey),
           let uh = Data(base64URLEncoded: uhB64), !uh.isEmpty {
            userHandle = uh
        } else {
            setPhase(3, "failed", "no saved userHandle")
            overallStatus = "failed"
            self.error = "Phase 3 only: no saved userHandle. Run the full chain first to register a key."
            appendLog("FAILED: no saved userHandle — run the full chain first.")
            FullFlowLog.step("failed", "phase 3 only: no saved userHandle")
            return
        }

        setPhase(3, "running")
        appendLog("\n--- Phase 3 only: loading SEP key from keychain (credID \(credIDB64.prefix(16))…) ---")
        do {
            let signer = SecureEnclaveSigner(biometry: true)
            guard let secKey = try signer.loadKey(credentialID: credID) else {
                throw GRPCError.transport("SEP key not in keychain (credID=\(credIDB64.prefix(16))…). It may have been deleted — run the full chain to re-register.")
            }
            _ = secKey
            let registeredKey = RegisteredSEPKey(credentialID: credID, publicKeyRaw: Data(), userHandle: userHandle)
            let cert = try await runPhase3Login(host: host, registeredKey: registeredKey, signer: signer)
            phase3CertLength = cert.count
            setPhase(3, "passed", "login cert \(cert.count) chars")
            appendLog("Phase 3 PASSED: passwordless login returned cert (\(cert.count) chars)")
            FullFlowLog.step("phase3_passed", "cert=\(cert.count)")
            overallStatus = "passed"
        } catch {
            setPhase(3, "failed", error.localizedDescription)
            overallStatus = "failed"
            self.error = "Phase 3 failed: \(error.localizedDescription)"
            appendLog("FAILED at Phase 3: \(error.localizedDescription)")
            FullFlowLog.step("failed", "phase 3: \(error.localizedDescription)")
        }
    }

    /// Forget the saved SEP key (clears the persisted credentialID from
    /// UserDefaults). The keychain key itself is left in place; a full-chain
    /// re-run with a new device name registers a fresh one. Useful if the
    /// server-side device was deleted in the portal.
    func forgetSavedKey() {
        UserDefaults.standard.removeObject(forKey: savedCredentialIDKey)
        UserDefaults.standard.removeObject(forKey: savedUserHandleKey)
        hasSavedKey = false
        appendLog("Forgot saved SEP credentialID (run the full chain to register a new key).")
        FullFlowLog.step("forgot_saved_key", "")
    }

    // MARK: - Phase 3 (passwordless login, reuses 1.6b login flow)

    /// Run the passwordless login with the SEP key registered in Phase 2.
    /// Mirrors SEPBiometryTestRunner steps 4-7 (login/begin → WebAuthn.login
    /// → login/finish), skipping steps 1-3 (registerchallenge / PUT token /
    /// device registration) since the key is already registered.
    private func runPhase3Login(host: String, registeredKey: RegisteredSEPKey, signer: SecureEnclaveSigner) async throws -> String {
        let baseURL = URL(string: "https://\(host)")!
        let origin = "https://\(host)"
        let rpID = host

        // Step 4: login/begin (passwordless).
        let beginBody = try JSONSerialization.data(withJSONObject: ["passwordless": true])
        let (rc4Data, rc4Status) = try await httpPOST(baseURL: baseURL, path: "/webapi/mfa/login/begin", body: beginBody)
        guard rc4Status == 200 else {
            throw GRPCError.http2("login/begin HTTP \(rc4Status): \(String(data: rc4Data, encoding: .utf8) ?? "?")")
        }
        guard let rc4 = try? JSONDecoder().decode(LoginBeginResponse.self, from: rc4Data),
              let assertion = rc4.webauthnChallenge else {
            throw GRPCError.decode("login/begin response")
        }
        let loginChallenge = Data(base64URLEncoded: assertion.publicKey.challenge) ?? Data(assertion.publicKey.challenge.utf8)
        let loginRpID = assertion.publicKey.rpId ?? rpID
        appendLog("  [3a] login/begin: challenge \(loginChallenge.count) bytes, rpID=\(loginRpID)")
        FullFlowLog.step("phase3_login_begin", "challenge=\(loginChallenge.count)B rpID=\(loginRpID)")

        // Step 5: WebAuthn.login with the registered SEP key (Face ID #3).
        FullFlowLog.step("phase3_webauthn_login", "signing credID=\(registeredKey.credentialID.count)B userHandle=\(registeredKey.userHandle.count)B")
        let assertionResp = try WebAuthn.login(
            origin: origin, rpID: loginRpID, challenge: loginChallenge,
            credentialID: registeredKey.credentialID, userHandle: registeredKey.userHandle, signer: signer
        )
        appendLog("  [3b] WebAuthn.login signed (Face ID #3)")
        FullFlowLog.step("phase3_webauthn_login", "signed sig=\(assertionResp.response.signature.count)B")

        // Step 6: ssh-keygen.
        let sshPubKey = SSHPubKey.generateEd25519AuthorizedKeys(comment: "vvterm-1.10-phase3")

        // Step 7: login/finish.
        appendLog("  [3c] login/finish: posting WebAuthn assertion + ssh pub key…")
        FullFlowLog.step("phase3_login_finish", "posting")
        let finishReq = LoginFinishReq(
            webauthnChallengeResponse: assertionResp,
            sshPubKey: Data(sshPubKey.utf8),
            ttl: 3_600_000_000_000
        )
        let finishBody = try JSONEncoder().encode(finishReq)
        let (rc7Data, rc7Status) = try await httpPOST(baseURL: baseURL, path: "/webapi/mfa/login/finish", body: finishBody)
        guard rc7Status == 200 else {
            let body = String(data: rc7Data, encoding: .utf8) ?? "<binary>"
            FullFlowLog.step("phase3_login_finish", "HTTP \(rc7Status): \(body.prefix(512))")
            throw GRPCError.http2("login/finish HTTP \(rc7Status): \(body)")
        }
        FullFlowLog.step("phase3_login_finish", "HTTP 200, decoding")
        guard let rc7 = try? JSONDecoder().decode(LoginFinishResponse.self, from: rc7Data),
              let cert = rc7.cert, !cert.isEmpty else {
            let body = String(data: rc7Data, encoding: .utf8) ?? "<binary>"
            FullFlowLog.step("phase3_login_finish", "decode failed: \(body.prefix(512))")
            throw GRPCError.decode("login/finish: no cert (body=\(body.prefix(256)))")
        }
        return cert
    }

    // MARK: - HTTP (async URLSession) — shared with 1.6b

    private func httpPOST(baseURL: URL, path: String, body: Data) async throws -> (Data, Int) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    // MARK: - Helpers

    private func setPhase(_ id: Int, _ status: String, _ detail: String = "") {
        guard let idx = phases.firstIndex(where: { $0.id == id }) else { return }
        phases[idx].status = status
        if !detail.isEmpty { phases[idx].detail = detail }
    }

    private func appendLog(_ line: String) {
        log.append(line)
    }

    /// Build a full log dump for the "Copy logs" button.
    func fullLogDump() -> String {
        var lines: [String] = []
        lines.append("=== Session 1.10 Full Chain — results ===")
        lines.append("Overall: \(overallStatus)")
        for p in phases {
            lines.append("\(p.phase.rawValue): \(p.status) — \(p.detail)")
        }
        if !error.isEmpty { lines.append("Error: \(error)") }
        lines.append("")
        lines.append("=== Log ===")
        lines.append(contentsOf: log)
        return lines.joined(separator: "\n")
    }
}
