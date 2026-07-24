import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct OperationNoticeView: View {
    let item: NoticeItem
    var surfaceStyle: NoticeSurfaceStyle = .standard

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                leadingView
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 4) {
                    if let title = item.title {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Text(item.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if let dismissAction = item.dismissAction {
                    Button(action: dismissAction) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let progress = item.progress,
               let completedUnitCount = progress.completedUnitCount,
               let totalUnitCount = progress.totalUnitCount,
               totalUnitCount > 0 {
                ProgressView(value: Double(completedUnitCount), total: Double(totalUnitCount))
                    .tint(item.level.tintColor)

                Text(
                    String(
                        format: String(localized: "%lld of %lld items"),
                        Int64(completedUnitCount),
                        Int64(totalUnitCount)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            if let action = item.action {
                Button(action.title, role: action.role, action: action.handler)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(maxWidth: NoticeMetrics.operationMaxWidth, alignment: .leading)
        .background(backgroundShape)
        .overlay(borderShape)
        .shadow(color: shadowColor, radius: 18, x: 0, y: 10)
    }

    @ViewBuilder
    private var leadingView: some View {
        switch resolvedLeading {
        case .none:
            EmptyView()
        case .activity:
            ProgressView()
                .controlSize(.small)
        case .icon(let systemName):
            Image(systemName: systemName)
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
                shape.fill(.ultraThinMaterial)
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

