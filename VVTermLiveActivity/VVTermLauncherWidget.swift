#if os(iOS)
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct VVTermLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: VVTermWidgetKind.launcher, provider: VVTermLauncherProvider()) { _ in
            VVTermLauncherWidgetView()
        }
        .configurationDisplayName(String(localized: "Open VVTerm"))
        .description(String(localized: "Open VVTerm from the Lock Screen."))
        .supportedFamilies([.accessoryCircular])
    }
}

@available(iOS 16.1, *)
private struct VVTermLauncherEntry: TimelineEntry {
    let date: Date
}

@available(iOS 16.1, *)
private struct VVTermLauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> VVTermLauncherEntry {
        VVTermLauncherEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (VVTermLauncherEntry) -> Void
    ) {
        completion(VVTermLauncherEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<VVTermLauncherEntry>) -> Void
    ) {
        completion(Timeline(entries: [VVTermLauncherEntry(date: Date())], policy: .never))
    }
}

@available(iOS 16.1, *)
private struct VVTermLauncherWidgetView: View {
    @ViewBuilder
    var body: some View {
        if #available(iOS 17.0, *) {
            launcherGlyph
                .containerBackground(for: .widget) {
                    AccessoryWidgetBackground()
                }
        } else {
            ZStack {
                AccessoryWidgetBackground()
                launcherGlyph
            }
        }
    }

    private var launcherGlyph: some View {
        Text(">_")
            .font(.system(size: 18, weight: .bold, design: .monospaced))
            .widgetAccentable()
            .accessibilityLabel(Text("Open VVTerm"))
    }
}
#endif
