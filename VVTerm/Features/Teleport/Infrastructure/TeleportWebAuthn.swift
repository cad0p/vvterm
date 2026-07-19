//
//  TeleportWebAuthn.swift
//  VVTerm
//
//  Solves a Teleport passwordless WebAuthn assertion challenge using iOS
//  ASAuthorizationPlatformPublicKeyCredentialAssertion (Face ID / Touch ID),
//  reusing the user's existing iCloud-Keychain passkey registered via Safari.
//
//  References:
//  - Teleport lib/auth/webauthntypes/webauthn.go (CredentialAssertionResponse — W3C clone)
//  - lib/auth/webauthn/origin.go:30 validateOrigin (accepts host == rpID)
//  - Session 1.1 §2 (passkey reuse via ASAuthorization*)
//

import Foundation
import AuthenticationServices

// MARK: - WebAuthn assertion result (wire fields for /finish)

/// The W3C CredentialAssertionResponse fields, base64url-encoded, ready for the
/// `webauthn_challenge_response` object in the /finish request.
struct WebAuthnAssertionResponse: Encodable {
    struct Response: Encodable {
        let authenticatorData: String
        let clientDataJSON: String
        let signature: String
        let userHandle: String
    }

    let rawId: String
    let response: Response
    let type: String

    enum CodingKeys: String, CodingKey {
        case rawId = "rawId"
        case response
        case type
    }
}

// MARK: - Challenge solver

/// Solves a Teleport WebAuthn passwordless assertion challenge via iOS Face ID / Touch ID.
///
/// The user's existing iCloud-Keychain passkey (registered via the Teleport web portal in
/// Safari) is surfaced by the platform credential picker. No in-app registration.
@MainActor
final class TeleportWebAuthnChallengeSolver: NSObject {

    /// Errors surfaced from the assertion ceremony.
    enum Failure: LocalizedError {
        case noPresenter
        case userCancelled
        case noCredentialReturned
        case missingField(String)
        case asAuthorizationError(Error)

        var errorDescription: String? {
            switch self {
            case .noPresenter:
                return "No view available to present the Face ID prompt."
            case .userCancelled:
                return "Face ID authentication was cancelled."
            case .noCredentialReturned:
                return "No passkey was returned. Make sure a passwordless passkey for teleport.pcad.it is registered via the web portal."
            case .missingField(let field):
                return "WebAuthn assertion response was missing field: \(field)."
            case .asAuthorizationError(let error):
                if let asError = error as? ASAuthorizationError {
                    switch asError.code {
                    case .canceled:
                        return "Face ID authentication was cancelled."
                    case .notHandled:
                        return "Face ID authentication was not handled (another app may have interrupted)."
                    case .notInteractive:
                        return "Face ID authentication could not be performed interactively."
                    case .failed:
                        return "Face ID authentication failed."
                    default:
                        return "Face ID authentication error: \(asError.localizedDescription)"
                    }
                }
                return "Face ID authentication error: \(error.localizedDescription)"
            }
        }
    }

    private var continuation: CheckedContinuation<WebAuthnAssertionResponse, Error>?

    /// Solve the challenge. `presenter` must be a `ASAuthorizationControllerPresentationContextProviding`
    /// (typically the topmost UIViewController / UIWindow).
    func solveChallenge(
        rpId: String,
        challenge: Data,
        userVerification: String,
        presenter: AnyObject
    ) async throws -> WebAuthnAssertionResponse {
        let preference: ASAuthorizationPublicKeyCredentialUserVerificationPreference
        switch userVerification.lowercased() {
        case "required": preference = .required
        case "discouraged": preference = .discouraged
        default: preference = .preferred // "preferred"
        }

        let request = ASAuthorizationPlatformPublicKeyCredentialAssertionRequest()
        request.relyingPartyIdentifier = rpId
        request.challenge = challenge
        request.userVerificationPreference = preference
        // allowedCredentials empty → discoverable/passwordless (picker resolves the user)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = (presenter as? ASAuthorizationControllerPresentationContextProviding)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension TeleportWebAuthnChallengeSolver: ASAuthorizationControllerDelegate {

    nonisolated func authorizationController(
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
                self.continuation?.resume(throwing: Failure.noCredentialReturned)
                return
            }

            guard let authenticatorData = credential.response.authenticatorData else {
                self.continuation?.resume(throwing: Failure.missingField("authenticatorData"))
                return
            }
            guard let clientDataJSON = credential.response.clientDataJSON else {
                self.continuation?.resume(throwing: Failure.missingField("clientDataJSON"))
                return
            }
            guard let signature = credential.response.signature else {
                self.continuation?.resume(throwing: Failure.missingField("signature"))
                return
            }
            guard let userHandle = credential.response.userID else {
                self.continuation?.resume(throwing: Failure.missingField("userHandle"))
                return
            }

            let response = WebAuthnAssertionResponse(
                rawId: credential.credentialID.base64URLEncodedString(),
                response: .init(
                    authenticatorData: authenticatorData.base64URLEncodedString(),
                    clientDataJSON: clientDataJSON.base64URLEncodedString(),
                    signature: signature.base64URLEncodedString(),
                    userHandle: userHandle.base64URLEncodedString()
                ),
                type: "public-key"
            )
            self.continuation?.resume(returning: response)
        }
    }

    nonisolated func authorizationController(
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            if let asError = error as? ASAuthorizationError, asError.code == .canceled {
                self.continuation?.resume(throwing: Failure.userCancelled)
            } else {
                self.continuation?.resume(throwing: Failure.asAuthorizationError(error))
            }
        }
    }
}

// MARK: - Data + base64url

extension Data {
    /// Base64url encoding (no padding) per RFC 4648 §5 — what WebAuthn/Teleport expects.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a base64url string, adding padding if necessary.
    static func base64URLDecoded(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}
