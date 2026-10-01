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

/// One-shot resume guard for the confirmation continuation.
///
/// Three paths can resume it — the paste action, the cancel action, and the
/// presentation-completion deny — and the actions can legitimately fire
/// around the same time as the completion (a dismissal race). A
/// `CheckedContinuation` double-resume traps, so every path claims the
/// continuation through this lock first.
private final class ClipboardConfirmationResumeState: @unchecked Sendable {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}

    private let lock = NSLock()
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<Bool, Never>, returning value: Bool) {
        lock.lock()
        let shouldResume = !didResume
        didResume = true
        lock.unlock()
        guard shouldResume else { return }
        continuation.resume(returning: value)
    }
}

extension Ghostty.App {
    /// Presents the unsafe-paste confirmation from the top-most presented view
    /// controller. Fail-safe: without a window, while an alert is already
    /// presented, or with a presenter that is not in the window hierarchy the
    /// request is denied without prompting (the caller completes it as a deny).
    static func presentClipboardConfirmation(
        _ request: ClipboardConfirmationRequest,
        on view: GhosttyTerminalView
    ) async -> Bool {
        // Prefer the window that hosts the terminal so a multi-scene iPad
        // (Stage Manager) prompts on the terminal's own scene; the global key
        // window stays the fallback for a view that is not in a window yet.
        // The liveness precondition (visible, foreground-active scene, rooted)
        // is deliberately kept: accepting a hidden or backgrounded host window
        // would shadow the known-live key window and present where no
        // `viewDidAppear` runs, stranding the continuation. On iOS 15+
        // `isKeyWindow` is scene-scoped, so preferring the scene's key window
        // still keeps the prompt on the terminal's own scene.
        let sceneWindow = view.window?.windowScene?.keyWindow ?? view.window
        let window: UIWindow?
        if let sceneWindow,
           !sceneWindow.isHidden,
           sceneWindow.windowScene?.activationState == .foregroundActive,
           sceneWindow.rootViewController != nil {
            window = sceneWindow
        } else {
            window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })
        }
        guard let window, let rootViewController = window.rootViewController else {
            Ghostty.logger.warning("clipboard confirmation dropped: no window")
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
            let resumeState = ClipboardConfirmationResumeState()
            let alert = UIAlertController(
                title: ClipboardConfirmationRequest.promptTitle,
                message: request.promptBody,
                preferredStyle: .alert
            )
            // Upstream parity: "Paste" is the default action; "Cancel" is the
            // cancel action.
            let pasteAction = UIAlertAction(title: "Paste", style: .default) { _ in
                resumeState.resume(continuation, returning: true)
            }
            let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
                resumeState.resume(continuation, returning: false)
            }
            alert.addAction(pasteAction)
            alert.addAction(cancelAction)
            alert.preferredAction = pasteAction
            // The presentation completion is the third resume site: a
            // silently-failed presentation never fires an action, so a deny
            // here is the only thing that keeps the continuation (and the
            // core's request state) from being retained forever.
            presenter.present(alert, animated: true) {
                if presenter.presentedViewController !== alert {
                    Ghostty.logger.warning("clipboard confirmation dropped: presentation did not take")
                    resumeState.resume(continuation, returning: false)
                }
            }
        }
    }
}
#endif
