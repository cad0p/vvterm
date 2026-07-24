import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct BlockingStatusView<Content: View>: View {
    var maxWidth: CGFloat = NoticeMetrics.blockingMaxWidth
    var showsScrim: Bool = true
    var cornerRadius: CGFloat = NoticeMetrics.cornerRadius
    var surfaceStyle: NoticeSurfaceStyle = .standard
    let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        maxWidth: CGFloat = NoticeMetrics.blockingMaxWidth,
        showsScrim: Bool = true,
        cornerRadius: CGFloat = NoticeMetrics.cornerRadius,
        surfaceStyle: NoticeSurfaceStyle = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.showsScrim = showsScrim
        self.cornerRadius = cornerRadius
        self.surfaceStyle = surfaceStyle
        self.content = content()
    }

    var body: some View {
        ZStack {
            if showsScrim {
                Color.black
                    .opacity(colorScheme == .dark ? 0.32 : 0.22)
                    .ignoresSafeArea()
            }

            content
                .frame(maxWidth: maxWidth)
                .padding(.horizontal, 28)
                .padding(.vertical, contentVerticalPadding)
                .background(cardBackground)
                .overlay(cardBorder)
                .shadow(color: shadowColor, radius: 18, x: 0, y: 10)
                .padding(24)
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        switch surfaceStyle {
        case .standard:
            if reduceTransparency {
                shape.fill(platformBaseColor)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        case .terminal(let backgroundColor):
            shape.fill(backgroundColor.opacity(colorScheme == .dark ? 0.96 : 0.98))
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(borderColor, lineWidth: 1)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    private var shadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.45 : 0.2)
    }

    private var contentVerticalPadding: CGFloat {
        #if os(iOS)
        return 26
        #else
        return 22
        #endif
    }

    private var platformBaseColor: Color {
        #if os(iOS)
        return Color(UIColor.secondarySystemBackground)
        #elseif os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return .black
        #endif
    }
}

