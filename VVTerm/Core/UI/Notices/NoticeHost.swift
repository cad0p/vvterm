import SwiftUI
import Combine

enum NoticeTopInsetBehavior {
    case contentTop
    case safeAreaTop
}

@MainActor
final class NoticeHostModel: ObservableObject {
    @Published var topBanner: NoticeItem?
    @Published var bottomOperation: NoticeItem?

    private var dismissalTasks: [NoticeLane: Task<Void, Never>] = [:]

    func show(_ item: NoticeItem) {
        set(item, for: item.lane)
    }

    func set(_ item: NoticeItem?, for lane: NoticeLane) {
        dismissalTasks[lane]?.cancel()

        switch lane {
        case .topBanner:
            topBanner = item
        case .bottomOperation:
            bottomOperation = item
        }

        guard let item else { return }

        if case .autoDismiss(let duration) = item.lifetime {
            dismissalTasks[lane] = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.dismiss(id: item.id)
                }
            }
        }
    }

    func update(
        id: String,
        title: String? = nil,
        message: String? = nil,
        detail: String? = nil,
        progress: NoticeProgress? = nil,
        level: NoticeLevel? = nil,
        leading: NoticeLeading? = nil,
        lifetime: NoticeLifetime? = nil,
        action: NoticeAction? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        if var item = topBanner, item.id == id {
            item = NoticeItem(
                id: item.id,
                lane: item.lane,
                level: level ?? item.level,
                leading: leading ?? item.leading,
                title: title ?? item.title,
                message: message ?? item.message,
                detail: detail ?? item.detail,
                progress: progress ?? item.progress,
                lifetime: lifetime ?? item.lifetime,
                action: action ?? item.action,
                dismissAction: dismissAction ?? item.dismissAction
            )
            set(item, for: .topBanner)
            return
        }

        if var item = bottomOperation, item.id == id {
            item = NoticeItem(
                id: item.id,
                lane: item.lane,
                level: level ?? item.level,
                leading: leading ?? item.leading,
                title: title ?? item.title,
                message: message ?? item.message,
                detail: detail ?? item.detail,
                progress: progress ?? item.progress,
                lifetime: lifetime ?? item.lifetime,
                action: action ?? item.action,
                dismissAction: dismissAction ?? item.dismissAction
            )
            set(item, for: .bottomOperation)
        }
    }

    func dismiss(id: String) {
        if topBanner?.id == id {
            set(nil, for: .topBanner)
        } else if bottomOperation?.id == id {
            set(nil, for: .bottomOperation)
        }
    }
}

struct NoticeHost<Content: View>: View {
    let topBanner: NoticeItem?
    let bottomOperation: NoticeItem?
    var topInsetBehavior: NoticeTopInsetBehavior = .contentTop
    var bannerSurfaceStyle: NoticeSurfaceStyle = .standard
    var operationSurfaceStyle: NoticeSurfaceStyle = .standard
    let content: Content

    init(
        topBanner: NoticeItem? = nil,
        bottomOperation: NoticeItem? = nil,
        topInsetBehavior: NoticeTopInsetBehavior = .contentTop,
        bannerSurfaceStyle: NoticeSurfaceStyle = .standard,
        operationSurfaceStyle: NoticeSurfaceStyle = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.topBanner = topBanner
        self.bottomOperation = bottomOperation
        self.topInsetBehavior = topInsetBehavior
        self.bannerSurfaceStyle = bannerSurfaceStyle
        self.operationSurfaceStyle = operationSurfaceStyle
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                GeometryReader { proxy in
                    ZStack {
                        VStack(spacing: 0) {
                            if let topBanner {
                                NoticeBannerView(item: topBanner, surfaceStyle: bannerSurfaceStyle)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, topHorizontalPadding)
                                    .padding(.top, topPadding(for: proxy.safeAreaInsets))
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                    .allowsHitTesting(true)
                            }

                            Spacer(minLength: 0)
                        }

                        VStack(spacing: 0) {
                            Spacer(minLength: 0)

                            if let bottomOperation {
                                OperationNoticeView(item: bottomOperation, surfaceStyle: operationSurfaceStyle)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, bottomHorizontalPadding)
                                    .padding(.bottom, proxy.safeAreaInsets.bottom + bottomVerticalPadding)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                    .allowsHitTesting(true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: topBanner?.id)
            .animation(.easeInOut(duration: 0.2), value: bottomOperation?.id)
    }

    private var topHorizontalPadding: CGFloat {
        #if os(iOS)
        return 12
        #else
        return 24
        #endif
    }

    private var topVerticalPadding: CGFloat {
        #if os(iOS)
        return 8
        #else
        return 10
        #endif
    }

    private func topPadding(for safeAreaInsets: EdgeInsets) -> CGFloat {
        switch topInsetBehavior {
        case .contentTop:
            return topVerticalPadding
        case .safeAreaTop:
            return safeAreaInsets.top + topVerticalPadding
        }
    }

    private var bottomHorizontalPadding: CGFloat {
        #if os(iOS)
        return 12
        #else
        return 20
        #endif
    }

    private var bottomVerticalPadding: CGFloat {
        #if os(iOS)
        return 10
        #else
        return 16
        #endif
    }
}
