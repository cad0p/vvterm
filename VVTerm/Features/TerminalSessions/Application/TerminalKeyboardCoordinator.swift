#if os(iOS)
import Combine
import Foundation
import UIKit
import os.log

/// Owns the terminal text-input session and observes what UIKit actually
/// does with it. The design rule that keeps this correct: the app CONTROLS
/// only the session (first responder) from app state; whether a software
/// keyboard is on screen is OBSERVED from keyboard frame notifications and
/// never predicted. There is deliberately no hardware-keyboard detection:
/// iOS decides whether to present the software keyboard for an active
/// session (it knows about attached keyboards and iPhone Mirroring
/// authoritatively). When UIKit accepts the responder but reports no real
/// software-keyboard frame, the terminal hides its input accessory so the
/// user never gets a long-lived bar without a keyboard.
@MainActor
final class TerminalKeyboardCoordinator: ObservableObject {
    struct StateInputs: Equatable {
        var viewActive: Bool
        var activePaneConnected: Bool
        var activePaneWindowAttached: Bool
        var userHidKeyboard: Bool
        var findNavigatorActive: Bool
    }

    @Published private(set) var isUserHidden = false
    /// Observed truth: a software keyboard (not just an input assistant bar)
    /// is on screen or animating in. Used to clear the terminal's accessory
    /// suppression once UIKit proves the keyboard is really present.
    @Published private(set) var isSoftwareKeyboardVisible = false

    var terminalProvider: ((UUID) -> GhosttyTerminalView?)?

    private var activePaneId: UUID?
    private var viewActive = false
    private var paneConnectedById: [UUID: Bool] = [:]
    private var paneWindowAttachedById: [UUID: Bool] = [:]
    private var findNavigatorActive = false
    private var syncScheduled = false
    private var isSyncing = false
    private var pendingSyncAfterCurrent = false
    private var pendingReason = "initial"
    private var lastManagedPaneId: UUID?
    private var wantsPresentationRefresh = false
    private var pendingPresentationVerify = false
    /// Rebuilding a session UIKit refuses to present cannot succeed by
    /// repetition; cap attempts until a keyboard actually shows (which
    /// resets the count).
    private var presentationRefreshAttemptCount = 0
    private let presentationRefreshAttemptLimit = 2
    /// An input assistant/shortcuts bar alone reports a small keyboard frame
    /// (~44-72pt); a real software keyboard is far taller on every device.
    private let softwareKeyboardMinimumHeight: CGFloat = 100
    private var keyboardObservers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // willShow/willHide fire at animation START so the bar travels with
        // the keyboard instead of trailing it; willChangeFrame catches
        // transitions that skip show/hide (hardware keyboard attaching while
        // the keyboard is up slides the frame off screen).
        for name in [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillChangeFrameNotification,
        ] {
            keyboardObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
                        .cgRectValue
                    Task { @MainActor [weak self] in
                        self?.noteKeyboardEndFrame(frame)
                    }
                }
            )
        }
        for name in [
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidHideNotification,
        ] {
            keyboardObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.noteSoftwareKeyboardVisible(false)
                    }
                }
            )
        }
        // A session that survives a scene transition (iPhone Mirroring
        // connect, unlock) can be stale for the remote-input pipeline: keys
        // arrive nowhere until the session is rebuilt. Request a one-shot
        // refresh evaluation on activation; it only acts when the session is
        // active with no keyboard on screen. The verifier folds the native
        // accessory away if UIKit still withholds a real keyboard frame.
        keyboardObservers.append(
            center.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.wantsPresentationRefresh = true
                    self.presentationRefreshAttemptCount = 0
                    self.markDirty(reason: "sceneActivated")
                }
            }
        )
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm",
        category: "KeyboardCoordinator"
    )

    /// Whether the terminal should hold the text-input session (first
    /// responder). Hardware keyboards are irrelevant here: key events need
    /// an active responder either way, and UIKit decides on its own whether
    /// the session also presents a software keyboard.
    nonisolated static func desiredKeyboardVisible(inputs: StateInputs) -> Bool {
        inputs.viewActive
            && inputs.activePaneConnected
            && inputs.activePaneWindowAttached
            && !inputs.userHidKeyboard
            && !inputs.findNavigatorActive
    }

    func setActivePane(_ paneId: UUID?) {
        guard activePaneId != paneId else { return }
        activePaneId = paneId
        markDirty(reason: "activePane")
    }

    func setViewActive(_ active: Bool) {
        guard viewActive != active else { return }
        viewActive = active
        markDirty(reason: "viewActive")
    }

    func setPaneConnected(_ connected: Bool, for paneId: UUID) {
        guard paneConnectedById[paneId] != connected else { return }
        paneConnectedById[paneId] = connected
        markDirty(reason: "paneConnected")
    }

    func removePane(_ paneId: UUID) {
        let didRemoveConnected = paneConnectedById.removeValue(forKey: paneId) != nil
        let didRemoveWindow = paneWindowAttachedById.removeValue(forKey: paneId) != nil
        if activePaneId == paneId {
            activePaneId = nil
            markDirty(reason: "removeActivePane")
        } else if didRemoveConnected || didRemoveWindow {
            markDirty(reason: "removePane")
        }
    }

    func setWindowAttached(_ attached: Bool, for paneId: UUID) {
        guard paneWindowAttachedById[paneId] != attached else { return }
        paneWindowAttachedById[paneId] = attached
        markDirty(reason: "windowAttached")
    }

    func setFindNavigatorActive(_ active: Bool) {
        guard findNavigatorActive != active else { return }
        findNavigatorActive = active
        markDirty(reason: "findNavigator")
    }

    func userRequestedHide() {
        guard !isUserHidden else { return }
        isUserHidden = true
        markDirty(reason: "userHide")
    }

    func userRequestedShow() {
        wantsPresentationRefresh = true
        // The repair cap stops AUTOMATIC rebuild loops (e.g. against a
        // hardware keyboard's legitimate suppression, which can exhaust it);
        // an explicit user action re-arms it, otherwise returning from
        // mirroring leaves taps unable to re-present the keyboard.
        presentationRefreshAttemptCount = 0
        if isUserHidden {
            isUserHidden = false
        }
        markDirty(reason: "userShow")
    }

    func directTouchOnTerminal(isFocusTap: Bool = false) {
        if isUserHidden {
            // A plain tap on the terminal means "I want to type": restore a
            // user-hidden keyboard instead of leaving the user stranded in
            // hidden mode. Selection/menu touches (isFocusTap == false)
            // still respect the hidden state.
            guard isFocusTap else { return }
            isUserHidden = false
        }
        wantsPresentationRefresh = true
        // See userRequestedShow: user actions get a fresh repair budget.
        presentationRefreshAttemptCount = 0
        markDirty(reason: "directTouch")
    }

    private func noteKeyboardEndFrame(_ frame: CGRect?) {
        guard let frame else { return }
        guard let screenBounds = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.screen.bounds })
            .first(where: { $0.intersects(frame) }) ?? (UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first)
        else { return }
        let overlap = screenBounds.intersection(frame)
        let visible = !overlap.isNull && overlap.height >= softwareKeyboardMinimumHeight
        noteSoftwareKeyboardVisible(visible)
    }

    private func noteSoftwareKeyboardVisible(_ visible: Bool) {
        if visible {
            presentationRefreshAttemptCount = 0
            activeTerminal?.setTerminalInputAccessorySuppressed(false)
        }
        guard isSoftwareKeyboardVisible != visible else { return }
        isSoftwareKeyboardVisible = visible
        markDirty(reason: visible ? "keyboardShown" : "keyboardHidden")
    }

    private var activeTerminal: GhosttyTerminalView? {
        activePaneId.flatMap { terminalProvider?($0) }
    }

    private var currentInputs: StateInputs {
        let paneId = activePaneId
        return StateInputs(
            viewActive: viewActive,
            activePaneConnected: paneId.flatMap { paneConnectedById[$0] } ?? false,
            activePaneWindowAttached: paneId.flatMap { paneWindowAttachedById[$0] } ?? false,
            userHidKeyboard: isUserHidden,
            findNavigatorActive: findNavigatorActive
        )
    }

    private func markDirty(reason: String) {
        pendingReason = reason
        if isSyncing {
            pendingSyncAfterCurrent = true
            return
        }
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.sync()
        }
    }

    private func sync() {
        syncScheduled = false
        guard !isSyncing else {
            pendingSyncAfterCurrent = true
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            if pendingSyncAfterCurrent {
                pendingSyncAfterCurrent = false
                markDirty(reason: "coalescedResync")
            }
        }

        let inputs = currentInputs
        let desired = Self.desiredKeyboardVisible(inputs: inputs)
        let reason = pendingReason

        if let previousPaneId = lastManagedPaneId,
           previousPaneId != activePaneId,
           let previousTerminal = terminalProvider?(previousPaneId) {
            let before = previousTerminal.keyboardCoordinatorDiagnosticSnapshot()
            if before.isFirstResponder {
                previousTerminal.releaseTerminalInput()
                logCommand(
                    desired: false,
                    reason: reason,
                    inputs: inputs,
                    before: before,
                    after: previousTerminal.keyboardCoordinatorDiagnosticSnapshot()
                )
            }
            lastManagedPaneId = nil
        }

        guard let activePaneId,
              let terminal = terminalProvider?(activePaneId) else {
            logger.info("command=none reason=\(self.pendingReason, privacy: .public) desired=\(desired) noActiveTerminal=true viewActive=\(inputs.viewActive) connected=\(inputs.activePaneConnected) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive)")
            return
        }
        lastManagedPaneId = activePaneId

        let refreshRequested = wantsPresentationRefresh
        wantsPresentationRefresh = false

        let before = terminal.keyboardCoordinatorDiagnosticSnapshot()
        // Compare against the software input session, not the combined
        // responder state: the view can hold first responder for native
        // selection, which must not read as "keyboard is up".
        guard before.isSoftwareInputActive != desired else {
            if desired,
               refreshRequested,
               before.isSoftwareInputActive,
               !isSoftwareKeyboardVisible,
               presentationRefreshAttemptCount < presentationRefreshAttemptLimit {
                // The session is active but no keyboard is up. Either the
                // presentation silently failed or a hardware keyboard is
                // suppressing it; rebuild once for the former, then the
                // verifier folds away the native accessory if UIKit still
                // withholds a real keyboard frame.
                presentationRefreshAttemptCount += 1
                terminal.rebuildTerminalInputSession()
                schedulePresentationVerify()
                let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
                logger.info("command=refresh repair=asyncRebuild reason=\(self.pendingReason, privacy: .public) viewActive=\(inputs.viewActive) connected=\(inputs.activePaneConnected) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive) kbVisible=\(self.isSoftwareKeyboardVisible) afterFirstResponder=\(after.isFirstResponder) afterSoftwareInput=\(after.isSoftwareInputActive)")
                return
            }
            logger.info("command=steady reason=\(self.pendingReason, privacy: .public) desired=\(desired) viewActive=\(inputs.viewActive) connected=\(inputs.activePaneConnected) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive) window=\(before.windowAttached) keyWindow=\(before.windowIsKey) scene=\(before.sceneActivationState, privacy: .public) firstResponder=\(before.isFirstResponder) softwareInput=\(before.isSoftwareInputActive) kbVisible=\(self.isSoftwareKeyboardVisible)")
            return
        }

        if desired {
            terminal.acquireTerminalInput()
        } else {
            terminal.releaseTerminalInput()
        }

        let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
        logCommand(
            desired: desired,
            reason: reason,
            inputs: inputs,
            before: before,
            after: after
        )

        if desired, after.isSoftwareInputActive {
            schedulePresentationVerify()
        } else if !desired {
            presentationRefreshAttemptCount = 0
        }
    }

    /// UIKit can accept the input session while legitimately withholding the
    /// software keyboard (hardware keyboard, iPhone Mirroring), or while a
    /// hosted keyboard scene is temporarily broken. Settle both cases by
    /// folding the accessory if no real keyboard frame arrives. Explicit
    /// user actions and scene activation still request one rebuild before
    /// this verifier runs, so the "tap once after mirroring" repair path is
    /// preserved without leaving a lone accessory bar.
    private func schedulePresentationVerify() {
        guard !pendingPresentationVerify else { return }
        pendingPresentationVerify = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.pendingPresentationVerify = false
            guard !self.isSoftwareKeyboardVisible else { return }
            guard let paneId = self.activePaneId,
                  let terminal = self.terminalProvider?(paneId) else { return }
            let inputs = self.currentInputs
            guard Self.desiredKeyboardVisible(inputs: inputs) else { return }
            let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
            guard snapshot.isSoftwareInputActive else { return }
            // Settled with an active session and no keyboard: hardware mode
            // or a failed software-keyboard presentation. Keep the responder
            // for hardware keys, but remove the accessory until a real
            // software keyboard frame arrives or the user tries focus again.
            terminal.setTerminalInputAccessorySuppressed(true)
            let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
            self.logger.info("command=verifySuppressed kbVisible=\(self.isSoftwareKeyboardVisible) afterFirstResponder=\(after.isFirstResponder) afterSoftwareInput=\(after.isSoftwareInputActive)")
        }
    }

    private func logCommand(
        desired: Bool,
        reason: String,
        inputs: StateInputs,
        before: TerminalKeyboardCoordinatorDiagnosticSnapshot,
        after: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        logger.info(
            "command=\(desired ? "acquire" : "release", privacy: .public) desired=\(desired) reason=\(reason, privacy: .public) viewActive=\(inputs.viewActive) connected=\(inputs.activePaneConnected) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive) kbVisible=\(self.isSoftwareKeyboardVisible) beforeWindow=\(before.windowAttached) beforeKeyWindow=\(before.windowIsKey) beforeScene=\(before.sceneActivationState, privacy: .public) beforeFirstResponder=\(before.isFirstResponder) beforeSoftwareInput=\(before.isSoftwareInputActive) afterWindow=\(after.windowAttached) afterKeyWindow=\(after.windowIsKey) afterScene=\(after.sceneActivationState, privacy: .public) afterFirstResponder=\(after.isFirstResponder) afterSoftwareInput=\(after.isSoftwareInputActive)"
        )
    }
}
#endif
