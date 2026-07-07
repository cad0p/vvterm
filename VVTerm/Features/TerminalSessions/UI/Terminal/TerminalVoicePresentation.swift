#if os(macOS) || os(iOS)
import SwiftUI

extension TerminalContainerView {
    var voiceTriggerHandler: (() -> Void)? {
        voiceButtonEnabled ? { handleVoiceTrigger() } : nil
    }

    var voiceOverlayBottomInset: CGFloat {
        bottomOperationNotice == nil ? 0 : 104
    }

    var voiceOverlay: some View {
        VoiceRecordingView(
            audioService: audioService,
            onSend: { transcribedText in
                handleVoiceTranscription(transcribedText)
                showingVoiceRecording = false
                voiceProcessing = false
            },
            onCancel: {
                showingVoiceRecording = false
                voiceProcessing = false
            },
            isProcessing: $voiceProcessing
        )
    }

    func cancelVoiceRecordingIfNeeded() {
        if showingVoiceRecording {
            audioService.cancelRecording()
            showingVoiceRecording = false
            voiceProcessing = false
        }
        onVoiceRecordingChange?(false)
    }

    func toggleVoiceRecording() {
        if showingVoiceRecording {
            Task {
                let text = await audioService.stopRecording()
                await MainActor.run {
                    let fallback = text.isEmpty ? audioService.partialTranscription : text
                    handleVoiceTranscription(fallback)
                    showingVoiceRecording = false
                    voiceProcessing = false
                }
            }
        } else {
            startVoiceRecording()
        }
    }

    func startVoiceRecording() {
        Task {
            do {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    showingVoiceRecording = true
                }
                try await audioService.startRecording()
            } catch {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    showingVoiceRecording = false
                }
                voiceProcessing = false
                if let recordingError = error as? AudioService.RecordingError {
                    permissionErrorMessage = recordingError.localizedDescription
                        + "\n\n"
                        + String(localized: "Enable Microphone and Speech Recognition in System Settings.")
                } else {
                    permissionErrorMessage = error.localizedDescription
                }
                showingPermissionError = true
            }
        }
    }

    func handleVoiceTrigger() {
        guard session.connectionState.isConnected, isReady else { return }
        guard !showingVoiceRecording else { return }
        startVoiceRecording()
    }
}
#endif
