// SPDX-License-Identifier: MIT
//
//  Ghostty.App+ClipboardConfirmation+iOS.swift
//  VVTerm
//
//  iOS presentation for the #327 unsafe-paste confirmation. The shared
//  decision flow lives in `Ghostty.App.confirmReadClipboard`; this file only
//  presents, and every drop path returns false (deny) so the caller always
//  completes the clipboard request instead of retaining it.

#if os(iOS)
import OSLog
import UIKit

extension Ghostty.App {
    /// Presents the unsafe-paste confirmation from the top-most presented view
    /// controller. Fail-safe: without a key window, while an alert is already
    /// presented, or with a presenter that is not in the window hierarchy the
    /// request is denied without prompting (the caller completes it as a deny).
    static func presentClipboardConfirmation(
        _ request: ClipboardConfirmationRequest,
        on view: GhosttyTerminalView
    ) async -> Bool {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }),
            let rootViewController = window.rootViewController
        else {
            Ghostty.logger.warning("clipboard confirmation dropped: no key window")
            return false
        }

        // Walk the presented-view-controller chain to the top-most presenter.
        var presenter = rootViewController
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        // Drop while an alert is already on screen: the top-most presenter IS
        // the alert in that case (a UIAlertController presenting another alert
        // is not supported). Dropping completes the request as a deny.
        guard !(presenter is UIAlertController) else {
            Ghostty.logger.warning("clipboard confirmation dropped: alert already presented")
            return false
        }
        guard presenter.viewIfLoaded?.window != nil, !presenter.isBeingDismissed else {
            Ghostty.logger.warning("clipboard confirmation dropped: presenter is not in the window hierarchy")
            return false
        }

        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Paste Unsafe Text?",
                message: request.promptBody,
                preferredStyle: .alert
            )
            // Upstream parity: "Paste" is the default action; "Cancel" is the
            // cancel action.
            let pasteAction = UIAlertAction(title: "Paste", style: .default) { _ in
                continuation.resume(returning: true)
            }
            let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(returning: false)
            }
            alert.addAction(pasteAction)
            alert.addAction(cancelAction)
            alert.preferredAction = pasteAction
            presenter.present(alert, animated: true)
        }
    }
}
#endif
