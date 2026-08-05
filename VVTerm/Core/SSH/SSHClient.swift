import Foundation
import os.log
import Darwin
import MoshCore
import MoshBootstrap

// MARK: - libssh2 Runtime

/// libssh2 has process-global lifecycle (`libssh2_init`/`libssh2_exit`).
/// Initialize once and keep alive for the app lifetime to avoid tearing down
/// the library while other SSH sessions are still active.
enum LibSSH2Runtime {
    private static let lock = NSLock()
    private static var initialized = false

    static func ensureInitialized() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !initialized else { return }
        let rc = libssh2_init(0)
        guard rc == 0 else {
            throw SSHError.unknown("libssh2_init failed: \(rc)")
        }
        initialized = true
    }

    nonisolated static func supports(requiredVersion: Int32) -> Bool {
        libssh2_version(requiredVersion) != nil
    }
}

// MARK: - libssh2 method preferences

/// libssh2 KEX + hostkey algorithm preference strings.
///
/// Teleport's TLS-routing proxy (like OpenSSH 8.8+) disables `ssh-rsa`
/// (SHA-1) hostkey signatures by default. libssh2 1.11.1 with the OpenSSL
/// backend supports `curve25519-sha256`, ECDH, and `rsa-sha2-256/512`, so we
/// offer modern algorithms first and keep `ssh-rsa` last as a fallback. This
/// avoids `LIBSSH2_ERROR_KEX_FAILURE` (-5) when the peer rejects the legacy
/// hostkey type.
///
/// These constants are pure data so they can be unit-tested without a live
/// libssh2 session; `SSHClient.connect` passes them to
/// `libssh2_session_method_pref` before `libssh2_session_handshake`.
enum SSHMethodPreferences {
    /// KEX algorithms preferred for every SSH connection. Ordered so the
    /// fastest, most modern algorithms negotiate first.
    static let kex =
        "curve25519-sha256,curve25519-sha256@libssh.org," +
        "ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521," +
        "diffie-hellman-group-exchange-sha256"

    /// Hostkey algorithms preferred for every SSH connection.
    ///
    /// Certificate variants (`*-cert-v01@openssh.com`) MUST be listed because
    /// Teleport's proxy structurally refuses plain hostkeys — it advertises
    /// only a certificate hostkey algorithm (e.g. `ecdsa-sha2-nistp256-cert-v01@openssh.com`
    /// for the FIPS suite, `ssh-ed25519-cert-v01@openssh.com` for balanced/hsm,
    /// `ssh-rsa-cert-v01@openssh.com` for legacy). Without a cert variant in
    /// our offer, KEX fails with `LIBSSH2_ERROR_KEX_FAILURE` (-5). libssh2
    /// 1.11.1 (OpenSSL backend) supports all of these. `ssh-rsa` (SHA-1) is
    /// intentionally last so Teleport/OpenSSH 8.8+ peers that disable it still
    /// negotiate a SHA-2 or Ed25519 hostkey.
    static let hostkey =
        "ssh-ed25519,ssh-ed25519-cert-v01@openssh.com," +
        "rsa-sha2-512,rsa-sha2-256," +
        "rsa-sha2-512-cert-v01@openssh.com,rsa-sha2-256-cert-v01@openssh.com,ssh-rsa-cert-v01@openssh.com," +
        "ecdsa-sha2-nistp521,ecdsa-sha2-nistp384,ecdsa-sha2-nistp256," +
        "ecdsa-sha2-nistp521-cert-v01@openssh.com,ecdsa-sha2-nistp384-cert-v01@openssh.com,ecdsa-sha2-nistp256-cert-v01@openssh.com," +
        "ssh-rsa"
}

// MARK: - SSH Client using libssh2

nonisolated struct ShellHandle: Sendable {
    let id: UUID
    let stream: AsyncStream<Data>
    let transport: ShellTransport
    let fallbackReason: MoshFallbackReason?
    let fallbackDiagnostics: MoshFallbackDiagnostics?
    let origin: ShellStartOrigin

    init(
        id: UUID,
        stream: AsyncStream<Data>,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        fallbackDiagnostics: MoshFallbackDiagnostics? = nil,
        origin: ShellStartOrigin = .fresh
    ) {
        self.id = id
        self.stream = stream
        self.transport = transport
        self.fallbackReason = fallbackReason
        self.fallbackDiagnostics = fallbackDiagnostics
        self.origin = origin
    }
}

nonisolated enum ShellStartOrigin: Equatable, Sendable {
    case fresh
    case restored
}

enum SSHUploadStrategy: Sendable {
    case automatic
    case execPreferred
}

actor SSHClient {
    private struct DisconnectOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct MoshShellRuntime {
        let session: MoshClientSession
    }

    private struct PreparedMoshShell: Sendable {
        let session: MoshClientSession
        let pendingOps: [MoshHostOp]
        let hostOpStream: AsyncStream<MoshHostOp>
    }

    private struct PreparedMoshBootstrap: Sendable {
        let shell: PreparedMoshShell
        let leaseID: UUID
        let lease: RemoteMoshServerLease
    }

    private var session: SSHSession?
    private let logger = Logger.forCategory("SSH")
    private var keepAliveTask: Task<Void, Never>?
    private var connectTask: Task<SSHSession, Error>?
    private var pendingConnectSession: SSHSession?
    private var connectionKey: String?
    private var connectedServer: Server?
    private var resolvedRemoteEnvironment: RemoteEnvironment?
    private var resolvedRemoteTerminalType: RemoteTerminalType?
    private var startupTrace: SSHStartupTrace?
    private var moshShells: [UUID: MoshShellRuntime] = [:]
    private var pendingMoshServerLeases: [UUID: RemoteMoshServerLease] = [:]
    private var disconnectOperation: DisconnectOperation?
    private let cloudflareTransportManager = CloudflareTransportManager()
    private let moshStartupTimeout: Duration = .seconds(8)
    private let connectTimeout: Duration = .seconds(30)
    private let disconnectTimeout: Duration = .seconds(4)
    private let execTimeout: Duration = .seconds(20)
    private let downloadTimeout: Duration = .seconds(120)
    private let uploadTimeout: Duration = .seconds(60)

    /// Prevents new client operations after disconnect begins.
    private var _isAborted = false

    /// Check if the client has been aborted
    var isAborted: Bool {
        _isAborted
    }

    // MARK: - Connection

    func connect(to server: Server, credentials: ServerCredentials) async throws -> SSHSession {
        while let disconnectOperation {
            await disconnectOperation.task.value
        }
        _isAborted = false
        try Task.checkCancellation()

        let key = "\(server.host):\(server.port):\(server.username):\(server.connectionMode):\(server.authMethod):\(server.cloudflareAccessMode?.rawValue ?? "none"):\(server.cloudflareTeamDomainOverride ?? "")"

        if let session = session, await session.isConnected, connectionKey == key {
            connectedServer = server
            return session
        }

        if let task = connectTask, connectionKey == key {
            let connected = try await task.value
            connectedServer = server
            return connected
        }

        if let session = session, await session.isConnected, connectionKey != key {
            throw SSHError.connectionFailed("SSH client already connected")
        }

        logger.info(
            "Connecting to \(server.host, privacy: .private(mask: .hash)):\(server.port) [mode: \(server.connectionMode.rawValue, privacy: .public)]"
        )
        logger.info("Auth method: \(String(describing: server.authMethod)), password present: \(credentials.password != nil)")
        let startupTrace = SSHStartupTrace(logger: logger)
        self.startupTrace = startupTrace
        let transportToken = startupTrace.begin(.transportPreparation)

        var dialHost = server.host
        var dialPort = server.port

        if server.connectionMode == .cloudflare {
            let localPort = try await cloudflareTransportManager.connect(server: server, credentials: credentials)
            dialHost = "127.0.0.1"
            dialPort = Int(localPort)
            logger.info("Using Cloudflare local tunnel endpoint \(dialHost):\(dialPort)")
        } else {
            await disconnectCloudflareTransport(reason: "pre-connect cleanup")
        }
        startupTrace.end(transportToken, detail: server.connectionMode.rawValue)

        let config = SSHSessionConfig(
            host: server.host,
            port: server.port,
            dialHost: dialHost,
            dialPort: dialPort,
            hostKeyHost: server.host,
            hostKeyPort: server.port,
            username: server.username,
            connectionMode: server.connectionMode,
            authMethod: server.authMethod,
            credentials: credentials,
            teleportNodeName: server.name
        )

        let pendingSession = SSHSession(config: config, startupTrace: startupTrace)
        pendingConnectSession = pendingSession

        let task = Task { [connectTimeout] () -> SSHSession in
            try Task.checkCancellation()
            do {
                try await SSHClient.runWithTimeout(connectTimeout) {
                    try await pendingSession.connect()
                }
                try Task.checkCancellation()
                return pendingSession
            } catch {
                pendingSession.abort()
                await pendingSession.disconnect()
                throw error
            }
        }

        connectTask = task
        connectionKey = key

        do {
            let session = try await task.value
            pendingConnectSession = nil
            if _isAborted || Task.isCancelled || task.isCancelled {
                session.abort()
                await session.disconnect()
                connectTask = nil
                connectionKey = nil
                self.session = nil
                self.connectedServer = nil
                await disconnectCloudflareTransport(reason: "connect cancellation")
                throw CancellationError()
            }
            self.session = session
            self.connectedServer = server
            self.resolvedRemoteEnvironment = nil
            self.resolvedRemoteTerminalType = nil
            startKeepAlive()
            connectTask = nil
            logger.info("Connected to \(server.host, privacy: .private(mask: .hash))")
            return session
        } catch {
            pendingConnectSession = nil
            connectTask = nil
            connectionKey = nil
            self.session = nil
            self.connectedServer = nil
            self.resolvedRemoteEnvironment = nil
            self.resolvedRemoteTerminalType = nil
            self.startupTrace = nil
            await disconnectCloudflareTransport(reason: "connect failure")
            if server.connectionMode == .cloudflare,
               case SSHError.connectionFailed(let message) = error,
               message.contains("SSH handshake failed: -13") {
                throw SSHError.cloudflareTunnelFailed(
                    String(
                        localized: "Cloudflare tunnel connected, but SSH handshake was closed by the upstream target. Verify Access policy and service token scope."
                    )
                )
            }
            throw error
        }
    }

    func disconnect() async {
        if let disconnectOperation {
            await disconnectOperation.task.value
            return
        }

        _isAborted = true

        let pendingMoshServerLeases = Array(self.pendingMoshServerLeases.values)
        self.pendingMoshServerLeases.removeAll()
        let activeMoshShells = Array(moshShells.values)
        moshShells.removeAll()

        keepAliveTask?.cancel()
        keepAliveTask = nil
        connectTask?.cancel()
        connectTask = nil
        pendingConnectSession?.abort()
        pendingConnectSession = nil
        connectionKey = nil

        let activeSession = session
        session = nil
        connectedServer = nil
        resolvedRemoteEnvironment = nil
        resolvedRemoteTerminalType = nil
        startupTrace = nil

        let operationID = UUID()
        let disconnectTimeout = self.disconnectTimeout
        let cloudflareTransportManager = self.cloudflareTransportManager
        let logger = self.logger
        let task = Task {
            let cleanupFinished = await SSHClient.cleanupPendingMoshServerLeases(
                pendingMoshServerLeases
            )
            if !cleanupFinished {
                logger.warning(
                    "Pending remote mosh-server cleanup exceeded the disconnect coordination window"
                )
            }

            for runtime in activeMoshShells {
                await runtime.session.stop()
            }

            await SSHClient.disconnectSSHSession(
                activeSession,
                timeout: disconnectTimeout,
                logger: logger
            )
            await SSHClient.disconnectCloudflareTransport(
                cloudflareTransportManager,
                reason: "client disconnect",
                timeout: disconnectTimeout,
                logger: logger
            )
            self.finishDisconnect(operationID: operationID)
            logger.diagInfo("SSHSession", "Disconnected (graceful)")
        }
        disconnectOperation = DisconnectOperation(id: operationID, task: task)
        await task.value
    }

    // MARK: - Command Execution

    func execute(_ command: String, timeout: Duration? = nil) async throws -> String {
        guard !_isAborted else {
            throw SSHError.notConnected
        }
        guard let session = session else {
            throw SSHError.notConnected
        }
        let effectiveTimeout = timeout ?? execTimeout
        return try await SSHClient.runWithTimeout(effectiveTimeout) {
            try Task.checkCancellation()
            return try await session.execute(command)
        }
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        guard !_isAborted else {
            throw SSHError.notConnected
        }
        guard let session = session else {
            throw SSHError.notConnected
        }

        logger.info(
            "Starting SSH upload [path: \(remotePath, privacy: .public)] [bytes: \(data.count)] [strategy: \(String(describing: strategy), privacy: .public)]"
        )
        try await SSHClient.runWithTimeout(uploadTimeout) {
            try Task.checkCancellation()
            try await session.upload(
                data,
                to: remotePath,
                permissions: permissions,
                strategy: strategy
            )
        }
    }

    func remoteEnvironment(forceRefresh: Bool = false) async -> RemoteEnvironment {
        // Teleport's outer session is the PROXY, which rejects exec with -22.
        // The resolver's exec probes must run on the INNER (target-node)
        // session, established by `prepareTeleportInnerSession()`. If the
        // inner session is not ready yet, establish it BEFORE resolving so
        // the probes route to the inner session (never the outer). If the
        // inner session can't be established, swallow the error — the
        // resolver's exec probes will themselves fail gracefully and return
        // `.unknown`, matching the prior behavior. This makes every caller of
        // remoteEnvironment()/remoteTerminalType() safe without each one
        // needing to know about Teleport.
        let authMethod = connectedServer?.authMethod ?? .password
        let innerReady = await (session?.isInnerSessionReady ?? false)
        if !forceRefresh,
           let resolvedRemoteEnvironment,
           // For Teleport, a cached `.unknown` platform means env was resolved
           // before the inner session existed (the prepare failed or hadn't
           // run yet). Treat it as a miss when the inner session is now ready
           // so we re-resolve against the real target node.
           !(authMethod == .faceIDTeleport && innerReady && resolvedRemoteEnvironment.platform == .unknown) {
            return resolvedRemoteEnvironment
        }

        if Self.shouldPrepareInnerSessionBeforeResolvingEnvironment(
            authMethod: authMethod,
            innerSessionReady: innerReady
        ) {
            do {
                try await prepareTeleportInnerSession()
            } catch {
                logger.warning(
                    "Failed to prepare Teleport inner session before resolving environment: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let token = startupTrace?.begin(.remoteEnvironment)
        let environment = await RemoteEnvironmentResolver.resolve(using: self)
        if let token {
            startupTrace?.end(token, detail: environment.platform.rawValue)
        }
        resolvedRemoteEnvironment = environment
        logger.info(
            "Resolved remote environment [platform: \(environment.platform.rawValue, privacy: .public), shell: \(environment.shellProfile.family.rawValue, privacy: .public), active: \(environment.activeShellName ?? "unknown", privacy: .public)]"
        )
        return environment
    }

    func remoteTerminalType(forceRefresh: Bool = false) async -> RemoteTerminalType {
        if !forceRefresh, let resolvedRemoteTerminalType {
            return resolvedRemoteTerminalType
        }

        let environment = await remoteEnvironment(forceRefresh: forceRefresh)
        let token = startupTrace?.begin(.terminalType)
        let terminalType = await RemoteTerminalTypeResolver.resolve(
            environment: environment,
            execute: { [weak self] command, timeout in
                guard let self else { throw SSHError.notConnected }
                return try await self.execute(command, timeout: timeout)
            }
        )
        if let token {
            startupTrace?.end(token, detail: terminalType.rawValue)
        }
        resolvedRemoteTerminalType = terminalType
        logger.info("Resolved remote terminal type: \(terminalType.rawValue, privacy: .public)")
        return terminalType
    }

    func remotePlatform(forceRefresh: Bool = false) async -> RemotePlatform {
        await remoteEnvironment(forceRefresh: forceRefresh).platform
    }

    func supportsTmuxRuntime() async -> Bool {
        let environment = await remoteEnvironment()
        return environment.supportsTmuxRuntime
    }

    func supportsMoshRuntime() async -> Bool {
        let environment = await remoteEnvironment()
        return environment.supportsMoshRuntime
    }

    // MARK: - Remote Files

    func listDirectory(at path: String, maxEntries: Int? = nil) async throws -> [RemoteFileEntry] {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.listDirectory(at: path, maxEntries: maxEntries)
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.stat(at: path)
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.lstat(at: path)
    }

    func readlink(at path: String) async throws -> String {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.readlink(at: path)
    }

    func readFile(at path: String, maxBytes: Int, offset: UInt64 = 0) async throws -> Data {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.readFile(at: path, maxBytes: maxBytes, offset: offset)
    }

    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.fileSystemStatus(at: path)
    }

    func downloadFile(at path: String, to localURL: URL) async throws {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }

        logger.info(
            "Starting SSH download [remote: \(path, privacy: .public)] [local: \(localURL.path, privacy: .private(mask: .hash))]"
        )
        try await SSHClient.runWithTimeout(downloadTimeout) {
            try Task.checkCancellation()
            try await session.downloadFile(at: path, to: localURL)
        }
    }

    func resolveHomeDirectory() async throws -> String {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.resolveHomeDirectory()
    }

    func createDirectory(at path: String, permissions: Int32 = 0o755) async throws {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.createDirectory(at: path, permissions: permissions)
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.setPermissions(at: path, permissions: permissions)
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.renameItem(at: sourcePath, to: destinationPath)
    }

    func deleteFile(at path: String) async throws {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.deleteFile(at: path)
    }

    func deleteDirectory(at path: String) async throws {
        guard !_isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.deleteDirectory(at: path)
    }

    // MARK: - Shell

    func startShell(
        cols: Int = 80,
        rows: Int = 24,
        pixelSize: TerminalPixelSize? = nil,
        startupCommand: String? = nil
    ) async throws -> ShellHandle {
        try Task.checkCancellation()
        guard !_isAborted, let sshSession = session else {
            throw SSHError.notConnected
        }

        let connectionMode = connectedServer?.connectionMode ?? .standard
        // Resolve unconditionally: for Teleport, remoteEnvironment() now
        // establishes the inner (target-node) session first, so the resolver's
        // exec probes route to the inner session (never the outer proxy).
        // startShellViaTeleportProxy later calls prepareTeleportInnerSession()
        // again — that's an idempotent no-op when the inner session is ready.
        let environment = await remoteEnvironment()
        try validateShellStartupSession(sshSession)
        let terminalType = await remoteTerminalType()
        try validateShellStartupSession(sshSession)
        if connectionMode != .mosh {
            let sshShell = try await startValidatedSSHShell(
                using: sshSession,
                cols: cols,
                rows: rows,
                pixelSize: pixelSize,
                startupCommand: startupCommand,
                environment: environment,
                terminalType: terminalType
            )
            return ShellHandle(
                id: sshShell.id,
                stream: sshShell.stream,
                transport: .ssh
            )
        }

        guard environment.platform != .windows && environment.shellProfile.family == .posix else {
            logger.warning("Mosh requested, but remote environment does not support Mosh runtime. Falling back to SSH.")
            let fallbackToken = startupTrace?.begin(.sshFallback)
            let fallbackShell = try await startValidatedSSHShell(
                using: sshSession,
                cols: cols,
                rows: rows,
                pixelSize: pixelSize,
                startupCommand: startupCommand,
                environment: environment,
                terminalType: terminalType
            )
            if let fallbackToken { startupTrace?.end(fallbackToken, detail: "unsupported_remote") }
            return ShellHandle(
                id: fallbackShell.id,
                stream: fallbackShell.stream,
                transport: .sshFallback,
                fallbackReason: .unsupportedRemoteCapabilities,
                fallbackDiagnostics: MoshFallbackDiagnostics.make(
                    reason: .unsupportedRemoteCapabilities,
                    events: startupTrace?.snapshot() ?? []
                )
            )
        }

        do {
            let preparedMosh = try await prepareMoshShell(
                using: sshSession,
                cols: cols,
                rows: rows,
                startupCommand: startupCommand,
                terminalType: terminalType
            )
            do {
                try validateShellStartupSession(sshSession)
            } catch {
                await discardPreparedMoshShell(preparedMosh)
                throw error
            }
            pendingMoshServerLeases.removeValue(forKey: preparedMosh.leaseID)
            return registerMoshShell(preparedMosh.shell)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if let sshError = error as? SSHError, case .notConnected = sshError {
                throw sshError
            }
            let moshError = error
            let fallbackReason = fallbackReason(for: moshError)
            logger.warning("Mosh startup failed, using SSH fallback: \(moshError.localizedDescription)")

            do {
                let fallbackToken = startupTrace?.begin(.sshFallback)
                let fallbackShell = try await startValidatedSSHShell(
                    using: sshSession,
                    cols: cols,
                    rows: rows,
                    pixelSize: pixelSize,
                    startupCommand: startupCommand,
                    environment: environment,
                    terminalType: terminalType
                )
                if let fallbackToken {
                    startupTrace?.end(fallbackToken, detail: fallbackReason.rawValue)
                }
                return ShellHandle(
                    id: fallbackShell.id,
                    stream: fallbackShell.stream,
                    transport: .sshFallback,
                    fallbackReason: fallbackReason,
                    fallbackDiagnostics: MoshFallbackDiagnostics.make(
                        reason: fallbackReason,
                        events: startupTrace?.snapshot() ?? []
                    )
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                if let sshError = error as? SSHError, case .notConnected = sshError {
                    throw sshError
                }
                throw SSHError.moshSessionFailed(
                    "Mosh startup failed (\(moshError.localizedDescription)); SSH fallback failed (\(error.localizedDescription))"
                )
            }
        }
    }

    private func startValidatedSSHShell(
        using expectedSession: SSHSession,
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize?,
        startupCommand: String?,
        environment: RemoteEnvironment,
        terminalType: RemoteTerminalType
    ) async throws -> ShellHandle {
        try validateShellStartupSession(expectedSession)
        let shell = try await expectedSession.startShell(
            cols: cols,
            rows: rows,
            pixelSize: pixelSize,
            startupCommand: startupCommand,
            environment: environment,
            terminalType: terminalType
        )
        do {
            try validateShellStartupSession(expectedSession)
            return shell
        } catch {
            await expectedSession.closeShell(shell.id)
            throw error
        }
    }

    private func validateShellStartupSession(_ expectedSession: SSHSession) throws {
        try Task.checkCancellation()
        guard !_isAborted,
              let currentSession = session,
              currentSession === expectedSession else {
            throw SSHError.notConnected
        }
    }

    func write(_ data: Data, to shellId: UUID) async throws {
        guard !_isAborted else {
            throw SSHError.notConnected
        }

        if let runtime = moshShells[shellId] {
            do {
                try await runtime.session.enqueue(.keystrokes(data))
                return
            } catch {
                throw SSHError.moshSessionFailed(error.localizedDescription)
            }
        }

        guard let session = session else {
            throw SSHError.notConnected
        }
        try await session.write(data, to: shellId)
    }

    func resize(
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize? = nil,
        for shellId: UUID
    ) async throws {
        if let runtime = moshShells[shellId] {
            guard let wireCols = Int32(exactly: cols),
                  let wireRows = Int32(exactly: rows) else {
                throw SSHError.unknown("Invalid terminal size \(cols)x\(rows)")
            }
            do {
                try await runtime.session.enqueue(.resize(cols: wireCols, rows: wireRows))
                return
            } catch {
                throw SSHError.moshSessionFailed(error.localizedDescription)
            }
        }

        guard let session = session else {
            throw SSHError.notConnected
        }
        try await session.resize(
            cols: cols,
            rows: rows,
            pixelSize: pixelSize,
            for: shellId
        )
    }

    func closeShell(_ shellId: UUID) async {
        if let runtime = moshShells.removeValue(forKey: shellId) {
            await runtime.session.stop()
            return
        }

        guard let session = session else { return }
        await session.closeShell(shellId)
    }

    func prepareMoshShellForApplicationBackground(
        _ shellId: UUID
    ) async throws -> MoshSnapshot? {
        guard let runtime = moshShells[shellId] else { return nil }
        return try await runtime.session.prepareForApplicationBackground()
    }

    func resumeMoshShellFromApplicationBackground(_ shellId: UUID) async throws {
        guard let runtime = moshShells[shellId] else { return }
        try await runtime.session.resumeFromApplicationBackground()
    }

    func moshSnapshot(for shellId: UUID) async throws -> MoshSnapshot? {
        guard let runtime = moshShells[shellId] else { return nil }
        return try await runtime.session.makeSnapshot()
    }

    // MARK: - Keep Alive

    private func startKeepAlive(interval: TimeInterval = 30) {
        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await session?.sendKeepAlive()
            }
        }
    }

    private func finishDisconnect(operationID: UUID) {
        guard disconnectOperation?.id == operationID else { return }
        disconnectOperation = nil
    }

    nonisolated static func cleanupPendingMoshServerLeases(
        _ leases: [RemoteMoshServerLease]
    ) async -> Bool {
        guard !leases.isEmpty else { return true }

        // This task is deliberately unstructured so cancellation of the caller
        // cannot shorten the cleanup window before the remote PID is known.
        return await Task {
            do {
                try await runWithTimeout(RemoteMoshManager.disconnectCleanupTimeout) {
                    await withTaskGroup(of: Void.self) { group in
                        for lease in leases {
                            group.addTask {
                                await lease.cleanup()
                            }
                        }
                    }
                }
                return true
            } catch {
                // The timeout is cooperative. Once termination starts, its own
                // five-second command bound remains authoritative.
                return false
            }
        }.value
    }

    private nonisolated static func disconnectSSHSession(
        _ activeSession: SSHSession?,
        timeout: Duration,
        logger: Logger
    ) async {
        guard let activeSession else { return }

        let abortWatchdog = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            logger.warning("Timed out while disconnecting SSH session; aborting socket")
            activeSession.abort()
        }
        defer { abortWatchdog.cancel() }

        await activeSession.disconnect()
    }

    private func disconnectCloudflareTransport(reason: String) async {
        await SSHClient.disconnectCloudflareTransport(
            cloudflareTransportManager,
            reason: reason,
            timeout: disconnectTimeout,
            logger: logger
        )
    }

    private nonisolated static func disconnectCloudflareTransport(
        _ manager: CloudflareTransportManager,
        reason: String,
        timeout: Duration,
        logger: Logger
    ) async {
        do {
            try await SSHClient.runWithTimeout(timeout) {
                await manager.disconnect()
            }
        } catch {
            logger.warning("Timed out while disconnecting Cloudflare transport (\(reason, privacy: .public))")
        }
    }

    // MARK: - State

    var isConnected: Bool {
        get async {
            await session?.isConnected ?? false
        }
    }

    /// Returns `true` when `execute(_:)` can currently succeed on the active
    /// session. For Teleport this requires the INNER (target-node) session to
    /// be established; for every other auth method it mirrors `isConnected`.
    /// Stats collection consults this to skip gracefully before the inner
    /// session is ready (e.g. before the shell starts) instead of spinning
    /// failing exec calls.
    var supportsExec: Bool {
        get async {
            await session?.supportsExec ?? false
        }
    }

    /// Returns `true` when SFTP (remote file browser) can currently succeed
    /// on the active session. For Teleport this requires the INNER
    /// (target-node) session to be established; for every other auth method
    /// it mirrors `isConnected`. File-browser callers consult this to
    /// surface a clear "not ready" error before attempting SFTP init (which
    /// would otherwise fail with "Failed to start SFTP session" on the
    /// Teleport proxy).
    var supportsSFTP: Bool {
        get async {
            await session?.supportsSFTP ?? false
        }
    }

    /// Establish the inner (target-node) session for a Teleport proxy
    /// connection without starting a shell.
    ///
    /// Teleport's outer session is the PROXY, which rejects `exec` with -22.
    /// Exec must run on the INNER (target-node) session, established by a
    /// second SSH handshake over a `proxy:<node>:0` subsystem tunnel. That
    /// second handshake used to only happen inside `startShell`, so exec-only
    /// consumers (the stats collector creates its own `SSHClient` and never
    /// starts a shell) never got an inner session — `supportsExec` stayed
    /// `false` forever and every stats poll logged a skip.
    ///
    /// Call this after `connect(to:credentials:)` for Teleport servers when
    /// the connection will be used for `execute` rather than `startShell`
    /// (stats collection, process control). It is a no-op for non-Teleport
    /// auth methods and idempotent for Teleport (a ready inner session is
    /// reused, so calling it when the terminal already opened a shell is
    /// safe and cheap).
    ///
    /// The terminal shell path also calls this (via `startShell` →
    /// `startShellViaTeleportProxy` → `prepareTeleportInnerSession`), so the
    /// live shell behavior is unchanged.
    func prepareTeleportInnerSession() async throws {
        guard let session = session else {
            throw SSHError.notConnected
        }
        try await session.prepareTeleportInnerSession()
        // The inner (target-node) session is now established. If env/terminal
        // type was resolved before the inner session existed (e.g. a caller
        // invoked remoteEnvironment() before the shell started and got
        // `.unknown` defaults because the prepare failed), the cached values
        // are stale. Clear them so the next remoteEnvironment(forceRefresh:
        // false) call re-resolves against the now-ready inner session.
        if connectedServer?.authMethod == .faceIDTeleport {
            resolvedRemoteEnvironment = nil
            resolvedRemoteTerminalType = nil
        }
    }

    /// Pure decision extracted from `remoteEnvironment()` so it can be unit-
    /// tested without a live libssh2 session. Returns `true` ONLY for the
    /// Teleport auth method AND when the inner (target-node) session is not
    /// yet ready — the client must establish the inner session BEFORE running
    /// the resolver's exec probes, otherwise the probes exec on the outer
    /// PROXY session (fails with -22 and poisons the session).
    ///
    /// For non-Teleport (outer session supports exec directly) and for
    /// Teleport-with-ready-inner (prepare is an idempotent no-op), returns
    /// `false`.
    nonisolated static func shouldPrepareInnerSessionBeforeResolvingEnvironment(
        authMethod: AuthMethod,
        innerSessionReady: Bool
    ) -> Bool {
        authMethod == .faceIDTeleport && !innerSessionReady
    }

    // MARK: - Mosh

    func restoreMoshShell(
        from snapshot: MoshSnapshot,
        cols: Int,
        rows: Int
    ) async throws -> ShellHandle {
        guard !_isAborted else { throw SSHError.notConnected }

        let restoredSession = try await MoshClientSession.restore(from: snapshot)
        do {
            try await restoredSession.start()
            try await restoredSession.enqueue(
                .resize(cols: Int32(cols), rows: Int32(rows))
            )
            let hostOpStream = await restoredSession.hostOpStream()
            return registerMoshShell(
                PreparedMoshShell(
                    session: restoredSession,
                    pendingOps: [],
                    hostOpStream: hostOpStream
                ),
                origin: .restored
            )
        } catch {
            await restoredSession.stop()
            throw error
        }
    }

    private func prepareMoshShell(
        using expectedSession: SSHSession,
        cols: Int,
        rows: Int,
        startupCommand: String?,
        terminalType: RemoteTerminalType
    ) async throws -> PreparedMoshBootstrap {
        let configuredHost = connectedServer?.host ?? ""
        let peerHost = await expectedSession.remoteEndpointHost()
        try validateShellStartupSession(expectedSession)
        let candidateHosts = MoshEndpointCandidatePolicy.hosts(
            configuredHost: configuredHost,
            sshPeerHost: peerHost
        )
        guard !candidateHosts.isEmpty else { throw SSHError.moshInvalidEndpoint }

        let terminateServer: @Sendable (Int32) async -> Void = { pid in
            await RemoteMoshManager.shared.terminateMoshServer(
                pid: pid,
                execute: { command, timeout in
                    try await SSHClient.runWithTimeout(timeout) {
                        try await expectedSession.execute(command)
                    }
                }
            )
        }
        let leaseID = UUID()
        let lease = RemoteMoshServerLease(terminate: terminateServer)
        pendingMoshServerLeases[leaseID] = lease

        let bootstrapToken = startupTrace?.begin(.moshBootstrap)
        let connectInfo: MoshServerConnectInfo
        do {
            connectInfo = try await RemoteMoshManager.shared.bootstrapConnectInfo(
                terminalType: terminalType,
                startCommand: startupCommand,
                portRange: 60001...61000,
                execute: { command, timeout in
                    try await SSHClient.runWithTimeout(timeout) {
                        try await expectedSession.execute(command)
                    }
                }
            )
            await lease.activate(serverPID: connectInfo.serverPID)
            if let bootstrapToken {
                startupTrace?.end(
                    bootstrapToken,
                    detail: RemoteMoshManager.portClass(Int(connectInfo.port)).rawValue
                )
            }
        } catch {
            if let bootstrapToken {
                startupTrace?.end(
                    bootstrapToken,
                    outcome: "failed",
                    detail: fallbackReason(for: error).rawValue
                )
            }
            await lease.bootstrapFailed()
            pendingMoshServerLeases.removeValue(forKey: leaseID)
            throw error
        }

        do {
            let preparedShell = try await prepareMoshShellStartup(
                using: expectedSession,
                configuredHost: configuredHost,
                candidateHosts: candidateHosts,
                connectInfo: connectInfo,
                cols: cols,
                rows: rows
            )
            return PreparedMoshBootstrap(
                shell: preparedShell,
                leaseID: leaseID,
                lease: lease
            )
        } catch {
            await lease.cleanup()
            pendingMoshServerLeases.removeValue(forKey: leaseID)
            throw error
        }
    }

    private func discardPreparedMoshShell(_ prepared: PreparedMoshBootstrap) async {
        await prepared.lease.cleanup()
        await prepared.shell.session.stop()
        pendingMoshServerLeases.removeValue(forKey: prepared.leaseID)
    }

    private func prepareMoshShellStartup(
        using expectedSession: SSHSession,
        configuredHost: String,
        candidateHosts: [String],
        connectInfo: MoshServerConnectInfo,
        cols: Int,
        rows: Int
    ) async throws -> PreparedMoshShell {
        try validateShellStartupSession(expectedSession)

        let startupTimeout = candidateHosts.count > 1 ? Duration.seconds(4) : moshStartupTimeout
        var lastStartupError: Error?
        var moshSession: MoshClientSession?
        var pendingOps: [MoshHostOp] = []

        for host in candidateHosts {
            try validateShellStartupSession(expectedSession)
            let endpointClass = host == configuredHost ? "configured" : "ssh_peer"
            startupTrace?.record(
                .moshEndpoint,
                stageMilliseconds: 0,
                outcome: "selected",
                detail: endpointClass
            )
            let udpToken = startupTrace?.begin(.moshUDPSession)
            let endpoint = MoshEndpoint(
                host: host,
                port: connectInfo.port,
                keyBase64_22: connectInfo.key
            )
            let candidateSession = MoshClientSession(endpoint: endpoint)

            do {
                pendingOps = try await SSHClient.runWithTimeout(startupTimeout) {
                    try await candidateSession.start()
                    try await candidateSession.enqueue(.resize(cols: Int32(cols), rows: Int32(rows)))
                    return try await SSHClient.waitForMoshTransportReadiness {
                        await candidateSession.drainHostOps()
                    }
                }
                moshSession = candidateSession
                if let udpToken { startupTrace?.end(udpToken, detail: endpointClass) }
                if host != configuredHost {
                    logger.info("Using SSH peer endpoint for Mosh: \(host, privacy: .private(mask: .hash))")
                }
                break
            } catch {
                await candidateSession.stop()
                if let udpToken {
                    startupTrace?.end(udpToken, outcome: "failed", detail: endpointClass)
                }
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                lastStartupError = error
                if host != candidateHosts.last {
                    logger.warning("Mosh startup failed for endpoint \(host, privacy: .private(mask: .hash)), trying next candidate")
                }
            }
        }

        guard let moshSession else {
            if let sshError = lastStartupError as? SSHError,
               case .timeout = sshError {
                throw SSHError.moshUDPTimeout
            }
            if let lastStartupError {
                throw SSHError.moshClientSessionFailed(lastStartupError.localizedDescription)
            }
            throw SSHError.moshClientSessionFailed("Failed to start Mosh session")
        }

        do {
            let hostOpStream = await moshSession.hostOpStream()
            try validateShellStartupSession(expectedSession)
            return PreparedMoshShell(
                session: moshSession,
                pendingOps: pendingOps,
                hostOpStream: hostOpStream
            )
        } catch {
            await moshSession.stop()
            throw error
        }
    }

    private func registerMoshShell(
        _ prepared: PreparedMoshShell,
        origin: ShellStartOrigin = .fresh
    ) -> ShellHandle {
        let shellId = UUID()
        if !prepared.pendingOps.isEmpty {
            logger.info("Mosh: \(prepared.pendingOps.count) pending host ops before stream creation")
        }

        let streamPair = AsyncStream<Data>.makeStream()
        let continuation = streamPair.continuation
        for op in prepared.pendingOps {
            if let bytes = MoshStartupReadiness.visibleTerminalBytes(from: op) {
                startupTrace?.recordOnce(.firstTerminalByte, detail: "mosh")
                continuation.yield(bytes)
            }
        }

        moshShells[shellId] = MoshShellRuntime(session: prepared.session)

        let moshLogger = logger
        let trace = startupTrace
        let streamTask = Task { [weak self] in
            var totalBytes = 0
            for await hostOp in prepared.hostOpStream {
                guard !Task.isCancelled else { break }
                if let bytes = MoshStartupReadiness.visibleTerminalBytes(from: hostOp) {
                    trace?.recordOnce(.firstTerminalByte, detail: "mosh")
                    totalBytes += bytes.count
                    moshLogger.debug("Mosh host bytes: \(bytes.count)B (total: \(totalBytes))")
                    continuation.yield(bytes)
                }
            }
            moshLogger.info("Mosh stream ended, total bytes delivered: \(totalBytes)")
            continuation.finish()
            await self?.closeShell(shellId)
        }

        continuation.onTermination = { [weak self] _ in
            streamTask.cancel()
            Task { [weak self] in
                await self?.closeShell(shellId)
            }
        }

        return ShellHandle(
            id: shellId,
            stream: streamPair.stream,
            transport: .mosh,
            origin: origin
        )
    }

    nonisolated static func waitForMoshTransportReadiness(
        pollInterval: Duration = .milliseconds(20),
        draining drainHostOps: @escaping @Sendable () async -> [MoshHostOp]
    ) async throws -> [MoshHostOp] {
        while true {
            try Task.checkCancellation()
            let drained = await drainHostOps()
            if MoshStartupReadiness.isTransportEstablished(by: drained) {
                return drained
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private nonisolated static func runWithTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SSHError.timeout
            }

            guard let result = try await group.next() else {
                throw SSHError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private func fallbackReason(for error: Error) -> MoshFallbackReason {
        guard let sshError = error as? SSHError else {
            return .sessionFailed
        }

        switch sshError {
        case .moshServerMissing:
            return .serverMissing
        case .moshServerRuntimeBroken:
            return .serverRuntimeBroken
        case .moshBootstrapFailed:
            return .bootstrapFailed
        case .moshInvalidEndpoint:
            return .invalidEndpoint
        case .moshUDPTimeout:
            return .udpTimeout
        case .moshClientSessionFailed:
            return .clientSessionFailed
        case .moshSessionFailed:
            return .sessionFailed
        default:
            return .sessionFailed
        }
    }
}

actor SSHConnectionOperationService {
    static let shared = SSHConnectionOperationService()

    private init() {}

    func runWithConnection<T>(
        using client: SSHClient,
        server: Server,
        credentials: ServerCredentials,
        disconnectWhenDone: Bool = false,
        operation: @escaping (SSHClient) async throws -> T
    ) async throws -> T {
        do {
            _ = try await client.connect(to: server, credentials: credentials)
            let result = try await operation(client)
            if disconnectWhenDone {
                await client.disconnect()
            }
            return result
        } catch {
            if disconnectWhenDone {
                await client.disconnect()
            }
            throw error
        }
    }

    func withTemporaryConnection<T>(
        server: Server,
        credentials: ServerCredentials,
        operation: @escaping (SSHClient) async throws -> T
    ) async throws -> T {
        let client = SSHClient()
        return try await runWithConnection(
            using: client,
            server: server,
            credentials: credentials,
            disconnectWhenDone: true,
            operation: operation
        )
    }
}

// MARK: - Keyboard Interactive Auth Helper

/// Per-session storage for keyboard-interactive password (used by C callback).
/// This avoids cross-session password races when multiple auth flows run concurrently.
private final class KeyboardInteractiveContext: @unchecked Sendable {
    private nonisolated(unsafe) var _password: String?
    private let lock = NSLock()

    nonisolated init() {}

    nonisolated func setPassword(_ password: String?) {
        lock.lock()
        defer { lock.unlock() }
        _password = password
    }

    nonisolated func password() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return _password
    }
}

private func keyboardInteractivePassword(
    from abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> String? {
    guard let abstract, let contextPointer = abstract.pointee else { return nil }
    let context = Unmanaged<KeyboardInteractiveContext>.fromOpaque(contextPointer).takeUnretainedValue()
    return context.password()
}

// C callback for keyboard-interactive authentication
nonisolated(unsafe) private let kbdintCallback: @convention(c) (
    UnsafePointer<CChar>?,  // name
    Int32,                   // name_len
    UnsafePointer<CChar>?,  // instruction
    Int32,                   // instruction_len
    Int32,                   // num_prompts
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,  // prompts
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,  // responses
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?  // abstract
) -> Void = { name, nameLen, instruction, instructionLen, numPrompts, prompts, responses, abstract in
    guard numPrompts > 0, let responses = responses, let password = keyboardInteractivePassword(from: abstract) else {
        return
    }

    // For each prompt, provide the password
    for i in 0..<Int(numPrompts) {
        let passwordData = password.utf8CString
        let length = passwordData.count - 1  // exclude null terminator

        // Allocate memory for response (libssh2 will free it)
        let responseBuf = UnsafeMutablePointer<CChar>.allocate(capacity: length + 1)
        passwordData.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            responseBuf.initialize(from: baseAddress, count: length)
        }
        responseBuf[length] = 0

        responses[i].text = responseBuf
        responses[i].length = UInt32(length)
    }
}

// MARK: - SSH Session using libssh2

actor SSHSession {
    enum ShellStartupStage: Sendable {
        case channelOpenRetry
        case ptyRequest
        case shellRequest
    }

    #if DEBUG
    struct ShellStartupTestEvent: Sendable {
        let stage: ShellStartupStage
        let sessionIsBlocking: Bool
    }
    #endif

    private final class ExecRequest {
        let id: UUID
        let command: String
        let continuation: CheckedContinuation<String, Error>
        var channel: OpaquePointer?
        var output = Data()
        var stderr = Data()
        var isStarted = false
        /// `true` for an exec channel backed by the inner (target-node) libssh2
        /// session of the Teleport proxy-subsystem path. The outer `ioLoop`
        /// skips these — they're drained by `innerIOLoop`, which polls the
        /// inner socketpair FD (data for the inner channel arrives via the
        /// proxy-subsystem pump, not the outer session's socket). Mirrors the
        /// `ShellChannelState.isInner` flag.
        var isInner: Bool = false

        init(id: UUID, command: String, continuation: CheckedContinuation<String, Error>) {
            self.id = id
            self.command = command
            self.continuation = continuation
        }
    }

    private final class ShellChannelState {
        let id: UUID
        var channel: OpaquePointer
        let continuation: AsyncStream<Data>.Continuation
        var batchBuffer = Data()
        var lastYieldTime: UInt64 = DispatchTime.now().uptimeNanoseconds
        var recentBytesPerRead: Int = 0
        var didRecordFirstByte = false
        /// `true` for a shell channel backed by the inner (target-node) libssh2
        /// session of the Teleport proxy-subsystem path. The outer `ioLoop`
        /// skips these — they're drained by `innerIOLoop`, which polls the
        /// inner socketpair FD (data for the inner channel arrives via the
        /// proxy-subsystem pump, not the outer session's socket).
        var isInner: Bool = false

        init(id: UUID, channel: OpaquePointer, continuation: AsyncStream<Data>.Continuation) {
            self.id = id
            self.channel = channel
            self.continuation = continuation
        }
    }

    let config: SSHSessionConfig
    private var libssh2Session: OpaquePointer?
    private var sftpSession: OpaquePointer?
    /// `true` when `sftpSession` was created via `libssh2_sftp_init` on the
    /// inner (target-node) libssh2 session (Teleport proxy-subsystem path).
    /// `false` when it was created on the outer (direct) session. SFTP I/O
    /// retries (EAGAIN) must wait on the matching socket: the inner
    /// socketpair FD for `true`, the outer socket for `false`. Mixing them
    /// would wait on the wrong FD and hang or spin.
    private var sftpSessionIsInner: Bool = false
    private var shellChannels: [UUID: ShellChannelState] = [:]
    private var shellStartupsInFlight: Set<UUID> = []
    private var socket: Int32 = -1
    /// The TLS+ALPN transport backing `socket` when the session connects to a
    /// Teleport proxy (`.faceIDTeleport`). Non-nil only for the TLS path;
    /// the raw-TCP path leaves this nil. Retained so `cleanup()` can close it
    /// (closing the libssh2 FD alone would leak the NWConnection + pump task).
    private var tlsTransport: SSHTLSTransport?
    /// The second (target-node) libssh2 session for the Teleport proxy-subsystem
    /// path. Non-nil only when `config.authMethod == .faceIDTeleport` and the
    /// shell was started via `startShellViaTeleportProxy`. Owned by this
    /// `SSHSession`; freed in `cleanupLibssh2`/`cleanup` (after the outer
    /// session's proxy-subsystem channel + the bridge transport are torn
    /// down).
    private var innerLibssh2Session: OpaquePointer?
    /// The `SSHProxySubsystemTransport` bridging the outer session's
    /// proxy-subsystem channel to the inner libssh2 session's FD. Retained
    /// for the inner session's lifetime so its pump keeps forwarding bytes
    /// between the outer channel and the inner socketpair. Closed in
    /// `cleanup` (before the inner session is freed).
    private var innerTransport: SSHProxySubsystemTransport?
    /// The outer (proxy) session channel that carries the proxy-subsystem
    /// tunnel. Retained so `cleanup` can free it after the inner session is
    /// torn down (the pump reads/writes this channel).
    private var proxySubsystemChannel: OpaquePointer?
    /// The inner socketpair's libssh2-facing FD. Mirrors `socket` for the
    /// outer session; closed via `innerAtomicSocket` after the inner libssh2
    /// session is freed.
    private var innerSocket: Int32 = -1
    /// Atomic storage for the inner FD, mirroring `atomicSocket` for the
    /// outer session. Lets the inner I/O be interrupted from any thread.
    private let innerAtomicSocket = AtomicSocket()
    /// The IO loop draining inner (target-node) shell channels. `nil` until
    /// `startShellViaTeleportProxy` starts it; cancelled in `cleanup`.
    private var innerIOTask: Task<Void, Never>?
    private var isActive = false
    private var ioTask: Task<Void, Never>?
    private var execRequests: [UUID: ExecRequest] = [:]
    private var connectedPeerAddress: String?
    private let logger = Logger.forCategory("SSHSession")
    private let startupTrace: SSHStartupTrace?

    /// Atomic socket storage for emergency abort from any thread
    private let atomicSocket = AtomicSocket()

    /// Guards all libssh2 calls on the outer (proxy) session. The Teleport
    /// proxy-subsystem pump (`SSHProxySubsystemTransport`) runs two concurrent
    /// loops that read/write the outer session's proxy-subsystem channel via
    /// `libssh2_channel_read_ex` / `libssh2_channel_write_ex` — both touch
    /// the same `LIBSSH2_SESSION*`. libssh2 is not thread-safe per-session,
    /// so without serialization the concurrent `ssh2_transport_read` /
    /// `ssh2_transport_send` corrupt the session's transport buffer
    /// accounting (`session->packet.writeidx/readidx`) and trip
    /// `assert(remainbuf >= 0)` in transport.c. This mutex is shared with the
    /// pump closures (`makeForChannel`) and acquired here in `sendKeepAlive`
    /// (and any other outer-session caller) so off-actor pump access and
    /// actor-isolated access never overlap. See `SessionMutex` for the race
    /// rationale.
    private let outerSessionMutex = SessionMutex()

    /// Session-specific auth callback context passed to libssh2 session abstract pointer.
    private let keyboardInteractiveContext = KeyboardInteractiveContext()

    /// Track if cleanup has been performed
    private var hasBeenCleaned = false

    #if DEBUG
    private var shellStartupTestHook: (@Sendable (ShellStartupTestEvent) -> Void)?
    private var discardedShellStartupChannelCount = 0
    #endif

    init(config: SSHSessionConfig, startupTrace: SSHStartupTrace? = nil) {
        self.config = config
        self.startupTrace = startupTrace
    }

    var isConnected: Bool {
        isActive && libssh2Session != nil
    }

    /// Returns `true` when `execute(_:)` can currently succeed on this session.
    ///
    /// For non-Teleport auth methods this mirrors `isConnected` (the outer
    /// session supports exec directly). For Teleport (`.faceIDTeleport`) the
    /// outer session is the PROXY, which rejects exec with -22; exec must be
    /// routed to the INNER (target-node) session, so this returns `true` only
    /// when the inner session is established (after the second handshake in
    /// `startShellViaTeleportProxy`). Stats collection consults this to skip
    /// gracefully before the shell starts rather than spinning failing exec
    /// calls.
    var supportsExec: Bool {
        guard isActive, !hasBeenCleaned, libssh2Session != nil else { return false }
        if config.authMethod == .faceIDTeleport {
            return innerLibssh2Session != nil
                && innerSocket >= 0
                && innerAtomicSocket.isUsable
        }
        return true
    }

    /// Returns `true` when the Teleport INNER (target-node) session has been
    /// established by `prepareTeleportInnerSession()` (non-nil libssh2
    /// session). This is a lightweight liveness check used by
    /// `SSHClient.remoteEnvironment()` to decide whether to prepare the inner
    /// session before running exec probes — distinct from `supportsExec`,
    /// which additionally gates on socket usability and active state. For
    /// non-Teleport auth methods this returns `false` (there is no inner
    /// session, and none is needed).
    var isInnerSessionReady: Bool {
        config.authMethod == .faceIDTeleport && innerLibssh2Session != nil
    }

    /// Returns `true` when SFTP (remote file browser) can currently succeed
    /// on this session.
    ///
    /// Teleport's outer session is the PROXY, which is in `proxyMode` and
    /// rejects the SFTP subsystem request with -22 (only the
    /// `proxy:<node>:0` subsystem is accepted). SFTP must run on the INNER
    /// (target-node) session, established by `prepareTeleportInnerSession()`.
    /// For non-Teleport auth methods this mirrors `isConnected` (the outer
    /// session supports SFTP directly).
    ///
    /// File-browser callers consult this to surface a clear "not ready"
    /// error before attempting SFTP init (which would otherwise fail with
    /// the opaque "Failed to start SFTP session" message on the proxy).
    var supportsSFTP: Bool {
        guard isActive, !hasBeenCleaned, libssh2Session != nil else { return false }
        if config.authMethod == .faceIDTeleport {
            return innerLibssh2Session != nil
                && innerSocket >= 0
                && innerAtomicSocket.isUsable
        }
        return true
    }

    /// Interrupt socket I/O from any thread; actor-owned cleanup performs the final close.
    nonisolated func abort() {
        atomicSocket.interrupt("abort")
    }

    #if DEBUG
    func setShellStartupTestHook(
        _ hook: (@Sendable (ShellStartupTestEvent) -> Void)?
    ) {
        shellStartupTestHook = hook
    }

    func discardedShellStartupChannelsForTesting() -> Int {
        discardedShellStartupChannelCount
    }

    private func notifyShellStartupTestHook(
        _ stage: ShellStartupStage,
        session: OpaquePointer
    ) {
        shellStartupTestHook?(
            ShellStartupTestEvent(
                stage: stage,
                sessionIsBlocking: libssh2_session_get_blocking(session) != 0
            )
        )
    }
    #endif

    // MARK: - Connection

    func connect() async throws {
        try Task.checkCancellation()
        try LibSSH2Runtime.ensureInitialized()
        socket = -1
        connectedPeerAddress = nil

        // Teleport proxies (default since Teleport 13) host SSH on port 443
        // behind a TLS listener with ALPN `teleport-proxy-ssh` (TLS Routing,
        // RFD 39). A raw TCP socket receives TLS bytes, not an SSH banner,
        // so `libssh2_session_handshake` fails immediately. For Teleport
        // servers we dial TLS+ALPN via `SSHTLSTransport`, which bridges
        // `NWConnection` to libssh2 through a socketpair + pump. The
        // non-Teleport path keeps the raw TCP connector unchanged.
        if config.authMethod == .faceIDTeleport {
            socket = try await connectTeleportTLS()
        } else {
            socket = try await SSHAddressConnector.connect(
                host: config.dialHost,
                port: config.dialPort,
                trace: startupTrace
            )
            applyRawTCPSocketOptions(socket)
        }

        // Store in atomic storage for emergency I/O interruption.
        atomicSocket.install(socket)
        connectedPeerAddress = resolveNumericPeerAddress(for: socket)

        // Create libssh2 session (use _ex variant since macros not available in Swift)
        let sessionAbstract = Unmanaged.passUnretained(keyboardInteractiveContext).toOpaque()
        libssh2Session = libssh2_session_init_ex(nil, nil, nil, sessionAbstract)
        guard let session = libssh2Session else {
            atomicSocket.close()
            self.socket = -1
            throw SSHError.unknown("Failed to create libssh2 session")
        }

        // Prefer fast ciphers - AES-GCM and ChaCha20 are hardware-accelerated on Apple Silicon
        // This reduces CPU overhead for encryption/decryption
        let fastCiphers = "aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-ctr,aes256-ctr"
        applyMethodPref(session, method: LIBSSH2_METHOD_CRYPT_CS, prefs: fastCiphers, label: "crypt_cs")
        applyMethodPref(session, method: LIBSSH2_METHOD_CRYPT_SC, prefs: fastCiphers, label: "crypt_sc")

        // Prefer fast MACs (message authentication codes)
        let fastMACs = "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512"
        applyMethodPref(session, method: LIBSSH2_METHOD_MAC_CS, prefs: fastMACs, label: "mac_cs")
        applyMethodPref(session, method: LIBSSH2_METHOD_MAC_SC, prefs: fastMACs, label: "mac_sc")

        // Force modern KEX + hostkey algorithms (Teleport proxy may reject ssh-rsa).
        // libssh2 1.11.1 with the OpenSSL backend (linked via libcrypto.a)
        // supports curve25519-sha256, ECDH, and rsa-sha2-256/512 hostkey
        // signatures. Teleport's proxy — like OpenSSH 8.8+ — disables
        // `ssh-rsa` (SHA-1) by default, so offering it first causes a KEX
        // failure (LIBSSH2_ERROR_KEX_FAILURE / -5). Order the preferences so
        // modern, SHA-2 based algorithms are tried before legacy `ssh-rsa`.
        applyMethodPref(session, method: LIBSSH2_METHOD_KEX, prefs: SSHMethodPreferences.kex, label: "kex")
        applyMethodPref(session, method: LIBSSH2_METHOD_HOSTKEY, prefs: SSHMethodPreferences.hostkey, label: "hostkey")

        // Set blocking mode for handshake
        libssh2_session_set_blocking(session, 1)

        // Perform SSH handshake.
        //
        // Teleport proxies running TLS Routing (the default since Teleport 13)
        // multiplex all client protocols on port 443 behind a single TLS
        // listener. SSH is reached via ALPN `teleport-proxy-ssh` *inside* a TLS
        // tunnel — a raw TCP socket here will get an immediate handshake
        // failure because the proxy speaks TLS, not SSH, on the bare socket.
        // When that happens `libssh2_session_last_error` typically reports a
        // banner/version error (e.g. "Error starting up SSH session: -1")
        // rather than a TLS error, because libssh2 never sees a TLS byte.
        // Capture the libssh2 error string so the live failure surfaces it.
        try Task.checkCancellation()
        let handshakeToken = startupTrace?.begin(.sshHandshake)
        let dialHost = config.dialHost
        let dialPort = config.dialPort
        let peer = connectedPeerAddress ?? "unknown"
        let fd = socket
        logger.info(
            "ssh_handshake_begin fd=\(fd) peer=\(peer, privacy: .public) dial=\(dialHost, privacy: .private(mask: .hash)):\(dialPort)"
        )
        // Bound the blocking handshake so a stalled transport fails with a
        // real error instead of hanging the session forever (Teleport's mux
        // waits for client bytes; a wedged pump would otherwise stall us).
        libssh2_session_set_timeout(session, 30_000)
        // Watchdog: libssh2's own timeout can fail to fire (e.g. when the
        // transport never EAGAINs); interrupt the socket so the C call
        // returns instead of wedging the caller's thread indefinitely.
        let handshakeWatchdog = Task.detached { [atomicSocket] in
            // Cancellation (the `defer` below, when the handshake completes)
            // must DISARM the watchdog. A `try?` would swallow the
            // CancellationError and fall through to interrupt() — killing
            // the just-established connection (dispatch 9: pump EOF + .notConnected
            // 0.8ms after "Connected to").
            do {
                try await Task.sleep(nanoseconds: 35_000_000_000)
            } catch {
                return  // cancelled — handshake completed; disarm
            }
            atomicSocket.interrupt("handshake-watchdog")
        }
        defer { handshakeWatchdog.cancel() }
        let handshakeResult = libssh2_session_handshake(session, socket)
        guard handshakeResult == 0 else {
            var errmsg: UnsafeMutablePointer<CChar>?
            var errmsgLen: Int32 = 0
            libssh2_session_last_error(session, &errmsg, &errmsgLen, 0)
            let errorMsg = errmsg != nil ? String(cString: errmsg!) : "no libssh2 error string"
            logger.error(
                "ssh_handshake_failed code=\(handshakeResult) libssh2=\(errorMsg, privacy: .public) fd=\(fd) peer=\(peer, privacy: .public) dial=\(dialHost, privacy: .private(mask: .hash)):\(dialPort)"
            )
            if let handshakeToken { startupTrace?.end(handshakeToken, outcome: "failed", detail: "code_\(handshakeResult)") }
            cleanup()
            throw SSHError.connectionFailed("SSH handshake failed (code \(handshakeResult)): \(errorMsg)")
        }

        // Log the negotiated KEX + hostkey algorithms so future live KEX
        // mismatches surface what libssh2 actually agreed on with the peer.
        let negotiatedKex = SSHSession.negotiatedMethod(session, method: LIBSSH2_METHOD_KEX)
        let negotiatedHostkey = SSHSession.negotiatedMethod(session, method: LIBSSH2_METHOD_HOSTKEY)
        logger.info(
            "ssh_handshake_ok kex=\(negotiatedKex, privacy: .public) hostkey=\(negotiatedHostkey, privacy: .public) fd=\(fd) peer=\(peer, privacy: .public)"
        )
        if let handshakeToken { startupTrace?.end(handshakeToken, outcome: "ok", detail: "kex_\(negotiatedKex)") }

        let hostKeyToken = startupTrace?.begin(.hostKeyVerification)
        do {
            try verifyHostKey()
            if let hostKeyToken { startupTrace?.end(hostKeyToken) }
        } catch {
            if let hostKeyToken { startupTrace?.end(hostKeyToken, outcome: "failed") }
            cleanup()
            throw error
        }

        // Authenticate
        try Task.checkCancellation()
        let authenticationToken = startupTrace?.begin(.authentication)
        do {
            try await authenticate()
            if let authenticationToken { startupTrace?.end(authenticationToken) }
        } catch {
            if let authenticationToken { startupTrace?.end(authenticationToken, outcome: "failed") }
            throw error
        }

        // Set non-blocking for I/O
        libssh2_session_set_blocking(session, 0)

        isActive = true
        logger.info("SSH session established")
    }

    // MARK: - Teleport TLS transport

    /// Dial the Teleport proxy over TLS+ALPN and return the libssh2-facing FD.
    ///
    /// Fetches the cluster name + TLS CA certs (captured at Phase 1 bootstrap,
    /// persisted in `TeleportKeyRing`) to build the NWProtocolTLS trust
    /// anchors. The transport is retained for the session lifetime so the
    /// pump + NWConnection stay alive; `cleanup()` closes it.
    ///
    /// If no cluster TLS state is persisted (e.g. the server arrived via
    /// iCloud on a fresh device, or the bootstrap didn't capture
    /// host_signers), throw `teleportCertMissing` so the UI layer triggers
    /// re-bootstrap — the SSH path can't construct the TLS trust store
    /// without the cluster CA.
    private func connectTeleportTLS() async throws -> Int32 {
        let clusterId = config.credentials.serverId
        let keyRing = TeleportKeyRing.shared
        guard let tlsState = await keyRing.clusterTLSState(for: clusterId) else {
            logger.error(
                "teleport TLS state missing for cluster \(clusterId.uuidString, privacy: .public) — re-bootstrap required"
            )
            throw SSHError.teleportCertMissing
        }

        // For Teleport, `config.host`/`config.dialHost` is the PROXY host
        // (e.g. teleport.pcad.it). The target node name is `Server.name`
        // (the display name), used only for the `proxy:<node>:0` subsystem
        // string. Dial the proxy with TLS+ALPN.
        let transport = SSHTLSTransport(
            host: config.dialHost,
            port: config.dialPort,
            clusterName: tlsState.clusterName,
            clusterCAPEMs: tlsState.clusterCAPEMs
        )
        let fd: Int32
        do {
            fd = try await transport.connect()
        } catch {
            // connect() already cleaned up its own FDs + NWConnection on
            // failure (see SSHTLSTransport.connect). Close once more to be
            // safe, then rethrow — don't retain the transport.
            await transport.close()
            throw error
        }
        tlsTransport = transport
        let dialPort = config.dialPort
        let dialHost = config.dialHost
        let caCertCount = tlsState.clusterCAPEMs.count
        logger.info(
            "teleport TLS transport connected dial=\(dialHost, privacy: .private(mask: .hash)):\(dialPort) alpn=\(SSHTLSTransport.alpnProtocol, privacy: .public) fd=\(fd) ca_certs=\(caCertCount)"
        )
        return fd
    }

    /// Apply TCP-specific socket options (Nagle, buffer sizes, NOSIGPIPE)
    /// to a raw TCP socket from `SSHAddressConnector`. Not called for the
    /// Teleport TLS path — the socket there is an AF_UNIX socketpair end,
    /// not a TCP socket.
    private func applyRawTCPSocketOptions(_ fd: Int32) {
        // Disable Nagle's algorithm for low-latency interactive typing.
        // Without this, small packets (keystrokes) are batched causing
        // 40-200ms delays.
        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        // Optimize socket buffers for interactive SSH:
        // - Small send buffer (8KB) reduces buffering delay for keystrokes
        // - Larger receive buffer (64KB) improves throughput for command output
        var sendBufSize: Int32 = 8192
        var recvBufSize: Int32 = 65536
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &recvBufSize, socklen_t(MemoryLayout<Int32>.size))

        // Prevent SIGPIPE on broken connections (handle errors in code instead).
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    private func authenticate() async throws {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }

        let username = config.username
        var authResult: Int32 = -1

        // Query supported auth methods
        let authList = libssh2_userauth_list(session, username, UInt32(username.utf8.count))
        if let authListPtr = authList {
            let methods = String(cString: authListPtr)
            logger.info("Server auth methods [mode: \(self.config.connectionMode.rawValue)]: \(methods)")
        } else {
            logger.warning("Could not get auth methods list")
        }

        if config.connectionMode == .tailscale {
            if libssh2_userauth_authenticated(session) != 0 {
                logger.info("Tailscale SSH authentication accepted by server policy")
                return
            }
            logger.error("Tailscale SSH auth not accepted by server")
            throw SSHError.tailscaleAuthenticationNotAccepted
        }

        // If authList is nil, check if already authenticated
        if authList == nil, libssh2_userauth_authenticated(session) != 0 {
            logger.info("Already authenticated")
            return
        }

        switch config.authMethod {
        case .faceIDTeleport:
            // Teleport cert seam — feed the Teleport-issued SSH cert + the
            // ed25519 private key to libssh2. The cert (authorized_keys
            // format: `ssh-ed25519-cert-v01@openssh.com AAAA… comment`) goes
            // in as `publicKeyData`; the ed25519 private key (OpenSSH PEM)
            // goes in as `privateKeyData`. No passphrase (Teleport certs
            // don't have one). Same `libssh2_userauth_publickey_frommemory`
            // call the `.sshKey` case uses, just with different key material.
            //
            // The cert + key are fetched live from `TeleportKeyRing` so a
            // refresh (Phase 3 re-auth) is picked up without rebuilding the
            // config. If no live cert (expired/missing) or no private key,
            // throw `teleportCertMissing` so the UI layer can trigger the
            // `TeleportLoginCoordinator` flow.
            let clusterId = config.credentials.serverId
            let keyRing = TeleportKeyRing.shared
            guard let certPEM = await keyRing.liveCertPEM(for: clusterId),
                  let certData = certPEM.data(using: .utf8),
                  let keyData = await keyRing.liveEd25519PrivateKey(for: clusterId) else {
                logger.error("No live Teleport cert or ed25519 key for cluster \(clusterId.uuidString, privacy: .public)")
                throw SSHError.teleportCertMissing
            }
            logger.info("Attempting Teleport cert auth for user: \(username)")
            authResult = certData.withUnsafeBytes { certBuffer -> Int32 in
                guard let certBase = certBuffer.bindMemory(to: CChar.self).baseAddress else {
                    return LIBSSH2_ERROR_ALLOC
                }
                return keyData.withUnsafeBytes { keyBuffer -> Int32 in
                    guard let keyBase = keyBuffer.bindMemory(to: CChar.self).baseAddress else {
                        return LIBSSH2_ERROR_ALLOC
                    }
                    return libssh2_userauth_publickey_frommemory(
                        session,
                        username,
                        Int(username.utf8.count),
                        certBase,
                        Int(certData.count),
                        keyBase,
                        Int(keyData.count),
                        nil
                    )
                }
            }
        case .password:
            guard let password = config.credentials.password else {
                logger.error("No password provided")
                throw SSHError.authenticationFailed
            }
            logger.info("Attempting password auth for user: \(username)")

            // Use _ex variant since macros not available in Swift
            authResult = libssh2_userauth_password_ex(
                session,
                username,
                UInt32(username.utf8.count),
                password,
                UInt32(password.utf8.count),
                nil
            )

            // If password auth fails, try keyboard-interactive as fallback
            if authResult != 0 {
                logger.info("Password auth failed, trying keyboard-interactive...")

                keyboardInteractiveContext.setPassword(password)
                defer { keyboardInteractiveContext.setPassword(nil) }

                authResult = libssh2_userauth_keyboard_interactive_ex(
                    session,
                    username,
                    UInt32(username.utf8.count),
                    kbdintCallback
                )
            }

        case .sshKey, .sshKeyWithPassphrase:
            guard let keyData = config.credentials.privateKey else {
                logger.error("No private key provided")
                throw SSHError.authenticationFailed
            }
            let passphrase = config.credentials.passphrase
            let publicKeyData = config.credentials.publicKey
            logger.info("Attempting publickey auth for user: \(username)")

            authResult = keyData.withUnsafeBytes { rawBuffer -> Int32 in
                guard let baseAddress = rawBuffer.bindMemory(to: CChar.self).baseAddress else {
                    return LIBSSH2_ERROR_ALLOC
                }

                if let publicKeyData, !publicKeyData.isEmpty {
                    return publicKeyData.withUnsafeBytes { publicBuffer -> Int32 in
                        guard let publicBase = publicBuffer.bindMemory(to: CChar.self).baseAddress else {
                            return LIBSSH2_ERROR_ALLOC
                        }
                        return libssh2_userauth_publickey_frommemory(
                            session,
                            username,
                            Int(username.utf8.count),
                            publicBase,
                            Int(publicKeyData.count),
                            baseAddress,
                            Int(keyData.count),
                            passphrase
                        )
                    }
                }

                return libssh2_userauth_publickey_frommemory(
                    session,
                    username,
                    Int(username.utf8.count),
                    nil,
                    0,
                    baseAddress,
                    Int(keyData.count),
                    passphrase
                )
            }
        }

        if authResult != 0 {
            // Get detailed error message
            var errmsg: UnsafeMutablePointer<CChar>?
            var errmsg_len: Int32 = 0
            libssh2_session_last_error(session, &errmsg, &errmsg_len, 0)
            let errorMsg = errmsg != nil ? String(cString: errmsg!) : "Unknown error"
            logger.error("Auth failed (\(authResult)): \(errorMsg)")
            throw SSHError.authenticationFailed
        }

        logger.info("Authentication successful")
    }

    private func verifyHostKey() throws {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }

        let (fingerprint, keyType) = try hostKeyFingerprint(for: session)
        let host = config.hostKeyHost
        let port = config.hostKeyPort

        if let entry = KnownHostsManager.shared.entry(for: host, port: port) {
            if entry.fingerprint != fingerprint {
                logger.error(
                    "Host key mismatch for \(host, privacy: .private(mask: .hash)):\(port). Known: \(entry.fingerprint, privacy: .private(mask: .hash)), Presented: \(fingerprint, privacy: .private(mask: .hash))"
                )
                throw SSHError.hostKeyVerificationFailed
            }
            KnownHostsManager.shared.updateSeen(host: host, port: port)
            logger.info("Host key verified for \(host, privacy: .private(mask: .hash)):\(port)")
            return
        }

        let entry = KnownHostsManager.Entry(
            host: host,
            port: port,
            fingerprint: fingerprint,
            keyType: keyType,
            addedAt: Date(),
            lastSeenAt: Date()
        )
        KnownHostsManager.shared.save(entry: entry)
        logger.info(
            "Trusted new host key for \(host, privacy: .private(mask: .hash)):\(port) (\(fingerprint, privacy: .private(mask: .hash)))"
        )
    }

    private func hostKeyFingerprint(for session: OpaquePointer) throws -> (String, Int) {
        guard let hashPtr = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_SHA256)) else {
            throw SSHError.hostKeyVerificationFailed
        }

        let hash = Data(bytes: hashPtr, count: 32)
        let base64 = hash.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let fingerprint = "SHA256:\(base64)"

        var keyLen: size_t = 0
        var keyType: Int32 = 0
        _ = libssh2_session_hostkey(session, &keyLen, &keyType)

        return (fingerprint, Int(keyType))
    }

    func disconnect() async {
        invalidateTransport()
        cleanupLibssh2()

        logger.diagInfo("SSHSession", "Disconnected")
    }

    private func invalidateTransport() {
        isActive = false
        connectedPeerAddress = nil
        abandonAllShellChannels()
        ioTask?.cancel()
        ioTask = nil
        stopInnerIOLoop()
        failAllExecRequests(error: SSHError.notConnected)
        atomicSocket.interrupt("disconnect-outer")
        innerAtomicSocket.interrupt("disconnect-inner")
        // Synchronously stop the bridge transport's pump so it stops
        // reading/writing the outer proxy-subsystem channel (the outer
        // session is freed next by cleanupLibssh2). The full actor-isolated
        // close() is deferred to cleanupLibssh2 for bookkeeping.
        innerTransport?.cancelPumpSync()
        socket = -1
        innerSocket = -1
    }

    private func cleanupLibssh2() {
        // A startup operation may still own a channel pointer across an actor
        // suspension. Its defer releases that ownership before final cleanup.
        guard shellStartupsInFlight.isEmpty else { return }
        // Prevent double cleanup
        guard !hasBeenCleaned else { return }
        sftpSession = nil
        sftpSessionIsInner = false

        // Free the Teleport inner (target-node) session first, before the
        // outer session. The inner session's I/O was already interrupted by
        // invalidateTransport (innerAtomicSocket.interrupt), and its bridge
        // transport pump was stopped there too, so freeing it is safe. The
        // inner FD is closed via innerAtomicSocket after the free (mirrors
        // the outer session's AtomicSocket close ordering).
        if let innerSession = innerLibssh2Session {
            var innerFreeResult = Int32(LIBSSH2_ERROR_EAGAIN)
            for _ in 0..<1_024 {
                innerFreeResult = libssh2_session_free(innerSession)
                if innerFreeResult != LIBSSH2_ERROR_EAGAIN {
                    break
                }
            }
            if innerFreeResult != 0 {
                logger.error("Abandoning incomplete inner libssh2 session cleanup: \(innerFreeResult)")
            }
            innerLibssh2Session = nil
            innerAtomicSocket.close()
            innerSocket = -1
        }

        // Synchronously stop the bridge transport's pump BEFORE freeing the
        // outer session. The pump reads/writes the outer proxy-subsystem
        // channel via libssh2_channel_read_ex / libssh2_channel_write_ex;
        // freeing the outer session underneath a live pump would be a
        // use-after-free. cancelPumpSync() cancels the pump task + closes the
        // pump FD (the loops exit on EBADF). The full actor-isolated close()
        // is also scheduled (below) for the libssh2FD bookkeeping, but the
        // synchronous cancel is what makes freeing the outer session safe.
        if let innerTransport = innerTransport {
            innerTransport.cancelPumpSync()
        }

        // Free the outer proxy-subsystem channel if it's still around (the
        // outer session free below may reap it, but close it explicitly to
        // avoid leaking it if the outer free is abandoned).
        if let proxyChannel = proxySubsystemChannel {
            _ = libssh2_channel_close(proxyChannel)
            _ = libssh2_channel_free(proxyChannel)
            proxySubsystemChannel = nil
        }

        if let transport = innerTransport {
            Task { await transport.close() }
            innerTransport = nil
        }

        guard let session = libssh2Session else {
            hasBeenCleaned = true
            atomicSocket.close()
            return
        }

        var freeResult = Int32(LIBSSH2_ERROR_EAGAIN)
        for _ in 0..<1_024 {
            freeResult = libssh2_session_free(session)
            if freeResult != LIBSSH2_ERROR_EAGAIN {
                break
            }
        }
        if freeResult == 0 {
            libssh2Session = nil
            hasBeenCleaned = true
            atomicSocket.close()
        } else {
            // No Swift operation may call the native session at this point. If
            // libssh2 still cannot finish, abandon its allocation rather than
            // calling into a partial operation or leaking the descriptor.
            logger.error("Abandoning incomplete libssh2 session cleanup: \(freeResult)")
            libssh2Session = nil
            hasBeenCleaned = true
            atomicSocket.close()
        }
    }

    private func cleanup() {
        // Tear down the Teleport inner session + bridge transport BEFORE the
        // outer session: the bridge pump must stop before the outer
        // proxy-subsystem channel is freed (it reads/writes that channel),
        // and the inner libssh2 session must be interrupted before it is
        // freed. invalidateTransport() (called by the startShell error path)
        // stops the inner I/O + closes the bridge transport + interrupts
        // both sockets; cleanupLibssh2() (called below) then frees the inner
        // + outer sessions in order. We do NOT duplicate the inner
        // session/transport/channel teardown here — cleanupLibssh2() owns it.
        //
        // The outer TLS transport is closed here (it is not touched by
        // cleanupLibssh2 because its lifecycle mirrors the outer socket's,
        // which is owned by AtomicSocket).
        if let transport = tlsTransport {
            atomicSocket.interrupt("cleanup-libssh2")  // shutdown(libssh2FD) unblocks libssh2 I/O
            // Detach the transport close so `cleanup()` stays synchronous.
            // The Task captures `transport` strongly, so it lives until close()
            // completes even though `tlsTransport` is nilled below. This is
            // safe because `cleanup()` runs after I/O has stopped.
            Task { await transport.close() }
            tlsTransport = nil
            socket = -1
        } else {
            // Close socket first to abort any blocking I/O.
            atomicSocket.interrupt("cleanup-libssh2-2")
            socket = -1
        }
        connectedPeerAddress = nil
        cleanupLibssh2()
    }

    func remoteEndpointHost() -> String? {
        connectedPeerAddress
    }

    // MARK: - Remote Files

    func listDirectory(at path: String, maxEntries: Int? = nil) async throws -> [RemoteFileEntry] {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        let handle = try await openDirectoryHandle(at: normalizedPath, sftp: sftp)
        defer { libssh2_sftp_close_handle(handle) }

        let limit = maxEntries ?? .max
        var entries: [RemoteFileEntry] = []
        var nameBuffer = [CChar](repeating: 0, count: 4096)

        while entries.count < limit {
            try Task.checkCancellation()
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()

            let bytesRead = nameBuffer.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else {
                    return Int(LIBSSH2_ERROR_EAGAIN)
                }

                return Int(
                    libssh2_sftp_readdir_ex(
                        handle,
                        baseAddress,
                        buffer.count,
                        nil,
                        0,
                        &attributes
                    )
                )
            }

            if bytesRead > 0 {
                let name = Self.string(from: nameBuffer, length: bytesRead)
                guard name != "." && name != ".." else { continue }

                let entryPath = RemoteFilePath.appending(name, to: normalizedPath)
                let baseEntry = RemoteFileEntry.from(
                    name: name,
                    path: entryPath,
                    attributes: attributes
                )
                let symlinkTarget = baseEntry.type == .symlink ? (try? await readlink(at: entryPath)) : nil
                entries.append(
                    RemoteFileEntry.from(
                        name: name,
                        path: entryPath,
                        attributes: attributes,
                        symlinkTarget: symlinkTarget
                    )
                )
                continue
            }

            if bytesRead == 0 {
                break
            }

            if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                await waitForSFTPSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: "read directory", path: normalizedPath)
        }

        return entries
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        try await stat(at: path, statType: Int32(LIBSSH2_SFTP_STAT))
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        try await stat(at: path, statType: Int32(LIBSSH2_SFTP_LSTAT))
    }

    func readlink(at path: String) async throws -> String {
        let sftp = try await ensureSFTPSession()
        return try await readSymlinkTarget(at: path, linkType: Int32(LIBSSH2_SFTP_READLINK), sftp: sftp)
    }

    func readFile(at path: String, maxBytes: Int, offset: UInt64 = 0) async throws -> Data {
        guard maxBytes > 0 else { return Data() }

        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        let handle = try await openFileHandle(
            at: normalizedPath,
            sftp: sftp,
            flags: UInt32(LIBSSH2_FXF_READ),
            mode: 0
        )
        defer { libssh2_sftp_close_handle(handle) }

        if offset > 0 {
            libssh2_sftp_seek64(handle, offset)
        }

        var data = Data()
        data.reserveCapacity(min(maxBytes, 32 * 1024))

        while data.count < maxBytes {
            try Task.checkCancellation()
            let remaining = maxBytes - data.count
            let chunkSize = min(32 * 1024, remaining)
            var buffer = [CChar](repeating: 0, count: chunkSize)

            let bytesRead = buffer.withUnsafeMutableBufferPointer { bufferPtr -> Int in
                guard let baseAddress = bufferPtr.baseAddress else {
                    return Int(LIBSSH2_ERROR_EAGAIN)
                }
                return Int(libssh2_sftp_read(handle, baseAddress, bufferPtr.count))
            }

            if bytesRead > 0 {
                buffer.withUnsafeBufferPointer { bufferPtr in
                    guard let baseAddress = bufferPtr.baseAddress else { return }
                    data.append(Data(bytes: UnsafeRawPointer(baseAddress), count: bytesRead))
                }
                continue
            }

            if bytesRead == 0 {
                break
            }

            if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                await waitForSFTPSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: "read file", path: normalizedPath)
        }

        return data
    }

    func downloadFile(at path: String, to localURL: URL) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        let handle = try await openFileHandle(
            at: normalizedPath,
            sftp: sftp,
            flags: UInt32(LIBSSH2_FXF_READ),
            mode: 0
        )
        defer { libssh2_sftp_close_handle(handle) }

        let fileManager = FileManager.default
        let destinationDirectory = localURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: localURL.path) {
            try fileManager.removeItem(at: localURL)
        }
        guard fileManager.createFile(atPath: localURL.path, contents: nil) else {
            throw RemoteFileBrowserError.failed(String(localized: "Unable to create the local download file."))
        }

        let localFileHandle = try FileHandle(forWritingTo: localURL)
        do {
            while true {
                try Task.checkCancellation()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)

                let bytesRead = buffer.withUnsafeMutableBufferPointer { bufferPtr -> Int in
                    guard let baseAddress = bufferPtr.baseAddress else {
                        return Int(LIBSSH2_ERROR_EAGAIN)
                    }
                    return Int(
                        libssh2_sftp_read(
                            handle,
                            UnsafeMutableRawPointer(baseAddress).assumingMemoryBound(to: CChar.self),
                            bufferPtr.count
                        )
                    )
                }

                if bytesRead > 0 {
                    try localFileHandle.write(contentsOf: Data(buffer.prefix(bytesRead)))
                    continue
                }

                if bytesRead == 0 {
                    break
                }

                if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                    await waitForSFTPSocket()
                    continue
                }

                throw Self.remoteFileError(from: sftp, operation: "download file", path: normalizedPath)
            }
        } catch {
            try? localFileHandle.close()
            try? fileManager.removeItem(at: localURL)
            throw error
        }

        try localFileHandle.close()
    }

    func writeFile(_ data: Data, to path: String, permissions: Int32 = 0o644) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        let handle = try await openFileHandle(
            at: normalizedPath,
            sftp: sftp,
            flags: UInt32(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_TRUNC | LIBSSH2_FXF_CREAT),
            mode: permissions,
            operation: "write file"
        )
        defer { libssh2_sftp_close_handle(handle) }

        var totalBytesWritten = 0
        while totalBytesWritten < data.count {
            try Task.checkCancellation()

            let bytesWritten = data.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                let remainingCount = min(64 * 1024, data.count - totalBytesWritten)
                let writeBaseAddress = baseAddress
                    .advanced(by: totalBytesWritten)
                    .assumingMemoryBound(to: CChar.self)
                return Int(libssh2_sftp_write(handle, writeBaseAddress, remainingCount))
            }

            if bytesWritten > 0 {
                totalBytesWritten += bytesWritten
                continue
            }

            if bytesWritten == Int(LIBSSH2_ERROR_EAGAIN) {
                await waitForSFTPSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: "write file", path: normalizedPath)
        }
    }

    func resolveHomeDirectory() async throws -> String {
        let sftp = try await ensureSFTPSession()
        let path = try await readSymlinkTarget(at: ".", linkType: Int32(LIBSSH2_SFTP_REALPATH), sftp: sftp)
        return path.isEmpty ? "/" : path
    }

    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        var status = LIBSSH2_SFTP_STATVFS()

        while true {
            try Task.checkCancellation()

            let result = normalizedPath.withCString { pathPtr in
                libssh2_sftp_statvfs(
                    sftp,
                    pathPtr,
                    normalizedPath.utf8.count,
                    &status
                )
            }

            if result == 0 {
                let fragmentSize = UInt64(status.f_frsize)
                let blockSize = fragmentSize > 0 ? fragmentSize : UInt64(status.f_bsize)
                return RemoteFileFilesystemStatus(
                    blockSize: blockSize,
                    totalBlocks: UInt64(status.f_blocks),
                    freeBlocks: UInt64(status.f_bfree),
                    availableBlocks: UInt64(status.f_bavail)
                )
            }

            if result == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSFTPSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: "read filesystem status", path: normalizedPath)
        }
    }

    func createDirectory(at path: String, permissions: Int32 = 0o755) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        try await performSFTPMutation(
            at: normalizedPath,
            sftp: sftp,
            operation: "create directory"
        ) { sftpHandle, pathPtr, pathLength in
            Int(
                libssh2_sftp_mkdir_ex(
                    sftpHandle,
                    pathPtr,
                    pathLength,
                    Int(permissions)
                )
            )
        }
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        attributes.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
        attributes.permissions = UInt(permissions)

        while true {
            try Task.checkCancellation()

            let result = normalizedPath.withCString { pathPtr in
                libssh2_sftp_stat_ex(
                    sftp,
                    pathPtr,
                    UInt32(normalizedPath.utf8.count),
                    Int32(LIBSSH2_SFTP_SETSTAT),
                    &attributes
                )
            }

            if result == 0 {
                return
            }

            if result == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSFTPSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: "set permissions", path: normalizedPath)
        }
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedSource = RemoteFilePath.normalize(sourcePath)
        let normalizedDestination = RemoteFilePath.normalize(destinationPath)
        let renameFlagCandidates: [Int] = [
            Int(LIBSSH2_SFTP_RENAME_OVERWRITE) |
                Int(LIBSSH2_SFTP_RENAME_ATOMIC) |
                Int(LIBSSH2_SFTP_RENAME_NATIVE),
            Int(LIBSSH2_SFTP_RENAME_OVERWRITE) |
                Int(LIBSSH2_SFTP_RENAME_NATIVE),
            Int(LIBSSH2_SFTP_RENAME_OVERWRITE),
            0
        ]

        var lastError: Error?

        for flags in renameFlagCandidates {
            do {
                try await performSFTPMutation(
                    at: normalizedSource,
                    sftp: sftp,
                    operation: "rename"
                ) { sftpHandle, sourcePtr, sourceLength in
                    normalizedDestination.withCString { destinationPtr in
                        Int(
                            libssh2_sftp_rename_ex(
                                sftpHandle,
                                sourcePtr,
                                sourceLength,
                                destinationPtr,
                                UInt32(normalizedDestination.utf8.count),
                                flags
                            )
                        )
                    }
                }
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RemoteFileBrowserError.failed(String(localized: "Failed to rename item."))
    }

    func deleteFile(at path: String) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        try await performSFTPMutation(
            at: normalizedPath,
            sftp: sftp,
            operation: "delete file"
        ) { sftpHandle, pathPtr, pathLength in
            Int(
                libssh2_sftp_unlink_ex(
                    sftpHandle,
                    pathPtr,
                    pathLength
                )
            )
        }
    }

    func deleteDirectory(at path: String) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        try await performSFTPMutation(
            at: normalizedPath,
            sftp: sftp,
            operation: "delete directory"
        ) { sftpHandle, pathPtr, pathLength in
            Int(
                libssh2_sftp_rmdir_ex(
                    sftpHandle,
                    pathPtr,
                    pathLength
                )
            )
        }
    }

    // MARK: - Shell

    func startShell(
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize? = nil,
        startupCommand: String? = nil,
        environment: RemoteEnvironment = .fallbackPOSIX,
        terminalType: RemoteTerminalType = RemoteTerminalBootstrap.defaultTerminalType
    ) async throws -> ShellHandle {
        guard isActive, let session = libssh2Session else {
            throw SSHError.notConnected
        }
        guard let wireCols = Int32(exactly: cols),
              let wireRows = Int32(exactly: rows) else {
            throw SSHError.unknown("Invalid terminal size \(cols)x\(rows)")
        }

        let startupId = UUID()
        shellStartupsInFlight.insert(startupId)
        var pendingChannel: OpaquePointer?
        var shouldInvalidateTransport = false
        defer {
            if shouldInvalidateTransport {
                invalidateTransport()
            }
            shellStartupsInFlight.remove(startupId)
            if !isActive {
                cleanupLibssh2()
            }
        }

        // Teleport proxy-subsystem path: the proxy listener is in `proxyMode`
        // and rejects `pty`/`shell`/`exec` on the outer session. Instead,
        // request a `proxy:<node>:0` subsystem, bridge the channel to a
        // socketpair, and run a second full SSH handshake (KEX + cert auth)
        // to the target node over that tunnel. The inner channel becomes
        // the shell channel. Non-Teleport auth methods keep the existing
        // direct PTY+shell flow.
        if config.authMethod == .faceIDTeleport {
            return try await startShellViaTeleportProxy(
                cols: cols,
                rows: rows,
                pixelSize: pixelSize,
                startupCommand: startupCommand,
                environment: environment,
                terminalType: terminalType
            )
        }

        do {
            // Keep the shared session nonblocking. libssh2 1.11.1 returns
            // EAGAIN when another caller owns a partial packet; yielding here
            // lets that owner finish instead of making a blocking caller spin.
            let channelToken = startupTrace?.begin(.shellChannel)
            let channel: OpaquePointer
            do {
                channel = try await openShellStartupChannel(session: session)
                pendingChannel = channel
                try validateShellStartup(session: session)
                if let channelToken { startupTrace?.end(channelToken) }
            } catch {
                if let channelToken {
                    startupTrace?.end(
                        channelToken,
                        outcome: error is CancellationError ? "cancelled" : "failed"
                    )
                }
                throw error
            }

            // Mirror Ghostty's SSH behavior so remote prompts/themes can detect
            // 24-bit color support without changing TERM compatibility.
            for variable in RemoteTerminalBootstrap.terminalEnvironment() {
                let result = try await performShellStartupCall(session: session) {
                    libssh2_channel_setenv_ex(
                        channel,
                        variable.name,
                        UInt32(variable.name.utf8.count),
                        variable.value,
                        UInt32(variable.value.utf8.count)
                    )
                }

                // Many SSH servers gate env forwarding via AcceptEnv; continue when
                // a variable is rejected so interactive sessions still start.
                if result != 0 {
                    logger.debug("Remote SSH server rejected env \(variable.name, privacy: .public): \(result)")
                }
            }

            let ptyToken = startupTrace?.begin(.ptyRequest)
            let ptyResult: Int32
            do {
                #if DEBUG
                notifyShellStartupTestHook(.ptyRequest, session: session)
                #endif
                ptyResult = try await performShellStartupCall(session: session) {
                    libssh2_channel_request_pty_ex(
                        channel,
                        terminalType.rawValue,
                        UInt32(terminalType.rawValue.utf8.count),
                        nil,
                        0,
                        wireCols,
                        wireRows,
                        Int32(pixelSize?.width ?? 0),
                        Int32(pixelSize?.height ?? 0)
                    )
                }
            } catch {
                if let ptyToken {
                    startupTrace?.end(
                        ptyToken,
                        outcome: error is CancellationError ? "cancelled" : "failed"
                    )
                }
                throw error
            }
            guard ptyResult == 0 else {
                var errmsg: UnsafeMutablePointer<CChar>?
                var errmsgLen: Int32 = 0
                libssh2_session_last_error(session, &errmsg, &errmsgLen, 0)
                let lastErrno = libssh2_session_last_errno(session)
                let errorMsg = errmsg != nil ? String(cString: errmsg!) : "no libssh2 error string"
                logger.error(
                    "pty_request_failed code=\(ptyResult) errno=\(lastErrno) libssh2=\(errorMsg, privacy: .public) term=\(terminalType.rawValue, privacy: .public) cols=\(wireCols) rows=\(wireRows)"
                )
                if let ptyToken { startupTrace?.end(ptyToken, outcome: "failed", detail: "code_\(ptyResult)") }
                throw SSHError.shellRequestFailed
            }
            if let ptyToken { startupTrace?.end(ptyToken) }

            let shellToken = startupTrace?.begin(.shellRequest)
            let shellResult: Int32
            do {
                #if DEBUG
                notifyShellStartupTestHook(.shellRequest, session: session)
                #endif
                switch RemoteTerminalBootstrap.launchPlan(
                    startupCommand: startupCommand,
                    environment: environment
                ) {
                case .shell:
                    shellResult = try await performShellStartupCall(session: session) {
                        libssh2_channel_process_startup(channel, "shell", 5, nil, 0)
                    }
                case .exec(let command):
                    shellResult = try await performShellStartupCall(session: session) {
                        command.withCString { pointer in
                            libssh2_channel_process_startup(
                                channel,
                                "exec",
                                4,
                                pointer,
                                UInt32(command.utf8.count)
                            )
                        }
                    }
                }
            } catch {
                if let shellToken {
                    startupTrace?.end(
                        shellToken,
                        outcome: error is CancellationError ? "cancelled" : "failed"
                    )
                }
                throw error
            }
            guard shellResult == 0 else {
                var errmsg: UnsafeMutablePointer<CChar>?
                var errmsgLen: Int32 = 0
                libssh2_session_last_error(session, &errmsg, &errmsgLen, 0)
                let lastErrno = libssh2_session_last_errno(session)
                let errorMsg = errmsg != nil ? String(cString: errmsg!) : "no libssh2 error string"
                logger.error(
                    "shell_request_failed code=\(shellResult) errno=\(lastErrno) libssh2=\(errorMsg, privacy: .public)"
                )
                if let shellToken { startupTrace?.end(shellToken, outcome: "failed", detail: "code_\(shellResult)") }
                throw SSHError.shellRequestFailed
            }
            if let shellToken { startupTrace?.end(shellToken) }

            try validateShellStartup(session: session)
            logger.info("Shell started (\(cols)x\(rows))")

            let shellId = UUID()
            let stream = AsyncStream<Data> { continuation in
                let state = ShellChannelState(id: shellId, channel: channel, continuation: continuation)
                self.shellChannels[shellId] = state

                continuation.onTermination = { [weak self] _ in
                    Task { [weak self] in
                        await self?.closeShell(shellId)
                    }
                }
            }

            pendingChannel = nil
            startIOLoop()
            return ShellHandle(id: shellId, stream: stream)
        } catch is CancellationError {
            shouldInvalidateTransport = true
            throw CancellationError()
        } catch SSHError.notConnected {
            shouldInvalidateTransport = true
            throw SSHError.notConnected
        } catch {
            if let pendingChannel {
                if await discardShellStartupChannel(pendingChannel, session: session) {
                    #if DEBUG
                    discardedShellStartupChannelCount += 1
                    #endif
                    self.logger.debug("Discarded failed shell startup channel")
                } else {
                    shouldInvalidateTransport = true
                }
            }
            throw error
        }
    }

    // MARK: - Teleport proxy-subsystem second handshake

    /// Establish the inner (target-node) libssh2 session for a Teleport proxy
    /// connection WITHOUT opening a shell channel.
    ///
    /// Teleport's outer session is the PROXY, which rejects `exec`/`pty`/
    /// `shell` with LIBSSH2_ERROR_CHANNEL_REQUEST_FAILURE (-22). Exec (used by
    /// stats collection, process control, and SFTP) must run on the INNER
    /// (target-node) session, established by a second SSH handshake over a
    /// `proxy:<node>:0` subsystem tunnel. Previously this second handshake
    /// only happened inside `startShellViaTeleportProxy`, so exec-only
    /// consumers (the stats collector creates its own `SSHClient` and never
    /// starts a shell) never got an inner session — `supportsExec` stayed
    /// `false` forever and every stats poll (every 2s) logged a skip.
    ///
    /// This method performs steps 1-7 of `startShellViaTeleportProxy`
    /// (open outer channel, request subsystem, bridge transport, create inner
    /// session, handshake, verify hostkey, cert auth) and switches the inner
    /// session to non-blocking. It is a no-op for non-Teleport auth methods
    /// (their outer session supports exec directly) and idempotent for
    /// Teleport (a ready inner session is reused, so calling it when the
    /// terminal already opened a shell is safe and cheap). `startShellViaTeleportProxy`
    /// calls this first, then opens a shell channel on the now-ready inner
    /// session.
    ///
    /// Ownership: the outer proxy-subsystem channel, the bridge transport, and
    /// the inner session are retained on this `SSHSession` and torn down in
    /// `cleanup`. On any failure the transport is invalidated so exec-only
    /// callers also tear down correctly.
    func prepareTeleportInnerSession() async throws {
        // Non-Teleport auth methods support exec directly on the outer session.
        guard config.authMethod == .faceIDTeleport else { return }
        // Idempotent: a ready inner session means a prior prepare (or shell)
        // already established the tunnel + second handshake.
        if innerLibssh2Session != nil { return }

        guard isActive, let outerSession = libssh2Session else {
            throw SSHError.notConnected
        }

        var shouldInvalidateTransport = false
        defer {
            if shouldInvalidateTransport {
                invalidateTransport()
            }
        }

        // 1. Open a session channel on the outer (proxy) session.
        let proxyToken = startupTrace?.begin(.teleportProxySubsystem)
        let outerChannel: OpaquePointer
        do {
            outerChannel = try await openShellStartupChannel(session: outerSession)
            try validateShellStartup(session: outerSession)
        } catch {
            if let proxyToken {
                startupTrace?.end(
                    proxyToken,
                    outcome: error is CancellationError ? "cancelled" : "failed",
                    detail: "outer_channel"
                )
            }
            shouldInvalidateTransport = true
            throw error
        }
        proxySubsystemChannel = outerChannel

        // 2. Request the proxy:<node>:0 subsystem. libssh2 returns 0 on
        //    success, LIBSSH2_ERROR_CHANNEL_FAILURE if the proxy rejects the
        //    subsystem name, or EAGAIN (handled by performShellStartupCall).
        //    The node name is normalized: `pcad-dev.teleport.pcad.it` → `pcad-dev`
        //    The node name is `Server.name` (the display name) — for Teleport
        //    servers, the display name IS the node name (e.g. "pcad-dev").
        let nodeName = config.teleportNodeName ?? config.host
        let subsystem = TeleportProxySubsystem.request(for: nodeName)
        let subsystemResult: Int32
        do {
            subsystemResult = try await performShellStartupCall(session: outerSession) {
                subsystem.withCString { subsystemPtr in
                    libssh2_channel_process_startup(
                        outerChannel,
                        "subsystem",
                        UInt32("subsystem".utf8.count),
                        subsystemPtr,
                        UInt32(subsystem.utf8.count)
                    )
                }
            }
        } catch {
            if let proxyToken {
                startupTrace?.end(
                    proxyToken,
                    outcome: error is CancellationError ? "cancelled" : "failed",
                    detail: "subsystem_request"
                )
            }
            shouldInvalidateTransport = true
            throw error
        }
        guard subsystemResult == 0 else {
            var errmsg: UnsafeMutablePointer<CChar>?
            var errmsgLen: Int32 = 0
            libssh2_session_last_error(outerSession, &errmsg, &errmsgLen, 0)
            let errorMsg = errmsg != nil ? String(cString: errmsg!) : "no libssh2 error string"
            // Read any extended data (stderr) the proxy may have sent before
            // rejecting. Teleport sometimes writes a human-readable error to
            // channel stderr before the CHANNEL_FAILURE.
            // libssh2_channel_read_stderr doesn't exist as a symbol; use
            // libssh2_channel_read_ex with stream_id=1 (SSH_EXTENDED_DATA_STDERR).
            var stderrBuf = [CChar](repeating: 0, count: 4096)
            let stderrLen = libssh2_channel_read_ex(outerChannel, 1, &stderrBuf, stderrBuf.count)
            let stderrMsg = stderrLen > 0
                ? String(cString: stderrBuf, encoding: .utf8) ?? "<non-utf8>"
                : "<no stderr>"
            logger.error(
                "teleport_proxy_subsystem_failed code=\(subsystemResult) libssh2=\(errorMsg, privacy: .public) subsystem=\(subsystem, privacy: .public) stderr=\(stderrMsg, privacy: .public)"
            )
            if let proxyToken {
                startupTrace?.end(proxyToken, outcome: "failed", detail: "code_\(subsystemResult)")
            }
            shouldInvalidateTransport = true
            throw SSHError.shellRequestFailed
        }
        logger.info(
            "teleport_proxy_subsystem_ok subsystem=\(subsystem, privacy: .public) target=\(nodeName, privacy: .private(mask: .hash))"
        )
        if let proxyToken { startupTrace?.end(proxyToken, detail: nodeName) }

        // 3. Bridge the outer channel to a socketpair for the inner session.
        //    The pump starts before start() returns the FD, so the target
        //    node's banner is forwarded as soon as it arrives.
        let handshakeToken = startupTrace?.begin(.teleportInnerHandshake)
        let transport = SSHProxySubsystemTransport.makeForChannel(
            channel: outerChannel,
            outerSession: outerSession,
            outerSessionMutex: outerSessionMutex
        )
        let innerFD: Int32
        do {
            innerFD = try await transport.start()
        } catch {
            logger.error(
                "teleport_proxy_transport_start_failed error=\(error.localizedDescription, privacy: .public)"
            )
            shouldInvalidateTransport = true
            throw error
        }
        innerTransport = transport
        innerSocket = innerFD
        innerAtomicSocket.install(innerFD)

        // 4. Create the inner libssh2 session + set the same method
        //    preferences. The target node presents a host cert (same HostCA
        //    as the proxy), so the cert hostkey variants are required here
        //    too — same fork as the outer session.
        logger.info(
            "teleport_inner_handshake_begin fd=\(innerFD) target=\(nodeName, privacy: .private(mask: .hash))"
        )
        guard let innerSession = libssh2_session_init_ex(nil, nil, nil, nil) else {
            shouldInvalidateTransport = true
            throw SSHError.unknown("Failed to create inner libssh2 session")
        }
        innerLibssh2Session = innerSession

        let fastCiphers = "aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-ctr,aes256-ctr"
        applyMethodPref(innerSession, method: LIBSSH2_METHOD_CRYPT_CS, prefs: fastCiphers, label: "inner_crypt_cs")
        applyMethodPref(innerSession, method: LIBSSH2_METHOD_CRYPT_SC, prefs: fastCiphers, label: "inner_crypt_sc")
        let fastMACs = "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512"
        applyMethodPref(innerSession, method: LIBSSH2_METHOD_MAC_CS, prefs: fastMACs, label: "inner_mac_cs")
        applyMethodPref(innerSession, method: LIBSSH2_METHOD_MAC_SC, prefs: fastMACs, label: "inner_mac_sc")
        // Sync file-marker diagnostics (bypasses os_log) so we can trace
        // progress even if the sim's os_log pipeline wedges.
        let diagPath = "/tmp/vvterm-diag-\(getpid()).txt"
        let diagFd = open(diagPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        func d(_ s: String) { s.withCString { Darwin.write(diagFd, $0, strlen($0)) }; Darwin.write(diagFd, "\n", 1) }
        d("after inner_mac_sc")
        // Use libssh2 defaults for inner session (no custom KEX/HOSTKEY,
        // no explicit blocking mode, no explicit timeout) — inner session
        // on socketpair fd exhibits stalls with any custom prefs or
        // explicit blocking mode/timeout. Outer session works with custom
        // prefs because it's on a real TCP connection; inner session on
        // socketpair fd behaves differently.
        d("using libssh2 defaults for inner session")
        // Run the blocking inner handshake on a dedicated thread so it
        // doesn't starve the cooperative pool (which runs the pump tasks).
        // The handshake can take many seconds; if it blocks a pool thread,
        // the pumpFDToChannel task never gets a thread and the banner
        // exchange deadlocks.
        d("inner_handshake_call_start (detached)")
        let handshakeResult = await withCheckedContinuation { continuation in
            Task.detached { [innerSession, innerFD] in
                let result = libssh2_session_handshake(innerSession, innerFD)
                continuation.resume(returning: result)
            }
        }
        d("handshake returned \(handshakeResult)")
        guard handshakeResult == 0 else {
            var errmsg: UnsafeMutablePointer<CChar>?
            var errmsgLen: Int32 = 0
            libssh2_session_last_error(innerSession, &errmsg, &errmsgLen, 0)
            let errorMsg = errmsg != nil ? String(cString: errmsg!) : "no libssh2 error string"
            logger.error(
                "teleport_inner_handshake_failed code=\(handshakeResult) libssh2=\(errorMsg, privacy: .public) target=\(nodeName, privacy: .private(mask: .hash))"
            )
            if let handshakeToken {
                startupTrace?.end(handshakeToken, outcome: "failed", detail: "code_\(handshakeResult)")
            }
            shouldInvalidateTransport = true
            throw SSHError.connectionFailed(
                "Teleport inner handshake failed (code \(handshakeResult)): \(errorMsg)"
            )
        }
        let negotiatedKex = SSHSession.negotiatedMethod(innerSession, method: LIBSSH2_METHOD_KEX)
        let negotiatedHostkey = SSHSession.negotiatedMethod(innerSession, method: LIBSSH2_METHOD_HOSTKEY)
        logger.info(
            "teleport_inner_handshake_ok kex=\(negotiatedKex, privacy: .public) hostkey=\(negotiatedHostkey, privacy: .public) target=\(nodeName, privacy: .private(mask: .hash))"
        )
        if let handshakeToken { startupTrace?.end(handshakeToken, detail: negotiatedKex) }

        // 6. Verify the inner hostkey against the target node hostname.
        let innerAuthToken = startupTrace?.begin(.teleportInnerAuthentication)
        do {
            try verifyInnerHostKey(session: innerSession, host: nodeName, port: config.port)
        } catch {
            if let innerAuthToken {
                startupTrace?.end(innerAuthToken, outcome: "failed", detail: "hostkey")
            }
            shouldInvalidateTransport = true
            throw error
        }

        // 7. Auth with the same cert + ed25519 key.
        do {
            try await authenticateInner(session: innerSession)
        } catch {
            if let innerAuthToken {
                startupTrace?.end(
                    innerAuthToken,
                    outcome: error is CancellationError ? "cancelled" : "failed",
                    detail: "auth"
                )
            }
            shouldInvalidateTransport = true
            throw error
        }
        if let innerAuthToken { startupTrace?.end(innerAuthToken) }

        // Switch the inner session to non-blocking for I/O.
        libssh2_session_set_blocking(innerSession, 0)
    }

    /// Start a shell via the Teleport proxy subsystem + a second SSH handshake
    /// to the target node.
    ///
    /// Teleport's proxy listener is in `proxyMode`: it rejects `pty`/`shell`/
    /// `exec` channel requests on the outer session. Instead:
    ///
    ///   1. Open a `session` channel on the outer (proxy) session.
    ///   2. Request a `proxy:<node>:0` subsystem — the proxy forwards the
    ///      channel as a raw TCP tunnel to the target node's SSH service.
    ///   3. Bridge the channel to a socketpair (`SSHProxySubsystemTransport`)
    ///      so a second libssh2 session can read/write through it.
    ///   4. Create the inner libssh2 session + set the same KEX/hostkey
    ///      preferences (cert hostkey variants — the target node presents a
    ///      host cert signed by the same HostCA as the proxy).
    ///   5. `libssh2_session_handshake(innerSession, innerFD)` — the second
    ///      handshake to the target node.
    ///   6. Verify the inner hostkey against the target node hostname
    ///      (`config.host`).
    ///   7. Auth with the same cert + ed25519 key (publickey auth).
    ///   8. Open a `session` channel on the inner session.
    ///   9. PTY + shell on the inner channel.
    ///  10. Return a `ShellHandle` wrapping the inner channel; `innerIOLoop`
    ///      drains it.
    ///
    /// The outer session + its proxy-subsystem channel + the bridge transport
    /// are retained for the inner session's lifetime and torn down in `cleanup`.
    private func startShellViaTeleportProxy(
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize?,
        startupCommand: String?,
        environment: RemoteEnvironment,
        terminalType: RemoteTerminalType
    ) async throws -> ShellHandle {
        guard isActive, libssh2Session != nil else {
            throw SSHError.notConnected
        }
        guard let wireCols = Int32(exactly: cols),
              let wireRows = Int32(exactly: rows) else {
            throw SSHError.unknown("Invalid terminal size \(cols)x\(rows)")
        }

        let startupId = UUID()
        shellStartupsInFlight.insert(startupId)
        var shouldInvalidateTransport = false
        defer {
            if shouldInvalidateTransport {
                invalidateTransport()
            }
            shellStartupsInFlight.remove(startupId)
            if !isActive {
                cleanupLibssh2()
            }
        }

        // Steps 1-7: establish the inner (target-node) session. This is a
        // connection-level concern (proxy subsystem + second handshake +
        // hostkey verify + cert auth), not a shell-level concern, so it is
        // extracted into `prepareTeleportInnerSession()` which is also called
        // by exec-only consumers (stats collector) that never start a shell.
        // Idempotent: a no-op if the inner session is already established by
        // a prior prepare call (e.g. stats ran before the terminal opened).
        try await prepareTeleportInnerSession()
        guard let innerSession = innerLibssh2Session else {
            shouldInvalidateTransport = true
            throw SSHError.notConnected
        }

        // 8. Open a session channel on the inner session.
        let innerChannelToken = startupTrace?.begin(.teleportInnerChannel)
        let innerChannel: OpaquePointer
        do {
            innerChannel = try await openInnerShellStartupChannel(session: innerSession)
            try validateInnerShellStartup(session: innerSession)
        } catch {
            if let innerChannelToken {
                startupTrace?.end(
                    innerChannelToken,
                    outcome: error is CancellationError ? "cancelled" : "failed",
                    detail: "channel_open"
                )
            }
            shouldInvalidateTransport = true
            throw error
        }

        // Mirror Ghostty's TERM env forwarding on the inner channel too.
        for variable in RemoteTerminalBootstrap.terminalEnvironment() {
            let result = try await performInnerShellStartupCall(session: innerSession) {
                libssh2_channel_setenv_ex(
                    innerChannel,
                    variable.name,
                    UInt32(variable.name.utf8.count),
                    variable.value,
                    UInt32(variable.value.utf8.count)
                )
            }
            if result != 0 {
                logger.debug("Remote node rejected env \(variable.name, privacy: .public): \(result)")
            }
        }

        if let innerChannelToken { startupTrace?.end(innerChannelToken) }

        // 9. PTY + shell on the inner channel.
        let innerPTYToken = startupTrace?.begin(.teleportInnerPTY)
        let ptyResult = try await performInnerShellStartupCall(session: innerSession, label: "pty_request") {
            libssh2_channel_request_pty_ex(
                innerChannel,
                terminalType.rawValue,
                UInt32(terminalType.rawValue.utf8.count),
                nil,
                0,
                wireCols,
                wireRows,
                Int32(pixelSize?.width ?? 0),
                Int32(pixelSize?.height ?? 0)
            )
        }
        guard ptyResult == 0 else {
            var errmsg: UnsafeMutablePointer<CChar>?
            var errmsgLen: Int32 = 0
            libssh2_session_last_error(innerSession, &errmsg, &errmsgLen, 0)
            let errorMsg = errmsg != nil ? String(cString: errmsg!) : "no libssh2 error string"
            logger.error(
                "teleport_inner_pty_failed code=\(ptyResult) libssh2=\(errorMsg, privacy: .public) term=\(terminalType.rawValue, privacy: .public)"
            )
            if let innerPTYToken {
                startupTrace?.end(innerPTYToken, outcome: "failed", detail: "code_\(ptyResult)")
            }
            shouldInvalidateTransport = true
            throw SSHError.shellRequestFailed
        }
        if let innerPTYToken { startupTrace?.end(innerPTYToken, detail: terminalType.rawValue) }

        let innerShellToken = startupTrace?.begin(.teleportInnerShellRequest)
        let shellResult: Int32
        switch RemoteTerminalBootstrap.launchPlan(
            startupCommand: startupCommand,
            environment: environment
        ) {
        case .shell:
            shellResult = try await performInnerShellStartupCall(session: innerSession, label: "shell_request") {
                libssh2_channel_process_startup(innerChannel, "shell", 5, nil, 0)
            }
        case .exec(let command):
            shellResult = try await performInnerShellStartupCall(session: innerSession, label: "exec_request") {
                command.withCString { pointer in
                    libssh2_channel_process_startup(
                        innerChannel,
                        "exec",
                        4,
                        pointer,
                        UInt32(command.utf8.count)
                    )
                }
            }
        }
        guard shellResult == 0 else {
            var errmsg: UnsafeMutablePointer<CChar>?
            var errmsgLen: Int32 = 0
            libssh2_session_last_error(innerSession, &errmsg, &errmsgLen, 0)
            let errorMsg = errmsg != nil ? String(cString: errmsg!) : "no libssh2 error string"
            logger.error(
                "teleport_inner_shell_failed code=\(shellResult) libssh2=\(errorMsg, privacy: .public)"
            )
            if let innerShellToken {
                startupTrace?.end(innerShellToken, outcome: "failed", detail: "code_\(shellResult)")
            }
            shouldInvalidateTransport = true
            throw SSHError.shellRequestFailed
        }
        if let innerShellToken { startupTrace?.end(innerShellToken) }
        logger.diagInfo("SSHSession", "Teleport inner shell started (\(cols)x\(rows))")

        // 10. Wrap the inner channel in a ShellHandle. The inner channel is
        //     marked `isInner` so the outer ioLoop skips it; `innerIOLoop`
        //     drains it instead.
        let shellId = UUID()
        let stream = AsyncStream<Data> { continuation in
            let state = ShellChannelState(id: shellId, channel: innerChannel, continuation: continuation)
            state.isInner = true
            self.shellChannels[shellId] = state
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.closeShell(shellId)
                }
            }
        }
        startInnerIOLoop()
        return ShellHandle(id: shellId, stream: stream)
    }

    /// Verify the inner (target-node) session's hostkey against the given
    /// host + port. Mirrors `verifyHostKey()` but parameterized so the inner
    /// session verifies against `config.host` (the target node), not the
    /// proxy host. The cert hostkey verification fork (libssh2) applies here
    /// too — the target node presents a host cert signed by the same HostCA
    /// as the proxy.
    private func verifyInnerHostKey(
        session: OpaquePointer,
        host: String,
        port: Int
    ) throws {
        let (fingerprint, keyType) = try innerHostKeyFingerprint(for: session)
        if let entry = KnownHostsManager.shared.entry(for: host, port: port) {
            if entry.fingerprint != fingerprint {
                logger.error(
                    "Inner host key mismatch for \(host, privacy: .private(mask: .hash)):\(port). Known: \(entry.fingerprint, privacy: .private(mask: .hash)), Presented: \(fingerprint, privacy: .private(mask: .hash))"
                )
                throw SSHError.hostKeyVerificationFailed
            }
            KnownHostsManager.shared.updateSeen(host: host, port: port)
            logger.info("Inner host key verified for \(host, privacy: .private(mask: .hash)):\(port)")
            return
        }
        let entry = KnownHostsManager.Entry(
            host: host,
            port: port,
            fingerprint: fingerprint,
            keyType: keyType,
            addedAt: Date(),
            lastSeenAt: Date()
        )
        KnownHostsManager.shared.save(entry: entry)
        logger.info(
            "Trusted new inner host key for \(host, privacy: .private(mask: .hash)):\(port) (\(fingerprint, privacy: .private(mask: .hash)))"
        )
    }

    private func innerHostKeyFingerprint(for session: OpaquePointer) throws -> (String, Int) {
        guard let hashPtr = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_SHA256)) else {
            throw SSHError.hostKeyVerificationFailed
        }
        let hash = Data(bytes: hashPtr, count: 32)
        let base64 = hash.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let fingerprint = "SHA256:\(base64)"
        var keyLen: size_t = 0
        var keyType: Int32 = 0
        _ = libssh2_session_hostkey(session, &keyLen, &keyType)
        return (fingerprint, Int(keyType))
    }

    /// Authenticate the inner (target-node) session with the same Teleport
    /// cert + ed25519 key used for the outer session.
    ///
    /// The SSH `user` for the inner session must be an OS login from the
    /// cert's `ValidPrincipals` (e.g. `root`), NOT the Teleport username.
    /// This MVP uses `config.username` (the Teleport username) as a first
    /// attempt — this works when the Teleport username matches the OS login
    /// (the common case). A future change should parse the cert's
    /// `ValidPrincipals` (via `SSHCertExpiryParser`'s wire-format walker) and
    /// use the first principal as the login, or expose a `teleportLogin`
    /// field on `Server`.
    /// TODO: parse cert ValidPrincipals for the inner-session OS login.
    private func authenticateInner(session: OpaquePointer) async throws {
        let clusterId = config.credentials.serverId
        let keyRing = TeleportKeyRing.shared
        guard let certPEM = await keyRing.liveCertPEM(for: clusterId),
              let certData = certPEM.data(using: .utf8),
              let keyData = await keyRing.liveEd25519PrivateKey(for: clusterId) else {
            logger.error("No live Teleport cert or ed25519 key for inner cluster \(clusterId.uuidString, privacy: .public)")
            throw SSHError.teleportCertMissing
        }
        // TODO: this should be the cert's first ValidPrincipal (OS login),
        // not the Teleport username. Using config.username as the MVP default.
        let username = config.username
        logger.info("Attempting Teleport cert inner auth for user: \(username)")
        let authResult = certData.withUnsafeBytes { certBuffer -> Int32 in
            guard let certBase = certBuffer.bindMemory(to: CChar.self).baseAddress else {
                return LIBSSH2_ERROR_ALLOC
            }
            return keyData.withUnsafeBytes { keyBuffer -> Int32 in
                guard let keyBase = keyBuffer.bindMemory(to: CChar.self).baseAddress else {
                    return LIBSSH2_ERROR_ALLOC
                }
                return libssh2_userauth_publickey_frommemory(
                    session,
                    username,
                    Int(username.utf8.count),
                    certBase,
                    Int(certData.count),
                    keyBase,
                    Int(keyData.count),
                    nil
                )
            }
        }
        guard authResult == 0 else {
            var errmsg: UnsafeMutablePointer<CChar>?
            var errmsgLen: Int32 = 0
            libssh2_session_last_error(session, &errmsg, &errmsgLen, 0)
            let errorMsg = errmsg != nil ? String(cString: errmsg!) : "Unknown error"
            logger.error("Inner auth failed (\(authResult)): \(errorMsg)")
            throw SSHError.authenticationFailed
        }
        logger.info("Teleport inner authentication successful")
    }

    private func validateInnerShellStartup(session: OpaquePointer) throws {
        try Task.checkCancellation()
        guard isActive,
              !hasBeenCleaned,
              let currentSession = innerLibssh2Session,
              currentSession == session,
              innerSocket >= 0,
              innerAtomicSocket.isUsable else {
            throw SSHError.notConnected
        }
    }

    private func waitForInnerSocket() async {
        guard let session = innerLibssh2Session, innerSocket >= 0 else { return }
        let direction = libssh2_session_block_directions(session)
        guard direction != 0 else { return }
        var pfd = pollfd()
        pfd.fd = innerSocket
        pfd.events = 0
        if direction & LIBSSH2_SESSION_BLOCK_INBOUND != 0 {
            pfd.events |= Int16(POLLIN)
        }
        if direction & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            pfd.events |= Int16(POLLOUT)
        }
        _ = poll(&pfd, 1, 5)
    }

    private func openInnerShellStartupChannel(session: OpaquePointer) async throws -> OpaquePointer {
        let stallTracker = InnerStartupStallTracker(operation: "channel_open")
        while true {
            try validateInnerShellStartup(session: session)
            if let channel = libssh2_channel_open_ex(
                session,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32768,
                nil,
                0
            ) {
                return channel
            }
            let error = libssh2_session_last_errno(session)
            guard error == LIBSSH2_ERROR_EAGAIN else {
                throw SSHError.channelOpenFailed
            }
            stallTracker.logIfStalled(session: session, logger: logger)
            try await waitForInnerShellStartupRetry(session: session)
        }
    }

    /// Logs a warning when an inner-session startup call spins on EAGAIN for
    /// more than ~2s (and every ~5s after that). The Teleport inner startup
    /// path previously had zero visibility between "inner auth successful"
    /// and "inner shell started" — a stall here produced a silent hang
    /// (issue #77).
    private final class InnerStartupStallTracker {
        private let operation: String
        private let startedAt = ContinuousClock.now
        private var lastLogAt = ContinuousClock.now

        init(operation: String) {
            self.operation = operation
        }

        func logIfStalled(session: OpaquePointer, logger: Logger) {
            let now = ContinuousClock.now
            let elapsed = startedAt.duration(to: now)
            guard elapsed >= .seconds(2) else { return }
            let sinceLastLog = lastLogAt.duration(to: now)
            guard sinceLastLog >= .seconds(5) || lastLogAt == startedAt else { return }
            lastLogAt = now
            let directions = libssh2_session_block_directions(session)
            let elapsedMs = Self.milliseconds(elapsed)
            logger.warning(
                "teleport_inner_startup_stall op=\(self.operation, privacy: .public) elapsedMs=\(elapsedMs) blockDirections=\(directions)"
            )
        }

        private static func milliseconds(_ duration: Duration) -> Int {
            let components = duration.components
            return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
        }
    }

    private func waitForInnerShellStartupRetry(session: OpaquePointer) async throws {
        try validateInnerShellStartup(session: session)
        await waitForInnerSocket()
        await Task.yield()
        try validateInnerShellStartup(session: session)
    }

    private func performInnerShellStartupCall(
        session: OpaquePointer,
        label: String = "startup_call",
        operation: () -> Int32
    ) async throws -> Int32 {
        let stallTracker = InnerStartupStallTracker(operation: label)
        while true {
            try validateInnerShellStartup(session: session)
            let result = operation()
            if result != LIBSSH2_ERROR_EAGAIN {
                try validateInnerShellStartup(session: session)
                return result
            }
            stallTracker.logIfStalled(session: session, logger: logger)
            try await waitForInnerShellStartupRetry(session: session)
        }
    }

    // MARK: - Inner IO loop

    private func startInnerIOLoop() {
        guard innerIOTask == nil else { return }
        innerIOTask = Task { [weak self] in
            guard let self else { return }
            await self.innerIOLoop()
            await self.innerIOLoopDidExit()
        }
    }

    /// Clears the completed loop task so future `startInnerIOLoop()` calls
    /// can start a fresh loop, and restarts immediately when inner work
    /// arrived while the previous loop was winding down (lost-wakeup guard).
    ///
    /// Root cause of issue #77: `innerIOLoop` breaks when idle, but
    /// `innerIOTask` stayed non-nil (a *completed* task), so the
    /// `innerIOTask == nil` guard in `startInnerIOLoop()` rejected every
    /// later restart. Inner exec requests enqueued after that point were
    /// never drained (the Ghostty terminfo install stalled until its 12s
    /// timeout on every connect), and the inner shell channel was never
    /// read — the shell "started" but no bytes ever reached the terminal.
    private func innerIOLoopDidExit() {
        innerIOTask = nil
        // A cancelled task means `stopInnerIOLoop()` ran (teardown) — do
        // not resurrect the loop during cleanup.
        guard !Task.isCancelled else { return }
        guard innerLibssh2Session != nil, !hasBeenCleaned else { return }
        let hasInnerChannels = shellChannels.values.contains { $0.isInner }
        let hasInnerExec = execRequests.values.contains { $0.isInner }
        if Self.shouldRestartInnerIOLoop(
            hasInnerChannels: hasInnerChannels,
            hasInnerExec: hasInnerExec
        ) {
            startInnerIOLoop()
        }
    }

    /// Pure restart decision extracted from `innerIOLoopDidExit()` so it can
    /// be unit-tested without a live libssh2 session. The loop must restart
    /// when any inner shell channel or inner exec request is still pending
    /// at the moment the previous loop exited.
    nonisolated static func shouldRestartInnerIOLoop(
        hasInnerChannels: Bool,
        hasInnerExec: Bool
    ) -> Bool {
        hasInnerChannels || hasInnerExec
    }

    private func stopInnerIOLoop() {
        innerIOTask?.cancel()
        innerIOTask = nil
    }

    /// Drain inner (target-node) shell channels. Mirrors `ioLoop` but polls
    /// the inner socketpair FD and reads only channels with `isInner == true`.
    private func innerIOLoop() async {
        var buffer = [CChar](repeating: 0, count: 32768)
        let batchThreshold = 65536
        let interactiveDelay: UInt64 = 1_000_000
        let bulkDelay: UInt64 = 5_000_000
        let interactiveThreshold = 100
        let bulkThreshold = 1000

        while !Task.isCancelled, innerLibssh2Session != nil {
            var didWork = false

            let innerStates = shellChannels.values.filter { $0.isInner }
            for state in innerStates {
                let bytesRead = libssh2_channel_read_ex(state.channel, 0, &buffer, buffer.count)
                if bytesRead > 0 {
                    if !state.didRecordFirstByte {
                        state.didRecordFirstByte = true
                        startupTrace?.recordOnce(.firstTerminalByte, detail: "ssh-teleport")
                    }
                    let readCount = Int(bytesRead)
                    state.batchBuffer.append(Data(bytes: buffer, count: readCount))
                    didWork = true
                    state.recentBytesPerRead = (state.recentBytesPerRead * 7 + readCount * 3) / 10
                    let maxBatchDelay: UInt64
                    if state.recentBytesPerRead < interactiveThreshold {
                        maxBatchDelay = interactiveDelay
                    } else if state.recentBytesPerRead > bulkThreshold {
                        maxBatchDelay = bulkDelay
                    } else {
                        let ratio = UInt64(state.recentBytesPerRead - interactiveThreshold) * 100 / UInt64(bulkThreshold - interactiveThreshold)
                        maxBatchDelay = interactiveDelay + (bulkDelay - interactiveDelay) * ratio / 100
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    let timeSinceYield = now - state.lastYieldTime
                    if state.batchBuffer.count >= batchThreshold || timeSinceYield >= maxBatchDelay {
                        state.continuation.yield(state.batchBuffer)
                        state.batchBuffer = Data()
                        state.lastYieldTime = now
                    }
                } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                    if !state.batchBuffer.isEmpty {
                        state.continuation.yield(state.batchBuffer)
                        state.batchBuffer = Data()
                        state.lastYieldTime = DispatchTime.now().uptimeNanoseconds
                    }
                    state.recentBytesPerRead = 0
                } else if bytesRead < 0 {
                    if !state.batchBuffer.isEmpty {
                        state.continuation.yield(state.batchBuffer)
                    }
                    logger.error("Inner read error: \(bytesRead)")
                    closeShellInternal(state.id)
                    didWork = true
                    continue
                }

                if libssh2_channel_eof(state.channel) != 0 {
                    if !state.batchBuffer.isEmpty {
                        state.continuation.yield(state.batchBuffer)
                    }
                    logger.info("Inner channel EOF")
                    closeShellInternal(state.id)
                    didWork = true
                }
            }

            let hasInnerChannels = shellChannels.values.contains { $0.isInner }
            // Drain inner exec requests. Mirrors the exec draining in the
            // outer `ioLoop`, but opens/reads the channel on the inner
            // (target-node) libssh2 session. The outer loop skips requests
            // with `isInner == true`, so they are only drained here.
            let hasInnerExec = execRequests.values.contains { $0.isInner }
            if hasInnerExec {
                let requestIds = Array(execRequests.keys)
                for requestId in requestIds {
                    guard let request = execRequests[requestId] else { continue }
                    guard request.isInner else { continue }
                    guard ensureInnerExecChannelReady(request) else { continue }

                    guard let execChannel = request.channel else { continue }

                    let bytesRead = libssh2_channel_read_ex(execChannel, 0, &buffer, buffer.count)
                    if bytesRead > 0 {
                        request.output.append(Data(bytes: buffer, count: Int(bytesRead)))
                        didWork = true
                    } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No data yet
                    } else if bytesRead < 0 {
                        finishExecRequest(requestId, error: SSHError.socketError("Inner exec read failed: \(bytesRead)"))
                        continue
                    }

                    let stderrRead = libssh2_channel_read_ex(execChannel, 1, &buffer, buffer.count)
                    if stderrRead > 0 {
                        request.stderr.append(Data(bytes: buffer, count: Int(stderrRead)))
                        didWork = true
                    } else if stderrRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No stderr data yet
                    } else if stderrRead < 0 {
                        finishExecRequest(requestId, error: SSHError.socketError("Inner exec stderr read failed: \(stderrRead)"))
                        continue
                    }

                    if let currentChannel = request.channel, libssh2_channel_eof(currentChannel) != 0 {
                        finishExecRequest(requestId, error: nil)
                        didWork = true
                    }
                }
            }
            if !hasInnerChannels, !execRequests.values.contains(where: { $0.isInner }) {
                break
            }

            if !didWork {
                await waitForInnerSocket()
            }
            await Task.yield()
        }
    }

    private func validateShellStartup(session: OpaquePointer) throws {
        try Task.checkCancellation()
        guard isActive,
              !hasBeenCleaned,
              let currentSession = libssh2Session,
              currentSession == session,
              socket >= 0,
              atomicSocket.isUsable else {
            throw SSHError.notConnected
        }
    }

    private func waitForShellStartupRetry(session: OpaquePointer) async throws {
        try validateShellStartup(session: session)
        await waitForSocket()
        await Task.yield()
        try validateShellStartup(session: session)
    }

    private func openShellStartupChannel(session: OpaquePointer) async throws -> OpaquePointer {
        while true {
            try validateShellStartup(session: session)
            if let channel = libssh2_channel_open_ex(
                session,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32768,
                nil,
                0
            ) {
                return channel
            }

            let error = libssh2_session_last_errno(session)
            guard error == LIBSSH2_ERROR_EAGAIN else {
                throw SSHError.channelOpenFailed
            }
            #if DEBUG
            notifyShellStartupTestHook(.channelOpenRetry, session: session)
            #endif
            do {
                try await waitForShellStartupRetry(session: session)
            } catch {
                invalidateTransport()
                await drainAbortedChannelOpen(session: session)
                throw error
            }
        }
    }

    private func performShellStartupCall(
        session: OpaquePointer,
        operation: () -> Int32
    ) async throws -> Int32 {
        while true {
            try validateShellStartup(session: session)
            let result = operation()
            if result != LIBSSH2_ERROR_EAGAIN {
                try validateShellStartup(session: session)
                return result
            }
            do {
                try await waitForShellStartupRetry(session: session)
            } catch {
                invalidateTransport()
                await drainAbortedShellStartupCall(operation)
                throw error
            }
        }
    }

    private func drainAbortedChannelOpen(session: OpaquePointer) async {
        for _ in 0..<1_024 {
            if libssh2_channel_open_ex(
                session,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32768,
                nil,
                0
            ) != nil || libssh2_session_last_errno(session) != LIBSSH2_ERROR_EAGAIN {
                return
            }
            await Task.yield()
        }
        logger.error("Unable to drain aborted libssh2 channel-open operation")
    }

    private func drainAbortedShellStartupCall(_ operation: () -> Int32) async {
        for _ in 0..<1_024 {
            if operation() != LIBSSH2_ERROR_EAGAIN {
                return
            }
            await Task.yield()
        }
        logger.error("Unable to drain aborted libssh2 shell-startup operation")
    }

    private func discardShellStartupChannel(
        _ channel: OpaquePointer,
        session: OpaquePointer
    ) async -> Bool {
        let closeResult = await completeActiveChannelCleanupCall(session: session) {
            libssh2_channel_close(channel)
        }
        guard closeResult == 0 else { return false }

        let freeResult = await completeActiveChannelCleanupCall(session: session) {
            libssh2_channel_free(channel)
        }
        return freeResult == 0
    }

    private func completeActiveChannelCleanupCall(
        session: OpaquePointer,
        operation: () -> Int32
    ) async -> Int32 {
        for _ in 0..<1_024 {
            guard isActive,
                  let currentSession = libssh2Session,
                  currentSession == session,
                  socket >= 0,
                  atomicSocket.isUsable else {
                return -1
            }

            let result = operation()
            if result != LIBSSH2_ERROR_EAGAIN {
                return result
            }
            await waitForSocket()
            await Task.yield()
        }
        return LIBSSH2_ERROR_EAGAIN
    }

    private func startIOLoop() {
        guard ioTask == nil else { return }
        ioTask = Task { [weak self] in
            await self?.ioLoop()
        }
    }

    private func stopIOLoop() {
        ioTask?.cancel()
        ioTask = nil
    }

    private func ioLoop() async {
        var buffer = [CChar](repeating: 0, count: 32768)
        let batchThreshold = 65536  // 64KB batch threshold

        // Adaptive batch delay: track data rate to switch between interactive and bulk modes
        // Interactive mode (keystrokes): 1ms delay for minimum latency
        // Bulk mode (command output): 5ms delay for better throughput
        let interactiveDelay: UInt64 = 1_000_000   // 1ms
        let bulkDelay: UInt64 = 5_000_000          // 5ms
        let interactiveThreshold = 100             // bytes - below this is interactive
        let bulkThreshold = 1000                   // bytes - above this is bulk

        while !Task.isCancelled, libssh2Session != nil {
            var didWork = false

            if !shellChannels.isEmpty {
                let states = Array(shellChannels.values)
                for state in states {
                    // Inner (Teleport proxy-subsystem) channels are drained by
                    // `innerIOLoop`, which polls the inner socketpair FD.
                    // The outer loop must not read them — doing so would race
                    // the inner loop for the same channel and double-yield.
                    if state.isInner { continue }
                    // Use _ex variant since macros not available in Swift (stream_id 0 = stdout)
                    let bytesRead = libssh2_channel_read_ex(state.channel, 0, &buffer, buffer.count)

                    if bytesRead > 0 {
                        if !state.didRecordFirstByte {
                            state.didRecordFirstByte = true
                            startupTrace?.recordOnce(.firstTerminalByte, detail: "ssh")
                        }
                        let readCount = Int(bytesRead)
                        state.batchBuffer.append(Data(bytes: buffer, count: readCount))
                        didWork = true

                        // Update exponential moving average (alpha = 0.3 for quick adaptation)
                        state.recentBytesPerRead = (state.recentBytesPerRead * 7 + readCount * 3) / 10

                        // Adaptive delay based on data rate
                        let maxBatchDelay: UInt64
                        if state.recentBytesPerRead < interactiveThreshold {
                            maxBatchDelay = interactiveDelay  // Fast for keystrokes
                        } else if state.recentBytesPerRead > bulkThreshold {
                            maxBatchDelay = bulkDelay         // Slower for bulk data
                        } else {
                            // Linear interpolation between modes
                            let ratio = UInt64(state.recentBytesPerRead - interactiveThreshold) * 100 / UInt64(bulkThreshold - interactiveThreshold)
                            maxBatchDelay = interactiveDelay + (bulkDelay - interactiveDelay) * ratio / 100
                        }

                        // Yield batch when threshold reached or enough time passed
                        let now = DispatchTime.now().uptimeNanoseconds
                        let timeSinceYield = now - state.lastYieldTime

                        if state.batchBuffer.count >= batchThreshold || timeSinceYield >= maxBatchDelay {
                            state.continuation.yield(state.batchBuffer)
                            state.batchBuffer = Data()
                            state.lastYieldTime = now
                        }
                    } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // Flush any pending data before waiting
                        if !state.batchBuffer.isEmpty {
                            state.continuation.yield(state.batchBuffer)
                            state.batchBuffer = Data()
                            state.lastYieldTime = DispatchTime.now().uptimeNanoseconds
                        }
                        // Reset to interactive mode when idle (waiting for input)
                        state.recentBytesPerRead = 0
                    } else if bytesRead < 0 {
                        // Error - flush remaining data first
                        if !state.batchBuffer.isEmpty {
                            state.continuation.yield(state.batchBuffer)
                        }
                        logger.error("Read error: \(bytesRead)")
                        closeShellInternal(state.id)
                        continue
                    }

                    // Check for EOF
                    if libssh2_channel_eof(state.channel) != 0 {
                        if !state.batchBuffer.isEmpty {
                            state.continuation.yield(state.batchBuffer)
                        }
                        logger.info("Channel EOF")
                        closeShellInternal(state.id)
                        didWork = true
                    }
                }
            }

            if !execRequests.isEmpty {
                let requestIds = Array(execRequests.keys)
                for requestId in requestIds {
                    guard let request = execRequests[requestId] else { continue }
                    // Inner (Teleport proxy-subsystem) exec requests are
                    // drained by `innerIOLoop`, which polls the inner
                    // socketpair FD. The outer loop must not touch them —
                    // doing so would open/read the channel on the outer
                    // (proxy) session and fail with -22.
                    if request.isInner { continue }
                    guard ensureExecChannelReady(request) else { continue }

                    guard let execChannel = request.channel else { continue }

                    let bytesRead = libssh2_channel_read_ex(execChannel, 0, &buffer, buffer.count)
                    if bytesRead > 0 {
                        request.output.append(Data(bytes: buffer, count: Int(bytesRead)))
                        didWork = true
                    } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No data yet
                    } else if bytesRead < 0 {
                        finishExecRequest(requestId, error: SSHError.socketError("Exec read failed: \(bytesRead)"))
                        continue
                    }

                    let stderrRead = libssh2_channel_read_ex(execChannel, 1, &buffer, buffer.count)
                    if stderrRead > 0 {
                        request.stderr.append(Data(bytes: buffer, count: Int(stderrRead)))
                        didWork = true
                    } else if stderrRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No stderr data yet
                    } else if stderrRead < 0 {
                        finishExecRequest(requestId, error: SSHError.socketError("Exec stderr read failed: \(stderrRead)"))
                        continue
                    }

                    if let currentChannel = request.channel, libssh2_channel_eof(currentChannel) != 0 {
                        finishExecRequest(requestId, error: nil)
                        didWork = true
                    }
                }
            }

            // Exit the outer loop when there are no outer shell channels
            // AND no outer exec requests. Inner (Teleport) shell/exec
            // requests are tracked in the same dictionaries but drained by
            // `innerIOLoop`; they must not keep the outer loop alive (it
            // would spin on `waitForSocket` with no work to do).
            let hasOuterShell = shellChannels.values.contains { !$0.isInner }
            let hasOuterExec = execRequests.values.contains { !$0.isInner }
            if !hasOuterShell, !hasOuterExec {
                break
            }

            if !didWork {
                await waitForSocket()
            }

            // Always yield to prevent starving other tasks (especially important during rapid typing)
            // This ensures write operations and UI updates get CPU time
            await Task.yield()
        }

        closeAllShellChannels()
        stopIOLoop()
    }

    func closeShell(_ shellId: UUID) async {
        closeShellInternal(shellId)
    }

    private func closeShellInternal(_ shellId: UUID) {
        guard let state = shellChannels.removeValue(forKey: shellId) else { return }
        if !state.batchBuffer.isEmpty {
            state.continuation.yield(state.batchBuffer)
        }
        libssh2_channel_close(state.channel)
        libssh2_channel_free(state.channel)
        state.continuation.finish()
    }

    private func closeAllShellChannels() {
        let states = shellChannels
        shellChannels.removeAll()
        for state in states.values {
            if !state.batchBuffer.isEmpty {
                state.continuation.yield(state.batchBuffer)
            }
            libssh2_channel_close(state.channel)
            libssh2_channel_free(state.channel)
            state.continuation.finish()
        }
    }

    private func abandonAllShellChannels() {
        let states = shellChannels
        shellChannels.removeAll()
        for state in states.values {
            if !state.batchBuffer.isEmpty {
                state.continuation.yield(state.batchBuffer)
            }
            state.continuation.finish()
        }
    }

    private func failAllExecRequests(error: Error) {
        let requests = execRequests
        execRequests.removeAll()
        for request in requests.values {
            request.channel = nil
            request.continuation.resume(throwing: error)
        }
    }

    private func ensureExecChannelReady(_ request: ExecRequest) -> Bool {
        guard let session = libssh2Session else {
            finishExecRequest(request.id, error: SSHError.notConnected)
            return false
        }

        if request.channel == nil {
            let newChannel = libssh2_channel_open_ex(
                session,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32768,
                nil,
                0
            )
            if let newChannel = newChannel {
                request.channel = newChannel
            } else {
                let lastError = libssh2_session_last_errno(session)
                if lastError == LIBSSH2_ERROR_EAGAIN {
                    return false
                }
                finishExecRequest(request.id, error: SSHError.channelOpenFailed)
                return false
            }
        }

        if !request.isStarted, let execChannel = request.channel {
            let execResult = libssh2_channel_process_startup(
                execChannel,
                "exec",
                4,
                request.command,
                UInt32(request.command.utf8.count)
            )
            if execResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                return false
            }
            if execResult != 0 {
                finishExecRequest(request.id, error: SSHError.unknown("Exec failed: \(execResult)"))
                return false
            }
            request.isStarted = true
        }

        return true
    }

    /// Mirror of `ensureExecChannelReady` for the inner (target-node) libssh2
    /// session. Opens a `session` channel on `innerLibssh2Session` and
    /// requests `exec` on it. The inner session is non-blocking, so
    /// EAGAIN retries are handled by the next `innerIOLoop` pass (which
    /// re-enties this via the per-request guard). Returns `false` (without
    /// failing the request) on EAGAIN so the loop retries; returns `false`
    /// (failing the request) on a hard error.
    private func ensureInnerExecChannelReady(_ request: ExecRequest) -> Bool {
        guard let session = innerLibssh2Session,
              innerSocket >= 0,
              innerAtomicSocket.isUsable,
              !hasBeenCleaned else {
            finishExecRequest(request.id, error: SSHError.notConnected)
            return false
        }

        if request.channel == nil {
            let newChannel = libssh2_channel_open_ex(
                session,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32768,
                nil,
                0
            )
            if let newChannel = newChannel {
                request.channel = newChannel
            } else {
                let lastError = libssh2_session_last_errno(session)
                if lastError == LIBSSH2_ERROR_EAGAIN {
                    return false
                }
                finishExecRequest(request.id, error: SSHError.channelOpenFailed)
                return false
            }
        }

        if !request.isStarted, let execChannel = request.channel {
            let execResult = libssh2_channel_process_startup(
                execChannel,
                "exec",
                4,
                request.command,
                UInt32(request.command.utf8.count)
            )
            if execResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                return false
            }
            if execResult != 0 {
                finishExecRequest(request.id, error: SSHError.unknown("Inner exec failed: \(execResult)"))
                return false
            }
            request.isStarted = true
        }

        return true
    }

    private func cancelExecRequest(_ requestId: UUID, error: Error) {
        guard execRequests[requestId] != nil else { return }
        finishExecRequest(requestId, error: error)
    }

    private func finishExecRequest(_ requestId: UUID, error: Error?) {
        guard let request = execRequests.removeValue(forKey: requestId) else { return }

        if let channel = request.channel {
            libssh2_channel_close(channel)
            libssh2_channel_free(channel)
            request.channel = nil
        }

        if let error = error {
            request.continuation.resume(throwing: error)
        } else {
            if !request.stderr.isEmpty,
               let stderr = String(data: request.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !stderr.isEmpty {
                logger.debug("Exec command stderr: \(stderr, privacy: .public)")
            }
            let output = String(data: request.output, encoding: .utf8) ?? ""
            request.continuation.resume(returning: output)
        }
    }

    private func waitForSocket() async {
        guard let session = libssh2Session, socket >= 0 else { return }

        let direction = libssh2_session_block_directions(session)
        guard direction != 0 else { return }

        // Use poll() for reliable, low-overhead socket waiting
        // This is simpler and more reliable than DispatchSource for this use case
        var pfd = pollfd()
        pfd.fd = socket
        pfd.events = 0

        if direction & LIBSSH2_SESSION_BLOCK_INBOUND != 0 {
            pfd.events |= Int16(POLLIN)
        }
        if direction & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            pfd.events |= Int16(POLLOUT)
        }

        // Poll with 5ms timeout - short enough for responsiveness, long enough to avoid busy spinning
        _ = poll(&pfd, 1, 5)
    }

    /// Wait for the SFTP session's backing socket to become readable/writable.
    /// SFTP operations retry on EAGAIN; the socket they must wait on depends
    /// on which libssh2 session the SFTP handle is bound to: the inner
    /// socketpair FD for the Teleport proxy-subsystem path
    /// (`sftpSessionIsInner == true`), the outer socket for the direct path.
    /// Waiting on the wrong FD would either hang (inner FD never sees the
    /// outer socket's traffic) or spin busily (outer socket is always
    /// ready, but the inner session is still EAGAIN).
    private func waitForSFTPSocket() async {
        if sftpSessionIsInner {
            await waitForInnerSocket()
        } else {
            await waitForSocket()
        }
    }

    private func resolveNumericPeerAddress(for socket: Int32) -> String? {
        var storage = sockaddr_storage()
        var storageLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

        let peerResult = withUnsafeMutablePointer(to: &storage) { storagePtr in
            storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getpeername(socket, sockaddrPtr, &storageLen)
            }
        }
        guard peerResult == 0 else { return nil }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let nameResult = withUnsafePointer(to: &storage) { storagePtr in
            storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getnameinfo(
                    sockaddrPtr,
                    storageLen,
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }
        guard nameResult == 0 else { return nil }
        return String(cString: hostBuffer)
    }

    // MARK: - Write

    func write(_ data: Data, to shellId: UUID) async throws {
        guard let state = shellChannels[shellId] else {
            throw SSHError.notConnected
        }

        // Copy data to array for async-safe access (withUnsafeBytes doesn't support async)
        var bytes = [UInt8](data)
        var remaining = bytes.count
        var offset = 0

        while remaining > 0 {
            // Use _ex variant since macros not available in Swift (stream_id 0 = stdin)
            let written = bytes.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let ptr = buffer.baseAddress else { return -1 }
                return Int(libssh2_channel_write_ex(
                    state.channel, 0,
                    UnsafeRawPointer(ptr.advanced(by: offset)).assumingMemoryBound(to: CChar.self),
                    remaining
                ))
            }

            if written > 0 {
                offset += written
                remaining -= written
            } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                // Would block - actually wait for socket to be ready
                await waitForSocket()
            } else {
                throw SSHError.socketError("Write failed: \(written)")
            }
        }
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        // Teleport's outer session is the PROXY, which rejects SCP channel
        // opens and exec channel requests with -22. SCP and exec uploads
        // would both fail on the outer session. Route uploads through the
        // SFTP `writeFile` path instead — SFTP runs on the INNER (target-
        // node) session for Teleport (see `ensureSFTPSession`), so the
        // upload succeeds there. Non-Teleport auth methods keep the existing
        // SCP-then-exec strategy (faster than SFTP for large uploads).
        let routeToInner = Self.shouldRouteSFTPToInnerSession(
            authMethod: config.authMethod,
            innerSessionReady: innerLibssh2Session != nil
        )
        if routeToInner {
            logger.info("Using SFTP upload for Teleport inner session [path: \(remotePath, privacy: .public)]")
            try await writeFile(data, to: remotePath, permissions: permissions)
            return
        }

        if strategy == .execPreferred {
            logger.info("Using exec-preferred upload strategy [path: \(remotePath, privacy: .public)]")
            try await uploadViaExec(data, to: remotePath)
            return
        }

        do {
            logger.info("Trying SCP upload [path: \(remotePath, privacy: .public)]")
            try await uploadViaSCP(data, to: remotePath, permissions: permissions)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("SCP upload failed, retrying with exec channel: \(error.localizedDescription, privacy: .public)")
            try await uploadViaExec(data, to: remotePath)
        }
    }

    private func uploadViaSCP(_ data: Data, to remotePath: String, permissions: Int32) async throws {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }
        guard !remotePath.isEmpty else {
            throw SSHError.unknown("Upload path is empty")
        }
        logger.info("Opening SCP upload channel [path: \(remotePath, privacy: .public)]")

        var scpChannel: OpaquePointer?
        do {
            while scpChannel == nil {
                try Task.checkCancellation()
                scpChannel = remotePath.withCString { pathPtr in
                    libssh2_scp_send64(
                        session,
                        pathPtr,
                        permissions,
                        Int64(data.count),
                        0,
                        0
                    )
                }

                if scpChannel != nil {
                    break
                }

                let lastError = libssh2_session_last_errno(session)
                if lastError == LIBSSH2_ERROR_EAGAIN {
                    await waitForSocket()
                    continue
                }
                throw SSHError.socketError("SCP channel open failed: \(lastError)")
            }

            guard let scpChannel else {
                throw SSHError.socketError("SCP channel open failed")
            }

            let bytes = [UInt8](data)
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                    guard let baseAddress = buffer.baseAddress else { return -1 }
                    let pointer = UnsafeRawPointer(baseAddress.advanced(by: offset)).assumingMemoryBound(to: CChar.self)
                    return Int(libssh2_channel_write_ex(scpChannel, 0, pointer, bytes.count - offset))
                }

                if written > 0 {
                    offset += written
                } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                    await waitForSocket()
                } else {
                    throw SSHError.socketError("SCP write failed: \(written)")
                }
            }

            _ = try await finishUploadChannel(scpChannel)
            logger.info("SCP upload finished [path: \(remotePath, privacy: .public)]")
        } catch {
            if let scpChannel {
                libssh2_channel_close(scpChannel)
                libssh2_channel_free(scpChannel)
            }
            throw error
        }
    }

    private func uploadViaExec(_ data: Data, to remotePath: String) async throws {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }
        guard !remotePath.isEmpty else {
            throw SSHError.unknown("Upload path is empty")
        }
        logger.info("Opening exec upload channel [path: \(remotePath, privacy: .public)]")

        let command = "cat > \(RemoteTerminalBootstrap.shellQuoted(remotePath))"

        var execChannel: OpaquePointer?
        do {
            while execChannel == nil {
                try Task.checkCancellation()
                execChannel = libssh2_channel_open_ex(
                    session,
                    "session",
                    UInt32("session".utf8.count),
                    2 * 1024 * 1024,
                    32768,
                    nil,
                    0
                )

                if execChannel != nil {
                    break
                }

                let lastError = libssh2_session_last_errno(session)
                if lastError == LIBSSH2_ERROR_EAGAIN {
                    await waitForSocket()
                    continue
                }
                throw SSHError.socketError("Exec upload channel open failed: \(lastError)")
            }

            guard let execChannel else {
                throw SSHError.socketError("Exec upload channel open failed")
            }

            _ = libssh2_channel_handle_extended_data2(
                execChannel,
                LIBSSH2_CHANNEL_EXTENDED_DATA_IGNORE
            )

            while true {
                try Task.checkCancellation()
                let execResult = libssh2_channel_process_startup(
                    execChannel,
                    "exec",
                    4,
                    command,
                    UInt32(command.utf8.count)
                )
                if execResult == 0 {
                    break
                }
                if execResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                    await waitForSocket()
                    continue
                }
                throw SSHError.socketError("Exec upload startup failed: \(execResult)")
            }

            let bytes = [UInt8](data)
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                    guard let baseAddress = buffer.baseAddress else { return -1 }
                    let pointer = UnsafeRawPointer(baseAddress.advanced(by: offset)).assumingMemoryBound(to: CChar.self)
                    return Int(libssh2_channel_write_ex(execChannel, 0, pointer, bytes.count - offset))
                }

                if written > 0 {
                    offset += written
                } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                    await waitForSocket()
                } else {
                    throw SSHError.socketError("Exec upload write failed: \(written)")
                }
            }

            let exitStatus = try await finishUploadChannel(execChannel, drainOutput: true)
            guard exitStatus == 0 else {
                throw SSHError.socketError("Exec upload failed with exit status \(exitStatus)")
            }
            logger.info("Exec upload finished [path: \(remotePath, privacy: .public)]")
        } catch {
            if let execChannel {
                libssh2_channel_close(execChannel)
                libssh2_channel_free(execChannel)
            }
            throw error
        }
    }

    private func finishUploadChannel(
        _ channel: OpaquePointer,
        drainOutput: Bool = false
    ) async throws -> Int32 {
        while true {
            try Task.checkCancellation()
            let sendEOFResult = libssh2_channel_send_eof(channel)
            if sendEOFResult == 0 {
                break
            }
            if sendEOFResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            throw SSHError.socketError("SCP send EOF failed: \(sendEOFResult)")
        }

        while true {
            try Task.checkCancellation()
            if drainOutput {
                try await drainChannelOutput(channel)
            }
            let waitEOFResult = libssh2_channel_wait_eof(channel)
            if waitEOFResult == 0 {
                break
            }
            if waitEOFResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            throw SSHError.socketError("SCP wait EOF failed: \(waitEOFResult)")
        }

        while true {
            try Task.checkCancellation()
            let closeResult = libssh2_channel_close(channel)
            if closeResult == 0 {
                break
            }
            if closeResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            throw SSHError.socketError("SCP close failed: \(closeResult)")
        }

        while true {
            try Task.checkCancellation()
            let waitClosedResult = libssh2_channel_wait_closed(channel)
            if waitClosedResult == 0 {
                break
            }
            if waitClosedResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            throw SSHError.socketError("SCP wait close failed: \(waitClosedResult)")
        }

        let exitStatus = libssh2_channel_get_exit_status(channel)
        libssh2_channel_free(channel)
        return exitStatus
    }

    private func drainChannelOutput(_ channel: OpaquePointer) async throws {
        var buffer = [CChar](repeating: 0, count: 4096)

        while true {
            try Task.checkCancellation()
            let stdoutRead = libssh2_channel_read_ex(channel, 0, &buffer, buffer.count)
            if stdoutRead > 0 {
                continue
            }
            if stdoutRead == Int(LIBSSH2_ERROR_EAGAIN) || stdoutRead == 0 {
                break
            }
            throw SSHError.socketError("Exec upload stdout drain failed: \(stdoutRead)")
        }

        while true {
            try Task.checkCancellation()
            let stderrRead = libssh2_channel_read_ex(channel, 1, &buffer, buffer.count)
            if stderrRead > 0 {
                continue
            }
            if stderrRead == Int(LIBSSH2_ERROR_EAGAIN) || stderrRead == 0 {
                break
            }
            throw SSHError.socketError("Exec upload stderr drain failed: \(stderrRead)")
        }
    }

    // MARK: - Resize

    func resize(
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize? = nil,
        for shellId: UUID
    ) async throws {
        guard let state = shellChannels[shellId] else {
            throw SSHError.notConnected
        }
        guard let wireCols = Int32(exactly: cols),
              let wireRows = Int32(exactly: rows) else {
            throw SSHError.unknown("Invalid terminal size \(cols)x\(rows)")
        }

        // Use _ex variant since macros not available in Swift. The SSH session
        // is nonblocking, so an EAGAIN result has not transmitted the resize.
        while true {
            try Task.checkCancellation()
            let result = libssh2_channel_request_pty_size_ex(
                state.channel,
                wireCols,
                wireRows,
                Int32(pixelSize?.width ?? 0),
                Int32(pixelSize?.height ?? 0)
            )
            if result == 0 {
                return
            }
            if result == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            logger.warning("PTY resize failed: \(result)")
            return
        }
    }

    // MARK: - Execute Command

    func execute(_ command: String) async throws -> String {
        // Teleport's outer session is the PROXY — it rejects exec/pty/shell
        // with LIBSSH2_ERROR_CHANNEL_REQUEST_FAILURE (-22). Route exec to
        // the inner (target-node) session when one exists. The inner session
        // is created inside `startShellViaTeleportProxy` (second handshake
        // over the `proxy:<node>:0` subsystem tunnel); before the shell
        // starts it is nil, so we surface `notConnected` and the caller
        // (stats collector) skips gracefully.
        let routeToInner = Self.shouldRouteExecToInnerSession(
            authMethod: config.authMethod,
            innerSessionReady: innerLibssh2Session != nil
        )
        if routeToInner {
            guard let inner = innerLibssh2Session,
                  innerSocket >= 0,
                  innerAtomicSocket.isUsable,
                  !hasBeenCleaned else {
                throw SSHError.notConnected
            }
            startInnerIOLoopIfNeeded()
            return try await enqueueExecRequest(command, isInner: true)
        }

        // Safety net: Teleport-without-inner must NEVER exec on the outer
        // proxy session — it would fail with -22 and poison the outer
        // session state so the subsequent subsystem request also fails.
        // Callers that want exec for a Teleport connection must first
        // establish the inner session via `prepareTeleportInnerSession()`
        // (or `SSHClient.remoteEnvironment()`, which does it automatically).
        if Self.shouldRejectExecOnOuterSession(
            authMethod: config.authMethod,
            innerSessionReady: innerLibssh2Session != nil
        ) {
            throw SSHError.notConnected
        }

        guard libssh2Session != nil else {
            throw SSHError.notConnected
        }
        startIOLoop()
        return try await enqueueExecRequest(command, isInner: false)
    }

    /// Pure routing decision extracted from `execute()` so it can be unit-
    /// tested without a live libssh2 session. Returns `true` only for the
    /// Teleport auth method AND when the inner (target-node) session is
    /// ready (non-nil). For every other combination the outer path is
    /// used.
    nonisolated static func shouldRouteExecToInnerSession(
        authMethod: AuthMethod,
        innerSessionReady: Bool
    ) -> Bool {
        authMethod == .faceIDTeleport && innerSessionReady
    }

    /// Pure safety-net decision extracted from `execute()` so it can be unit-
    /// tested without a live libssh2 session. Returns `true` ONLY for the
    /// Teleport auth method AND when the inner (target-node) session is NOT
    /// ready — exec must be rejected in this case rather than falling through
    /// to the outer PROXY session, which rejects exec with -22 and poisons
    /// the outer session state so the subsequent subsystem request also
    /// fails.
    ///
    /// For non-Teleport (outer session supports exec directly) and for
    /// Teleport-with-ready-inner (exec routes to the inner session via
    /// `shouldRouteExecToInnerSession`), returns `false`.
    nonisolated static func shouldRejectExecOnOuterSession(
        authMethod: AuthMethod,
        innerSessionReady: Bool
    ) -> Bool {
        authMethod == .faceIDTeleport && !innerSessionReady
    }

    /// Pure routing decision extracted from `ensureSFTPSession()` so it can
    /// be unit-tested without a live libssh2 session. Returns `true` only
    /// for the Teleport auth method AND when the inner (target-node)
    /// session is ready (non-nil). For every other combination the outer
    /// path is used.
    ///
    /// Teleport's outer session is the PROXY, which rejects the SFTP
    /// subsystem request (`libssh2_sftp_init` on the outer session fails
    /// with LIBSSH2_ERROR_CHANNEL_REQUEST_FAILURE, -22) because the proxy
    /// is in `proxyMode` and only accepts the `proxy:<node>:0` subsystem.
    /// SFTP must run on the INNER (target-node) session, established by
    /// `prepareTeleportInnerSession()` (second handshake over the
    /// `proxy:<node>:0` subsystem tunnel).
    nonisolated static func shouldRouteSFTPToInnerSession(
        authMethod: AuthMethod,
        innerSessionReady: Bool
    ) -> Bool {
        authMethod == .faceIDTeleport && innerSessionReady
    }

    /// Pure safety-net decision extracted from `ensureSFTPSession()` so it
    /// can be unit-tested without a live libssh2 session. Returns `true` ONLY
    /// for the Teleport auth method AND when the inner (target-node) session
    /// is NOT ready — SFTP init must be rejected in this case rather than
    /// falling through to the outer PROXY session, which rejects the SFTP
    /// subsystem request with -22 and poisons the outer session state so
    /// the subsequent subsystem request also fails.
    ///
    /// For non-Teleport (outer session supports SFTP directly) and for
    /// Teleport-with-ready-inner (SFTP routes to the inner session via
    /// `shouldRouteSFTPToInnerSession`), returns `false`.
    nonisolated static func shouldRejectSFTPOnOuterSession(
        authMethod: AuthMethod,
        innerSessionReady: Bool
    ) -> Bool {
        authMethod == .faceIDTeleport && !innerSessionReady
    }

    private func enqueueExecRequest(_ command: String, isInner: Bool) async throws -> String {
        let requestId = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let request = ExecRequest(id: requestId, command: command, continuation: continuation)
                request.isInner = isInner
                execRequests[request.id] = request
            }
        }, onCancel: { [weak self] in
            Task {
                await self?.cancelExecRequest(requestId, error: CancellationError())
            }
        })
    }

    /// Start the inner I/O loop if it is not already running. Called when an
    /// exec request is routed to the inner session without a shell channel
    /// already keeping the loop alive.
    private func startInnerIOLoopIfNeeded() {
        startInnerIOLoop()
    }

    // MARK: - Keep Alive

    func sendKeepAlive() {
        guard let session = libssh2Session else { return }
        var secondsToNext: Int32 = 0
        // Acquire the outer-session mutex: the Teleport proxy-subsystem pump
        // may be reading/writing the outer session's proxy channel off-actor
        // at this moment. Without the lock, `libssh2_keepalive_send` (->
        // `ssh2_transport_send`) races the pump's `ssh2_transport_read` /
        // `ssh2_transport_send` and corrupts the session transport buffer
        // (the `remainbuf >= 0` assertion). No-op when the pump isn't active
        // (non-Teleport path) — the lock is uncontended.
        outerSessionMutex.withLock {
            libssh2_keepalive_send(session, &secondsToNext)
        }
    }

    private func ensureSFTPSession() async throws -> OpaquePointer {
        if let sftpSession {
            return sftpSession
        }

        // Teleport's outer session is the PROXY, which is in `proxyMode` and
        // rejects the SFTP subsystem request with -22 (only the
        // `proxy:<node>:0` subsystem is accepted). SFTP must run on the INNER
        // (target-node) session, established by `prepareTeleportInnerSession()`.
        // When the inner session is not ready yet, surface a clear error instead
        // of attempting SFTP init on the outer session (which fails with the
        // opaque "Failed to start SFTP session" message).
        let routeToInner = Self.shouldRouteSFTPToInnerSession(
            authMethod: config.authMethod,
            innerSessionReady: innerLibssh2Session != nil
        )

        if routeToInner {
            guard let inner = innerLibssh2Session,
                  innerSocket >= 0,
                  innerAtomicSocket.isUsable,
                  !hasBeenCleaned else {
                throw RemoteFileBrowserError.failed(
                    String(localized: "The Teleport target node session is not ready for file browsing.")
                )
            }

            while true {
                try Task.checkCancellation()

                if let sftpSession = libssh2_sftp_init(inner) {
                    self.sftpSession = sftpSession
                    self.sftpSessionIsInner = true
                    return sftpSession
                }

                let lastError = libssh2_session_last_errno(inner)
                if lastError == LIBSSH2_ERROR_EAGAIN {
                    await waitForInnerSocket()
                    continue
                }

                throw Self.remoteFileError(from: nil, operation: "start SFTP session", path: nil)
            }
        }

        // Safety net: Teleport-without-inner must NEVER run SFTP on the
        // outer proxy session — `libssh2_sftp_init` on the PROXY fails with
        // -22 and poisons the outer session state so the subsequent
        // subsystem request also fails. Callers (the SFTP adapter already
        // calls `prepareTeleportInnerSession()` before SFTP init) should not
        // reach this branch, but guard defensively.
        if Self.shouldRejectSFTPOnOuterSession(
            authMethod: config.authMethod,
            innerSessionReady: innerLibssh2Session != nil
        ) {
            throw RemoteFileBrowserError.failed(
                String(localized: "The Teleport target node session is not ready for file browsing.")
            )
        }

        guard let session = libssh2Session else {
            throw RemoteFileBrowserError.disconnected
        }

        while true {
            try Task.checkCancellation()

            if let sftpSession = libssh2_sftp_init(session) {
                self.sftpSession = sftpSession
                self.sftpSessionIsInner = false
                return sftpSession
            }

            let lastError = libssh2_session_last_errno(session)
            if lastError == LIBSSH2_ERROR_EAGAIN {
                await waitForSocket()
                continue
            }

            throw Self.remoteFileError(from: nil, operation: "start SFTP session", path: nil)
        }
    }

    private func openDirectoryHandle(at path: String, sftp: OpaquePointer) async throws -> OpaquePointer {
        try await openSFTPHandle(
            at: path,
            sftp: sftp,
            flags: 0,
            mode: 0,
            openType: Int32(LIBSSH2_SFTP_OPENDIR),
            operation: "open directory"
        )
    }

    private func openFileHandle(
        at path: String,
        sftp: OpaquePointer,
        flags: UInt32,
        mode: Int32,
        operation: String = "open file"
    ) async throws -> OpaquePointer {
        try await openSFTPHandle(
            at: path,
            sftp: sftp,
            flags: flags,
            mode: mode,
            openType: Int32(LIBSSH2_SFTP_OPENFILE),
            operation: operation
        )
    }

    private func openSFTPHandle(
        at path: String,
        sftp: OpaquePointer,
        flags: UInt32,
        mode: Int32,
        openType: Int32,
        operation: String
    ) async throws -> OpaquePointer {
        // The libssh2 session that backs `sftp` — used for EAGAIN detection
        // via `libssh2_session_last_errno`. For Teleport this is the INNER
        // (target-node) session; for direct connections it is the outer
        // session. Picking the wrong one would misread the error code and
        // either hang (treating a real error as EAGAIN) or throw a misleading
        // error (treating EAGAIN as a hard failure).
        guard let session = sftpSessionIsInner ? innerLibssh2Session : libssh2Session else {
            throw RemoteFileBrowserError.disconnected
        }

        let pathLength = UInt32(path.utf8.count)
        while true {
            try Task.checkCancellation()

            if let handle = path.withCString({ pathPtr in
                libssh2_sftp_open_ex(
                    sftp,
                    pathPtr,
                    pathLength,
                    UInt(flags),
                    Int(mode),
                    Int32(openType)
                )
            }) {
                return handle
            }

            let lastError = libssh2_session_last_errno(session)
            if lastError == LIBSSH2_ERROR_EAGAIN {
                await waitForSFTPSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: operation, path: path)
        }
    }

    private func performSFTPMutation(
        at path: String,
        sftp: OpaquePointer,
        operation: String,
        mutation: (OpaquePointer, UnsafePointer<CChar>, UInt32) -> Int
    ) async throws {
        // The libssh2 session backing `sftp` (inner for Teleport, outer for
        // direct). `performSFTPMutation` does not itself read the errno, but
        // the nil-check gates the EAGAIN wait path: if the backing session
        // is gone there is nothing to wait on.
        let session = sftpSessionIsInner ? innerLibssh2Session : libssh2Session
        guard session != nil else {
            throw RemoteFileBrowserError.disconnected
        }

        let pathLength = UInt32(path.utf8.count)
        while true {
            try Task.checkCancellation()

            let result = path.withCString { pathPtr in
                mutation(sftp, pathPtr, pathLength)
            }

            if result == 0 {
                return
            }

            if result == Int(LIBSSH2_ERROR_EAGAIN) {
                await waitForSFTPSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: operation, path: path)
        }
    }

    private func stat(at path: String, statType: Int32) async throws -> RemoteFileEntry {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()

        while true {
            try Task.checkCancellation()

            let result = normalizedPath.withCString { pathPtr in
                libssh2_sftp_stat_ex(
                    sftp,
                    pathPtr,
                    UInt32(normalizedPath.utf8.count),
                    statType,
                    &attributes
                )
            }

            if result == 0 {
                let entryName = Self.fileName(for: normalizedPath)
                var symlinkTarget: String?
                let entry = RemoteFileEntry.from(name: entryName, path: normalizedPath, attributes: attributes)
                if statType == Int32(LIBSSH2_SFTP_LSTAT), entry.type == .symlink {
                    symlinkTarget = try? await readlink(at: normalizedPath)
                }
                return RemoteFileEntry.from(
                    name: entryName,
                    path: normalizedPath,
                    attributes: attributes,
                    symlinkTarget: symlinkTarget
                )
            }

            if result == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSFTPSocket()
                continue
            }

            throw Self.remoteFileError(
                from: sftp,
                operation: statType == Int32(LIBSSH2_SFTP_LSTAT) ? "lstat" : "stat",
                path: normalizedPath
            )
        }
    }

    private func readSymlinkTarget(
        at path: String,
        linkType: Int32,
        sftp: OpaquePointer
    ) async throws -> String {
        // The libssh2 session backing `sftp` (inner for Teleport, outer for
        // direct). `readSymlinkTarget` reads `libssh2_session_last_errno` to
        // distinguish EAGAIN from a hard failure, so it must consult the
        // session that actually owns the SFTP channel.
        guard let session = sftpSessionIsInner ? innerLibssh2Session : libssh2Session else {
            throw RemoteFileBrowserError.disconnected
        }

        let requestPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = requestPath.isEmpty ? "." : requestPath
        var buffer = [CChar](repeating: 0, count: 4096)

        while true {
            try Task.checkCancellation()

            let result = buffer.withUnsafeMutableBufferPointer { bufferPtr -> Int in
                guard let baseAddress = bufferPtr.baseAddress else {
                    return Int(LIBSSH2_ERROR_EAGAIN)
                }

                return normalizedPath.withCString { pathPtr in
                    Int(
                        libssh2_sftp_symlink_ex(
                            sftp,
                            pathPtr,
                            UInt32(normalizedPath.utf8.count),
                            baseAddress,
                            UInt32(bufferPtr.count),
                            linkType
                        )
                    )
                }
            }

            if result >= 0 {
                return Self.string(from: buffer, length: result)
            }

            let lastError = libssh2_session_last_errno(session)
            if lastError == LIBSSH2_ERROR_EAGAIN {
                await waitForSFTPSocket()
                continue
            }

            throw Self.remoteFileError(
                from: sftp,
                operation: linkType == Int32(LIBSSH2_SFTP_REALPATH) ? "resolve path" : "read link",
                path: normalizedPath
            )
        }
    }

    private static func fileName(for path: String) -> String {
        let normalized = RemoteFilePath.normalize(path)
        guard normalized != "/" else { return "/" }
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }

    private static func string(from buffer: [CChar], length: Int) -> String {
        let bytes = buffer.prefix(length).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Returns the algorithm libssh2 negotiated for the given method type after
    /// a successful handshake, or `"unknown"` if libssh2 could not report it.
    /// Used for diagnostics so future KEX mismatches surface the agreed value.
    nonisolated static func negotiatedMethod(_ session: OpaquePointer?, method: Int32) -> String {
        guard let session else { return "unknown" }
        guard let raw = libssh2_session_methods(session, method) else {
            return "unknown"
        }
        return String(cString: raw)
    }

    /// Apply a libssh2 method preference and log the result (0 = success).
    ///
    /// A non-zero return means libssh2 rejected the preference string (e.g.
    /// none of the listed algorithms are compiled in, or a name is
    /// misspelled). The caller does not abort on failure — libssh2 will fall
    /// back to its built-in defaults — but the log surfaces the rejection so a
    /// KEX mismatch is not misdiagnosed as a server problem.
    private func applyMethodPref(
        _ session: OpaquePointer,
        method: Int32,
        prefs: String,
        label: String
    ) {
        let rc = prefs.withCString { libssh2_session_method_pref(session, method, $0) }
        if rc == 0 {
            logger.info("ssh_method_pref_ok label=\(label, privacy: .public) rc=\(rc)")
        } else {
            var errmsg: UnsafeMutablePointer<CChar>?
            var errmsgLen: Int32 = 0
            libssh2_session_last_error(session, &errmsg, &errmsgLen, 0)
            let errorMsg = errmsg != nil ? String(cString: errmsg!) : "no libssh2 error string"
            logger.error(
                "ssh_method_pref_fail label=\(label, privacy: .public) rc=\(rc) libssh2=\(errorMsg, privacy: .public)"
            )
        }
    }

    private static func remoteFileError(
        from sftp: OpaquePointer?,
        operation: String,
        path: String?
    ) -> RemoteFileBrowserError {
        let code = sftp.map { libssh2_sftp_last_error($0) } ?? 0
        return remoteFileError(lastError: UInt(code), operation: operation, path: path)
    }

    private static func remoteFileError(
        lastError: UInt,
        operation: String,
        path: String?
    ) -> RemoteFileBrowserError {
        switch lastError {
        case UInt(LIBSSH2_FX_PERMISSION_DENIED):
            return .permissionDenied
        case UInt(LIBSSH2_FX_NO_SUCH_FILE), UInt(LIBSSH2_FX_NO_SUCH_PATH):
            return .pathNotFound
        case UInt(LIBSSH2_FX_NO_CONNECTION), UInt(LIBSSH2_FX_CONNECTION_LOST):
            return .disconnected
        case UInt(LIBSSH2_FX_NOT_A_DIRECTORY):
            return .failed(String(localized: "The remote path is not a directory."))
        case UInt(LIBSSH2_FX_LINK_LOOP):
            return .failed(String(localized: "The remote path contains a symbolic link loop."))
        default:
            let location = path.map { " (\($0))" } ?? ""
            return .failed(String(localized: "Failed to \(operation)\(location)."))
        }
    }
}

// MARK: - SSH Session Config

struct SSHSessionConfig {
    let host: String
    /// For `.faceIDTeleport`, the Teleport target node name (e.g. `pcad-dev`).
    /// This is `Server.name` (the display name) — for Teleport servers, the
    /// display name IS the node name the user wants to connect to. Used to
    /// build the `proxy:<node>:0` subsystem string. Ignored for other auth
    /// methods.
    let teleportNodeName: String?
    let port: Int
    let dialHost: String
    let dialPort: Int
    let hostKeyHost: String
    let hostKeyPort: Int
    let username: String
    let connectionMode: SSHConnectionMode
    let authMethod: AuthMethod
    let credentials: ServerCredentials

    var connectionTimeout: TimeInterval = 30
    var keepAliveInterval: TimeInterval = 30

    init(
        host: String,
        port: Int,
        dialHost: String? = nil,
        dialPort: Int? = nil,
        hostKeyHost: String? = nil,
        hostKeyPort: Int? = nil,
        username: String,
        connectionMode: SSHConnectionMode,
        authMethod: AuthMethod,
        credentials: ServerCredentials,
        teleportNodeName: String? = nil,
        connectionTimeout: TimeInterval = 30,
        keepAliveInterval: TimeInterval = 30
    ) {
        self.host = host
        self.teleportNodeName = teleportNodeName
        self.port = port
        self.dialHost = dialHost ?? host
        self.dialPort = dialPort ?? port
        self.hostKeyHost = hostKeyHost ?? host
        self.hostKeyPort = hostKeyPort ?? port
        self.username = username
        self.connectionMode = connectionMode
        self.authMethod = authMethod
        self.credentials = credentials
        self.connectionTimeout = connectionTimeout
        self.keepAliveInterval = keepAliveInterval
    }
}

// MARK: - SSH Error

enum SSHError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case tailscaleAuthenticationNotAccepted
    case cloudflareConfigurationRequired(String)
    case cloudflareAuthenticationFailed(String)
    case cloudflareTunnelFailed(String)
    case moshServerMissing
    case moshServerRuntimeBroken
    case moshBootstrapFailed(String)
    case moshSessionFailed(String)
    case moshInvalidEndpoint
    case moshUDPTimeout
    case moshClientSessionFailed(String)
    case timeout
    case channelOpenFailed
    case shellRequestFailed
    case hostKeyVerificationFailed
    case socketError(String)
    case teleportCertMissing
    case unknown(String)

    var allowsAutomaticReconnectRetry: Bool {
        switch self {
        case .notConnected,
             .connectionFailed,
             .cloudflareTunnelFailed,
             .moshSessionFailed,
             .moshUDPTimeout,
             .moshClientSessionFailed,
             .timeout,
             .channelOpenFailed,
             .shellRequestFailed,
             .socketError:
            return true
        case .authenticationFailed,
             .tailscaleAuthenticationNotAccepted,
             .cloudflareConfigurationRequired,
             .cloudflareAuthenticationFailed,
             .moshServerMissing,
             .moshServerRuntimeBroken,
             .moshBootstrapFailed,
             .moshInvalidEndpoint,
             .hostKeyVerificationFailed,
             .teleportCertMissing,
             .unknown:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "Authentication failed"
        case .tailscaleAuthenticationNotAccepted:
            return "\(String(localized: "Tailscale SSH authentication was not accepted by the server.")) \(String(localized: "This app currently supports direct tailnet connections only (no userspace proxy fallback)."))"
        case .cloudflareConfigurationRequired(let message):
            return String(format: String(localized: "Cloudflare configuration error: %@"), message)
        case .cloudflareAuthenticationFailed(let message):
            return String(format: String(localized: "Cloudflare authentication failed: %@"), message)
        case .cloudflareTunnelFailed(let message):
            return String(format: String(localized: "Cloudflare tunnel failed: %@"), message)
        case .moshServerMissing:
            return String(localized: "mosh-server is not installed on the remote host")
        case .moshServerRuntimeBroken:
            return String(localized: "mosh-server is installed but cannot run. Repair its package installation on the remote host.")
        case .moshBootstrapFailed(let msg):
            return "Mosh bootstrap failed: \(msg)"
        case .moshSessionFailed(let msg):
            return "Mosh session failed: \(msg)"
        case .moshInvalidEndpoint:
            return "Mosh server address is invalid"
        case .moshUDPTimeout:
            return "Mosh UDP session timed out"
        case .moshClientSessionFailed(let msg):
            return "Mosh client session failed: \(msg)"
        case .timeout: return "Connection timed out"
        case .channelOpenFailed: return "Failed to open channel"
        case .shellRequestFailed: return "Failed to request shell"
        case .hostKeyVerificationFailed:
            return "Host key verification failed. The saved SSH host fingerprint does not match the server's current key."
        case .socketError(let msg): return "Socket error: \(msg)"
        case .teleportCertMissing:
            return String(localized: "Teleport certificate is missing or expired. Sign in with Face ID to refresh it.")
        case .unknown(let msg): return "Unknown error: \(msg)"
        }
    }
}

// MARK: - fd_set helpers for select()

private func fdZero(_ set: inout fd_set) {
    set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    guard fd >= 0, fd < FD_SETSIZE else { return }
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    withUnsafeMutableBytes(of: &set.fds_bits) { buf in
        guard let baseAddress = buf.baseAddress,
              intOffset * MemoryLayout<Int32>.size < buf.count else { return }
        let ptr = baseAddress.assumingMemoryBound(to: Int32.self)
        ptr[intOffset] |= Int32(1 << bitOffset)
    }
}

// MARK: - Atomic Socket for Thread-Safe Interruption

/// Thread-safe socket storage that separates cross-thread I/O interruption
/// from the actor-owned final descriptor close.
final class AtomicSocket: @unchecked Sendable {
    private enum State: Sendable {
        case closed
        case open(Int32)
        case interrupted(Int32)
    }

    private nonisolated(unsafe) var state = State.closed
    private let lock = NSLock()

    nonisolated init() {}

    nonisolated var isUsable: Bool {
        lock.withLock {
            if case .open = state {
                true
            } else {
                false
            }
        }
    }

    nonisolated func install(_ socket: Int32) {
        lock.withLock {
            state = .open(socket)
        }
    }

    /// Wake blocking socket I/O without releasing the descriptor. This avoids
    /// descriptor reuse while libssh2 may still be returning from a native call.
    nonisolated func interrupt(_ label: String = "") {
        let logger = Logger.forCategory("SSHSession")
        lock.withLock {
            guard case .open(let socket) = state else {
                if !label.isEmpty {
                    logger.info("atomic_socket_interrupt_skipped label=\(label, privacy: .public) socket=not_open")
                }
                return
            }
            Darwin.shutdown(socket, SHUT_RDWR)
            state = .interrupted(socket)
            if !label.isEmpty {
                logger.info("atomic_socket_interrupt label=\(label, privacy: .public) socket=\(socket)")
            }
        }
    }

    /// Release the descriptor after the SSHSession actor has finished libssh2 cleanup.
    nonisolated func close() {
        lock.withLock {
            switch state {
            case .closed:
                return
            case .open(let socket), .interrupted(let socket):
                Darwin.close(socket)
                state = .closed
            }
        }
    }
}
