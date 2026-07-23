import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private struct NoticeSurfaceModifier: ViewModifier {
    let style: NoticeSurfaceStyle
    let prominence: NoticeSurfaceProminence
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if reduceTransparency {
            content
                .background(opaqueColor, in: shape)
                .overlay(shape.stroke(borderColor, lineWidth: 1))
                .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
        } else if #available(iOS 26, macOS 26, *) {
            nativeGlass(content: content, shape: shape)
                .overlay(shape.stroke(borderColor, lineWidth: 0.75))
                .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
        } else {
            fallbackSurface(content: content, shape: shape)
                .overlay(shape.stroke(borderColor, lineWidth: 1))
                .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
        }
    }

    @available(iOS 26, macOS 26, *)
    @ViewBuilder
    private func nativeGlass(
        content: Content,
        shape: RoundedRectangle
    ) -> some View {
        switch style {
        case .standard:
            if prominence == .emphasized {
                content
                    .glassEffect(.clear.tint(neutralGlassTint), in: shape)
            } else {
                content
                    .glassEffect(.regular, in: shape)
            }
        case .terminal(let backgroundColor, _):
            if prominence == .emphasized {
                content
                    .glassEffect(.clear.tint(neutralGlassTint), in: shape)
            } else {
                content
                    .background(
                        backgroundColor.opacity(terminalBackgroundOpacity),
                        in: shape
                    )
                    .glassEffect(.regular.tint(backgroundColor.opacity(terminalTintOpacity)), in: shape)
            }
        }
    }

    @ViewBuilder
    private func fallbackSurface(
        content: Content,
        shape: RoundedRectangle
    ) -> some View {
        switch style {
        case .standard:
            content.background(.ultraThinMaterial, in: shape)
        case .terminal(let backgroundColor, _):
            content.background(
                backgroundColor.opacity(colorScheme == .dark ? 0.95 : 0.98),
                in: shape
            )
        }
    }

    private var opaqueColor: Color {
        switch style {
        case .standard:
            return platformBaseColor
        case .terminal(let backgroundColor, _):
            return backgroundColor.opacity(colorScheme == .dark ? 0.98 : 1)
        }
    }

    private var borderColor: Color {
        let baseOpacity = colorScheme == .dark ? 0.1 : 0.08
        return colorScheme == .dark
            ? Color.white.opacity(prominence == .emphasized ? 0.16 : baseOpacity)
            : Color.black.opacity(prominence == .emphasized ? 0.12 : baseOpacity)
    }

    private var shadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.36 : 0.16)
    }

    private var terminalBackgroundOpacity: Double {
        switch prominence {
        case .regular:
            return colorScheme == .dark ? 0.66 : 0.76
        case .emphasized:
            return colorScheme == .dark ? 0.8 : 0.88
        }
    }

    private var terminalTintOpacity: Double {
        prominence == .emphasized ? 0.48 : 0.38
    }

    private var neutralGlassTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.14)
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

extension View {
    func noticeSurface(
        style: NoticeSurfaceStyle,
        prominence: NoticeSurfaceProminence = .regular,
        cornerRadius: CGFloat = NoticeMetrics.cornerRadius,
        shadowRadius: CGFloat,
        shadowY: CGFloat
    ) -> some View {
        modifier(
            NoticeSurfaceModifier(
                style: style,
                prominence: prominence,
                cornerRadius: cornerRadius,
                shadowRadius: shadowRadius,
                shadowY: shadowY
            )
        )
    }

    @ViewBuilder
    func noticePrimaryButtonStyle() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func noticeSecondaryButtonStyle() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.buttonStyle(SwiftUI.GlassButtonStyle())
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

enum NoticeSurfaceProminence: Equatable {
    case regular
    case emphasized
}

struct NoticeGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}
