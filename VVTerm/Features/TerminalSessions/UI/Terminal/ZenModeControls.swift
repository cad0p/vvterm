import SwiftUI

struct ZenModeFloatingOverlay<Panel: View>: View {
    @Binding var isPanelPresented: Bool
    let panel: (CGFloat) -> Panel

    #if os(macOS)
    private let chromeTopPadding: CGFloat = 6
    private let chromeTrailingPadding: CGFloat = 8
    #else
    private let chromeTopPadding: CGFloat = 12
    private let chromeTrailingPadding: CGFloat = 12
    #endif

    init(
        isPanelPresented: Binding<Bool>,
        indicatorColor: Color? = nil,
        @ViewBuilder panel: @escaping (CGFloat) -> Panel
    ) {
        self._isPanelPresented = isPanelPresented
        self.panel = panel
    }

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = max(250, min(proxy.size.width - 24, 360))

            ZStack(alignment: .topTrailing) {
                if isPanelPresented {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            closePanel()
                        }
                        .transition(.opacity)
                }

                chromeStack(panelWidth: panelWidth)
                    .padding(.top, chromeTopPadding)
                    .padding(.trailing, chromeTrailingPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    @ViewBuilder
    private func chromeStack(panelWidth: CGFloat) -> some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: 12) {
                overlayContent(panelWidth: panelWidth)
            }
        } else {
            overlayContent(panelWidth: panelWidth)
        }
    }

    private func overlayContent(panelWidth: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            launcherButton

            if isPanelPresented {
                panel(panelWidth)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var launcherButton: some View {
        Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                isPanelPresented.toggle()
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(.primary)
                .zenModeLauncherGlass()
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Zen controls"))
        .accessibilityValue(isPanelPresented ? String(localized: "Expanded") : String(localized: "Collapsed"))
    }

    private func closePanel() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isPanelPresented = false
        }
    }
}

private extension View {
    @ViewBuilder
    func zenModeLauncherGlass() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }
}

struct ZenModePanelCard<Content: View>: View {
    let width: CGFloat
    let backgroundColor: Color?
    let content: Content
    private let cornerRadius: CGFloat = 22

    init(width: CGFloat, backgroundColor: Color? = nil, @ViewBuilder content: () -> Content) {
        self.width = width
        self.backgroundColor = backgroundColor
        self.content = content()
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(width: width)
        .frame(maxHeight: 430)
        .background(panelBackground(for: cardShape))
        .clipShape(cardShape)
        .overlay(
            cardShape
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 14, y: 10)
    }

    @ViewBuilder
    private func panelBackground(for shape: RoundedRectangle) -> some View {
        if let backgroundColor {
            shape
                .fill(backgroundColor)
                .overlay(
                    shape.fill(Color.white.opacity(0.02))
                )
        } else {
            shape
                .fill(.ultraThinMaterial)
        }
    }
}

struct ZenModeSection<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(sectionHeaderColor)
                .textCase(.uppercase)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionHeaderColor: Color {
        #if os(iOS)
        Color.primary.opacity(0.78)
        #else
        Color.secondary
        #endif
    }
}

struct ZenModeChoiceChip: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(foregroundColor)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(backgroundOpacity))
                )
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        if isSelected {
            return .primary
        }

        #if os(iOS)
        return Color.primary.opacity(0.8)
        #else
        return Color.primary.opacity(0.72)
        #endif
    }

    private var backgroundOpacity: Double {
        if isSelected {
            return 0.16
        }

        #if os(iOS)
        return 0.1
        #else
        return 0.08
        #endif
    }
}

struct ZenModeActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = .primary
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .foregroundStyle(isDisabled ? Color.secondary : tint)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

struct ZenModeStatusLine: View {
    let title: String
    let subtitle: String
    let indicatorColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.headline)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(subtitleColor)
        }
    }

    private var subtitleColor: Color {
        #if os(iOS)
        Color.primary.opacity(0.72)
        #else
        .secondary
        #endif
    }
}


extension ConnectionState {
    var statusTintColor: Color {
        switch self {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected, .idle:
            return .secondary
        case .failed:
            return .red
        }
    }
}
