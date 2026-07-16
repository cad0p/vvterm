#if os(iOS)
import Combine
import Foundation
import UIKit
import os.log

@MainActor
protocol TerminalKeyboardInputSession: AnyObject {
    func keyboardCoordinatorDiagnosticSnapshot() -> TerminalKeyboardCoordinatorDiagnosticSnapshot
    @discardableResult
    func acquireTerminalInput() -> Bool
    @discardableResult
    func forceSoftwareKeyboardInput() -> Bool
    @discardableResult
    func focusTerminalInputWithoutShowingSoftwareKeyboard() -> Bool
    func releaseTerminalInput()
    func rebuildTerminalInputSession()
    func setTerminalInputAccessorySuppressed(_ suppressed: Bool)
}

extension GhosttyTerminalView: TerminalKeyboardInputSession {}

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
    enum PresentationRefreshAction: Equatable {
        case none
        case deferUntilVerification
        case rebuild
    }

    private enum PresentationRequest: Equatable {
        case none
        case automaticRefresh
        case forceSoftwareKeyboard
    }

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
    /// The observed software-keyboard frame in the screen coordinate space.
    /// Layout consumers convert this into their own window before using it.
    @Published private(set) var softwareKeyboardEndFrame: CGRect?
    private(set) var keyboardAnimationDuration: TimeInterval = 0.25
    private(set) var keyboardAnimationCurve: UIView.AnimationCurve = .easeInOut

    var terminalProvider: ((UUID) -> (any TerminalKeyboardInputSession)?)?

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
    private var pendingPresentationRequest = PresentationRequest.none
    private var presentationVerifyTask: Task<Void, Never>?
    /// Rebuilding a session UIKit refuses to present cannot succeed by
    /// repetition; cap attempts until a keyboard actually shows (which
    /// resets the count).
    private var presentationRefreshAttemptCount = 0
    private let presentationRefreshAttemptLimit = 2
    /// An input assistant/shortcuts bar alone reports a small keyboard frame
    /// (~44-72pt); a real software keyboard is far taller on every device.
    private let softwareKeyboardMinimumHeight: CGFloat = 100
    private var keyboardObservers: [NSObjectProtocol] = []
    private let lifecycleLoggingEnabled: Bool

    init(lifecycleLoggingEnabled: Bool = TerminalKeyboardCoordinator.defaultLifecycleLoggingEnabled) {
        self.lifecycleLoggingEnabled = lifecycleLoggingEnabled

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
                    let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval
                    let curveRawValue = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
                    Task { @MainActor [weak self] in
                        self?.noteKeyboardEndFrame(
                            frame,
                            animationDuration: duration,
                            animationCurveRawValue: curveRawValue
                        )
                    }
                }
            )
        }
        for name in [
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidHideNotification,
        ] {
            keyboardObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval
                    let curveRawValue = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
                    Task { @MainActor [weak self] in
                        self?.noteSoftwareKeyboardHidden(
                            animationDuration: duration,
                            animationCurveRawValue: curveRawValue
                        )
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
                    self.requestAutomaticPresentationRefresh()
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

    #if DEBUG
    nonisolated private static var usesUITestKeyboardFrameSimulation: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-simulate-keyboard-frames")
    }
    #endif

    nonisolated private static var defaultLifecycleLoggingEnabled: Bool {
        DebugLogConfiguration.isEnabled("keyboard")
    }

    /// Whether the terminal should hold the text-input session (first
    /// responder). Hardware keyboards and the user's software-keyboard hidden
    /// preference are irrelevant here: key events need an active responder
    /// either way, and UIKit decides on its own whether the session also
    /// presents a software keyboard.
    nonisolated static func desiredInputSessionActive(inputs: StateInputs) -> Bool {
        inputs.viewActive
            && inputs.activePaneConnected
            && inputs.activePaneWindowAttached
            && !inputs.findNavigatorActive
    }

    nonisolated static func desiredKeyboardVisible(inputs: StateInputs) -> Bool {
        desiredInputSessionActive(inputs: inputs)
            && !inputs.userHidKeyboard
    }

    nonisolated static func presentationRefreshAction(
        keyboardPresentationDesired: Bool,
        refreshRequested: Bool,
        softwareInputActive: Bool,
        softwareKeyboardVisible: Bool,
        presentationVerificationPending: Bool,
        refreshAttemptCount: Int,
        refreshAttemptLimit: Int
    ) -> PresentationRefreshAction {
        guard keyboardPresentationDesired,
              refreshRequested,
              softwareInputActive,
              !softwareKeyboardVisible,
              refreshAttemptCount < refreshAttemptLimit else {
            return .none
        }
        return presentationVerificationPending ? .deferUntilVerification : .rebuild
    }

    func setActivePane(_ paneId: UUID?) {
        guard activePaneId != paneId else { return }
        cancelPresentationVerify()
        activePaneId = paneId
        markDirty(reason: "activePane")
    }

    func setViewActive(_ active: Bool) {
        if !active {
            cancelPresentationVerify()
            clearSoftwareKeyboardObservation()
        }
        guard viewActive != active else { return }
        viewActive = active
        markDirty(reason: "viewActive")
    }

    func setPaneConnected(_ connected: Bool, for paneId: UUID) {
        guard paneConnectedById[paneId] != connected else { return }
        if !connected, activePaneId == paneId {
            cancelPresentationVerify()
        }
        paneConnectedById[paneId] = connected
        markDirty(reason: "paneConnected")
    }

    func removePane(_ paneId: UUID) {
        let didRemoveConnected = paneConnectedById.removeValue(forKey: paneId) != nil
        let didRemoveWindow = paneWindowAttachedById.removeValue(forKey: paneId) != nil
        if activePaneId == paneId {
            cancelPresentationVerify()
            activePaneId = nil
            markDirty(reason: "removeActivePane")
        } else if didRemoveConnected || didRemoveWindow {
            markDirty(reason: "removePane")
        }
    }

    func setWindowAttached(_ attached: Bool, for paneId: UUID) {
        guard paneWindowAttachedById[paneId] != attached else { return }
        if !attached, activePaneId == paneId {
            cancelPresentationVerify()
        }
        paneWindowAttachedById[paneId] = attached
        markDirty(reason: "windowAttached")
    }

    func setFindNavigatorActive(_ active: Bool) {
        guard findNavigatorActive != active else { return }
        if active {
            cancelPresentationVerify()
        }
        findNavigatorActive = active
        markDirty(reason: "findNavigator")
    }

    /// Privacy and app-lock shields must remove the UIKit input accessory
    /// before iOS captures protected content. A scheduled reconciliation can
    /// run too late because the keyboard belongs to a separate system scene.
    func deactivateInputImmediately() {
        clearSoftwareKeyboardObservation()
        guard activePaneId != nil || viewActive || findNavigatorActive || lastManagedPaneId != nil else {
            return
        }
        activePaneId = nil
        viewActive = false
        findNavigatorActive = false
        cancelPresentationVerify()
        pendingReason = "contentProtection"
        syncScheduled = false
        sync()
    }

    func userRequestedHide() {
        pendingPresentationRequest = .none
        cancelPresentationVerify()
        guard !isUserHidden else { return }
        isUserHidden = true
        markDirty(reason: "userHide")
    }

    func userRequestedShow() {
        pendingPresentationRequest = .forceSoftwareKeyboard
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
            return
        }
        requestAutomaticPresentationRefresh()
        // See userRequestedShow: user actions get a fresh repair budget.
        presentationRefreshAttemptCount = 0
        markDirty(reason: "directTouch")
    }

    private func noteKeyboardEndFrame(
        _ frame: CGRect?,
        animationDuration: TimeInterval?,
        animationCurveRawValue: Int?
    ) {
        #if DEBUG
        guard !Self.usesUITestKeyboardFrameSimulation else { return }
        #endif
        guard viewActive, let frame else { return }
        updateKeyboardAnimation(duration: animationDuration, curveRawValue: animationCurveRawValue)
        guard let screenBounds = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.screen.bounds })
            .first(where: { $0.intersects(frame) }) ?? (UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first)
        else { return }
        let overlap = screenBounds.intersection(frame)
        let visible = !overlap.isNull && overlap.height >= softwareKeyboardMinimumHeight
        let visibleFrame = visible ? frame : nil
        if softwareKeyboardEndFrame != visibleFrame {
            softwareKeyboardEndFrame = visibleFrame
        }
        noteSoftwareKeyboardVisible(visible)
    }

    private func noteSoftwareKeyboardHidden(
        animationDuration: TimeInterval?,
        animationCurveRawValue: Int?
    ) {
        #if DEBUG
        guard !Self.usesUITestKeyboardFrameSimulation else { return }
        #endif
        updateKeyboardAnimation(duration: animationDuration, curveRawValue: animationCurveRawValue)
        clearSoftwareKeyboardObservation()
    }

    private func clearSoftwareKeyboardObservation() {
        softwareKeyboardEndFrame = nil
        noteSoftwareKeyboardVisible(false)
    }

    private func updateKeyboardAnimation(duration: TimeInterval?, curveRawValue: Int?) {
        if let duration, duration > 0 {
            keyboardAnimationDuration = duration
        }
        if let curveRawValue, let curve = UIView.AnimationCurve(rawValue: curveRawValue) {
            keyboardAnimationCurve = curve
        }
    }

    private func noteSoftwareKeyboardVisible(_ visible: Bool) {
        if visible {
            cancelPresentationVerify()
            presentationRefreshAttemptCount = 0
            activeTerminal?.setTerminalInputAccessorySuppressed(false)
        } else {
            activeTerminal?.setTerminalInputAccessorySuppressed(true)
        }
        guard isSoftwareKeyboardVisible != visible else { return }
        isSoftwareKeyboardVisible = visible
        markDirty(reason: visible ? "keyboardShown" : "keyboardHidden")
    }

    private var activeTerminal: (any TerminalKeyboardInputSession)? {
        activePaneId.flatMap { terminalProvider?($0) }
    }

    private func requestAutomaticPresentationRefresh() {
        guard pendingPresentationRequest != .forceSoftwareKeyboard else { return }
        pendingPresentationRequest = .automaticRefresh
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
        let inputSessionDesired = Self.desiredInputSessionActive(inputs: inputs)
        let keyboardPresentationDesired = Self.desiredKeyboardVisible(inputs: inputs)
        let reason = pendingReason

        if !keyboardPresentationDesired {
            cancelPresentationVerify()
        }

        if let previousPaneId = lastManagedPaneId,
           previousPaneId != activePaneId,
           let previousTerminal = terminalProvider?(previousPaneId) {
            let before = previousTerminal.keyboardCoordinatorDiagnosticSnapshot()
            if before.isFirstResponder {
                previousTerminal.releaseTerminalInput()
                logCommand(
                    inputSessionDesired: false,
                    keyboardPresentationDesired: false,
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
            logNoActiveTerminal(inputSessionDesired: inputSessionDesired, inputs: inputs)
            return
        }
        lastManagedPaneId = activePaneId

        let presentationRequest = pendingPresentationRequest
        if keyboardPresentationDesired || presentationRequest != .forceSoftwareKeyboard {
            pendingPresentationRequest = .none
        }

        let before = terminal.keyboardCoordinatorDiagnosticSnapshot()
        if keyboardPresentationDesired,
           presentationRequest == .forceSoftwareKeyboard {
            _ = terminal.forceSoftwareKeyboardInput()
            let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
            if after.isSoftwareInputActive {
                if !isSoftwareKeyboardVisible {
                    schedulePresentationVerify()
                }
            } else {
                pendingPresentationRequest = .forceSoftwareKeyboard
            }
            logCommand(
                inputSessionDesired: inputSessionDesired,
                keyboardPresentationDesired: keyboardPresentationDesired,
                reason: reason,
                inputs: inputs,
                before: before,
                after: after
            )
            return
        }

        let refreshRequested = presentationRequest == .automaticRefresh
        // Compare against the software input session, not the combined
        // responder state: the view can hold first responder for native
        // selection, which must not read as "keyboard is up".
        guard before.isSoftwareInputActive != inputSessionDesired else {
            let refreshAction = Self.presentationRefreshAction(
                keyboardPresentationDesired: keyboardPresentationDesired,
                refreshRequested: refreshRequested,
                softwareInputActive: before.isSoftwareInputActive,
                softwareKeyboardVisible: isSoftwareKeyboardVisible,
                presentationVerificationPending: presentationVerifyTask != nil,
                refreshAttemptCount: presentationRefreshAttemptCount,
                refreshAttemptLimit: presentationRefreshAttemptLimit
            )
            switch refreshAction {
            case .deferUntilVerification:
                requestAutomaticPresentationRefresh()
                logDeferredRefresh(inputs: inputs, before: before)
                return
            case .rebuild:
                // The session is active but no keyboard is up. Either the
                // presentation silently failed or a hardware keyboard is
                // suppressing it; rebuild once for the former, then the
                // verifier folds away the native accessory if UIKit still
                // withholds a real keyboard frame.
                presentationRefreshAttemptCount += 1
                terminal.rebuildTerminalInputSession()
                schedulePresentationVerify()
                let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
                logAsyncRebuild(inputs: inputs, after: after)
                return
            case .none:
                break
            }
            logSteady(
                inputSessionDesired: inputSessionDesired,
                keyboardPresentationDesired: keyboardPresentationDesired,
                inputs: inputs,
                before: before
            )
            return
        }

        if inputSessionDesired {
            if inputs.userHidKeyboard {
                terminal.focusTerminalInputWithoutShowingSoftwareKeyboard()
            } else {
                terminal.acquireTerminalInput()
            }
        } else {
            terminal.releaseTerminalInput()
        }

        let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
        logCommand(
            inputSessionDesired: inputSessionDesired,
            keyboardPresentationDesired: keyboardPresentationDesired,
            reason: reason,
            inputs: inputs,
            before: before,
            after: after
        )

        if keyboardPresentationDesired, after.isSoftwareInputActive {
            schedulePresentationVerify()
        } else {
            cancelPresentationVerify()
            if !inputSessionDesired {
                presentationRefreshAttemptCount = 0
            }
        }
    }

    /// UIKit can accept the input session while legitimately withholding the
    /// software keyboard (hardware keyboard, iPhone Mirroring), or while a
    /// hosted keyboard scene is temporarily broken. Settle both cases by
    /// folding the accessory if no real keyboard frame arrives. A refresh
    /// requested while presentation is still in flight waits for this check;
    /// only a settled failure gets one rebuild. That preserves the "tap once
    /// after mirroring" repair path without restarting a keyboard animation.
    private func schedulePresentationVerify() {
        presentationVerifyTask?.cancel()
        presentationVerifyTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.presentationVerifyTask = nil
            guard !self.isSoftwareKeyboardVisible else { return }
            guard let paneId = self.activePaneId,
                  let terminal = self.terminalProvider?(paneId) else { return }
            let inputs = self.currentInputs
            guard Self.desiredKeyboardVisible(inputs: inputs) else { return }
            let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
            guard snapshot.isSoftwareInputActive else { return }
            if self.pendingPresentationRequest != .none {
                self.markDirty(reason: "presentationUnverified")
                return
            }
            // Settled with an active session and no keyboard: hardware mode
            // or a failed software-keyboard presentation. Keep the responder
            // for hardware keys, but remove the accessory until a real
            // software keyboard frame arrives or the user tries focus again.
            terminal.setTerminalInputAccessorySuppressed(true)
            let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
            self.logVerifySuppressed(after: after)
        }
    }

    private func cancelPresentationVerify() {
        presentationVerifyTask?.cancel()
        presentationVerifyTask = nil
    }

    private func logNoActiveTerminal(inputSessionDesired: Bool, inputs: StateInputs) {
        guard lifecycleLoggingEnabled else { return }
        logger.info("command=none reason=\(self.pendingReason, privacy: .public) inputDesired=\(inputSessionDesired) noActiveTerminal=true viewActive=\(inputs.viewActive) connected=\(inputs.activePaneConnected) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive)")
    }

    private func logAsyncRebuild(
        inputs: StateInputs,
        after: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        guard lifecycleLoggingEnabled else { return }
        logger.info("command=refresh repair=asyncRebuild reason=\(self.pendingReason, privacy: .public) viewActive=\(inputs.viewActive) connected=\(inputs.activePaneConnected) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive) kbVisible=\(self.isSoftwareKeyboardVisible) afterFirstResponder=\(after.isFirstResponder) afterSoftwareInput=\(after.isSoftwareInputActive)")
    }

    private func logDeferredRefresh(
        inputs: StateInputs,
        before: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        guard lifecycleLoggingEnabled else { return }
        logger.info("command=refresh repair=deferred reason=\(self.pendingReason, privacy: .public) viewActive=\(inputs.viewActive) connected=\(inputs.activePaneConnected) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive) kbVisible=\(self.isSoftwareKeyboardVisible) firstResponder=\(before.isFirstResponder) softwareInput=\(before.isSoftwareInputActive)")
    }

    private func logSteady(
        inputSessionDesired: Bool,
        keyboardPresentationDesired: Bool,
        inputs: StateInputs,
        before: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        guard lifecycleLoggingEnabled else { return }
        logger.info("command=steady reason=\(self.pendingReason, privacy: .public) inputDesired=\(inputSessionDesired) keyboardDesired=\(keyboardPresentationDesired) viewActive=\(inputs.viewActive) connected=\(inputs.activePaneConnected) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive) window=\(before.windowAttached) keyWindow=\(before.windowIsKey) scene=\(before.sceneActivationState, privacy: .public) firstResponder=\(before.isFirstResponder) softwareInput=\(before.isSoftwareInputActive) kbVisible=\(self.isSoftwareKeyboardVisible)")
    }

    private func logVerifySuppressed(
        after: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        guard lifecycleLoggingEnabled else { return }
        logger.info("command=verifySuppressed kbVisible=\(self.isSoftwareKeyboardVisible) afterFirstResponder=\(after.isFirstResponder) afterSoftwareInput=\(after.isSoftwareInputActive)")
    }

    private func logCommand(
        inputSessionDesired: Bool,
        keyboardPresentationDesired: Bool,
        reason: String,
        inputs: StateInputs,
        before: TerminalKeyboardCoordinatorDiagnosticSnapshot,
        after: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        guard lifecycleLoggingEnabled else { return }
        logger.info(
            "command=\(inputSessionDesired ? "acquire" : "release", privacy: .public) inputDesired=\(inputSessionDesired) keyboardDesired=\(keyboardPresentationDesired) reason=\(reason, privacy: .public) viewActive=\(inputs.viewActive) connected=\(inputs.activePaneConnected) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive) kbVisible=\(self.isSoftwareKeyboardVisible) beforeWindow=\(before.windowAttached) beforeKeyWindow=\(before.windowIsKey) beforeScene=\(before.sceneActivationState, privacy: .public) beforeFirstResponder=\(before.isFirstResponder) beforeSoftwareInput=\(before.isSoftwareInputActive) afterWindow=\(after.windowAttached) afterKeyWindow=\(after.windowIsKey) afterScene=\(after.sceneActivationState, privacy: .public) afterFirstResponder=\(after.isFirstResponder) afterSoftwareInput=\(after.isSoftwareInputActive)"
        )
    }

    #if DEBUG
    var keyboardUITestPresentationVerificationPending: Bool {
        presentationVerifyTask != nil
    }

    func keyboardUITestSetSoftwareKeyboardEndFrame(_ frame: CGRect?) {
        softwareKeyboardEndFrame = frame
        noteSoftwareKeyboardVisible(frame != nil)
    }
    #endif
}
#endif
