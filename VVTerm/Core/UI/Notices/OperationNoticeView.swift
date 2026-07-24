import SwiftUI

struct OperationNoticeView: View {
    let item: NoticeItem
    var surfaceStyle: NoticeSurfaceStyle = .standard

    var body: some View {
        NoticeGlassGroup(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    leadingView
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 4) {
                        if let title = item.title {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(surfaceStyle.primaryForegroundColor)
                                .lineLimit(1)
                        }

                        Text(item.message)
                            .font(.subheadline)
                            .foregroundStyle(surfaceStyle.secondaryForegroundColor)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    if let dismissAction = item.dismissAction {
                        Button(action: dismissAction) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(surfaceStyle.secondaryForegroundColor)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(surfaceStyle.secondaryForegroundColor)
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
                    .foregroundStyle(surfaceStyle.secondaryForegroundColor)
                    .monospacedDigit()
                }

                if let action = item.action {
                    Button(action.title, role: action.role, action: action.handler)
                        .noticePrimaryButtonStyle()
                }
            }
            .padding(14)
            .frame(maxWidth: NoticeMetrics.operationMaxWidth, alignment: .leading)
            .noticeSurface(
                style: surfaceStyle,
                prominence: .emphasized,
                cornerRadius: NoticeMetrics.notificationCornerRadius,
                shadowRadius: 18,
                shadowY: 10
            )
            .accessibilityIdentifier("vvterm.notice.operation")
        }
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

}
