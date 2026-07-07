#if os(macOS)
import SwiftUI
import AppKit

struct MacOSZenWindowChromeBridge: NSViewRepresentable {
    @Binding var contentInsets: EdgeInsets

    func makeNSView(context: Context) -> WindowObserverView {
        WindowObserverView()
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onWindowUpdate = { [contentInsets = _contentInsets] window in
            guard let closeButton = window.standardWindowButton(.closeButton),
                  let miniButton = window.standardWindowButton(.miniaturizeButton),
                  let zoomButton = window.standardWindowButton(.zoomButton) else { return }

            let buttons = [closeButton, miniButton, zoomButton]
            buttons.forEach { button in
                button.isHidden = false
                button.alphaValue = 1
                button.superview?.isHidden = false
                button.superview?.alphaValue = 1
            }

            let safeArea = window.contentView?.safeAreaInsets
                ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            let titlebarHeight = max(
                window.frame.height - window.contentLayoutRect.height,
                safeArea.top
            )
            let newInsets = EdgeInsets(
                top: titlebarHeight,
                leading: safeArea.left,
                bottom: safeArea.bottom,
                trailing: safeArea.right
            )

            let currentInsets = contentInsets.wrappedValue
            let didChange =
                abs(currentInsets.top - newInsets.top) > 0.5 ||
                abs(currentInsets.leading - newInsets.leading) > 0.5 ||
                abs(currentInsets.bottom - newInsets.bottom) > 0.5 ||
                abs(currentInsets.trailing - newInsets.trailing) > 0.5

            if didChange {
                contentInsets.wrappedValue = newInsets
            }
        }
        nsView.triggerUpdate()
    }

    static func dismantleNSView(_ nsView: WindowObserverView, coordinator: ()) {
        nsView.removeObservers()
    }

    final class WindowObserverView: NSView {
        var onWindowUpdate: ((NSWindow) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override var intrinsicContentSize: NSSize {
            .zero
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installObservers()
            triggerUpdate()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            triggerUpdate()
        }

        override func layout() {
            super.layout()
            triggerUpdate()
        }

        func triggerUpdate() {
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.onWindowUpdate?(window)
            }
        }

        func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }

        private func installObservers() {
            removeObservers()
            guard let window else { return }

            let center = NotificationCenter.default
            observers = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didBecomeKeyNotification
            ].map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.triggerUpdate()
                }
            }
        }

        deinit {
            removeObservers()
        }
    }
}

struct MacOSToolbarBackdrop: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 52
            color
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
        }
        .allowsHitTesting(false)
    }
}

extension ConnectionTerminalContainer {
    var platformBody: some View {
        sharedBody
            .focusedValue(\.openTerminalTab, handleNewTabCommand)
            .focusedValue(\.serverViewTabActions, serverViewTabActions())
            // The connected-server toolbar is rendered by the AppKit NSToolbar
            // (see MacConnectionToolbar). This pane publishes its sections into
            // the shared bridge; the toolbar hosts them.
            .onAppear { activateToolbarBridge(); updateCommandBridge() }
            .onDisappear {
                MacToolbarBridge.shared.deactivate(ownerId: server.id.uuidString)
                MacShellCommandBridge.shared.clear(ownerId: server.id.uuidString)
            }
            .onChange(of: selectedView) { _ in activateToolbarBridge(); updateCommandBridge() }
            .onChange(of: shouldShowViewPicker) { _ in activateToolbarBridge() }
            .onChange(of: serverTabs.count) { _ in activateToolbarBridge() }
            .onChange(of: serverFileTabs.count) { _ in activateToolbarBridge() }
            .onChange(of: selectedFileTabId) { _ in activateToolbarBridge() }
            .onChange(of: selectedTabId) { _ in activateToolbarBridge(); updateCommandBridge() }
            .onChange(of: isZenModeEnabled) { _ in activateToolbarBridge() }
            .alert(
                disconnectAlertTitle,
                isPresented: $showingDisconnectConfirmation,
            ) {
                Button("Cancel", role: .cancel) {}
                Button(disconnectActionTitle, role: .destructive) {
                    disconnectFromServer()
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text(disconnectAlertMessage)
            }
            .alert("Close this terminal?", isPresented: $showingPaneCloseConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Close", role: .destructive) {
                    closeFocusedPaneConfirmed()
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text("The SSH connection will be terminated.")
            }
            .sheet(item: $serverToEdit) { editingServer in
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: serverManager.workspaces.first { $0.id == editingServer.workspaceId },
                    server: editingServer,
                    onSave: { _ in
                        serverToEdit = nil
                    }
                )
                .adaptiveSoftScrollEdges()
                .frame(
                    minWidth: 640,
                    idealWidth: 700,
                    maxWidth: 760,
                    minHeight: 520,
                    idealHeight: 620,
                    maxHeight: 680
                )
            }
    }

    func platformChrome<Content: View>(
        _ content: Content,
        backgroundColor: Color
    ) -> some View {
        content
            .overlay(alignment: .top) {
                if !isZenModeEnabled {
                    MacOSToolbarBackdrop(color: backgroundColor)
                }
            }
            .background {
                if isZenModeEnabled {
                    MacOSZenWindowChromeBridge(contentInsets: $zenWindowSafeAreaInsets)
                        .frame(width: 0, height: 0)
                }
            }
            .macOSZenExpandedTopSafeArea(isZenModeEnabled && selectedView == "terminal")
    }

    private var terminalContentInsets: EdgeInsets {
        isZenModeEnabled ? zenWindowSafeAreaInsets : EdgeInsets()
    }

    @ViewBuilder
    var terminalLayer: some View {
        ForEach(serverTabs, id: \.id) { tab in
            let isVisible = selectedView == "terminal" && selectedTabId == tab.id
            TerminalTabView(
                tab: tab,
                server: server,
                tabManager: tabManager,
                isSelected: isVisible
            )
            .padding(terminalContentInsets)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .zIndex(isVisible ? 1 : 0)
        }

        if selectedView == "terminal" && serverTabs.isEmpty {
            TerminalEmptyStateView(server: server) {
                openNewTab()
            }
            .padding(terminalContentInsets)
        }
    }
}

private extension View {
    @ViewBuilder
    func macOSZenExpandedTopSafeArea(_ isEnabled: Bool) -> some View {
        if isEnabled {
            self.ignoresSafeArea(.container, edges: .top)
        } else {
            self
        }
    }
}
#endif
