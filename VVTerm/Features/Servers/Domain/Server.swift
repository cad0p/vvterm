import Foundation

// MARK: - Server Model (CloudKit synced)

struct Server: Identifiable, Codable, Hashable {
    let id: UUID
    var workspaceId: UUID
    var environment: ServerEnvironment
    var name: String
    /// The connection target.
    ///
    /// For `.faceIDTeleport` servers, `name` is the Teleport NODE name
    /// (e.g. `pcad-dev`) — the display name doubles as the node name for the
    /// `proxy:<node>:0` subsystem string. `host` is the PROXY host
    /// (e.g. `teleport.pcad.it`). This mirrors `tsh ssh pier@pcad-dev`:
    /// the user names the node, the proxy is separate.
    ///
    /// For all other auth methods, `name` is just the display name and
    /// `host` is the direct SSH target.
    ///
    /// This is a model reinterpretation of `name`/`host` for Teleport rows,
    /// not a schema change to those fields. The only schema addition for
    /// Teleport is the optional `teleportHostLogin` (tsh's "host login"),
    /// which is written by the setup picker and resolved against the current
    /// certificate's principals at connect time. Existing Teleport servers
    /// (whose `host` currently holds the proxy host) require a one-time
    /// migration to
    var host: String
    var port: Int
    /// TCP port exposed by etserver. SSH still uses `port` for bootstrap.
    var eternalTerminalPort: Int
    /// The Teleport user (the SSH identity). For `.faceIDTeleport` this is
    /// the Teleport *user* (`pier`) — it is needed before any cert exists
    /// (headless bootstrap, gRPC registration, `login/begin|finish`), so the
    /// host login (the certificate principal, `deploy`) is a separate field.
    var username: String
    /// The certificate principal to send as the SSH username for a Teleport
    /// connection (tsh's "host login", e.g. `deploy`). Picked once during
    /// setup Phase 3 from the issued certificate's non-internal principals and
    /// frozen per server row. `nil` for non-Teleport rows and for Teleport
    /// rows that have not completed the picker yet (the connect path then
    /// derives only when the cert has exactly one non-internal principal).
    ///
    /// Shape-validated on the persist/decode seam (non-empty, ≤255 bytes, no
    /// control characters); the authoritative check is the connect-time
    /// principal match against the certificate being sent.
    var teleportHostLogin: String?
    var connectionMode: SSHConnectionMode
    var authMethod: AuthMethod
    var cloudflareAccessMode: CloudflareAccessMode?
    var cloudflareTeamDomainOverride: String?
    var cloudflareAppDomainOverride: String?
    var tags: [String]
    var notes: String?
    var lastConnected: Date?
    var isFavorite: Bool
    var requiresBiometricUnlock: Bool
    /// Override for tmux persistence (nil = use global default)
    var tmuxEnabledOverride: Bool?
    /// Override for tmux startup behavior (nil = use global default)
    var tmuxStartupBehaviorOverride: TmuxStartupBehavior?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        workspaceId: UUID,
        environment: ServerEnvironment = .production,
        name: String,
        host: String,
        port: Int = 22,
        eternalTerminalPort: Int = 2022,
        username: String,
        teleportHostLogin: String? = nil,
        connectionMode: SSHConnectionMode = .standard,
        authMethod: AuthMethod = .password,
        cloudflareAccessMode: CloudflareAccessMode? = nil,
        cloudflareTeamDomainOverride: String? = nil,
        cloudflareAppDomainOverride: String? = nil,
        tags: [String] = [],
        notes: String? = nil,
        lastConnected: Date? = nil,
        isFavorite: Bool = false,
        requiresBiometricUnlock: Bool = false,
        tmuxEnabledOverride: Bool? = nil,
        tmuxStartupBehaviorOverride: TmuxStartupBehavior? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.environment = environment
        self.name = name
        self.host = host
        self.port = port
        self.eternalTerminalPort = (1...65535).contains(eternalTerminalPort)
            ? eternalTerminalPort
            : 2022
        self.username = username
        self.teleportHostLogin = Server.normalizedTeleportHostLogin(teleportHostLogin)
        self.connectionMode = connectionMode
        self.authMethod = authMethod
        self.cloudflareAccessMode = cloudflareAccessMode
        self.cloudflareTeamDomainOverride = cloudflareTeamDomainOverride
        self.cloudflareAppDomainOverride = cloudflareAppDomainOverride
        self.tags = tags
        self.notes = notes
        self.lastConnected = lastConnected
        self.isFavorite = isFavorite
        self.requiresBiometricUnlock = requiresBiometricUnlock
        self.tmuxEnabledOverride = tmuxEnabledOverride
        self.tmuxStartupBehaviorOverride = tmuxStartupBehaviorOverride
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayAddress: String {
        if port == 22 {
            return "\(username)@\(host)"
        }
        return "\(username)@\(host):\(port)"
    }

    /// The maximum UTF-8 byte length accepted for `teleportHostLogin`.
    static let maxTeleportHostLoginBytes = 255

    /// Shape-validates a Teleport host login for the persist/decode seam.
    ///
    /// Persist/decode can only check the shape — the authoritative check is
    /// the connect-time principal match against the certificate being sent,
    /// which a decode cannot perform. Returns `nil` for a value that is empty
    /// (or whitespace-only), longer than 255 UTF-8 bytes, or contains a
    /// control character. `@` is explicitly allowed (Teleport logins may
    /// contain it).
    static func normalizedTeleportHostLogin(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count <= maxTeleportHostLoginBytes else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceId
        case environment
        case name
        case host
        case port
        case eternalTerminalPort
        case username
        case teleportHostLogin
        case connectionMode
        case authMethod
        case cloudflareAccessMode
        case cloudflareTeamDomainOverride
        case cloudflareAppDomainOverride
        case tags
        case notes
        case lastConnected
        case isFavorite
        case requiresBiometricUnlock
        case tmuxEnabledOverride
        case tmuxStartupBehaviorOverride
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        workspaceId = try container.decode(UUID.self, forKey: .workspaceId)
        environment = try container.decodeIfPresent(ServerEnvironment.self, forKey: .environment) ?? .production
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        let decodedETPort = try container.decodeIfPresent(Int.self, forKey: .eternalTerminalPort) ?? 2022
        eternalTerminalPort = (1...65535).contains(decodedETPort) ? decodedETPort : 2022
        username = try container.decode(String.self, forKey: .username)
        teleportHostLogin = Server.normalizedTeleportHostLogin(
            try container.decodeIfPresent(String.self, forKey: .teleportHostLogin)
        )
        connectionMode = try container.decodeIfPresent(SSHConnectionMode.self, forKey: .connectionMode) ?? .standard
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password
        if let rawCloudflareMode = try container.decodeIfPresent(String.self, forKey: .cloudflareAccessMode) {
            cloudflareAccessMode = CloudflareAccessMode(rawValue: rawCloudflareMode)
        } else {
            cloudflareAccessMode = nil
        }
        cloudflareTeamDomainOverride = try container.decodeIfPresent(String.self, forKey: .cloudflareTeamDomainOverride)
        cloudflareAppDomainOverride = try container.decodeIfPresent(String.self, forKey: .cloudflareAppDomainOverride)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        requiresBiometricUnlock = try container.decodeIfPresent(Bool.self, forKey: .requiresBiometricUnlock) ?? false
        tmuxEnabledOverride = try container.decodeIfPresent(Bool.self, forKey: .tmuxEnabledOverride)
        if let raw = try container.decodeIfPresent(String.self, forKey: .tmuxStartupBehaviorOverride) {
            tmuxStartupBehaviorOverride = TmuxStartupBehavior(rawValue: raw)
        } else {
            tmuxStartupBehaviorOverride = nil
        }
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(workspaceId, forKey: .workspaceId)
        try container.encode(environment, forKey: .environment)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(eternalTerminalPort, forKey: .eternalTerminalPort)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(teleportHostLogin, forKey: .teleportHostLogin)
        try container.encode(connectionMode, forKey: .connectionMode)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encodeIfPresent(cloudflareAccessMode, forKey: .cloudflareAccessMode)
        try container.encodeIfPresent(cloudflareTeamDomainOverride, forKey: .cloudflareTeamDomainOverride)
        try container.encodeIfPresent(cloudflareAppDomainOverride, forKey: .cloudflareAppDomainOverride)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(lastConnected, forKey: .lastConnected)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(requiresBiometricUnlock, forKey: .requiresBiometricUnlock)
        try container.encodeIfPresent(tmuxEnabledOverride, forKey: .tmuxEnabledOverride)
        try container.encodeIfPresent(tmuxStartupBehaviorOverride, forKey: .tmuxStartupBehaviorOverride)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

enum SSHConnectionMode: String, Codable, CaseIterable, Identifiable {
    case standard
    case tailscale
    case mosh
    case eternalTerminal
    case cloudflare

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? Self.standard.rawValue
        self = Self(rawValue: rawValue) ?? .standard
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum CloudflareAccessMode: String, Codable, CaseIterable, Identifiable {
    case oauth
    case serviceToken

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oauth:
            return String(localized: "OAuth")
        case .serviceToken:
            return String(localized: "Service Token")
        }
    }
}

// MARK: - Authentication Method

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case sshKey
    case sshKeyWithPassphrase
    case faceIDTeleport

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        // Fall back to .password for unknown raw values so old clients that
        // encounter a future auth method (added after this build was compiled)
        // don't crash — they decode to the safe default instead.
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AuthMethod(rawValue: raw) ?? .password
    }

    var displayName: String {
        switch self {
        case .password: return String(localized: "Password")
        case .sshKey: return String(localized: "SSH Key")
        case .sshKeyWithPassphrase: return String(localized: "SSH Key + Passphrase")
        case .faceIDTeleport: return String(localized: "Face ID (Teleport)")
        }
    }

    var icon: String {
        switch self {
        case .password: return "key.fill"
        case .sshKey: return "lock.doc.fill"
        case .sshKeyWithPassphrase: return "lock.shield.fill"
        case .faceIDTeleport: return "faceid"
        }
    }
}

// MARK: - Server Credentials (for authentication)

struct ServerCredentials: Sendable {
    let serverId: UUID
    var password: String?
    var privateKey: Data?
    var publicKey: Data?
    var passphrase: String?
    var cloudflareClientID: String?
    var cloudflareClientSecret: String?

    var sshKey: Data? {
        get { privateKey }
        set { privateKey = newValue }
    }

    var sshPassphrase: String? {
        get { passphrase }
        set { passphrase = newValue }
    }
}

// MARK: - Stored SSH Key Entry (reusable keys in Keychain)

struct SSHKeyEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var hasPassphrase: Bool
    var createdAt: Date
    var keyType: SSHKeyType?
    var publicKey: String?

    init(
        id: UUID = UUID(),
        name: String,
        hasPassphrase: Bool = false,
        createdAt: Date = Date(),
        keyType: SSHKeyType? = nil,
        publicKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hasPassphrase = hasPassphrase
        self.createdAt = createdAt
        self.keyType = keyType
        self.publicKey = publicKey
    }
}
