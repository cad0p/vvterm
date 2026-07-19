//
//  TeleportLoginCoordinator.swift
//  VVTerm
//
//  Orchestrates the V1 passwordless login flow:
//    Ping → keypair generation → begin → Face ID (ASAuthorization) → finish → KeyRing.
//
//  This is the Application layer of the Teleport feature: it depends on the
//  TeleportClient (Infrastructure), the WebAuthn solver (Infrastructure),
//  the key generator (Domain), and the KeyRing store (Infrastructure), but
//  knows nothing about SSH/libssh2 — that's the cert-injection seam's job.
//
//  Reference: spec §2 (login flow), §3 (cert shape).
//

import Foundation
import AuthenticationServices

/// Result of a successful login: the KeyRing plus the resolved cluster metadata.
struct TeleportLoginResult {
    let keyRing: TeleportKeyRing
    let ping: TeleportPingResponse
}

enum TeleportLoginError: LocalizedError {
    case passwordlessDisabled
    case missingChallenge
    case invalidChallenge(String)
    case noHostSigners
    case webAuthn(Error)
    case client(TeleportClientError)
    case keyGeneration(Error)

    var errorDescription: String? {
        switch self {
        case .passwordlessDisabled:
            return "Teleport cluster does not allow passwordless login."
        case .missingChallenge:
            return "Teleport did not return a WebAuthn challenge."
        case .invalidChallenge(let detail):
            return "Invalid WebAuthn challenge: \(detail)"
        case .noHostSigners:
            return "Teleport login response contained no host signers (Host CA bundle)."
        case .webAuthn(let error):
            return error.localizedDescription
        case .client(let error):
            return error.localizedDescription
        case .keyGeneration(let error):
            return "Key generation failed: \(error.localizedDescription)"
        }
    }
}

/// Orchestrates the V1 passwordless login flow.
///
/// `presenter` must conform to `ASAuthorizationControllerPresentationContextProviding`
/// (typically the topmost `UIWindow` or `UIViewController`). Pass it from the view layer.
@MainActor
final class TeleportLoginCoordinator {

    private let client: TeleportClient
    private let webAuthnSolver = TeleportWebAuthnChallengeSolver()

    init(proxyHost: String, validateTLS: Bool = true) {
        self.client = TeleportClient(configuration: .init(
            proxyHost: proxyHost,
            validateTLS: validateTLS
        ))
    }

    /// Convenience for the common case: pcad.it production cluster.
    static let pcadItProxyHost = "teleport.pcad.it"

    /// Run the full login flow. Returns the KeyRing and cluster metadata on success.
    /// `presenter` is the `ASAuthorizationControllerPresentationContextProviding` for Face ID.
    func login(presenter: AnyObject) async throws -> TeleportLoginResult {
        // 1. Ping — discover cluster auth settings.
        let ping: TeleportPingResponse
        do {
            ping = try await client.ping()
        } catch let error as TeleportClientError {
            throw TeleportLoginError.client(error)
        }

        guard ping.auth.allowPasswordless else {
            throw TeleportLoginError.passwordlessDisabled
        }

        let rpId = ping.auth.webauthn.rpId
        let ttlNanoseconds = ping.defaultSessionTTLNanoseconds
        let suite = TeleportSignatureSuite.from(ping.auth.signatureAlgorithmSuite)

        // 2. Generate client keypairs (ed25519 SSH + ECDSA-P256 TLS for balanced-v1).
        let keyPair: TeleportKeyGenerator.GeneratedKeyPair
        do {
            keyPair = try TeleportKeyGenerator.generate(
                suite: suite,
                sshComment: "vvterm@\(ping.clusterName)"
            )
        } catch {
            throw TeleportLoginError.keyGeneration(error)
        }

        // 3. Begin passwordless login — get the WebAuthn challenge.
        let challenge: TeleportMFAAuthenticateChallenge
        do {
            challenge = try await client.beginPasswordlessLogin()
        } catch let error as TeleportClientError {
            throw TeleportLoginError.client(error)
        }

        let publicKey = challenge.webauthnChallenge.publicKey
        guard !publicKey.challenge.isEmpty else {
            throw TeleportLoginError.missingChallenge
        }
        guard let challengeData = Data.base64URLDecoded(publicKey.challenge) else {
            throw TeleportLoginError.invalidChallenge("challenge base64url decode failed")
        }

        // 4. Solve the challenge via Face ID (reuses the iCloud-Keychain passkey).
        let assertion: WebAuthnAssertionResponse
        do {
            assertion = try await webAuthnSolver.solveChallenge(
                rpId: rpId,
                challenge: challengeData,
                userVerification: publicKey.userVerification,
                presenter: presenter
            )
        } catch {
            throw TeleportLoginError.webAuthn(error)
        }

        // 5. Finish login — submit assertion + pubkeys, receive SSH cert + TLS cert + Host CA.
        let loginResponse: TeleportCLILoginResponse
        do {
            loginResponse = try await client.finishPasswordlessLogin(
                assertion: assertion,
                sshPublicKey: keyPair.sshPublicKeyAuthorized,
                tlsPublicKey: keyPair.tlsPublicKeyPEM,
                ttlNanoseconds: ttlNanoseconds
            )
        } catch let error as TeleportClientError {
            throw TeleportLoginError.client(error)
        }

        guard let hostSigner = loginResponse.hostSigners.first else {
            throw TeleportLoginError.noHostSigners
        }

        // 6. Build and persist the KeyRing.
        let expiry = Date().addingTimeInterval(TimeInterval(ttlNanoseconds) / 1_000_000_000)
        let keyRing = TeleportKeyRing(
            username: loginResponse.username,
            clusterName: ping.clusterName,
            proxyHost: client.configuration.proxyHost,
            sshPrivateKeyPEM: keyPair.sshPrivateKeyPEM,
            sshPublicKeyAuthorized: keyPair.sshPublicKeyAuthorized,
            sshCertificatePEM: loginResponse.cert,
            tlsPrivateKeyPEM: keyPair.tlsPrivateKeyPEM,
            tlsPublicKeyPEM: keyPair.tlsPublicKeyPEM,
            tlsCertificatePEM: loginResponse.tlsCert,
            hostCheckingKeys: hostSigner.checkingKeys,
            hostTLSCerts: hostSigner.tlsCerts ?? [],
            expiry: expiry
        )

        try TeleportKeyRingStore.shared.store(keyRing)

        return TeleportLoginResult(keyRing: keyRing, ping: ping)
    }
}
