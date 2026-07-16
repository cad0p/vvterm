#if os(iOS)
import Combine
import Foundation
import SwiftUI
import UIKit

enum TerminalRenderingTransition: Equatable {
    case none
    case pause
    case resume
}

enum TerminalRenderingPolicy {
    static func transition(
        terminalIsActive: Bool,
        sceneIsActive: Bool,
        renderingIsPaused: Bool
    ) -> TerminalRenderingTransition {
        if terminalIsActive && sceneIsActive {
            return renderingIsPaused ? .resume : .none
        }
        return renderingIsPaused ? .none : .pause
    }
}

extension View {
    func terminalCommandFocusValues(
        activeServerId: UUID?,
        activePaneId: UUID?,
        splitActions: TerminalSplitActions?
    ) -> some View {
        self
    }

    func terminalKeyboardAvoidance(
        focusedPaneId: UUID?,
        paneIds: [UUID],
        terminalRegistryVersion: Int,
        terminalProvider: @escaping (UUID) -> GhosttyTerminalView?,
        enabledOverride: Bool? = nil
    ) -> some View {
        modifier(
            TerminalKeyboardAvoidanceModifier(
                focusedPaneId: focusedPaneId,
                paneIds: paneIds,
                terminalRegistryVersion: terminalRegistryVersion,
                terminalProvider: terminalProvider,
                enabledOverride: enabledOverride
            )
        )
    }
}

@MainActor
private final class TerminalKeyboardAvoidanceViewModel: ObservableObject {
    @Published private(set) var verticalOffset: CGFloat = 0

    private weak var terminal: GhosttyTerminalView?
    private var keyboardFrame: CGRect?
    private var cursorRect: CGRect = .zero

    func update(
        enabled: Bool,
        terminal newTerminal: GhosttyTerminalView?,
        keyboardFrame: CGRect?,
        animation: Animation?
    ) {
        self.keyboardFrame = keyboardFrame

        guard enabled, let newTerminal else {
            detachTerminal()
            setVerticalOffset(0, animation: animation)
            return
        }

        if terminal !== newTerminal {
            detachTerminal()
            terminal = newTerminal
            newTerminal.onKeyboardAvoidanceCursorRectChange = { [weak self, weak newTerminal] cursorRect in
                guard let self, let newTerminal, self.terminal === newTerminal else { return }
                self.cursorRect = cursorRect
                self.recalculate(animation: .easeOut(duration: 0.12))
            }
        }

        cursorRect = newTerminal.keyboardAvoidanceCursorRect()
        recalculate(animation: animation)
    }

    func detach() {
        detachTerminal()
        verticalOffset = 0
    }

    private func detachTerminal() {
        terminal?.disableKeyboardAvoidanceSizePreservation()
        terminal?.onKeyboardAvoidanceCursorRectChange = nil
        terminal = nil
        cursorRect = .zero
    }

    private func recalculate(animation: Animation?) {
        guard let terminal, let window = terminal.window else {
            setVerticalOffset(0, animation: animation)
            return
        }

        let currentBoundsFrame = terminal.convert(terminal.bounds, to: window)
        let baseBoundsFrame = currentBoundsFrame.offsetBy(dx: 0, dy: -verticalOffset)
        let keyboardFrameInWindow = keyboardFrame.map {
            window.convert($0, from: window.screen.coordinateSpace)
        }
        let screenFrameInWindow = window.convert(
            window.screen.bounds,
            from: window.screen.coordinateSpace
        )
        let geometry = TerminalKeyboardAvoidancePolicy.resolvedGeometry(
            screenFrame: screenFrameInWindow,
            terminalFrame: baseBoundsFrame,
            keyboardFrame: keyboardFrameInWindow
        )
        terminal.setKeyboardAvoidanceSizePreservationEnabled(
            geometry.preservesTerminalSurfaceSize
        )

        let currentTerminalFrame = terminal.convert(terminal.keyboardAvoidanceTerminalRect(), to: window)
        let currentCursorFrame = terminal.convert(cursorRect, to: window)
        let baseTerminalFrame = currentTerminalFrame.offsetBy(dx: 0, dy: -verticalOffset)
        let baseCursorFrame = currentCursorFrame.offsetBy(dx: 0, dy: -verticalOffset)
        let newOffset = TerminalKeyboardAvoidancePolicy.verticalOffset(
            terminalFrame: baseTerminalFrame,
            cursorFrame: baseCursorFrame,
            keyboardFrame: geometry.frame
        )
        setVerticalOffset(newOffset, animation: animation)
    }

    private func setVerticalOffset(_ newValue: CGFloat, animation: Animation?) {
        guard abs(verticalOffset - newValue) >= 0.5 else { return }
        if let animation {
            withAnimation(animation) {
                verticalOffset = newValue
            }
        } else {
            verticalOffset = newValue
        }
    }
}

private struct TerminalKeyboardAvoidanceModifier: ViewModifier {
    let focusedPaneId: UUID?
    let paneIds: [UUID]
    let terminalRegistryVersion: Int
    let terminalProvider: (UUID) -> GhosttyTerminalView?
    let enabledOverride: Bool?

    @AppStorage(TerminalDefaults.preserveTerminalSizeForKeyboardKey) private var storedEnabled = false
    @ObservedObject private var keyboardCoordinator: TerminalKeyboardCoordinator
    @StateObject private var model = TerminalKeyboardAvoidanceViewModel()

    init(
        focusedPaneId: UUID?,
        paneIds: [UUID],
        terminalRegistryVersion: Int,
        terminalProvider: @escaping (UUID) -> GhosttyTerminalView?,
        enabledOverride: Bool?
    ) {
        self.focusedPaneId = focusedPaneId
        self.paneIds = paneIds
        self.terminalRegistryVersion = terminalRegistryVersion
        self.terminalProvider = terminalProvider
        self.enabledOverride = enabledOverride
        _keyboardCoordinator = ObservedObject(
            wrappedValue: TerminalTabManager.shared.keyboardCoordinator
        )
    }

    private var isEnabled: Bool {
        enabledOverride ?? storedEnabled
    }

    func body(content: Content) -> some View {
        Group {
            if isEnabled {
                content
                    .offset(y: model.verticalOffset)
                    .clipped()
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            } else {
                content
            }
        }
        .onAppear {
            refresh(animation: nil)
        }
        .onDisappear {
            for paneId in paneIds {
                terminalProvider(paneId)?.onKeyboardAvoidanceCursorRectChange = nil
            }
            model.detach()
        }
        .onChange(of: isEnabled) { _ in
            refresh(animation: keyboardAnimation)
        }
        .onChange(of: focusedPaneId) { _ in
            refresh(animation: .easeOut(duration: 0.12))
        }
        .onChange(of: terminalRegistryVersion) { _ in
            refresh(animation: nil)
        }
        .onChange(of: keyboardCoordinator.softwareKeyboardEndFrame) { _ in
            refresh(animation: keyboardAnimation)
        }
    }

    private var keyboardAnimation: Animation {
        let duration = keyboardCoordinator.keyboardAnimationDuration
        switch keyboardCoordinator.keyboardAnimationCurve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        case .linear:
            return .linear(duration: duration)
        case .easeInOut:
            return .easeInOut(duration: duration)
        @unknown default:
            return .easeInOut(duration: duration)
        }
    }

    private func refresh(animation: Animation?) {
        let terminal = focusedPaneId.flatMap(terminalProvider)
        model.update(
            enabled: isEnabled,
            terminal: terminal,
            keyboardFrame: keyboardCoordinator.softwareKeyboardEndFrame,
            animation: animation
        )
    }
}

/// Wraps SSH connection and Ghostty terminal for a pane on iOS/iPadOS.
struct SSHTerminalPaneWrapper: View {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    let isActive: Bool
    let terminalContextMenuActions: TerminalContextMenuActions
    let onProcessExit: () -> Void
    let onReady: () -> Void
    let onVoiceTrigger: (() -> Void)?
    let onSceneActivation: () -> Void

    var body: some View {
        GeometryReader { geometry in
            SSHTerminalPaneRepresentable(
                paneId: paneId,
                server: server,
                credentials: credentials,
                richPasteUIModel: richPasteUIModel,
                size: geometry.size,
                isActive: isActive,
                terminalContextMenuActions: terminalContextMenuActions,
                onProcessExit: onProcessExit,
                onReady: onReady,
                onVoiceTrigger: onVoiceTrigger
            )
            .background {
                TerminalSceneActivationObserver(
                    onSceneActivation: handleSceneActivation
                )
                .allowsHitTesting(false)
            }
        }
    }

    private func handleSceneActivation(_ activatedScene: UIScene) {
        // A SwiftUI wrapper can briefly outlive registry ownership. Never let
        // that stale wrapper resume or reconnect a terminal now hosted by
        // another scene.
        guard let terminal = TerminalTabManager.shared.getTerminal(for: paneId),
              let terminalScene = terminal.window?.windowScene,
              terminalScene === activatedScene else { return }

        if TerminalRenderingPolicy.transition(
            terminalIsActive: isActive,
            sceneIsActive: terminalScene.activationState == .foregroundActive,
            renderingIsPaused: terminal.isRenderingPaused
        ) == .resume {
            terminal.resumeRendering()
            terminal.forceRefresh()
        }
        onSceneActivation()
    }
}

private struct TerminalSceneActivationObserver: UIViewRepresentable {
    let onSceneActivation: (UIScene) -> Void

    func makeUIView(context: Context) -> TerminalSceneActivationView {
        TerminalSceneActivationView(onSceneActivation: onSceneActivation)
    }

    func updateUIView(_ view: TerminalSceneActivationView, context: Context) {
        view.onSceneActivation = onSceneActivation
    }
}

private final class TerminalSceneActivationView: UIView {
    var onSceneActivation: (UIScene) -> Void
    private var observer: NSObjectProtocol?

    init(onSceneActivation: @escaping (UIScene) -> Void) {
        self.onSceneActivation = onSceneActivation
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        observer = NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let activatedScene = notification.object as? UIScene,
                  activatedScene === self.window?.windowScene else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      activatedScene === self.window?.windowScene else { return }
                self.onSceneActivation(activatedScene)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private struct SSHTerminalPaneRepresentable: UIViewRepresentable {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    let size: CGSize
    let isActive: Bool
    let terminalContextMenuActions: TerminalContextMenuActions
    let onProcessExit: () -> Void
    let onReady: () -> Void
    let onVoiceTrigger: (() -> Void)?

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.scenePhase) private var scenePhase

    func makeCoordinator() -> TerminalPaneSSHCoordinator {
        TerminalPaneSSHCoordinator(
            paneId: paneId,
            server: server,
            credentials: credentials,
            sshClient: SSHClient(),
            richPasteUIModel: richPasteUIModel
        )
    }

    func makeUIView(context: Context) -> UIView {
        guard let app = ghosttyApp.app else {
            return UIView(frame: .zero)
        }

        let coordinator = context.coordinator

        if let existingTerminal = TerminalTabManager.shared.getTerminal(for: paneId) {
            coordinator.terminal = existingTerminal
            coordinator.isTerminalReady = true
            coordinator.preservePane = true
            configureExistingTerminal(existingTerminal, coordinator: coordinator)

            if existingTerminal.superview != nil {
                existingTerminal.removeFromSuperview()
            }
            if size.width > 0 && size.height > 0 {
                coordinator.lastReportedSize = size
                existingTerminal.frame = CGRect(origin: .zero, size: size)
                existingTerminal.sizeDidChange(size)
            }

            DispatchQueue.main.async {
                onReady()
                startSSHConnectionIfNeeded(
                    terminal: existingTerminal,
                    coordinator: coordinator,
                    state: TerminalTabManager.shared.paneStates[paneId]?.connectionState ?? .idle
                )
            }
            return existingTerminal
        }

        let initialSize = (size.width > 0 && size.height > 0) ? size : CGSize(width: 800, height: 600)
        let terminalView = GhosttyTerminalView(
            frame: CGRect(origin: .zero, size: initialSize),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: paneId.uuidString,
            useCustomIO: true
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            guard let coordinator else { return }
            DispatchQueue.main.async {
                coordinator.isTerminalReady = true
                onReady()
                if let terminalView {
                    startSSHConnectionIfNeeded(
                        terminal: terminalView,
                        coordinator: coordinator,
                        state: TerminalTabManager.shared.paneStates[paneId]?.connectionState ?? .idle
                    )
                }
            }
        }
        terminalView.onProcessExit = processExitHandler(for: terminalView)
        terminalView.onVoiceButtonTapped = onVoiceTrigger
        terminalView.onPwdChange = { [paneId] rawDirectory in
            DispatchQueue.main.async {
                TerminalTabManager.shared.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
            }
        }
        terminalView.onTitleChange = { [paneId] title in
            TerminalTabManager.shared.updatePaneTitle(paneId, rawTitle: title)
        }
        terminalView.onZoomAction = { [paneId] action in
            TerminalTabManager.shared.handleTerminalZoom(action, for: paneId)
        }
        terminalView.terminalContextMenuActions = terminalContextMenuActions
        terminalView.applyPresentationOverrides(TerminalTabManager.shared.presentationOverrides(for: paneId))

        coordinator.terminal = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        TerminalTabManager.shared.registerTerminal(terminalView, for: paneId)

        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToSSH(data)
        }
        terminalView.setupWriteCallback()
        terminalView.onResize = { [weak coordinator] cols, rows in
            coordinator?.handleResize(cols: cols, rows: rows)
        }

        coordinator.lastReportedSize = initialSize
        if size.width > 0 && size.height > 0 {
            terminalView.sizeDidChange(size)
        }
        if !isActive {
            terminalView.pauseRendering()
        }

        return terminalView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let terminalView = uiView as? GhosttyTerminalView else {
            return
        }

        guard TerminalTabManager.shared.paneStates[paneId] != nil else {
            context.coordinator.cancelShell()
            terminalView.writeCallback = nil
            terminalView.onReady = nil
            terminalView.onProcessExit = nil
            terminalView.onVoiceButtonTapped = nil
            return
        }

        let windowScene = terminalView.window?.windowScene
        let windowSceneIsActive = windowScene.map {
            $0.activationState == .foregroundActive
        }
        let sceneIsActive = TerminalSceneActivityPolicy.isActive(
            environmentIsActive: scenePhase == .active,
            windowSceneIsActive: windowSceneIsActive
        )
        let renderingTransition = TerminalRenderingPolicy.transition(
            terminalIsActive: isActive,
            sceneIsActive: sceneIsActive,
            renderingIsPaused: terminalView.isRenderingPaused
        )

        if terminalView.surfacePresentationOverrides != TerminalTabManager.shared.presentationOverrides(for: paneId) {
            terminalView.applyPresentationOverrides(TerminalTabManager.shared.presentationOverrides(for: paneId))
        }
        terminalView.onVoiceButtonTapped = onVoiceTrigger
        terminalView.terminalContextMenuActions = terminalContextMenuActions
        if size.width > 0, size.height > 0, size != context.coordinator.lastReportedSize {
            context.coordinator.lastReportedSize = size
            terminalView.sizeDidChange(size)
        }

        if context.coordinator.isTerminalReady {
            switch renderingTransition {
            case .resume:
                terminalView.resumeRendering()
                terminalView.forceRefresh()
            case .pause:
                terminalView.pauseRendering()
            case .none:
                break
            }
        }

        let state = TerminalTabManager.shared.paneStates[paneId]?.connectionState ?? .idle
        let shouldStartSSHConnection = TerminalConnectionStartPolicy.shouldStart(
            connectionState: state
        )

        if shouldStartSSHConnection {
            startSSHConnectionIfNeeded(
                terminal: terminalView,
                coordinator: context.coordinator,
                state: state
            )
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        guard let terminalView = uiView as? GhosttyTerminalView else { return }

        let paneStillExists = TerminalTabManager.shared.paneStates[coordinator.paneId] != nil
        if paneStillExists {
            coordinator.preservePane = true
            return
        }

        coordinator.terminal = nil
        let paneId = coordinator.paneId
        Task { @MainActor in
            TerminalTabManager.shared.unregisterTerminal(terminalView, for: paneId)
            coordinator.cancelShell()
        }
    }

    private func configureExistingTerminal(_ terminal: GhosttyTerminalView, coordinator: TerminalPaneSSHCoordinator) {
        terminal.onProcessExit = processExitHandler(for: terminal)
        terminal.onVoiceButtonTapped = onVoiceTrigger
        terminal.onPwdChange = { [paneId] rawDirectory in
            DispatchQueue.main.async {
                TerminalTabManager.shared.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
            }
        }
        terminal.onTitleChange = { [paneId] title in
            TerminalTabManager.shared.updatePaneTitle(paneId, rawTitle: title)
        }
        terminal.onZoomAction = { [paneId] action in
            TerminalTabManager.shared.handleTerminalZoom(action, for: paneId)
        }
        terminal.terminalContextMenuActions = terminalContextMenuActions
        terminal.applyPresentationOverrides(TerminalTabManager.shared.presentationOverrides(for: paneId))
        terminal.writeCallback = { [weak coordinator] data in
            coordinator?.sendToSSH(data)
        }
        coordinator.installRichPasteInterception(on: terminal)
        terminal.onResize = { [weak coordinator] cols, rows in
            coordinator?.handleResize(cols: cols, rows: rows)
        }
    }

    private func processExitHandler(for terminal: GhosttyTerminalView) -> () -> Void {
        { [weak terminal] in
            guard let terminal,
                  TerminalTabManager.shared.getTerminal(for: paneId) === terminal else { return }
            onProcessExit()
        }
    }

    private func startSSHConnectionIfNeeded(
        terminal: GhosttyTerminalView,
        coordinator: TerminalPaneSSHCoordinator,
        state: ConnectionState
    ) {
        guard TerminalTabManager.shared.paneStates[paneId] != nil else { return }
        guard TerminalTabManager.shared.shellId(for: paneId) == nil else { return }
        guard coordinator.shellTask == nil else { return }
        guard !TerminalTabManager.shared.isShellStartInFlight(for: paneId) else { return }
        guard UIApplication.shared.applicationState == .active else { return }

        switch state {
        case .connecting, .reconnecting, .connected:
            break
        case .disconnected, .failed, .idle:
            return
        }

        coordinator.startSSHConnection(terminal: terminal)
    }
}
#endif
