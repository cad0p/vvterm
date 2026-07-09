#if os(iOS) && DEBUG
import Combine
import SwiftUI
import UIKit

struct TerminalKeyboardUITestHarness: View {
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @State private var terminalView: GhosttyTerminalView?
    @State private var terminalReady = false
    @State private var showsTerminal = true
    @State private var focusRequestID = 0
    @State private var keyboardVisible = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var diagnostics = "notReady"

    private let diagnosticTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsTerminal {
                TerminalKeyboardHarnessRepresentable(
                    terminalView: $terminalView,
                    terminalReady: $terminalReady,
                    focusRequestID: focusRequestID
                )
                .ignoresSafeArea()
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
            refreshDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardVisible = false
            keyboardHeight = 0
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
        )
    }
}

private struct TerminalKeyboardHarnessRepresentable: UIViewRepresentable {
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @Binding var terminalView: GhosttyTerminalView?
    @Binding var terminalReady: Bool
    let focusRequestID: Int

    func makeUIView(context: Context) -> TerminalKeyboardHarnessContainerView {
        TerminalKeyboardHarnessContainerView()
    }

    func updateUIView(_ uiView: TerminalKeyboardHarnessContainerView, context: Context) {
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
        terminal.writeCallback = { _ in }
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
