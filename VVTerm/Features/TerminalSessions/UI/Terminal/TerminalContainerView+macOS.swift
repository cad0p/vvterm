#if os(macOS)
import SwiftUI
import AppKit

final class TerminalVoiceKeyMonitor {
    private var monitor: Any?

    func start(
        isRecording: @escaping () -> Bool,
        cancelRecording: @escaping () -> Void,
        submitRecording: @escaping () -> Void,
        toggleRecording: @escaping () -> Void
    ) {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCodeEscape: UInt16 = 53
            let keyCodeReturn: UInt16 = 36

            if isRecording() {
                if event.keyCode == keyCodeEscape {
                    cancelRecording()
                    return nil
                }

                if event.keyCode == keyCodeReturn {
                    submitRecording()
                    return nil
                }
            }

            guard MacTerminalShortcut.toggleVoiceRecording.matches(event) else {
                return event
            }

            toggleRecording()
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        stop()
    }
}

extension TerminalContainerView {
    static func platformFallbackBackgroundColor() -> Color {
        Color(NSColor.windowBackgroundColor)
    }

    func platformVoicePresentation<Content: View>(_ content: Content) -> some View {
        content
            .alert("Voice Input Unavailable", isPresented: $showingPermissionError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(permissionErrorMessage)
            }
            .onChange(of: showingVoiceRecording) { isRecording in
                onVoiceRecordingChange?(isRecording)
            }
            .onAppear {
                setupKeyMonitor()
            }
            .onDisappear {
                cleanupKeyMonitor()
                cancelVoiceRecordingIfNeeded()
            }
    }

    @ViewBuilder
    var platformVoiceOverlayLayer: some View {
        if session.connectionState.isConnected && isReady {
            if showingVoiceRecording {
                voiceOverlay
                    .padding(.bottom, voiceOverlayBottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if voiceButtonEnabled {
                voiceTriggerButton
                    .padding(.bottom, voiceOverlayBottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
            }
        }
    }

    var voiceTriggerButton: some View {
        Button {
            startVoiceRecording()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Voice input (Command+Shift+M)"))
        .padding(14)
    }

    func setupKeyMonitor() {
        keyMonitor.start(
            isRecording: {
                showingVoiceRecording
            },
            cancelRecording: {
                audioService.cancelRecording()
                showingVoiceRecording = false
                voiceProcessing = false
            },
            submitRecording: {
                toggleVoiceRecording()
            },
            toggleRecording: {
                toggleVoiceRecording()
            }
        )
    }

    func cleanupKeyMonitor() {
        keyMonitor.stop()
    }

    func platformTerminalWrapperDidAppear() {
        ConnectionSessionManager.shared.peekTerminal(for: session.id)?.resumeRendering()
    }

    func platformTerminalWrapperDidDisappear() {
        ConnectionSessionManager.shared.peekTerminal(for: session.id)?.pauseRendering()
    }
}
#endif
