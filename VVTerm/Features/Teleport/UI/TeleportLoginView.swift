//
//  TeleportLoginView.swift
//  VVTerm
//
//  "Sign in with Face ID" screen for Teleport passwordless login.
//  On success → proceeds (caller wires the resulting KeyRing into a connection).
//  On failure (no passkey / cancelled) → fallback prompting the user to register
//  a passkey via the Teleport web portal in Safari.
//
//  Reference: spec §1.1 (onboarding model), session 1.1 §6.1 (fallback UX).
//

import SwiftUI
import AuthenticationServices

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// SwiftUI view that runs the Teleport passwordless login flow and surfaces
/// the outcome. The caller observes `onLoginResult` to proceed.
struct TeleportLoginView: View {

    /// Called on the main actor when login completes. `result` is nil on failure.
    let onLoginResult: (TeleportLoginResult?) -> Void

    @State private var isLoggingIn = false
    @State private var errorMessage: String?
    @State private var showFallback = false

    private let proxyHost = TeleportLoginCoordinator.pcadItProxyHost

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "faceid")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Sign in with Face ID")
                    .font(.title2.bold())

                Text("Tap to sign in to \(proxyHost) using your Teleport passkey.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            Button {
                Task { await startLogin() }
            } label: {
                HStack {
                    if isLoggingIn {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "faceid")
                    }
                    Text(isLoggingIn ? "Authenticating…" : "Sign In")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoggingIn)
            .padding(.horizontal)

            Button("Open Teleport web portal") {
                openWebPortal()
            }
            .font(.footnote)
            .padding(.bottom, 24)
        }
        .navigationTitle("Teleport")
        .navigationBarTitleDisplayMode(.inline)
        .alert("No passkey found", isPresented: $showFallback) {
            Button("Open Web Portal") { openWebPortal() }
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text("No passwordless passkey for \(proxyHost) was found in iCloud Keychain. Open the Teleport web portal in Safari to register a passkey, then return.")
        }
    }

    @MainActor
    private func startLogin() async {
        isLoggingIn = true
        errorMessage = nil

        let coordinator = TeleportLoginCoordinator(proxyHost: proxyHost)
        do {
            let result = try await coordinator.login(presenter: presenter())
            onLoginResult(result)
        } catch let error as TeleportLoginError {
            errorMessage = error.localizedDescription
            if case .webAuthn = error {
                showFallback = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoggingIn = false
    }

    private func openWebPortal() {
        let urlString = "https://\(proxyHost)/web/"
        #if os(iOS)
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
        #else
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    /// Returns the object that presents the ASAuthorization UI (Face ID picker).
    private func presenter() -> AnyObject {
        #if os(iOS)
        // The topmost window scene's window is the presentation context.
        return TeleportPresentationContext.shared
        #else
        return TeleportPresentationContext.shared
        #endif
    }
}

#if os(iOS)
/// A shared presentation context provider for ASAuthorizationController.
/// Resolves to the foreground window scene's key window at presentation time.
final class TeleportPresentationContext: NSObject, ASAuthorizationControllerPresentationContextProviding {

    static let shared = TeleportPresentationContext()

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Find the foreground active window scene's key window.
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        return scenes.first?.windows.first(where: { $0.isKeyWindow })
            ?? scenes.first?.windows.first
            ?? ASPresentationAnchor()
    }
}
#else
/// macOS stub — V1 is iOS-focused; the Face ID passkey flow targets iOS.
final class TeleportPresentationContext: NSObject, ASAuthorizationControllerPresentationContextProviding {
    static let shared = TeleportPresentationContext()

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return ASPresentationAnchor()
    }
}
#endif
