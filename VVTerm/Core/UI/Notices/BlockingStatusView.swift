import SwiftUI

struct BlockingStatusView<Content: View>: View {
    var maxWidth: CGFloat = NoticeMetrics.blockingMaxWidth
    var showsScrim: Bool = true
    var cornerRadius: CGFloat = NoticeMetrics.cornerRadius
    var surfaceStyle: NoticeSurfaceStyle = .standard
    let content: Content

    @Environment(\.colorScheme) private var colorScheme
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

            NoticeGlassGroup(spacing: 12) {
                content
                    .foregroundStyle(surfaceStyle.primaryForegroundColor)
                    .frame(maxWidth: maxWidth)
                    .padding(.horizontal, 28)
                    .padding(.vertical, contentVerticalPadding)
                    .noticeSurface(
                        style: surfaceStyle,
                        cornerRadius: cornerRadius,
                        shadowRadius: 18,
                        shadowY: 10
                    )
                    .padding(24)
            }
        }
    }

    private var contentVerticalPadding: CGFloat {
        #if os(iOS)
        return 26
        #else
        return 22
        #endif
    }
}
