import SwiftUI

struct AppLockContainer<Content: View>: View {
    @EnvironmentObject private var appLockManager: AppLockManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PrivacyModeSettings.enabledKey) private var privacyModeEnabled = false

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shouldObscureForInactiveScene = scenePhase != .active && (appLockManager.fullAppLockEnabled || privacyModeEnabled)
        let shouldBlockContent = appLockManager.isAppLocked || shouldObscureForInactiveScene

        ZStack {
            content
                .blur(radius: shouldBlockContent ? 6 : 0)
                .allowsHitTesting(!shouldBlockContent)

            if !appLockManager.isAppLocked, shouldObscureForInactiveScene {
                AppPrivacyShieldView()
                    .transition(.opacity)
                    .zIndex(9)
            }

            if appLockManager.isAppLocked {
                AppLockGateView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appLockManager.isAppLocked)
        .animation(.easeInOut(duration: 0.15), value: scenePhase)
        .onAppear {
            appLockManager.handleScenePhaseChange(scenePhase)
            if appLockManager.fullAppLockEnabled {
                Task {
                    _ = await appLockManager.ensureAppUnlocked()
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            appLockManager.handleScenePhaseChange(newPhase)
            if newPhase == .active, appLockManager.fullAppLockEnabled {
                Task {
                    _ = await appLockManager.ensureAppUnlocked()
                }
            }
        }
    }
}

private struct AppPrivacyShieldView: View {
    var body: some View {
        Color.black
            .opacity(0.55)
            .ignoresSafeArea()
    }
}

struct AppLockGateView: View {
    @EnvironmentObject private var appLockManager: AppLockManager

    private var unlockLabel: String {
        String(format: String(localized: "Unlock with %@"), appLockManager.biometryDisplayName)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(String(localized: "VVTerm is locked"))
                    .font(.headline)

                if let message = appLockManager.lastErrorMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task {
                        _ = await appLockManager.ensureAppUnlocked()
                    }
                } label: {
                    if appLockManager.isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(unlockLabel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appLockManager.isAuthenticating)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 20)
        }
    }
}
