import SwiftUI

enum NoticeSurfaceStyle {
    case standard
    case terminal(backgroundColor: Color, foregroundColor: Color)

    var primaryForegroundColor: Color {
        switch self {
        case .standard:
            return .primary
        case .terminal(_, let foregroundColor):
            return foregroundColor
        }
    }

    var secondaryForegroundColor: Color {
        switch self {
        case .standard:
            return .secondary
        case .terminal:
            return primaryForegroundColor.opacity(0.68)
        }
    }
}

struct NoticeMetrics {
    static let cornerRadius: CGFloat = 16
    static let bannerMaxWidth: CGFloat = 620
    static let operationMaxWidth: CGFloat = 560
    static let blockingMaxWidth: CGFloat = 340
    static let notificationCornerRadius: CGFloat = 30
}

extension NoticeLevel {
    var tintColor: Color {
        switch self {
        case .info:
            return .accentColor
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    var defaultIconSystemName: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }
}
