#if os(iOS) && DEBUG
import Combine
import SwiftUI
import UIKit

struct TerminalKeyboardUITestHarness: View {
    private static let paneId = UUID(uuidString: "B54F29D8-7C3E-4DB8-B3D7-9D9F1604B755")!

    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @State private var terminalView: GhosttyTerminalView?
    @State private var terminalReady = false
    @State private var showsTerminal = true
    @State private var focusRequestID = 0
    @State private var keyboardVisible = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardFrame: CGRect?
    @State private var diagnostics = "notReady"
    @State private var reconnectStatus = "initial"
    @State private var receivedInputHex = "none"
    @Environment(\.scenePhase) private var scenePhase

    private var preservesTerminalSize: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-preserve-terminal-size")
    }

    private let diagnosticTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsTerminal {
                TerminalKeyboardHarnessRepresentable(
                    terminalView: $terminalView,
                    terminalReady: $terminalReady,
                    focusRequestID: focusRequestID,
                    onInput: { data in
                        receivedInputHex = data.map { String(format: "%02x", $0) }.joined()
                    }
                )
                .terminalKeyboardAvoidance(
                    focusedPaneId: Self.paneId,
                    paneIds: [Self.paneId],
                    terminalRegistryVersion: terminalView == nil ? 0 : 1,
                    terminalProvider: { _ in terminalView },
                    enabledOverride: preservesTerminalSize
                )
                .ignoresSafeArea(.container)
                .accessibilityIdentifier("vvterm.keyboardTest.container")
            } else {
                nonTerminalSurface
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(terminalReady ? "ready=true" : "ready=false")
                    .accessibilityIdentifier("vvterm.keyboardTest.ready")
                Text(diagnostics)
                    .accessibilityIdentifier("vvterm.keyboardTest.diagnostics")
                    .lineLimit(6)
            }
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.72))
            .allowsHitTesting(false)
            .accessibilityElement(children: .contain)

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Terminal") {
                        terminalReady = false
                        showsTerminal = true
                        focusRequestID += 1
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.mode.terminal")

                    Button("Other") {
                        terminalView?.releaseTerminalInput()
                        terminalView = nil
                        terminalReady = false
                        showsTerminal = false
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.mode.other")

                    Button("Hide") {
                        terminalView?.dismissKeyboardFromToolbar()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hideViaToolbar")

                    Button("Keyboard") {
                        terminalView?.requestKeyboardFocus(for: .explicitUserRequest)
                        focusRequestID += 1
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.showKeyboard")
                }

                HStack(spacing: 8) {
                    Button("Mark") {
                        terminalView?.keyboardUITestSetMarkedText("nihon")
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.ime.mark")

                    Button("Del") {
                        terminalView?.keyboardUITestDeleteBackwardThroughIMEProxy()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.ime.delete")

                    Button("Commit") {
                        terminalView?.keyboardUITestCommitMarkedText()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.ime.commit")

                    Button("Hardware") {
                        terminalView?.keyboardUITestRequestHardwareKeyboardFocus()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hardwareFocus")

                    Button("HW On") {
                        terminalView?.keyboardUITestSetHardwareKeyboardAttached(true)
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hardware.attach")

                    Button("HW Off") {
                        terminalView?.keyboardUITestSetHardwareKeyboardAttached(false)
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hardware.detach")
                }

                Button("Cursor Bottom") {
                    terminalView?.keyboardUITestMoveCursorToBottom()
                }
                .accessibilityIdentifier("vvterm.keyboardTest.cursor.bottom")
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.72))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity, alignment: .topTrailing)
            .padding(8)
        }
        .background(Color.black)
        .task {
            ghosttyApp.startIfNeeded()
        }
        .onChange(of: terminalReady) { isReady in
            guard isReady else { return }
            configureLifecycleHarness()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                restoreLifecycleHarnessAfterForeground()
            } else {
                reconnectStatus = "background"
                TerminalTabManager.shared.keyboardCoordinator.setViewActive(false)
            }
        }
        .onReceive(diagnosticTimer) { _ in
            refreshDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            noteKeyboardFrame(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            noteKeyboardFrame(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
            keyboardHeight = 0
            keyboardFrame = nil
            refreshDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardVisible = false
            keyboardHeight = 0
            keyboardFrame = nil
            refreshDiagnostics()
        }
    }

    private var nonTerminalSurface: some View {
        Button("Other Surface") { }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.08))
            .accessibilityIdentifier("vvterm.keyboardTest.nonTerminalSurface")
    }

    private func noteKeyboardFrame(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
            return
        }
        let screenBounds = terminalView?.window?.screen.bounds ?? UIScreen.main.bounds
        let overlap = screenBounds.intersection(frame)
        let height = overlap.isNull ? 0 : overlap.height
        keyboardHeight = height
        keyboardVisible = height >= 100
        keyboardFrame = keyboardVisible ? frame : nil
        refreshDiagnostics()
    }

    private func refreshDiagnostics() {
        guard let terminalView else {
            diagnostics = "notReady ghostty=\(ghosttyApp.readiness.rawValue)"
            return
        }
        diagnostics = terminalView.keyboardUITestDiagnostics(
            keyboardVisible: keyboardVisible,
            keyboardHeight: keyboardHeight
        ) + " " + keyboardAvoidanceDiagnostics(for: terminalView)
            + " reconnect=\(reconnectStatus) inputHex=\(receivedInputHex)"
    }

    private func configureLifecycleHarness() {
        guard let terminalView else { return }
        let manager = TerminalTabManager.shared
        if manager.paneStates[Self.paneId] == nil {
            let tab = TerminalTab(serverId: UUID(), title: "Keyboard lifecycle test")
            manager.paneStates[Self.paneId] = TerminalPaneState(
                paneId: Self.paneId,
                tabId: tab.id,
                serverId: tab.serverId
            )
        }
        manager.registerTerminal(terminalView, for: Self.paneId)
        manager.updatePaneState(Self.paneId, connectionState: .connected)
        manager.keyboardCoordinator.setActivePane(Self.paneId)
        manager.keyboardCoordinator.setViewActive(true)
        reconnectStatus = "connected"
    }

    private func restoreLifecycleHarnessAfterForeground() {
        guard terminalReady else { return }
        reconnectStatus = "reconnecting"
        TerminalTabManager.shared.updatePaneState(
            Self.paneId,
            connectionState: .reconnecting(attempt: 1)
        )
        TerminalTabManager.shared.keyboardCoordinator.setActivePane(Self.paneId)
        TerminalTabManager.shared.keyboardCoordinator.setViewActive(true)
        TerminalTabManager.shared.updatePaneState(Self.paneId, connectionState: .connected)
        reconnectStatus = "connected"
    }

    private func keyboardAvoidanceDiagnostics(for terminal: GhosttyTerminalView) -> String {
        guard let window = terminal.window else {
            return "preserveSize=\(preservesTerminalSize) terminalTop=unavailable cursorBottom=unavailable keyboardTop=unavailable"
        }

        let terminalFrame = terminal.convert(terminal.bounds, to: window)
        let cursorFrame = terminal.convert(terminal.keyboardAvoidanceCursorRect(), to: window)
        let keyboardTop = keyboardFrame.map {
            window.convert($0, from: window.screen.coordinateSpace).minY
        }
        return [
            "preserveSize=\(preservesTerminalSize)",
            "terminalTop=\(metricText(terminalFrame.minY))",
            "cursorBottom=\(metricText(cursorFrame.maxY))",
            "keyboardTop=\(keyboardTop.map(metricText) ?? "none")"
        ].joined(separator: " ")
    }

    private func metricText(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

private struct TerminalKeyboardHarnessRepresentable: UIViewRepresentable {
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @Binding var terminalView: GhosttyTerminalView?
    @Binding var terminalReady: Bool
    let focusRequestID: Int
    let onInput: (Data) -> Void

    func makeUIView(context: Context) -> TerminalKeyboardHarnessContainerView {
        TerminalKeyboardHarnessContainerView()
    }

    func updateUIView(_ uiView: TerminalKeyboardHarnessContainerView, context: Context) {
        uiView.onInput = onInput
        uiView.installTerminalIfNeeded(app: ghosttyApp.app, appWrapper: ghosttyApp)
        uiView.requestKeyboardFocusIfNeeded(focusRequestID: focusRequestID)

        if let installedTerminal = uiView.terminalView, terminalView !== installedTerminal {
            DispatchQueue.main.async {
                terminalView = installedTerminal
                terminalReady = true
            }
        }
    }

    static func dismantleUIView(_ uiView: TerminalKeyboardHarnessContainerView, coordinator: ()) {
        uiView.releaseTerminalInput()
    }
}

private final class TerminalKeyboardHarnessContainerView: UIView {
    private(set) weak var terminalView: GhosttyTerminalView?
    var onInput: ((Data) -> Void)?
    private var lastHandledFocusRequestID: Int?
    private var pendingFocusRequestID = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        accessibilityIdentifier = "vvterm.keyboardTest.containerView"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installTerminalIfNeeded(app: ghostty_app_t?, appWrapper: Ghostty.App) {
        guard terminalView == nil, let app else { return }

        let initialSize = bounds.size == .zero ? CGSize(width: 390, height: 844) : bounds.size
        let terminal = GhosttyTerminalView(
            frame: CGRect(origin: .zero, size: initialSize),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: appWrapper,
            paneId: "keyboard-ui-test",
            useCustomIO: true
        )
        terminal.accessibilityIdentifier = "vvterm.keyboardTest.terminalSurface"
        terminal.accessibilityLabel = "Terminal Keyboard Test Surface"
        terminal.isAccessibilityElement = true
        terminal.acceptsTerminalInput = true
        terminal.keyboardUITestSetHardwareKeyboardAttached(false)
        terminal.writeCallback = { [weak self] data in
            DispatchQueue.main.async {
                self?.onInput?(data)
            }
        }
        terminal.setupWriteCallback()
        terminal.onReady = { [weak self, weak terminal] in
            guard let self, let terminal else { return }
            terminal.acceptsTerminalInput = true
            DispatchQueue.main.async {
                self.requestKeyboardFocusIfNeeded()
            }
        }

        addSubview(terminal)
        terminalView = terminal
        setNeedsLayout()

        DispatchQueue.main.async { [weak self] in
            self?.requestKeyboardFocusIfNeeded()
        }
    }

    func requestKeyboardFocusIfNeeded(focusRequestID: Int) {
        pendingFocusRequestID = focusRequestID
        requestKeyboardFocusIfNeeded()
    }

    func requestKeyboardFocusIfNeeded() {
        guard window != nil, let terminalView else { return }
        guard lastHandledFocusRequestID != pendingFocusRequestID else { return }
        lastHandledFocusRequestID = pendingFocusRequestID
        terminalView.acceptsTerminalInput = true
        _ = terminalView.requestKeyboardFocus(for: .explicitUserRequest)
    }

    func releaseTerminalInput() {
        terminalView?.releaseTerminalInput()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.requestKeyboardFocusIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let terminalView else { return }
        terminalView.frame = bounds
        if bounds.width > 0, bounds.height > 0 {
            terminalView.sizeDidChange(bounds.size)
        }
    }
}
#endif
