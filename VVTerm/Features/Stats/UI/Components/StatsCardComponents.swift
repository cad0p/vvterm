import SwiftUI

struct AppleCard<Content: View>: View {
    let style: StatsVisualStyle
    let minHeight: CGFloat?
    let content: () -> Content

    init(
        style: StatsVisualStyle,
        minHeight: CGFloat? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.style = style
        self.minHeight = minHeight
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
            .background(style.cardFill, in: RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous)
                    .stroke(style.cardStroke, lineWidth: 1)
            }
    }
}

struct StatsCustomizeButton: View {
    let style: StatsVisualStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline.weight(.bold))
                Text(String(localized: "Customize"))
                    .font(.subheadline.weight(.bold))

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(StatsCardButtonStyle())
        .accessibilityLabel(Text("Customize Stats"))
    }
}

struct StatsCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct AppleMetricCard<Preview: View>: View {
    let icon: String
    let title: String
    let titleColor: Color
    let trailing: String
    let value: String
    let unit: String
    let footer: String
    let detailItems: [MetricDetailItem]
    let showsChevron: Bool
    let style: StatsVisualStyle
    let preview: () -> Preview

    init(
        icon: String,
        title: String,
        titleColor: Color,
        trailing: String,
        value: String,
        unit: String,
        footer: String,
        detailItems: [MetricDetailItem] = [],
        showsChevron: Bool = false,
        style: StatsVisualStyle,
        @ViewBuilder preview: @escaping () -> Preview
    ) {
        self.icon = icon
        self.title = title
        self.titleColor = titleColor
        self.trailing = trailing
        self.value = value
        self.unit = unit
        self.footer = footer
        self.detailItems = detailItems
        self.showsChevron = showsChevron
        self.style = style
        self.preview = preview
    }

    var body: some View {
        AppleCard(style: style, minHeight: style.metricMinHeight) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.headline.weight(.bold))
                    Text(title)
                        .font(.headline.weight(.bold))

                    Spacer()

                    Text(trailing)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(style.secondaryText)

                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(style.secondaryText)
                    }
                }
                .foregroundStyle(titleColor)

                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(value)
                                .font(.system(size: style.metricValueSize, weight: .bold, design: .rounded))
                                .foregroundStyle(style.primaryText)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)

                            if !unit.isEmpty {
                                Text(unit)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(style.secondaryText)
                                    .lineLimit(1)
                            }
                        }

                        if !footer.isEmpty {
                            Text(footer)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(style.secondaryText)
                                .lineLimit(2)
                                .minimumScaleFactor(0.78)
                        }
                    }

                    Spacer(minLength: 8)

                    preview()
                        .frame(width: style.metricPreviewWidth, height: style.metricPreviewHeight)
                }

                if style.density == .detailed, !detailItems.isEmpty {
                    MetricDetailGrid(items: detailItems, style: style)
                }
            }
            .padding(style.cardPadding)
        }
    }
}

struct MetricDetailItem: Identifiable {
    let title: String
    let value: String
    let color: Color

    var id: String { title }
}

struct MetricDetailGrid: View {
    let items: [MetricDetailItem]
    let style: StatsVisualStyle

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 6, height: 6)
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(style.secondaryText)
                    }

                    Text(item.value)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(style.primaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }
}

struct NetworkValue: View {
    let symbol: String
    let title: String
    let value: String
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(color)

            Text(value)
                .font(.system(size: style.networkValueSize, weight: .bold, design: .rounded))
                .foregroundStyle(style.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.58)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FooterValue: View {
    let title: String
    let value: String
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(style.secondaryText)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(style.primaryText)
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

struct ProcessCardHeader: View {
    let processCount: Int
    let style: StatsVisualStyle
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.headline.weight(.bold))
            Text(String(localized: "Processes"))
                .font(.headline.weight(.bold))

            Spacer()

            if processCount > 0 {
                Text("\(processCount)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(style.secondaryText)
                    .monospacedDigit()
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(style.secondaryText)
            }
        }
        .foregroundStyle(Color.purple)
    }
}

struct CardHeader: View {
    let icon: String
    let title: String
    let titleColor: Color
    let trailing: String
    var showsChevron = false
    let style: StatsVisualStyle

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.headline.weight(.bold))
            Text(title)
                .font(.headline.weight(.bold))

            Spacer()

            if !trailing.isEmpty {
                Text(trailing)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(style.secondaryText)
                    .monospacedDigit()
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(style.secondaryText)
            }
        }
        .foregroundStyle(titleColor)
    }
}

struct VolumeCardRow: View {
    let volume: VolumeInfo
    let style: StatsVisualStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(volume.mountPoint)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Text(formatPercent(volume.percent))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(volumeColor)
                    .monospacedDigit()
            }

            SegmentedCapacityBar(
                segments: [
                    CapacitySegment(value: Double(volume.used), color: volumeColor),
                    CapacitySegment(value: Double(volume.total > volume.used ? volume.total - volume.used : 0), color: style.tertiaryText)
                ],
                total: Double(max(volume.total, 1)),
                style: style
            )

            Text(formatUsedCapacity(volume.used, total: volume.total))
                .font(.caption.weight(.medium))
                .foregroundStyle(style.secondaryText)
                .lineLimit(1)
        }
    }

    private var volumeColor: Color {
        if volume.percent > 90 { return .red }
        if volume.percent > 80 { return .orange }
        return .green
    }
}

struct ProcessCardRow: View {
    let process: ProcessInfo
    let style: StatsVisualStyle

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(process.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(String(format: String(localized: "PID %lld"), Int64(process.pid)))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(style.secondaryText)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            ProcessBadge(
                title: String(localized: "CPU"),
                value: process.cpuPercent,
                color: .pink,
                style: style
            )

            ProcessBadge(
                title: String(localized: "MEM"),
                value: process.memoryPercent,
                color: .blue,
                style: style
            )
        }
    }
}

struct ProcessBadge: View {
    let title: String
    let value: Double
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatPercent(value))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(style.primaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(style.secondaryText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.68)

            MiniMeter(value: min(value / 100, 1), color: color, style: style)
                .frame(width: 54)
        }
        .frame(width: 62, alignment: .trailing)
    }
}

struct EmptyCardState: View {
    let icon: String
    let title: String
    let message: String
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 48, height: 48)
                .background(color.opacity(0.14), in: Circle())

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(style.primaryText)

                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(style.secondaryText)
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, minHeight: 142, maxHeight: .infinity, alignment: .center)
        .padding(.vertical, style.density == .detailed ? 18 : 12)
    }
}
