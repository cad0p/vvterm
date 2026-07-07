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

    func platformTerminalWrapperDidAppear() {
        ConnectionSessionManager.shared.peekTerminal(for: session.id)?.resumeRendering()
    }

    func platformTerminalWrapperDidDisappear() {
        ConnectionSessionManager.shared.peekTerminal(for: session.id)?.pauseRendering()
    }
}
#endif
