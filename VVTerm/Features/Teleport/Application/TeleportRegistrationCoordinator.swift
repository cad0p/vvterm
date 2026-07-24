// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportRegistrationCoordinator.swift
//  VVTerm
//
//  Phase 2 of the Teleport SEP-key integration: register the VVTerm SEP key.
//
//  The coordinator runs the Browser MFA ceremony (existing-device assertion
//  via Safari) → `CreateRegisterChallenge` → native SEP key registration
//  (Face ID) → `AddMFADeviceSync`. On success, the SEP key is registered on
//  the Teleport cluster + the credentialID + userHandle are persisted in
//  `TeleportKeyRing`.
//
//  This is entirely native Swift — no webview, no web session, no privilege
//  token. This is the `tsh mfa add` path (tool/tsh/common/mfa.go:430-475),
//  proven in sessions 1.10/1.11/1.12 (PRs #27/#28/#29).
//
//  The flow:
//    1. gRPC CreateAuthenticateChallenge (ContextUser, MANAGE_DEVICES,
//       BrowserMFATSHRedirectURL = loopback callback URL).
//    2. Browser MFA ceremony (Safari opens to /web/mfa/browser/<request_id>,
//       user asserts the existing iCloud passkey, loopback listener receives
//       the encrypted response, AES-GCM decrypt → CredentialAssertionResponse).
//       → ExistingMFAResponse.Browser.
//       (Skipped on the first-device path — no existing WebAuthn device.)
//    3. gRPC CreateRegisterChallenge (ExistingMFAResponse, WEBAUTHN,
//       PASSWORDLESS). Captures the user.id (WebAuthn user handle).
//    4. Native SEP key creation (SecureEnclaveSigner.createKey) + WebAuthn
//       registration response builder (Face ID prompt #2).
//    5. gRPC AddMFADeviceSync (NewDeviceName, NewMFAResponse, PASSWORDLESS,
//       no TokenID — ContextUser cert auth).
//
//  The userHandle is captured at step 3 (user.id from the register challenge,
//  decoded as UTF-8 — NOT base64url, see the 2.2 prompt gotcha) and persisted
//  alongside the credentialID. Phase 3 login requires it.
//
//  Protocol-backed (`TeleportRegistrationCoordinating`) for mock injection
//  in UI tests — the key enabler for the CI strategy.
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup D)
//    - 2026-07-21-strategy-b-session2.2-vvterm-sep-key-integration-prompt.md
//      (Phase 2 — the 5 device-only gotchas)
//    - spike: spikes/sep-webauthn-iotest/iotest/GRPC/GRPCRegisterRunner.swift
//

import Foundation
import Security
import os.log

/// The state of a Phase 2 registration attempt.
enum TeleportRegistrationState: Equatable {
    case idle
    /// Connecting the gRPC client (TLS+ALPN+mTLS dial).
    case connectingGRPC
    /// Safari is open for the Browser MFA ceremony (existing-device assertion).
    case awaitingExistingAssertion
    /// The in-app Face ID prompt is showing (SEP key creation + WebAuthn.register).
    case creatingSEPKey
    /// AddMFADeviceSync is in flight (registering the new key with the server).
    case registeringWithServer
    /// The SEP key is registered + persisted. Phase 2 complete.
    case success
    /// A step failed. The error drives the recovery UX.
    case failed(TeleportRegistrationError)
}

/// The error matrix for Phase 2.
enum TeleportRegistrationError: Error, Equatable {
    /// AddMFADeviceSync returned ALREADY_EXISTS (gRPC code 6). The user must
    /// rename the device or delete the old one in the Teleport portal.
    /// The device name is included for the inline error message.
    case deviceNameAlreadyExists(String)
    /// The Browser MFA ceremony failed (Safari didn't open, the loopback
    /// listener failed, or the user cancelled in Safari).
    case browserMFAFailed(String)
    /// The SEP key creation failed (Face ID cancelled, biometry unavailable,
    /// or the keychain rejected the persistent key).
    case sepKeyCreationFailed(String)
    /// A gRPC error from the server (non-ALREADY_EXISTS). The message is the
    /// gRPC status message.
    case server(String)
    /// An unexpected error (decode failure, connection failure, etc.).
    case unknown(String)
}

/// Protocol-backed coordinator for Phase 2 (SEP-key registration).
///
/// `@MainActor` because it drives sheet state + presents Face ID (the SEP
/// signer blocks on `SecKeyCreateSignature`, which must be on the main thread
/// for the biometric prompt).
@MainActor
protocol TeleportRegistrationCoordinating: AnyObject {
    /// The current state. SwiftUI views observe this to drive the sheet UI.
    var state: TeleportRegistrationState { get }

    /// Begin a Phase 2 registration.
    /// - Parameters:
    ///   - cluster: the Teleport cluster config.
    ///   - deviceName: the MFA device name (must be unique per Teleport user).
    ///   - bootstrapResult: the Phase-1 result (cert + TLS keypair for mTLS).
    func begin(cluster: TeleportCluster, deviceName: String, bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult) async

    /// Cancel an in-flight registration. Cancels the gRPC call + the
    /// Browser MFA ceremony.
    func cancel() async
}

@MainActor
final class TeleportRegistrationCoordinator: ObservableObject, TeleportRegistrationCoordinating {
    @Published private(set) var state: TeleportRegistrationState = .idle

    /// The injected gRPC client (wraps CreateAuthenticateChallenge,
    /// CreateRegisterChallenge, AddMFADeviceSync). Defaults to the shared
    /// `TeleportGRPCClient` in production; injectable for tests.
    private let grpcClient: any TeleportGRPCClienting

    /// The injected Browser MFA ceremony runner. Defaults to the shared
    /// `BrowserMFACeremony` in production; injectable for tests.
    private let browserMFACeremony: any BrowserMFACeremonyRunning

    /// The injected key ring (stores the credentialID + userHandle).
    private let keyRing: any TeleportKeyRingStoring

    /// The injected SEP signer (creates the persistent SEP key + signs the
    /// WebAuthn registration response). Defaults to a real
    /// `SecureEnclaveSigner`; UI tests inject a `MockSEPKeySigner`.
    private let signer: any TeleportSEPSigning

    /// The injected WebAuthn builder wrapper. In production this is just
    /// `WebAuthn.register` (a static method); the seam lets UI tests inject
    /// a mock that returns a scripted response. Defaults to the real impl.
    private let webAuthnBuilder: any TeleportWebAuthnBuilding

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "it.pcad.vvterm",
        category: "teleport-registration"
    )

    init(
        grpcClient: any TeleportGRPCClienting,
        browserMFACeremony: any BrowserMFACeremonyRunning,
        keyRing: any TeleportKeyRingStoring,
        signer: any TeleportSEPSigning = SecureEnclaveSigner(),
        webAuthnBuilder: any TeleportWebAuthnBuilding = TeleportWebAuthnBuilder()
    ) {
        self.grpcClient = grpcClient
        self.browserMFACeremony = browserMFACeremony
        self.keyRing = keyRing
        self.signer = signer
        self.webAuthnBuilder = webAuthnBuilder
    }

    func begin(
        cluster: TeleportCluster,
        deviceName: String,
        bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult
    ) async {
        state = .connectingGRPC
        logger.info("beginning registration for cluster \(cluster.host, privacy: .public) device=\(deviceName, privacy: .public)")

        // ── Step 1: connect the gRPC client with the Phase-1 cert ────────
        // The cert authenticates the call (ContextUser, mTLS). The cluster
        // CA bundle is NOT used for verification (the proxy cert is
        // "not standards compliant" — see the 2.2 prompt gotcha); the
        // concrete gRPC client always completes TLS verification.
        do {
            try await grpcClient.connect(
                host: cluster.host,
                clientCertPEM: bootstrapResult.tlsCertPEM,
                privateKey: bootstrapResult.tlsKeyPairPrivateKey,
                clusterName: bootstrapResult.clusterName,
                clusterCAPEMs: bootstrapResult.clusterCAPEMs
            )
        } catch {
            logger.error("gRPC connect failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(.server("gRPC connect failed: \(error.localizedDescription)"))
            return
        }

        // ── Step 2: CreateAuthenticateChallenge + Browser MFA ceremony ──
        // The ceremony owns both: it starts the loopback NWListener, calls
        // CreateAuthenticateChallenge with BrowserMFATSHRedirectURL, opens
        // Safari to /web/mfa/browser/<id>, awaits the loopback callback,
        // and returns ExistingMFAResponse.Browser.
        //
        // If the user has no existing WebAuthn device, the ceremony throws
        // noBrowserMFAChallenge and we fall back to the first-device path
        // (ExistingMFAResponse = nil).
        state = .awaitingExistingAssertion
        let loopbackURL = "http://localhost:0/callback"  // the concrete ceremony picks the port
        var existingMfaResponse: Proto_MFAAuthenticateResponse?
        do {
            let challenge = try await grpcClient.createAuthenticateChallenge(
                browserMFATSHRedirectURL: loopbackURL
            )
            let browserResp = try await browserMFACeremony.run(
                host: cluster.host,
                challenge: challenge
            )
            var mfaResp = Proto_MFAAuthenticateResponse()
            mfaResp.browser = browserResp
            existingMfaResponse = mfaResp
            logger.info("Browser MFA ceremony complete")
        } catch {
            // noBrowserMFAChallenge is the first-device path — not an error.
            // The concrete ceremony surfaces it as a specific error; we
            // string-match here because BrowserMFACeremonyError isn't
            // available yet (parallel agent's file).
            let msg = error.localizedDescription
            if msg.contains("noBrowserMFAChallenge") || msg.contains("no BrowserMFAChallenge") {
                logger.info("no BrowserMFAChallenge — first-device path")
                existingMfaResponse = nil
            } else {
                logger.error("Browser MFA ceremony failed: \(msg, privacy: .public)")
                state = .failed(.browserMFAFailed(msg))
                await grpcClient.disconnect()
                return
            }
        }

        // ── Step 3: CreateRegisterChallenge ──────────────────────────────
        // WEBAUTHN (3) + PASSWORDLESS (2). Captures the user.id (WebAuthn
        // user handle) — decoded as UTF-8, NOT base64url (the 2.2 prompt
        // gotcha: the gRPC proto's UserEntity.id is a raw UUID string).
        let regChal: Proto_MFARegisterChallenge
        do {
            regChal = try await grpcClient.createRegisterChallenge(
                existingMFAResponse: existingMfaResponse
            )
        } catch {
            logger.error("CreateRegisterChallenge failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(.server("CreateRegisterChallenge: \(error.localizedDescription)"))
            await grpcClient.disconnect()
            return
        }

        let webauthnCC = regChal.webauthn.publicKey
        guard !webauthnCC.challenge.isEmpty else {
            logger.error("no webauthn register challenge")
            state = .failed(.unknown("no webauthn register challenge"))
            await grpcClient.disconnect()
            return
        }
        let rpID = webauthnCC.rp.id.isEmpty ? cluster.rpID : webauthnCC.rp.id
        let challenge = webauthnCC.challenge
        // The user handle is the raw UUID string's UTF-8 bytes — NOT
        // base64url-decoded. See the 2.2 prompt gotcha.
        let userHandle = Data(webauthnCC.user.id.utf8)
        logger.info("got register challenge: \(challenge.count)B, rpID=\(rpID, privacy: .public), userHandle=\(userHandle.count)B")

        // ── Step 4: create the SEP key + build the WebAuthn registration ──
        // This is the in-app Face ID prompt (Face ID #2). The SEP key is
        // created with .biometryAny access control + kSecAttrIsPermanent
        // (persists across app relaunch — proven in 1.12).
        state = .creatingSEPKey
        let credentialID: Data
        let publicKeyRaw: Data
        do {
            (credentialID, publicKeyRaw) = try signer.createKey()
        } catch {
            logger.error("SEP key creation failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(.sepKeyCreationFailed(error.localizedDescription))
            await grpcClient.disconnect()
            return
        }

        let origin = "https://\(cluster.host)"
        let ccr: CredentialCreationResponse
        do {
            ccr = try webAuthnBuilder.register(
                origin: origin,
                rpID: rpID,
                challenge: challenge,
                credentialID: credentialID,
                publicKeyRaw: publicKeyRaw,
                signer: signer
            )
        } catch {
            logger.error("WebAuthn.register failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(.sepKeyCreationFailed("WebAuthn.register: \(error.localizedDescription)"))
            await grpcClient.disconnect()
            return
        }
        logger.info("SEP key created + WebAuthn.register signed (credID \(credentialID.base64URLEncodedString().prefix(16))…)")

        // ── Step 5: AddMFADeviceSync ─────────────────────────────────────
        // ContextUser cert auth — no privilege token. The new device name
        // must be unique per Teleport user; ALREADY_EXISTS (gRPC code 6) is
        // surfaced as an actionable error.
        state = .registeringWithServer
        var addReq = Proto_MFARegisterResponse()
        addReq.webauthn = Proto_CredentialCreationResponse()
        addReq.webauthn.id = ccr.id
        addReq.webauthn.rawID = Data(base64URLEncoded: ccr.rawId) ?? Data(ccr.rawId.utf8)
        addReq.webauthn.type = ccr.type
        addReq.webauthn.response.clientDataJson = Data(base64URLEncoded: ccr.response.clientDataJSON) ?? Data(ccr.response.clientDataJSON.utf8)
        addReq.webauthn.response.attestationObject = Data(base64URLEncoded: ccr.response.attestationObject) ?? Data(ccr.response.attestationObject.utf8)

        do {
            try await grpcClient.addMFADeviceSync(
                deviceName: deviceName,
                newMFAResponse: addReq
            )
        } catch {
            logger.error("AddMFADeviceSync failed: \(error.localizedDescription, privacy: .public)")
            // Distinguish ALREADY_EXISTS (gRPC code 6) from other errors.
            // The concrete gRPC client surfaces this via GRPCError.grpc(6, ...);
            // we string-match because GRPCError isn't concretely typed here.
            let msg = error.localizedDescription
            if msg.contains("grpc(6)") || msg.lowercased().contains("already exists") {
                state = .failed(.deviceNameAlreadyExists(deviceName))
            } else {
                state = .failed(.server("AddMFADeviceSync: \(msg)"))
            }
            await grpcClient.disconnect()
            return
        }

        // ── Success: persist the credentialID + userHandle ──────────────
        keyRing.storeRegisteredSEPKey(
            credentialID: credentialID,
            userHandle: userHandle,
            publicKeyRaw: publicKeyRaw,
            deviceName: deviceName,
            for: cluster.id
        )
        logger.info("registration succeeded — SEP key registered for cluster \(cluster.id.uuidString, privacy: .public)")

        await grpcClient.disconnect()
        state = .success
    }

    func cancel() async {
        logger.info("cancelling registration")
        await grpcClient.disconnect()
        state = .failed(.unknown("cancelled"))
    }
}
