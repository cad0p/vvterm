import Foundation

enum ShellTransport: String, Codable, Hashable, Sendable {
    case ssh
    case mosh
    case sshFallback
}

enum MoshFallbackReason: String, Codable, Hashable, Sendable {
    case serverMissing
    case bootstrapFailed
    case sessionFailed
    case unsupportedRemoteCapabilities

    var bannerMessage: String {
        switch self {
        case .serverMissing:
            return String(localized: "Using SSH fallback for this session (mosh-server is missing).")
        case .unsupportedRemoteCapabilities:
            return String(localized: "Using SSH fallback for this session (Mosh is not supported by the resolved remote environment).")
        case .bootstrapFailed, .sessionFailed:
            return String(localized: "Using SSH fallback for this session.")
        }
    }
}
