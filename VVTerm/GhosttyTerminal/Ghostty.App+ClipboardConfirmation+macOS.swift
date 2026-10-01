// SPDX-License-Identifier: MIT
//
//  Ghostty.App+ClipboardConfirmation+macOS.swift
//  VVTerm
//
//  macOS presentation for the #327 unsafe-paste confirmation. The shared
//  decision flow lives in `Ghostty.App.confirmReadClipboard`; this file only
//  presents, and every drop path returns false (deny) so the caller always
//  completes the clipboard request instead of retaining it.

#if os(macOS)
import AppKit
import OSLog

extension Ghostty.App {
    /// Presents the unsafe-paste confirmation as a sheet on the view's window,
    /// or app-modal when the view has no visible window. Fail-safe: a window
    /// that already has a sheet attached denies without prompting (the caller
    /// completes it as a deny).
    static func presentClipboardConfirmation(
        _ request: ClipboardConfirmationRequest,
        on view: GhosttyTerminalView
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Paste Unsafe Text?"
        alert.informativeText = request.promptBody
        alert.alertStyle = .warning
        // Upstream parity: "Paste" is the default button, "Cancel" the cancel
        // action. NSAlert's first added button is the default one.
        let pasteButton = alert.addButton(withTitle: "Paste")
        pasteButton.keyEquivalent = "\r"
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1B}"

        guard let window = view.window, window.isVisible else {
            // No window to sheet on: app-modal, matching upstream's fallback.
            return alert.runModal() == .alertFirstButtonReturn
        }

        guard window.attachedSheet == nil else {
            Ghostty.logger.warning("clipboard confirmation dropped: sheet already presented")
            return false
        }

        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
}
#endif
