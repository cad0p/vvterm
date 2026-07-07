#if os(iOS)
import SwiftUI
import UIKit

extension TerminalContainerView {
    static func platformFallbackBackgroundColor() -> Color {
        Color(UIColor.systemBackground)
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
            .onDisappear {
                cancelVoiceRecordingIfNeeded()
            }
    }

    @ViewBuilder
    var platformVoiceOverlayLayer: some View {
        if session.connectionState.isConnected && isReady && showingVoiceRecording {
            voiceOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 16)
                .padding(.bottom, voiceOverlayBottomInset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
        }
    }

    func platformTerminalWrapperDidAppear() {}

    func platformTerminalWrapperDidDisappear() {}
}
#endif
