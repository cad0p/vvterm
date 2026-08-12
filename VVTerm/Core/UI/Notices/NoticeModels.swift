import SwiftUI

enum NoticeLane {
    case topBanner
    case bottomOperation
}

enum NoticeLevel {
    case info
    case success
    case warning
    case error
}

enum NoticeLeading {
    case none
    case icon(String)
    case activity
}

enum NoticeLifetime {
    case persistent
    case autoDismiss(Duration)
}

struct NoticeProgress: Equatable {
    var completedUnitCount: Int?
    var totalUnitCount: Int?

    var isDeterminate: Bool {
        guard let totalUnitCount, totalUnitCount > 0 else { return false }
        return completedUnitCount != nil
    }
}

struct NoticeAction: Identifiable {
    let id: String
    let title: String
    let role: ButtonRole?
    let handler: () -> Void

    init(
        id: String,
        title: String,
        role: ButtonRole? = nil,
        handler: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.role = role
        self.handler = handler
    }
}

struct NoticeItem: Identifiable {
    let id: String
    let lane: NoticeLane
    let level: NoticeLevel
    let leading: NoticeLeading
    let title: String?
    let message: String
    let detail: String?
    let progress: NoticeProgress?
    let lifetime: NoticeLifetime
    let action: NoticeAction?
    let dismissAction: (() -> Void)?

    init(
        id: String,
        lane: NoticeLane,
        level: NoticeLevel,
        leading: NoticeLeading = .none,
        title: String? = nil,
        message: String,
        detail: String? = nil,
        progress: NoticeProgress? = nil,
        lifetime: NoticeLifetime = .persistent,
        action: NoticeAction? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        self.id = id
        self.lane = lane
        self.level = level
        self.leading = leading
        self.title = title
        self.message = message
        self.detail = detail
        self.progress = progress
        self.lifetime = lifetime
        self.action = action
        self.dismissAction = dismissAction
    }

    /// Whether the banner carries any interactive element (details, action,
    /// or dismiss). Non-interactive status banners (e.g. "Connecting…") must
    /// not consume touches so scroll gestures pass through to the terminal
    /// underneath — otherwise the first scroll while a status banner is up
    /// silently does nothing.
    var isInteractive: Bool {
        detail != nil || action != nil || dismissAction != nil
    }
}
