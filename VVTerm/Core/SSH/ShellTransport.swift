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
    case invalidEndpoint
    case udpTimeout
    case clientSessionFailed

    var bannerMessage: String {
        switch self {
        case .serverMissing:
            return String(localized: "Using SSH fallback for this session (mosh-server is missing).")
        case .unsupportedRemoteCapabilities:
            return String(localized: "Using SSH fallback for this session (Mosh is not supported by the resolved remote environment).")
        case .bootstrapFailed:
            return String(localized: "Using SSH fallback for this session (mosh-server could not start correctly).")
        case .invalidEndpoint:
            return String(localized: "Using SSH fallback for this session (the Mosh server address was invalid).")
        case .udpTimeout:
            return String(localized: "Using SSH fallback for this session (the Mosh UDP connection timed out; check UDP ports 60001–61000).")
        case .clientSessionFailed:
            return String(localized: "Using SSH fallback for this session (the Mosh client session could not start).")
        case .sessionFailed:
            return String(localized: "Using SSH fallback for this session.")
        }
    }
}

nonisolated enum MoshEndpointCandidatePolicy {
    static func hosts(configuredHost: String, sshPeerHost: String?) -> [String] {
        let configured = configuredHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else { return [] }
        var result = [configured]
        if let peer = sshPeerHost?.trimmingCharacters(in: .whitespacesAndNewlines),
           !peer.isEmpty,
           peer != configured {
            result.append(peer)
        }
        return result
    }
}
