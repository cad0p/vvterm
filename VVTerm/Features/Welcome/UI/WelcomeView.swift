//
//  WelcomeView.swift
//  VVTerm
//

import SwiftUI

struct WelcomeView: View {
    @Binding var hasSeenWelcome: Bool

    var body: some View {
        #if os(iOS)
        iOSWelcomeContent(hasSeenWelcome: $hasSeenWelcome)
        #else
        macOSWelcomeContent(hasSeenWelcome: $hasSeenWelcome)
        #endif
    }
}

// MARK: - iOS Welcome

#if os(iOS)
private struct iOSWelcomeContent: View {
    @Binding var hasSeenWelcome: Bool
    @State private var showingProUpgrade = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: 24)

                    // App Icon (load 1024px version for best quality)
                    if let iconImage = UIImage(named: "icon-ios-1024") {
                        Image(uiImage: iconImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 108, height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    }

                    // Header
                    Text("Welcome to VVTerm")
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.top, 18)
                        .multilineTextAlignment(.center)

                    Text("Your secure SSH terminal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 24)

                    // Features
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(WelcomeFeatureCatalog.features) { feature in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: feature.icon)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(width: 46, height: 46)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(feature.color)
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(feature.title)
                                        .font(.headline)

                                    Text(feature.description)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
            }

            // Continue button
            VStack(spacing: 14) {
                Button {
                    hasSeenWelcome = true
                    AnalyticsTracker.shared.trackWelcomeCompleted()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.accentColor)
                        )
                }

                Button {
                    showingProUpgrade = true
                } label: {
                    Text("Explore Pro")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 8)
            .proUpgradePresentation(isPresented: $showingProUpgrade, source: .welcome)
        }
    }
}
#endif

// MARK: - macOS Welcome

#if os(macOS)
private struct macOSWelcomeContent: View {
    @Binding var hasSeenWelcome: Bool
    @State private var showingProUpgrade = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: 32)

                    // App Icon (load 512@2x for best quality)
                    if let iconImage = NSImage(named: "icon-mac-512@2x") {
                        Image(nsImage: iconImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 96, height: 96)
                    } else {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 96, height: 96)
                    }

                    // Header
                    Text("Welcome to VVTerm")
                        .font(.system(size: 28, weight: .bold))
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    Text("Your secure SSH terminal")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 24)

                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(WelcomeFeatureCatalog.features) { feature in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: feature.icon)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(feature.color)
                                    )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title)
                                        .font(.system(size: 13, weight: .semibold))

                                    Text(feature.description)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 48)
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
            }

            // Continue button
            VStack(spacing: 12) {
                Button {
                    hasSeenWelcome = true
                    AnalyticsTracker.shared.trackWelcomeCompleted()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: 420)
                        .frame(height: 32)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShapeCompat()
                .tint(Color(red: 1.0, green: 0.27, blue: 0.35))
                .controlSize(.large)

                Button {
                    showingProUpgrade = true
                } label: {
                    Text("Explore Pro")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 28)
            .proUpgradePresentation(isPresented: $showingProUpgrade, source: .welcome)
        }
        .frame(minWidth: 520, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif

#Preview {
    WelcomeView(hasSeenWelcome: .constant(false))
}

private extension View {
    @ViewBuilder
    func buttonBorderShapeCompat() -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            buttonBorderShape(.capsule)
        } else {
            self
        }
    }
}
