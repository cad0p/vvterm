// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  BrowserMFAPresenter.swift
//  VVTerm
//
//  The host-side `BrowserMFAPresenting` adapter over
//  `ASWebAuthenticationSession`.
//
//  Owns the Safari session, the `vvterm` callback scheme, and the
//  presentation anchor. Deliberately NOT merged with
//  `WebAuthenticationSessionPresenter` (the Phase-1 headless presenter):
//  the ceremony's handle-based session lifecycle and the headless flow's
//  fire-and-forget session are separate behaviors.
//

#if canImport(AuthenticationServices)
import AuthenticationServices
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Host adapter: presents Safari in-app and returns a cancellable handle.
@MainActor
final class LiveBrowserMFAPresenter: NSObject, BrowserMFAPresenting {
    func present(
        url: URL,
        completion: @escaping @Sendable (Error?) -> Void
    ) async -> any BrowserMFASessionHandle {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "vvterm") { _, error in
            completion(error)
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        let started = session.start()
        return LiveBrowserMFASession(session: session, didStart: started)
    }
}

extension LiveBrowserMFAPresenter: ASWebAuthenticationPresentationContextProviding {
    @MainActor
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApp.keyWindow ?? ASPresentationAnchor()
        #else
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
        #endif
    }
}

/// One live Safari session, retained by the ceremony until it cancels it.
@MainActor
final class LiveBrowserMFASession: BrowserMFASessionHandle {
    private let session: ASWebAuthenticationSession
    let didStart: Bool

    init(session: ASWebAuthenticationSession, didStart: Bool) {
        self.session = session
        self.didStart = didStart
    }

    func cancel() {
        session.cancel()
    }
}

#endif
