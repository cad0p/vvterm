import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct NoticeBannerView: View {
    let item: NoticeItem
    var surfaceStyle: NoticeSurfaceStyle = .standard

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            leadingView

            VStack(alignment: .leading, spacing: item.title == nil ? 0 : 2) {
                if let title = item.title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(item.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(item.title == nil ? 2 : 1)
            }

            Spacer(minLength: 8)

            if let action = item.action {
                Button(action.title, role: action.role, action: action.handler)
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
            }

            if let dismissAction = item.dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: NoticeMetrics.bannerMaxWidth, alignment: .leading)
        .background(backgroundShape)
        .overlay(borderShape)
        .shadow(color: shadowColor, radius: 14, x: 0, y: 8)
    }

    @ViewBuilder
    private var leadingView: some View {
        switch resolvedLeading {
        case .none:
            EmptyView()
        case .activity:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(item.level.tintColor)
                .controlSize(.small)
        case .icon(let systemName):
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(item.level.tintColor)
        }
    }

    private var resolvedLeading: NoticeLeading {
        switch item.leading {
        case .none:
            return .icon(item.level.defaultIconSystemName)
        default:
            return item.leading
        }
    }

    @ViewBuilder
    private var backgroundShape: some View {
        let shape = RoundedRectangle(cornerRadius: NoticeMetrics.cornerRadius, style: .continuous)

        switch surfaceStyle {
        case .standard:
            if reduceTransparency {
                shape.fill(platformBaseColor)
            } else {
                shape.fill(.thinMaterial)
            }
        case .terminal(let backgroundColor):
            shape.fill(backgroundColor.opacity(colorScheme == .dark ? 0.95 : 0.98))
        }
    }

    private var borderShape: some View {
        RoundedRectangle(cornerRadius: NoticeMetrics.cornerRadius, style: .continuous)
            .stroke(borderColor, lineWidth: 1)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    private var shadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.38 : 0.16)
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

