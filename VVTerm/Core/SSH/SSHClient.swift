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

#if DEBUG
/// Shell-channel write telemetry for UI-test diagnostics
/// (sshWrites=/sshWriteTail=/sshWriteError=): the ghostty write callback
/// hands bytes to the transport, but CI shows the shell never receives them
/// — these counters locate whether libssh2 accepted the write or the
/// channel/socket rejected it. DEBUG-only cross-actor telemetry; benign
/// data race.
nonisolated(unsafe) enum SSHClientUITestDebug {
    static var writeCount = 0
    static var writeTail = ""
    static var writeError = ""
    static var writeTails: [String] = []
    static var receivedCount = 0
    static var receivedBytes = 0
    static var receivedTail = ""
    static var receivedTails: [String] = []
    static var osc0Hits = 0
    static var osc7Hits = 0
    static func noteWrite(_ data: Data) {
        writeCount += 1
        let text = String(data: data, encoding: .utf8) ?? data.map { String(format: "%02x", $0) }.joined()
        let normalized = text.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        writeTail = normalized.count > 12 ? String(normalized.suffix(12)) : normalized
        writeTails.append(writeTail)
        if writeTails.count > 6 {
            writeTails.removeFirst(writeTails.count - 6)
        }
    }
    static func noteReceived(_ data: Data) {
        receivedCount += 1
        receivedBytes += data.count
        let text = String(data: data, encoding: .utf8) ?? data.map { String(format: "%02x", $0) }.joined()
        let normalized = text.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        receivedTail = normalized.count > 160 ? String(normalized.suffix(160)) : normalized
        receivedTails.append(receivedTail)
        if receivedTails.count > 3 {
            receivedTails.removeFirst(receivedTails.count - 3)
        }
    }
    static func noteError(_ message: String) {
        writeError = String(message.prefix(60))
    }
}
#endif

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
    /// The Teleport logging seam forwarded into every `SSHSession` (and from
    /// there into `SSHTLSTransport`). Defaulted so the synthesized `init()`
    /// keeps every bare `SSHClient()` call site compiling; the app injects
    /// `AppTeleportLogging.shared`, tests can inject a spy.
    var teleportLogging: any TeleportLogging = AppTeleportLogging.shared
    /// The Teleport credential store forwarded into every `SSHSession`.
    /// Defaulted so the synthesized `init()` keeps every bare `SSHClient()`
    /// call site compiling; the default adapter resolves the single host
    /// keyring (`TeleportKeyRingHost.shared`), so coordinators and the SSH
    /// session always see the same object + in-memory state.
    var teleportCredentialStore: any TeleportCredentialStore = TeleportKeyRingCredentialStore()
    /// The Teleport channel transport factory forwarded into every
    /// `SSHSession` (D6 #3/#4). Defaulted so the synthesized `init()` keeps
    /// every bare `SSHClient()` call site compiling; the default builds the
    /// host-side libssh2 channel bridge.
    var teleportTransportFactory: any TeleportChannelTransportFactory = SSHProxySubsystemTransportFactory()
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
    /// Budget for the whole `connect(to:)` operation (transport dial +
    /// handshake + auth). Settable so the Teleport integration tests can
    /// give a contended CI cluster more headroom; the app default (30s) is
    /// unchanged.
    var connectTimeout: Duration = .seconds(30)
    /// Set the connect budget (integration tests give a contended CI
    /// cluster more headroom; the app default 30s is unchanged).
    func setConnectTimeout(_ timeout: Duration) {
        connectTimeout = timeout
    }

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

        let key = "\(server.host):\(server.port):\(server.username):\(server.teleportHostLogin ?? ""):\(server.connectionMode):\(server.authMethod):\(server.cloudflareAccessMode?.rawValue ?? "none"):\(server.cloudflareTeamDomainOverride ?? "")"

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
            teleportHostLogin: server.teleportHostLogin,
            teleportNodeName: server.name
        )

        let pendingSession = SSHSession(
            config: config,
            startupTrace: startupTrace,
            teleportLogging: teleportLogging,
            teleportCredentialStore: teleportCredentialStore,
            teleportTransportFactory: teleportTransportFactory
        )
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

    func remoteEnvironment(
        forceRefresh: Bool = false,
        watchdogOrigin: String = "unspecified"
    ) async -> RemoteEnvironment {
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
        // #276/V3: capture the connection generation at entry so the cache
        // write below cannot land on a newer session (the epoch guard is
        // checked immediately before the write, with no await in between).
        let capturedSession = session
        let authMethod = connectedServer?.authMethod ?? .password
        // Pre-hop fast path (#276/D2a): a usable cache skips the
        // `isInnerSessionReady` actor hop entirely — that hop is what parked
        // the incident connect (`SSHClient.swift:490` in the pre-fix tree).
        // Teleport + a cached `.unknown` platform always hops: the platform
        // was resolved before the inner session existed and must be
        // re-resolved against the real target node once the inner session is
        // ready.
        if let cached = resolvedRemoteEnvironment,
           Self.canReuseCachedEnvironmentBeforeInnerCheck(
               forceRefresh: forceRefresh,
               cached: cached,
               authMethod: authMethod
           ) {
            return cached
        }
        // #276/D4: name the park if this hop is still suspended after the
        // short watchdog deadline (startShell and the terminal-type stage
        // label their calls; other callers use the default label).
        let innerReady = await Self.withStartupWatchdog(
            deadline: Self.startupHopWatchdogDeadline,
            emitter: { detail in
                Logger.forCategory("SSH").diagError(
                    "SSH",
                    "startup watchdog: remoteEnvironment(from:\(watchdogOrigin)) \(detail)"
                )
            }
        ) {
            await (self.session?.isInnerSessionReady ?? false)
        }
        // Post-hop reuse decision (the pre-fix composite, kept verbatim):
        // reuse unless this is a Teleport connection whose cached platform is
        // `.unknown` and the inner session is now ready — the case that must
        // re-resolve for real.
        if let cached = resolvedRemoteEnvironment,
           Self.canReuseCachedEnvironmentAfterInnerCheck(
               forceRefresh: forceRefresh,
               cached: cached,
               authMethod: authMethod,
               innerReady: innerReady
           ) {
            return cached
        }

        if Self.shouldPrepareInnerSessionBeforeResolvingEnvironment(
            authMethod: authMethod,
            innerSessionReady: innerReady
        ) {
            do {
                try await prepareTeleportInnerSession()
            } catch {
                let message = Self.teleportInnerSessionPrepareFailureMessage(
                    for: error,
                    redacting: connectedServer
                )
                logger.warning(
                    "Failed to prepare Teleport inner session before resolving environment: \(message, privacy: .public)"
                )
            }
        }

        let token = startupTrace?.begin(.remoteEnvironment)
        let environment = await RemoteEnvironmentResolver.resolve(using: self)
        if let token {
            startupTrace?.end(token, detail: environment.platform.rawValue)
        }
        if Self.isCurrentSession(capturedSession, current: session) {
            resolvedRemoteEnvironment = environment
        }
        logger.info(
            "Resolved remote environment [platform: \(environment.platform.rawValue, privacy: .public), shell: \(environment.shellProfile.family.rawValue, privacy: .public), active: \(environment.activeShellName ?? "unknown", privacy: .public)]"
        )
        return environment
    }

    func remoteTerminalType(forceRefresh: Bool = false) async -> RemoteTerminalType {
        if !forceRefresh, let resolvedRemoteTerminalType {
            return resolvedRemoteTerminalType
        }

        // #276/D2b: bound the WHOLE stage — including the
        // `remoteEnvironment(forceRefresh:)` re-entry below — with an
        // abandonable deadline. The trace token is begun here, before the
        // race, and ended exactly once by this caller; the abandoned worker
        // must not end it (`SSHStartupTrace.end` is not idempotent, so a late
        // `end` would emit a second event with a huge `stageMs`). Side
        // effect: the `.terminalType` stage now spans the env re-entry.
        //
        // The deadline bounds the *caller*, not the exec request: the
        // abandoned worker keeps running (never cancelled — cancelling it can
        // resume a parked exec request and tear the session down) and fills
        // the cache when it completes, epoch-guarded.
        let token = startupTrace?.begin(.terminalType)
        let capturedSession = session
        do {
            let terminalType = try await SSHClient.withStartupDeadline(
                deadline: SSHClient.terminalTypeStageDeadline,
                emitter: { detail in
                    Logger.forCategory("SSH").diagError(
                        "SSH",
                        "startup watchdog: terminalType stage \(detail), falling back to \(RemoteTerminalBootstrap.defaultTerminalType.rawValue)"
                    )
                },
                operation: { [weak self] in
                    guard let self else { throw SSHError.notConnected }
                    return try await self.resolveRemoteTerminalTypeForStage(
                        forceRefresh: forceRefresh,
                        capturedSession: capturedSession
                    )
                }
            )
            if let token {
                startupTrace?.end(token, detail: terminalType.rawValue)
            }
            return terminalType
        } catch is SSHClient.StartupDeadlineExceeded {
            // Degrade within the deadline; the fallback is deliberately NOT
            // cached (a later call re-probes until the abandoned resolution
            // completes and fills the cache itself).
            if let token {
                startupTrace?.end(
                    token,
                    outcome: "fallback",
                    detail: RemoteTerminalBootstrap.defaultTerminalType.rawValue
                )
            }
            return RemoteTerminalBootstrap.defaultTerminalType
        } catch is CancellationError {
            // V10: the caller was cancelled (dismissal), so this non-throwing
            // API returns the fallback rather than rethrowing — the enclosing
            // shell start unwinds at its own next cancellation check. The
            // abandoned worker keeps resolving (including
            // `prepareTeleportInnerSession`) and epoch-guards its late cache
            // fill.
            if let token {
                startupTrace?.end(token, outcome: "cancelled", detail: "cancelled")
            }
            return RemoteTerminalBootstrap.defaultTerminalType
        } catch {
            if let token {
                startupTrace?.end(token, outcome: "failed", detail: "resolution_error")
            }
            return RemoteTerminalBootstrap.defaultTerminalType
        }
    }

    /// The worker body of `remoteTerminalType()` (#276/D2b): the environment
    /// re-entry plus the resolver, plus the epoch-guarded worker-side cache
    /// fill. It must NOT end the stage token — the race caller owns it.
    ///
    /// The worker may outlive the caller's deadline (it is abandoned, never
    /// cancelled); a completion after a fallback on the same session fills
    /// `resolvedRemoteTerminalType` so the next call returns it, while a
    /// completion after a reconnect does not overwrite the new session's
    /// cache (N7 epoch guard).
    private func resolveRemoteTerminalTypeForStage(
        forceRefresh: Bool,
        capturedSession: SSHSession?
    ) async throws -> RemoteTerminalType {
        let environment = await remoteEnvironment(
            forceRefresh: forceRefresh,
            watchdogOrigin: "terminalTypeStage"
        )
        let redactionServer = connectedServer
        let terminalType = await RemoteTerminalTypeResolver.resolve(
            environment: environment,
            execute: { [weak self] command, timeout in
                guard let self else { throw SSHError.notConnected }
                return try await self.execute(command, timeout: timeout)
            },
            onExecError: { error in
                let message = SSHError.diagnosticsMessage(for: error, redacting: redactionServer)
                Logger.forCategory("SSH").diagError("SSH", "terminalType exec failed: \(message)")
            }
        )
        if Self.isCurrentSession(capturedSession, current: session) {
            resolvedRemoteTerminalType = terminalType
            logger.info("Resolved remote terminal type: \(terminalType.rawValue, privacy: .public)")
        }
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
        let environment = await remoteEnvironment(watchdogOrigin: "startShell")
        // prepareTeleportInnerSession() is invoked (and its error swallowed)
        // by remoteEnvironment(); rethrow the stored prepare failure here
        // instead of letting the shell-start guard mask the proxy's real
        // rejection as `.notConnected` (#268).
        try await rethrowStoredTeleportPrepareFailure(from: sshSession)
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
        // #276/D4: name the park if the shell start is still suspended after
        // the short watchdog deadline. Non-interrupting: the shell start is
        // awaited normally.
        let shell = try await SSHClient.withStartupWatchdog(
            deadline: SSHClient.startupHopWatchdogDeadline,
            emitter: { detail in
                Logger.forCategory("SSH").diagError(
                    "SSH",
                    "startup watchdog: session.startShell \(detail)"
                )
            }
        ) {
            try await expectedSession.startShell(
                cols: cols,
                rows: rows,
                pixelSize: pixelSize,
                startupCommand: startupCommand,
                environment: environment,
                terminalType: terminalType
            )
        }
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

    /// Pre-hop fast path for a cached remote environment (#276/D2a). No
    /// `innerReady` input by construction: that flag is exactly what the
    /// `isInnerSessionReady` actor hop computes and a pre-hop decision cannot
    /// depend on it.
    ///
    /// Teleport + a cached `.unknown` platform always hops — the cache was
    /// resolved before the inner session existed, so the platform must be
    /// re-resolved against the now-ready target node. Every other cached
    /// combination is reusable without touching the session actor.
    nonisolated static func canReuseCachedEnvironmentBeforeInnerCheck(
        forceRefresh: Bool,
        cached: RemoteEnvironment?,
        authMethod: AuthMethod
    ) -> Bool {
        guard !forceRefresh, let cached else { return false }
        return !(authMethod == .faceIDTeleport && cached.platform == .unknown)
    }

    /// Post-hop reuse decision — the pre-fix `remoteEnvironment()` composite,
    /// kept verbatim. Teleport + `.unknown` + inner-**not**-ready still
    /// returns the cache after the hop (no `prepareTeleportInnerSession()`
    /// side effect on that path); Teleport + `.unknown` + inner-ready falls
    /// through so the environment is re-resolved.
    nonisolated static func canReuseCachedEnvironmentAfterInnerCheck(
        forceRefresh: Bool,
        cached: RemoteEnvironment?,
        authMethod: AuthMethod,
        innerReady: Bool
    ) -> Bool {
        guard !forceRefresh, let cached else { return false }
        return !(authMethod == .faceIDTeleport && innerReady && cached.platform == .unknown)
    }

    /// Rendering for the swallowed `prepareTeleportInnerSession()` failure in
    /// `remoteEnvironment()`. Extracted so the redaction contract can be unit-
    /// tested without a live libssh2 session: the inner resolver can throw
    /// `TeleportHostLoginFailure.ambiguousPrincipalSet`, whose
    /// `localizedDescription` embeds the principal logins, and this message is
    /// logged at public privacy for the diagnostics export. It must go through
    /// the same redaction spine as the recorder.
    nonisolated static func teleportInnerSessionPrepareFailureMessage(
        for error: Error,
        redacting server: Server?
    ) -> String {
        SSHError.diagnosticsMessage(for: error, redacting: server)
    }

    /// Rethrow the stored Teleport inner-session prepare failure (if any).
    ///
    /// `remoteEnvironment()` swallows the prepare error so its resolver can
    /// still run; by the time the shell/exec path runs, only the stored
    /// failure carries the proxy's real rejection reason (#268). Emits a
    /// case-only `diagError` so the device ring records the failure stage.
    private func rethrowStoredTeleportPrepareFailure(from session: SSHSession) async throws {
        guard connectedServer?.authMethod == .faceIDTeleport,
              let failure = session.lastTeleportPrepareFailure else {
            return
        }
        let rendered = SSHError.diagnosticsMessage(for: failure, redacting: connectedServer)
        logger.diagError("SSH", "teleportPrepareFailed \(rendered)")
        throw failure
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

    /// Race `operation` against a sleep; whichever finishes first wins.
    ///
    /// #276/D1: `group.cancelAll()` is now on every exit path (`defer`)
    /// instead of only the success path — clarity only. Cancellation is a
    /// *request*, not a bound: the task-group scope still awaits the
    /// operation child before it can return, so a child suspended inside a
    /// synchronously-wedged `SSHSession` actor keeps this call parked past
    /// the deadline (the E2 characterization test pins that).
    nonisolated static func runWithTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
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
            return result
        }
    }

    /// Thrown by `withStartupDeadline` when the deadline (not the operation)
    /// wins.
    struct StartupDeadlineExceeded: Error {}

    /// Wall-clock budget for the whole `remoteTerminalType()` body (#276/N6):
    /// a 12 s terminfo install plus up to three 2 s environment probes plus
    /// slack. A false fire degrades the running shell's `TERM` to
    /// `xterm-256color` with no retro-fix, so this must not be tightened
    /// without re-deriving that budget.
    nonisolated static let terminalTypeStageDeadline: Duration = .seconds(25)

    /// Race `operation` against a wall-clock `deadline` (#276/D2b).
    ///
    /// A one-shot continuation is claimed by whichever of {operation task,
    /// detached timer, caller cancellation} reaches it first. On a deadline
    /// win the operation task is **abandoned — never awaited, never
    /// cancelled**: cancelling it can resume a parked exec request and,
    /// through `invalidateTransport()`, tear down a live session. It may still
    /// finish later and fill a cache; the caller's epoch guard
    /// (`isCurrentSession(_:current:)`) decides whether that write lands.
    ///
    /// - `deadline` is injected by the caller (tests use milliseconds).
    /// - `emitter` receives a short detail string when the deadline wins and
    ///   is injectable so tests can record it; the production default logs on
    ///   the `SSH` diag channel.
    /// - Throws `StartupDeadlineExceeded` on a deadline win, or
    ///   `CancellationError` when the caller's task was cancelled (V10: resume
    ///   early so a dismissal does not block the full deadline).
    nonisolated static func withStartupDeadline<T: Sendable>(
        deadline: Duration,
        emitter: @escaping @Sendable (String) -> Void = { detail in
            Logger.forCategory("SSH").diagError("SSH", "startup watchdog: \(detail)")
        },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = StartupDeadlineRace<T>()
        defer { race.cancelTimer() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                // Pre-install cancellation (V10): the onCancel handler can
                // fire before this body runs; `install` then applies it and
                // we must not start the abandoned worker.
                guard race.install(continuation) else { return }
                // Unstructured on purpose: the deadline must be able to
                // abandon the operation, so the caller never awaits it
                // structurally. Detached also avoids inheriting this
                // task's cancellation.
                Task.detached {
                    do {
                        race.resume(returning: try await operation())
                    } catch {
                        race.resume(throwing: error)
                    }
                }
                race.armTimer(deadline: deadline, emitter: emitter)
            }
        }, onCancel: {
            // V10: resume the *caller* early — never cancel the operation.
            race.cancel()
        })
    }

    /// One-shot claim holder for `withStartupDeadline` (#276/V6). Claim-once
    /// under the lock; every `resume` happens after the lock is released.
    /// Mirrors `SSHSession.ExecRequest`'s holder shape (D1).
    private nonisolated final class StartupDeadlineRace<T: Sendable>: @unchecked Sendable {
        private struct State: Sendable {
            var continuation: CheckedContinuation<T, Error>?
            var resumed = false
            var pendingCancellation = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let timer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

        /// Install the continuation. Returns `false` (and resumes with
        /// `CancellationError`) when a cancellation already arrived.
        func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
            let shouldCancel = state.withLock { state -> Bool in
                guard !state.resumed else { return true }
                guard !state.pendingCancellation else {
                    state.resumed = true
                    return true
                }
                state.continuation = continuation
                return false
            }
            if shouldCancel {
                continuation.resume(throwing: CancellationError())
                return false
            }
            return true
        }

        /// Claim the continuation for the deadline outcome. Returns the
        /// continuation when this call won (the operation has not resumed),
        /// nil when the operation already won — so a losing timer never emits
        /// a misleading line.
        func claimDeadline() -> CheckedContinuation<T, Error>? {
            state.withLock { state in
                guard !state.resumed else { return nil }
                state.resumed = true
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
        }

        func resume(returning value: T) {
            guard let continuation = claim() else { return }
            continuation.resume(returning: value)
        }

        func resume(throwing error: Error) {
            guard let continuation = claim() else { return }
            continuation.resume(throwing: error)
        }

        /// Caller cancellation: claim or record a pending cancellation for
        /// `install`.
        func cancel() {
            let continuation = state.withLock { state -> CheckedContinuation<T, Error>? in
                guard !state.resumed else { return nil }
                guard let continuation = state.continuation else {
                    state.pendingCancellation = true
                    return nil
                }
                state.resumed = true
                state.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }

        func armTimer(
            deadline: Duration,
            emitter: @escaping @Sendable (String) -> Void
        ) {
            let task = Task.detached { [weak self] in
                do {
                    try await Task.sleep(for: deadline)
                } catch {
                    return // cancelled — the operation won or the caller left
                }
                guard let self else { return }
                guard let continuation = self.claimDeadline() else { return }
                emitter("deadline after \(SSHClient.secondsText(deadline))s")
                continuation.resume(throwing: StartupDeadlineExceeded())
            }
            // Store and check atomically: if the race already settled (the
            // operation, the caller's cancellation, or a deadline claim) while
            // this body was between `install` and here, the caller's
            // `defer { cancelTimer() }` has already run and seen `nil`, so the
            // timer would escape. Cancel it here instead of leaking a task that
            // sleeps the full deadline. `S1` (lens 1).
            let escaped = timer.withLock { stored -> Bool in
                stored = task
                return state.withLock { $0.resumed }
            }
            if escaped { task.cancel() }
        }

        func cancelTimer() {
            let task = timer.withLock { task -> Task<Void, Never>? in
                let stored = task
                task = nil
                return stored
            }
            task?.cancel()
        }

        private func claim() -> CheckedContinuation<T, Error>? {
            state.withLock { state in
                guard !state.resumed else { return nil }
                state.resumed = true
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
        }
    }

    /// Human-readable seconds for a `Duration` in diag lines (`25s`, `0.20s`).
    nonisolated static func secondsText(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        if seconds == seconds.rounded() {
            return String(Int(seconds))
        }
        return String(format: "%.2f", seconds)
    }

    /// Epoch guard for a late cache write (#276/N7): `SSHSession` is recreated
    /// per connect, so session identity is the connection generation. A worker
    /// that resolved against an older session must not overwrite the current
    /// one's cache. `nil === nil` is true, so a session-less resolution may
    /// still fill the cache while no session exists.
    nonisolated static func isCurrentSession(_ captured: SSHSession?, current: SSHSession?) -> Bool {
        captured === current
    }

    /// Short per-call deadline for the D4 naming watchdogs (#276/N8): if the
    /// watched await is still parked after this, emit one labelled diag line.
    /// Nothing is bounded here — `withStartupDeadline` owns bounding.
    nonisolated static let startupHopWatchdogDeadline: Duration = .seconds(3)

    /// Non-interrupting startup watchdog (#276/D4).
    ///
    /// Arms a detached timer; if `operation` is still parked at `deadline` the
    /// timer emits `detail` through `emitter` **once** (the `catch { return }`
    /// disarm pattern — a cancelled sleep must not fall through to an emit).
    /// The operation is awaited normally and its result/error is returned: this
    /// names a park, it does not bound one. The benign boundary race (the
    /// operation completes exactly as the timer fires) can produce one extra
    /// line — an extra line is not a failure signal.
    nonisolated static func withStartupWatchdog<T: Sendable>(
        deadline: Duration,
        emitter: @escaping @Sendable (String) -> Void = { detail in
            Logger.forCategory("SSH").diagError("SSH", "startup watchdog: \(detail)")
        },
        operation: @escaping @Sendable () async throws -> T
    ) async rethrows -> T {
        let timer = Task.detached {
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return // cancelled — the watched operation completed in time
            }
            emitter("still parked after \(secondsText(deadline))s")
        }
        defer { timer.cancel() }
        return try await operation()
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

    /// All lock-protected state is immutable-after-claim; the mutable
    /// channel/output fields are only touched from this actor. The shared
    /// holder must cross into the off-actor cancellation handler, hence
    /// `@unchecked Sendable` (the lock is the synchronization).
    nonisolated final class ExecRequest: @unchecked Sendable {
        /// Cancellation/once state shared between the session actor
        /// (registration, loop-side completion, teardown) and the
        /// **off-actor** `withTaskCancellationHandler(onCancel:)` handler.
        /// #276/D1: the handler used to hop back into this actor
        /// (`Task { await self?.cancelExecRequest(…) }`); that hop never
        /// arrives while the actor is parked, so a timed-out exec request
        /// stayed in flight. The holder is now the single once-guard and the
        /// handler resumes the continuation directly, off-actor.
        ///
        /// Claim-once under the lock; every `resume` call happens after the
        /// lock is released.
        struct State: Sendable {
            var continuation: CheckedContinuation<String, Error>?
            var cancelled = false
            var resumed = false
        }

        let id: UUID
        let command: String
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
        var isInner: Bool

        private let state = OSAllocatedUnfairLock(initialState: State())

        init(id: UUID, command: String, isInner: Bool) {
            self.id = id
            self.command = command
            self.isInner = isInner
        }

        /// The off-loop cancellation path marks the request (probe timeouts,
        /// task cancellation) but must NOT close/free the channel: the owning
        /// I/O loop may be suspended between reads on it (issue #121). The
        /// loop checks this on every pass — it wakes at least every 5ms via
        /// the poll timeout in `waitForSocket` — and performs the channel
        /// teardown exactly once. The request stays in `execRequests` until
        /// then, which also keeps the loop alive.
        nonisolated var isCancelled: Bool {
            state.withLock { $0.cancelled }
        }

        /// `true` once the continuation was claimed for resume. Kept for the
        /// single-resume tests and the teardown comments; production code
        /// only observes it through the resume guards.
        nonisolated var continuationResumed: Bool {
            state.withLock { $0.resumed }
        }

        /// Install the continuation.
        ///
        /// Applies a cancellation that landed before install: the `onCancel`
        /// handler can fire before this actor ever reached the continuation
        /// body (it is invoked immediately when the task is already cancelled
        /// at handler installation). In that case the continuation is resumed
        /// with `CancellationError` here and `false` is returned so the caller
        /// can drop the freshly registered `execRequests` entry (the request
        /// never started, so it has no channel for the loop to tear down).
        @discardableResult
        nonisolated func install(_ continuation: CheckedContinuation<String, Error>) -> Bool {
            let shouldCancel = state.withLock { state -> Bool in
                guard !state.resumed else { return true }
                guard !state.cancelled else {
                    state.resumed = true
                    return true
                }
                state.continuation = continuation
                return false
            }
            if shouldCancel {
                continuation.resume(throwing: CancellationError())
                return false
            }
            return true
        }

        /// Off-actor cancellation: mark the request cancelled and resume its
        /// continuation directly — no session-actor hop. Safe to call before
        /// `install(_:)`; the pending cancellation is applied at install.
        nonisolated func cancel() {
            let continuation = state.withLock { state -> CheckedContinuation<String, Error>? in
                state.cancelled = true
                guard !state.resumed else { return nil }
                guard let continuation = state.continuation else { return nil }
                state.resumed = true
                state.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }

        /// Resume exactly once; later calls are no-ops.
        nonisolated func resume(returning output: String) {
            guard let continuation = claimContinuation() else { return }
            continuation.resume(returning: output)
        }

        /// Resume exactly once; later calls are no-ops.
        nonisolated func resume(throwing error: Error) {
            guard let continuation = claimContinuation() else { return }
            continuation.resume(throwing: error)
        }

        private nonisolated func claimContinuation() -> CheckedContinuation<String, Error>? {
            state.withLock { state in
                guard !state.resumed else { return nil }
                state.resumed = true
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
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
    /// In-flight `prepareTeleportInnerSession()` **initiator** bodies (#286).
    /// `cleanupLibssh2()` defers the inner-session + proxy-subsystem-channel
    /// free while any token is held, so a parked prepare body cannot resume
    /// onto freed libssh2 state. Scope: a token protects the prepare **body**
    /// only — it does not protect a caller's post-prepare use of the inner
    /// session, which each caller must guard for itself. (The dedup joiner
    /// registers nothing because its frame touches no libssh2 after resuming;
    /// the known unregistered caller-side window is the SFTP EAGAIN loop,
    /// tracked separately.)
    private var innerPreparesInFlight: Set<UUID> = []
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
    /// `cleanup` (before the inner session is freed). Stored through the
    /// package-movable `TeleportChannelTransport` seam.
    private var innerTransport: (any TeleportChannelTransport)?
    /// The outer (proxy) session channel that carries the proxy-subsystem
    /// tunnel. Retained so `cleanup` can free it after the inner session is
    /// torn down (the pump reads/writes this channel).
    private var proxySubsystemChannel: OpaquePointer?
    /// The dedicated ssh-agent serving task for proxy-recorded clusters
    /// (#269). Installed before the `auth-agent-req@openssh.com` request and
    /// torn down (cancelled, drained, freed) in the same pre-free window as
    /// the bridge pump.
    private var agentForwardingService: TeleportAgentForwardingService?
    /// The last `prepareTeleportInnerSession()` failure (#268). The prepare is
    /// invoked (and its error swallowed) by `SSHClient.remoteEnvironment()`,
    /// so the shell/exec paths rethrow this stored failure instead of masking
    /// it as `.notConnected`. Cleared on a successful prepare and on connect;
    /// `CancellationError` is never stored.
    ///
    /// #276/D3: a **per-session** lock-protected box instead of an
    /// actor-isolated property, so
    /// `SSHClient.rethrowStoredTeleportPrepareFailure(from:)` reads it without
    /// hopping into this actor (that hop is a startup park candidate). The box
    /// is owned by this session — a client-owned shared snapshot would be
    /// stale across sessions and would miss the `connect()` clear. Same value,
    /// same lifetime, same throw type as the pre-fix field.
    private let lastTeleportPrepareFailureBox = OSAllocatedUnfairLock<SSHError?>(initialState: nil)

    /// Off-actor read of the stored prepare failure; same value and lifetime
    /// as the pre-fix actor-isolated property.
    private(set) nonisolated var lastTeleportPrepareFailure: SSHError? {
        get { lastTeleportPrepareFailureBox.withLock { $0 } }
        set { lastTeleportPrepareFailureBox.withLock { $0 = newValue } }
    }
    /// The in-flight `prepareTeleportInnerSession()` body (#276/V1).
    /// Concurrent callers await this task instead of starting a second body
    /// that would clobber `proxySubsystemChannel` / `agentForwardingService`
    /// mid-handshake. Cleared by the task itself when the body completes.
    private var prepareTeleportInnerSessionTask: Task<Void, Error>?
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
    /// Monotonic diagnostic event counter shared by the `ssh_diag` read-
    /// failure and shell-close logs (issue #120). Actor-isolated, so the
    /// ordering between log sites is total within a session.
    private var diagEventCounter: UInt64 = 0
    private var connectedPeerAddress: String?
    private let logger = Logger.forCategory("SSHSession")
    private let startupTrace: SSHStartupTrace?
    /// The Teleport logging seam (forwarded to `SSHTLSTransport`). Injected
    /// through `SSHClient`; defaulted so direct `SSHSession` construction in
    /// tests keeps compiling.
    private let teleportLogging: any TeleportLogging
    /// The Teleport credential store (cluster TLS state + cert/key reads).
    /// Injected through `SSHClient`; defaulted so direct `SSHSession`
    /// construction in tests keeps compiling. The default resolves the
    /// single host keyring, so the UI and the session share state.
    private let teleportCredentialStore: any TeleportCredentialStore
    /// The Teleport channel transport factory (D6 #3/#4). Injected through
    /// `SSHClient`; defaulted so direct `SSHSession` construction in tests
    /// keeps compiling.
    private let teleportTransportFactory: any TeleportChannelTransportFactory

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
    /// rationale. Stored through the package-movable `TeleportSessionMutex`
    /// seam.
    private let outerSessionMutex: any TeleportSessionMutex

    /// Session-specific auth callback context passed to libssh2 session abstract pointer.
    private let keyboardInteractiveContext = KeyboardInteractiveContext()

    /// Track if cleanup has been performed
    private var hasBeenCleaned = false

    #if DEBUG
    private var shellStartupTestHook: (@Sendable (ShellStartupTestEvent) -> Void)?
    private var discardedShellStartupChannelCount = 0
    /// Parks the prepare body so the V1 in-flight dedup can be observed
    /// without a live libssh2 session (#276). Each body entry awaits it; the
    /// dedup test asserts only one entry while the first is parked.
    private var prepareTeleportInnerSessionBodyTestHook: (@Sendable () async -> Void)?
    #endif

    init(
        config: SSHSessionConfig,
        startupTrace: SSHStartupTrace? = nil,
        teleportLogging: any TeleportLogging = AppTeleportLogging.shared,
        teleportCredentialStore: any TeleportCredentialStore = TeleportKeyRingCredentialStore(),
        teleportTransportFactory: any TeleportChannelTransportFactory = SSHProxySubsystemTransportFactory(),
        teleportSessionMutex: any TeleportSessionMutex = SessionMutex()
    ) {
        self.config = config
        self.startupTrace = startupTrace
        self.teleportLogging = teleportLogging
        self.teleportCredentialStore = teleportCredentialStore
        self.teleportTransportFactory = teleportTransportFactory
        self.outerSessionMutex = teleportSessionMutex
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
    /// session) on a live session. This is a lightweight liveness check used
    /// by `SSHClient.remoteEnvironment()` to decide whether to prepare the
    /// inner session before running exec probes — distinct from
    /// `supportsExec`, which additionally gates on socket usability. The
    /// `isActive` conjunct matters during the deferred-teardown window (#286):
    /// while a parked prepare holds its `innerPreparesInFlight` token,
    /// `cleanupLibssh2()` has returned early, so `innerLibssh2Session` is
    /// still non-nil although the session is dead and must not be reported as
    /// ready. For non-Teleport auth methods this returns `false` (there is no
    /// inner session, and none is needed).
    var isInnerSessionReady: Bool {
        isActive
            && config.authMethod == .faceIDTeleport
            && innerLibssh2Session != nil
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

    func setPrepareTeleportInnerSessionBodyTestHook(
        _ hook: (@Sendable () async -> Void)?
    ) {
        prepareTeleportInnerSessionBodyTestHook = hook
    }

    func discardedShellStartupChannelsForTesting() -> Int {
        discardedShellStartupChannelCount
    }

    /// Test seam for #286: observes whether the synchronous teardown
    /// (`cleanupLibssh2()`, including its no-session return) has completed.
    var hasBeenCleanedForTesting: Bool { hasBeenCleaned }

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
        // A fresh connect clears any stale prepare failure from a previous
        // attempt (#268); the next prepare re-records it if it fails again.
        lastTeleportPrepareFailure = nil
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
        let handshakeResult: Int32
        if config.authMethod == .faceIDTeleport {
            // Teleport (TLS socketpair) path — non-blocking EAGAIN loop. A
            // blocking `libssh2_session_handshake` C call pins a
            // cooperative-pool thread for its whole duration; the TLS
            // transport's pumps (also pool tasks) need those threads to
            // forward the banner/KEX bytes. On small runners the pool
            // exhausts, the pumps starve, and the handshake times out
            // (the socketpair-KEX stall in the teleport-e2e runs). The
            // loop suspends between attempts, releasing the thread to the
            // pumps.
            let diag = SyncDiag()
            diag.mark("outer_handshake_begin fd=\(fd) dial=\(dialHost):\(dialPort)")
            do {
                handshakeResult = try await performNonBlockingHandshake(
                    session: session,
                    fd: socket,
                    deadline: ContinuousClock.now + .seconds(35)
                )
            } catch {
                diag.mark("outer_handshake_cancelled")
                if let handshakeToken {
                    startupTrace?.end(handshakeToken, outcome: "failed", detail: "cancelled")
                }
                cleanup()
                throw error
            }
            diag.mark("outer_handshake_returned \(handshakeResult)")
            // Host-key verification + auth run in blocking mode (as before).
            libssh2_session_set_blocking(session, 1)
        } else {
            // Regular TCP path — blocking handshake (unchanged), bounded by
            // libssh2's own timeout + a watchdog interrupt.
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
            handshakeResult = libssh2_session_handshake(session, socket)
        }
        guard handshakeResult == 0 else {
            var errmsg: UnsafeMutablePointer<CChar>?
            var errmsgLen: Int32 = 0
            libssh2_session_last_error(session, &errmsg, &errmsgLen, 0)
            let errorMsg = handshakeResult == LIBSSH2_ERROR_TIMEOUT
                ? "handshake timed out (EAGAIN loop deadline)"
                : (errmsg != nil ? String(cString: errmsg!) : "no libssh2 error string")
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
            try await verifyHostKey()
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
        guard let tlsState = await teleportCredentialStore.clusterTLSState(for: clusterId) else {
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
            clusterCAPEMs: tlsState.clusterCAPEMs,
            logging: teleportLogging
        )
        let fd: Int32
        do {
            fd = try await transport.connect()
        } catch {
            // connect() already cleaned up its own FDs + NWConnection on
            // failure (see SSHTLSTransport.connect). Close once more to be
            // safe, then rethrow — don't retain the transport. Map the
            // package error into the host space so the app's
            // `error as? SSHError` classification keeps working.
            await transport.close()
            throw TeleportErrorMapping.map(error)
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

    /// Grace window for reading the proxy's rejection stderr after
    /// CHANNEL_FAILURE (#268). The proxy has already written the text by the
    /// time the failure arrives; the bound only stops a peer that keeps the
    /// channel open without sending anything.
    private static let proxyStderrCaptureWindowMilliseconds = 100

    /// The resolved auth material for a Teleport connection: the SSH username
    /// (a certificate principal) plus the exact cert/key pair it was resolved
    /// against. The pair is read together so the username and the certificate
    /// the SSH call sends can never come from different generations.
    private struct TeleportAuthMaterial {
        let username: String
        let certData: Data
        let keyData: Data
    }

    /// Resolve the Teleport SSH username from the exact certificate that is
    /// about to be sent.
    ///
    /// This is the only writer of the Teleport SSH username. The stored
    /// `config.teleportHostLogin` is used only when it is still a principal of
    /// this certificate; otherwise the login is derived only for an
    /// exactly-one-principal certificate. A keyID mismatch (the certificate
    /// does not belong to the configured Teleport user) and every fail-closed
    /// resolution clear the credential so readiness flips to `.needsBootstrap`
    /// and the row's setup sheet (with the picker) becomes reachable.
    private func resolveTeleportAuthMaterial() async throws -> TeleportAuthMaterial {
        let clusterId = config.credentials.serverId
        guard let snapshot = await teleportCredentialStore.liveCredentialSnapshot(for: clusterId),
              let certData = snapshot.certPEM.data(using: .utf8) else {
            logger.error("No live Teleport cert or ed25519 key for cluster \(clusterId.uuidString, privacy: .public)")
            throw SSHError.teleportCertMissing
        }

        // The certificate must be readable and must belong to the configured
        // Teleport user — a foreign/stale cert must never name the SSH user.
        guard let cert = OpenSSHCertificate.parse(authorizedKeysOrPEM: snapshot.certPEM) else {
            logger.error(
                "Teleport certificate unreadable for cluster \(clusterId.uuidString, privacy: .public) — clearing credential"
            )
            await teleportCredentialStore.clear(for: clusterId)
            throw SSHError.teleportCertMissing
        }
        guard cert.keyID == config.username else {
            logger.error(
                "Teleport certificate keyID does not match the configured Teleport user for cluster \(clusterId.uuidString, privacy: .public) — clearing credential"
            )
            await teleportCredentialStore.clear(for: clusterId)
            throw SSHError.teleportCertMissing
        }

        switch TeleportHostLogin.resolve(cert: cert, storedLogin: config.teleportHostLogin) {
        case .success(let login):
            if let stored = config.teleportHostLogin, stored == login {
                logger.info(
                    "Using the stored Teleport host login for cluster \(clusterId.uuidString, privacy: .public)"
                )
            } else {
                // Derived from the certificate's single non-internal principal.
                logger.info(
                    "Derived the Teleport host login from the certificate's single principal for cluster \(clusterId.uuidString, privacy: .public)"
                )
            }
            return TeleportAuthMaterial(username: login, certData: certData, keyData: snapshot.privateKeyPEM)
        case .failure(let failure):
            // Log the case name only: the failure's principal payload is
            // identity material and must not be rendered into logs or the
            // diagnostics export.
            logger.error(
                "Teleport host login unresolvable for cluster \(clusterId.uuidString, privacy: .public): \(failure.caseDescription, privacy: .public) — clearing credential"
            )
            throw await TeleportHostLoginFailureRoute.clearAndFail(
                failure,
                store: teleportCredentialStore,
                clusterId: clusterId
            )
        }
    }

    private func authenticate() async throws {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }

        // The SSH username must be resolved BEFORE any call that sends it:
        // for Teleport it is a certificate principal (the host login), not the
        // Teleport user. Non-Teleport connections keep `config.username`.
        let username: String
        let teleportAuth: TeleportAuthMaterial?
        if config.authMethod == .faceIDTeleport {
            let material = try await resolveTeleportAuthMaterial()
            username = material.username
            teleportAuth = material
        } else {
            username = config.username
            teleportAuth = nil
        }
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
            // The cert + key were read together above and the username was
            // resolved to one of the cert's principals; both auth sites (the
            // outer proxy session here and the inner node session) send the
            // same login, because Teleport checks `conn.User()` on both.
            guard let teleportAuth else {
                logger.error("Teleport auth material missing after resolution")
                throw SSHError.teleportCertMissing
            }
            let certData = teleportAuth.certData
            let keyData = teleportAuth.keyData
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

    /// Run `libssh2_session_handshake` in non-blocking mode with cooperative
    /// yields between EAGAIN retries.
    ///
    /// A blocking handshake C call pins a cooperative-pool thread for its
    /// whole duration. On the Teleport TLS paths the transport pumps are also
    /// pool tasks — if the handshake holds the last free thread, the pumps
    /// never run, no bytes flow, and the handshake times out (the
    /// socketpair-KEX stall in the teleport-e2e runs). This loop suspends
    /// (`Task.sleep`) between attempts, releasing the thread so the pumps can
    /// forward the banner + KEX traffic.
    ///
    /// The session is switched to non-blocking mode here (callers restore
    /// blocking mode when the handshake completes, so auth keeps its
    /// pre-existing blocking semantics). The fd must be O_NONBLOCK (both
    /// transports' socketpairs set it) so libssh2 returns
    /// `LIBSSH2_ERROR_EAGAIN` instead of blocking in recv().
    ///
    /// - Returns: 0 on success, or the terminal libssh2 error code
    ///   (`LIBSSH2_ERROR_TIMEOUT` when `deadline` passes).
    /// - Throws: `CancellationError` when the task is cancelled.
    private func performNonBlockingHandshake(
        session: OpaquePointer,
        fd: Int32,
        deadline: ContinuousClock.Instant
    ) async throws -> Int32 {
        libssh2_session_set_blocking(session, 0)
        while true {
            try Task.checkCancellation()
            let result = libssh2_session_handshake(session, fd)
            if result == 0 { return 0 }
            if result != LIBSSH2_ERROR_EAGAIN { return result }
            if ContinuousClock.now >= deadline { return LIBSSH2_ERROR_TIMEOUT }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func verifyHostKey() async throws {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }

        let info = try hostKeyInfo(for: session)
        try await verifyHostKey(
            fingerprint: info.fingerprint,
            keyType: info.keyType,
            blob: info.blob,
            host: config.hostKeyHost,
            port: config.hostKeyPort,
            expectedPrincipals: [config.hostKeyHost]
        )
    }

    /// Apply the host-key trust policy and update the known-hosts pin.
    ///
    /// Teleport (`faceIDTeleport`): the Host CA is authoritative — the host
    /// certificate is verified against the pinned `checking_keys`, and the
    /// (rotating) certificate fingerprint pin is refreshed on success, never
    /// used to reject. Missing anchors fail closed (the readiness layer routes
    /// the user to login/bootstrap before connecting).
    ///
    /// Non-Teleport: the fingerprint pin decides.
    private func verifyHostKey(
        fingerprint: String,
        keyType: Int,
        blob: Data,
        host: String,
        port: Int,
        expectedPrincipals: [String]
    ) async throws {
        let checkingKeys: [String]
        if config.authMethod == .faceIDTeleport {
            checkingKeys = await teleportCredentialStore
                .clusterTLSState(for: config.credentials.serverId)?
                .hostCACheckingKeys ?? []
        } else {
            checkingKeys = []
        }

        let knownFingerprint = KnownHostsManager.shared.entry(for: host, port: port)?.fingerprint
        let decision = HostKeyTrustPolicy.decide(
            isTeleport: config.authMethod == .faceIDTeleport,
            fingerprint: fingerprint,
            keyType: keyType,
            knownFingerprint: knownFingerprint,
            hostKeyBlob: blob,
            expectedPrincipals: expectedPrincipals,
            teleportHostCACheckingKeys: checkingKeys,
            now: Date()
        )

        switch decision {
        case .verified(let refreshPin):
            if refreshPin || knownFingerprint == nil {
                let entry = KnownHostsManager.Entry(
                    host: host,
                    port: port,
                    fingerprint: fingerprint,
                    keyType: keyType,
                    addedAt: Date(),
                    lastSeenAt: Date()
                )
                KnownHostsManager.shared.save(entry: entry)
            } else {
                KnownHostsManager.shared.updateSeen(host: host, port: port)
            }
            logger.info("Host key verified for \(host, privacy: .private(mask: .hash)):\(port)")

        case .rejectHostKeyVerification:
            if config.authMethod == .faceIDTeleport,
               let cert = OpenSSHCertificate.parse(blob: blob) {
                // Actionable diagnostics: the presented principals let an
                // operator correct the expected set from evidence. Identity
                // values stay at the default (private) interpolation so they
                // cannot reach the shareable diagnostics export.
                logger.error(
                    "teleport_host_cert_rejected key_id=\(cert.keyID) principals=\(cert.validPrincipals.joined(separator: ",")) expected=\(expectedPrincipals.joined(separator: ","))"
                )
            }
            logger.error(
                "Host key mismatch for \(host, privacy: .private(mask: .hash)):\(port). Known: \(knownFingerprint ?? "none", privacy: .private(mask: .hash)), Presented: \(fingerprint, privacy: .private(mask: .hash))"
            )
            throw SSHError.hostKeyVerificationFailed

        case .rejectMissingTeleportAnchors:
            logger.error(
                "Teleport Host CA checking keys missing for \(host, privacy: .private(mask: .hash)):\(port) — login/bootstrap required"
            )
            throw SSHError.teleportCertMissing

        case .unknownHost(let presentedFingerprint, let presentedKeyType):
            // Defense in depth: the policy only returns this for non-Teleport
            // hosts (a Teleport host either verifies against the Host CA or
            // fails closed with missing anchors). A Teleport host must never
            // be offered a first-use trust prompt — fail closed instead.
            guard config.authMethod != .faceIDTeleport else {
                logger.error(
                    "teleport host key reached the first-use path for \(host, privacy: .private(mask: .hash)):\(port) — failing closed"
                )
                throw SSHError.hostKeyVerificationFailed
            }
            // First use: record the key as pending and prompt. The pin is
            // persisted only after the user confirms the trust affordance.
            let entry = KnownHostsManager.Entry(
                host: host,
                port: port,
                fingerprint: presentedFingerprint,
                keyType: presentedKeyType,
                addedAt: Date(),
                lastSeenAt: Date()
            )
            KnownHostsManager.shared.recordPending(entry: entry)
            logger.info(
                "Host key for \(host, privacy: .private(mask: .hash)):\(port) is not trusted yet (\(presentedFingerprint, privacy: .private(mask: .hash))) — awaiting user confirmation"
            )
            throw SSHError.hostKeyUnknown(
                host: host,
                port: port,
                fingerprint: presentedFingerprint,
                keyType: presentedKeyType
            )
        }
    }

    /// Read the host key fingerprint, libssh2 key type, and raw host key blob
    /// (the full certificate blob for certificate host keys).
    private func hostKeyInfo(for session: OpaquePointer) throws -> (fingerprint: String, keyType: Int, blob: Data) {
        guard let hashPtr = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_SHA256)) else {
            throw SSHError.hostKeyVerificationFailed
        }

        let hash = Data(bytes: hashPtr, count: 32)
        let base64 = hash.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let fingerprint = "SHA256:\(base64)"

        var keyLen: size_t = 0
        var keyType: Int32 = 0
        guard let keyPtr = libssh2_session_hostkey(session, &keyLen, &keyType), keyLen > 0 else {
            throw SSHError.hostKeyVerificationFailed
        }
        let blob = Data(bytes: keyPtr, count: keyLen)

        return (fingerprint, Int(keyType), blob)
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
        // Stop the agent-serving task and free its channels before the outer
        // session is freed — the same pre-free window as the pump cancel.
        teardownAgentForwarding()
        socket = -1
        innerSocket = -1
    }

    private func cleanupLibssh2() {
        // The in-flight sets sequence the native free after the last registered
        // user: a shell startup or a Teleport prepare may still own a libssh2
        // object across an actor suspension (the prepare body also owns the
        // outer proxy-subsystem channel across the stderr-capture awaits), and
        // its defer releases the token before re-entering here. A deferred
        // cleanup leaves `innerLibssh2Session` / `proxySubsystemChannel`
        // allocated while `isActive` is already `false`. The two gates this fix
        // touched (the prepare idempotence check and `isInnerSessionReady`) test
        // `isActive`; the exec/SFTP gates still route on
        // `innerLibssh2Session != nil` and are carried by the `innerSocket = -1`
        // / `innerAtomicSocket.isUsable` / `!hasBeenCleaned` invariants that
        // `invalidateTransport()` sets before any deferral — plus the
        // cached-SFTP fast path, which is #288's window.
        guard shellStartupsInFlight.isEmpty, innerPreparesInFlight.isEmpty else { return }
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
        // use-after-free. cancelPumpSync() cancels the pump task and wakes the
        // pump FD (shutdown, not close — the loops exit on EOF/EPIPE and
        // `runPump` releases the number after its join, issue #237). The full
        // actor-isolated close() is also scheduled (below) for the libssh2FD
        // bookkeeping, but the synchronous cancel is what makes freeing the
        // outer session safe.
        if let innerTransport = innerTransport {
            innerTransport.cancelPumpSync()
        }

        // Belt and braces: the agent service is normally torn down by
        // invalidateTransport, but cleanupLibssh2 is the window that precedes
        // `libssh2_session_free`, so drain/free here too (idempotent).
        teardownAgentForwarding()

        // Free the outer proxy-subsystem channel if it's still around (the
        // outer session free below may reap it, but close it explicitly to
        // avoid leaking it if the outer free is abandoned).
        if let proxyChannel = proxySubsystemChannel {
            // Serialized through `outerSessionMutex` against the bridge
            // pump's read/write closures: those re-check their cancel token
            // inside the same mutex, so a call that just passed the check
            // cannot race this free, and `cancelPumpSync()` (above) flipped
            // the token, so no new pump call can start after this point. The
            // pre-transport stderr-capture read on this channel is a separate
            // window, not covered here (#286).
            outerSessionMutex.withLock {
                _ = libssh2_channel_close(proxyChannel)
                _ = libssh2_channel_free(proxyChannel)
            }
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

        // Both frees on the outer session and its bridge channel are
        // serialized through `outerSessionMutex` against the agent service's
        // and the bridge pump's libssh2 closures: the read/write closures
        // re-check their cancel token inside the same mutex, so a call that
        // just passed the token check cannot touch a freed channel or session.
        // (The inner-session free above is a separate window — #286.)
        var freeResult = Int32(LIBSSH2_ERROR_EAGAIN)
        outerSessionMutex.withLock {
            for _ in 0..<1_024 {
                freeResult = libssh2_session_free(session)
                if freeResult != LIBSSH2_ERROR_EAGAIN {
                    break
                }
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
        // Reachability of the deferred-teardown re-check (#286): `cleanup()`
        // is connect-failure-only today — its callers run before
        // `isActive = true`, and `SSHClient` publishes `session` only after
        // `connect()` returns, so no prepare can be in flight. It does NOT
        // clear `isActive` (unlike `invalidateTransport()`), so a future
        // post-connect caller must clear `isActive` — or set a
        // `teardownRequested` flag the shell/prepare defers re-check — for
        // the `if !isActive` re-entry to complete the free.
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
            throw lastTeleportPrepareFailure ?? SSHError.notConnected
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
        // already established the tunnel + second handshake. The `isActive`
        // conjunct matters during the deferred-teardown window (#286): while a
        // parked prepare holds its `innerPreparesInFlight` token,
        // `cleanupLibssh2()` has returned early, so `innerLibssh2Session` is
        // still non-nil although the session is dead. Reporting "ready" here
        // would send a new caller into a pending free; falling through reaches
        // the body's own liveness guard and yields the real `.notConnected`.
        if isActive, innerLibssh2Session != nil { return }

        // #276/V1: in-flight dedup. A concurrent caller joins the running
        // prepare instead of starting a second body that would clobber
        // `proxySubsystemChannel` / `agentForwardingService` mid-handshake
        // (the inner session only becomes non-nil after the handshake, so
        // the idempotence check above does not cover this window).
        //
        // The slot is cleared by the *initiator* once it has resumed from
        // `task.value`, so a later caller after a failure starts a fresh
        // attempt (the pre-fix retry behavior). Precisely: a caller that
        // arrives after the body finished but before the initiator's
        // continuation resumed joins the finished task and rethrows its
        // result instead of retrying. That window is one actor scheduling
        // turn and the outcome (the same error) is indistinguishable to the
        // caller; clearing from inside the task body would need an extra
        // actor hop to write the property, which is worse.
        //
        // The slot is per-session and the task is unstructured: a cancelled
        // caller does not cancel a body another caller may be waiting on.
        //
        // The joiner registers no `innerPreparesInFlight` token (#286): this
        // frame awaits the initiator's body and touches no libssh2 after
        // resuming, so the initiator's token already covers the whole body.
        // Every prepare caller must instead hold its own token (the shell
        // paths) or re-validate before its next libssh2 call. Within the #286
        // audit's caller set, the one known unregistered caller-side window is
        // the SFTP EAGAIN loop (#288); the shell write/resize post-wait window
        // found outside that set is #290.
        if let inFlight = prepareTeleportInnerSessionTask {
            return try await inFlight.value
        }

        let prepareId = UUID()
        innerPreparesInFlight.insert(prepareId)
        defer {
            // Order is load-bearing (#286): the token must be removed BEFORE
            // the re-entry, or `cleanupLibssh2()`'s guard sees its own token
            // and no later completer exists.
            innerPreparesInFlight.remove(prepareId)
            // Mirror the shell-start defers: if the teardown ran while this
            // prepare was parked, `cleanupLibssh2()` returned early —
            // complete it now. This relies on every deferrable trigger
            // clearing `isActive` first; a future trigger that does not must
            // set a `teardownRequested` flag this defer re-checks.
            if !isActive {
                cleanupLibssh2()
            }
        }

        let task = Task { [weak self] () -> Void in
            guard let self else { throw SSHError.notConnected }
            try await self.prepareTeleportInnerSessionBodyStoringFailure()
        }
        prepareTeleportInnerSessionTask = task
        defer { prepareTeleportInnerSessionTask = nil }
        try await task.value
    }

    /// `prepareTeleportInnerSessionBody()` plus the stored-failure rule (#268):
    /// store `SSHError`s, never a cancellation, and clear on success. Split out
    /// so the V1 dedup task can call it with `await` from a nonisolated task
    /// context.
    private func prepareTeleportInnerSessionBodyStoringFailure() async throws {
        do {
            try await prepareTeleportInnerSessionBody()
        } catch is CancellationError {
            // A user cancel must not be rethrown later as a connection
            // failure: never store it.
            throw CancellationError()
        } catch {
            lastTeleportPrepareFailure = Self.storedTeleportPrepareFailure(
                for: error,
                previous: lastTeleportPrepareFailure
            )
            throw error
        }
        // Successful prepare: nothing stale to rethrow at the mask points.
        lastTeleportPrepareFailure = nil
    }

    /// Pure storage rule for the prepare failure (#268): store `SSHError`s,
    /// never a cancellation, and never clear a previously stored failure for
    /// an unrelated (non-`SSHError`) throw.
    nonisolated static func storedTeleportPrepareFailure(
        for error: Error,
        previous: SSHError?
    ) -> SSHError? {
        if error is CancellationError { return previous }
        return (error as? SSHError) ?? previous
    }

    /// The body of `prepareTeleportInnerSession()`, split out so the entry
    /// point can record every thrown failure without touching each throw site.
    private func prepareTeleportInnerSessionBody() async throws {
        #if DEBUG
        await prepareTeleportInnerSessionBodyTestHook?()
        #endif
        guard isActive, let outerSession = libssh2Session else {
            throw SSHError.notConnected
        }

        // Resolve the exact cert+key pair once, before anything uses it. The
        // forwarded agent identity and the inner authentication MUST be the
        // same pair (an agent certificate that differs from the inner-auth
        // certificate would sign for an identity the node rejects), and the
        // identity must be loaded before the auth-agent request — the proxy
        // can open its agent channel while it handles the subsystem request.
        let material = try await resolveTeleportAuthMaterial()

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

        // 1b. Forward an SSH agent. Cluster configurations that record at the
        //     proxy (`session_recording: proxy` / `proxy-sync`) make the proxy
        //     dial the node itself with the SSH agent the client forwards; the
        //     agent request must precede the subsystem request because the
        //     proxy opens its agent channel while handling the subsystem.
        //     Non-fatal by design: a non-recording cluster needs no agent, and
        //     on a recording cluster the now-surfaced subsystem error is the
        //     actionable failure.
        do {
            try await installAgentForwarding(
                session: outerSession,
                channel: outerChannel,
                material: material
            )
        } catch is CancellationError {
            shouldInvalidateTransport = true
            throw CancellationError()
        } catch {
            // Identity/callback setup failures never fail the connect: inner
            // auth surfaces the real error. Static label only.
            logger.error("teleport_agent_forwarding_setup_failed")
        }

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
            // Read the rejection reason the proxy wrote to the channel's
            // extended-data (stderr) before CHANNEL_FAILURE. Bounded, decoded
            // by the actual byte count, and sanitized before it reaches the
            // terminal banner; the actionable text must not be masked as
            // `.notConnected` (#268).
            // libssh2_channel_read_stderr doesn't exist as a symbol; use
            // libssh2_channel_read_ex with stream_id=1 (SSH_EXTENDED_DATA_STDERR).
            let stderrData = await TeleportSubsystemStderrCapture.capture(
                deadline: ContinuousClock.now + .milliseconds(Self.proxyStderrCaptureWindowMilliseconds),
                read: { buffer in
                    Int(libssh2_channel_read_ex(outerChannel, 1, buffer.baseAddress, buffer.count))
                },
                sleep: { try? await Task.sleep(nanoseconds: 5_000_000) }
            )
            let failureMessage = TeleportSubsystemFailureMessage.display(
                code: subsystemResult,
                stderr: stderrData
            )
            // Payload-free: the proxy's channel stderr is arbitrary server
            // text (it can embed the node name or the host login) and the
            // OSLog/ring merge feeds the shareable diagnostics report. Log the
            // code and byte count only; the text travels through the thrown
            // error to the transient terminal banner.
            logger.error(
                "teleport_proxy_subsystem_failed code=\(subsystemResult) stderr_bytes=\(stderrData.count)"
            )
            if let proxyToken {
                startupTrace?.end(proxyToken, outcome: "failed", detail: "code_\(subsystemResult)")
            }
            shouldInvalidateTransport = true
            throw SSHError.teleportPrepareFailed(failureMessage)
        }
        // Payload-free like the failure twin: the subsystem name embeds the
        // node name, and the OSLog/ring merge feeds the shareable report.
        logger.info("teleport_proxy_subsystem_ok")
        // The trace detail is mirrored into the always-exported diagnostics
        // ring (`SSHStartupDiagnostics.record` -> `logger.diagInfo` ->
        // `DiagnosticsRecorder`), and `nodeName` is
        // `config.teleportNodeName ?? config.host` — environment metadata, and
        // the proxy FQDN on the fallback. Constant, like the sibling
        // `detail: "code_\(subsystemResult)"` on the failure path; the node is
        // hashed where triage needs it (`teleport_inner_handshake_*`).
        if let proxyToken { startupTrace?.end(proxyToken, detail: "node") }

        // 3. Bridge the outer channel to a socketpair for the inner session.
        //    The pump starts before start() returns the FD, so the target
        //    node's banner is forwarded as soon as it arrives.
        let handshakeToken = startupTrace?.begin(.teleportInnerHandshake)
        let transport = teleportTransportFactory.makeChannelTransport(
            channel: outerChannel,
            outerSession: outerSession,
            mutex: outerSessionMutex
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
        // The bridge pump is running, so every outer-session libssh2 call is
        // now serialized through `outerSessionMutex`. Only from this point may
        // the agent-serving task read the agent channel (the prepare path
        // above used the outer session without the mutex).
        agentForwardingService?.markTransportStarted()

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
        // KEX/HOSTKEY prefs are intentionally NOT applied to the inner
        // session: libssh2's defaults already cover the Teleport cert
        // hostkey variants, and custom prefs on the socketpair session
        // stalled in the teleport-e2e runs (the outer session keeps its
        // custom prefs on the real TCP path).
        // Sync file-marker diagnostics (bypasses os_log) so we can trace
        // progress even if the sim's os_log pipeline wedges.
        let diag = SyncDiag()
        diag.mark("after inner_mac_sc")

        // Non-blocking EAGAIN-loop handshake (see performNonBlockingHandshake):
        // the inner session sits on a socketpair whose pumps are pool tasks —
        // a blocking handshake C call would pin the last free pool thread and
        // starve the pumps (the socketpair-KEX stall). The loop yields between
        // attempts; host-key verification + cert auth below run in blocking
        // mode (restored after the loop), matching the pre-stall behavior.
        diag.mark("inner_handshake_call_start")
        let handshakeResult: Int32
        do {
            handshakeResult = try await performNonBlockingHandshake(
                session: innerSession,
                fd: innerFD,
                deadline: ContinuousClock.now + .seconds(60)
            )
        } catch {
            diag.mark("inner_handshake_cancelled")
            shouldInvalidateTransport = true
            throw error
        }
        diag.mark("handshake returned \(handshakeResult)")
        // Host-key verification + cert auth run in blocking mode (as before).
        libssh2_session_set_blocking(innerSession, 1)
        guard handshakeResult == 0 else {
            var errmsg: UnsafeMutablePointer<CChar>?
            var errmsgLen: Int32 = 0
            libssh2_session_last_error(innerSession, &errmsg, &errmsgLen, 0)
            let errorMsg = handshakeResult == LIBSSH2_ERROR_TIMEOUT
                ? "inner handshake timed out after 60s (EAGAIN loop deadline)"
                : (errmsg != nil ? String(cString: errmsg!) : "no libssh2 error string")
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
            try await verifyInnerHostKey(session: innerSession, host: nodeName, port: config.port)
        } catch {
            if let innerAuthToken {
                startupTrace?.end(innerAuthToken, outcome: "failed", detail: "hostkey")
            }
            shouldInvalidateTransport = true
            throw error
        }

        // 7. Auth with the same cert + ed25519 key.
        do {
            try await authenticateInner(session: innerSession, material: material)
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

    /// Install the forwarded-agent callback, register the per-session service,
    /// and request `auth-agent-req@openssh.com` on the outer channel.
    ///
    /// The identity is loaded from the same material the inner session will
    /// authenticate with (resolved once by `prepareTeleportInnerSession`).
    /// An unreadable/mismatched identity is logged and skipped — the connect
    /// proceeds without an agent, so non-recording clusters are unaffected.
    private func installAgentForwarding(
        session: OpaquePointer,
        channel: OpaquePointer,
        material: TeleportAuthMaterial
    ) async throws {
        let identityMaterial: TeleportAgentIdentityMaterial
        do {
            identityMaterial = try TeleportAgentIdentity.make(
                certPEM: String(decoding: material.certData, as: UTF8.self),
                privateKeyPEM: material.keyData
            )
        } catch {
            // Case-name-only failure (never the PEM/key bytes). No agent is
            // served; a recording cluster then fails the subsystem and the
            // caller surfaces the proxy's own reason.
            logger.error("teleport_agent_identity_unavailable")
            return
        }

        let service = TeleportAgentForwardingService.makeForSession(
            identityMaterial: identityMaterial,
            mutex: outerSessionMutex
        )
        // Register the libssh2 callback BEFORE the request: it is the only way
        // libssh2 accepts a server-initiated `auth-agent@openssh.com` channel,
        // and the proxy may open that channel while it handles the request.
        // The callback routes through the session-keyed registry (the
        // keyboard-interactive context already owns `session->abstract`).
        let callback = unsafeBitCast(
            TeleportAgentForwardingService.sessionCallback,
            to: (@convention(c) () -> Void).self
        )
        _ = libssh2_session_callback_set2(session, Int32(LIBSSH2_CALLBACK_AUTHAGENT), callback)
        // Start the task and register the service before the request so a
        // channel opened during it has a queue to land in.
        service.start()
        TeleportAgentCallbackRegistry.shared.register(service, for: session)
        agentForwardingService = service

        let requestResult = try await performShellStartupCall(session: session) {
            libssh2_channel_request_auth_agent(channel)
        }
        service.resolveRequest(succeeded: requestResult == 0)
        if requestResult != 0 {
            // OpenSSH treats a failed `auth-agent-req` as a warning and
            // proceeds; the recording-cluster failure is then the proxy's
            // subsystem rejection, which carries the actionable text.
            logger.warning("teleport_agent_request_rejected code=\(requestResult)")
        }
    }

    /// Stop the agent-serving task, drop the callback registry entry, and free
    /// every channel the service still owns. Runs synchronously in the
    /// pre-`libssh2_session_free` window (idempotent).
    private func teardownAgentForwarding() {
        guard let service = agentForwardingService else { return }
        if let session = libssh2Session {
            TeleportAgentCallbackRegistry.shared.remove(for: session)
        }
        agentForwardingService = nil
        for channel in service.cancelAndDrain() {
            service.closeAndFree(channel)
        }
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
    ) async throws {
        let info = try hostKeyInfo(for: session)
        try await verifyHostKey(
            fingerprint: info.fingerprint,
            keyType: info.keyType,
            blob: info.blob,
            host: host,
            port: port,
            expectedPrincipals: [host]
        )
    }

    /// Authenticate the inner (target-node) session with the Teleport cert +
    /// ed25519 key and the resolved username of the caller-provided material.
    ///
    /// The caller (`prepareTeleportInnerSession`) resolves the pair once so
    /// this authentication and the forwarded agent identity (#269) can never
    /// use different certificate/key generations.
    ///
    /// The SSH `user` for the inner session must be a certificate principal
    /// (the host login, e.g. `deploy`), NOT the Teleport username — Teleport
    /// runs the same `CertChecker` principal check on the node as on the
    /// proxy.
    private func authenticateInner(
        session: OpaquePointer,
        material: TeleportAuthMaterial
    ) async throws {
        let username = material.username
        let certData = material.certData
        let keyData = material.keyData
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

    /// Pure decision extracted from `ioLoop`'s exit condition so it can be
    /// unit-tested without a live libssh2 session. The loop must keep running
    /// while any outer shell channel or outer exec request exists. A request
    /// cancelled off-loop (probe timeout) stays in `execRequests` until the
    /// loop tears its channel down, so it counts as work — this is what
    /// guarantees the deferred teardown (issue #121) always runs before the
    /// loop exits.
    nonisolated static func shouldOuterIOLoopContinue(
        hasOuterShell: Bool,
        hasOuterExec: Bool
    ) -> Bool {
        hasOuterShell || hasOuterExec
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
                    logSSHReadFailure(
                        kind: "inner_shell_read_failed",
                        code: Int32(bytesRead),
                        session: innerLibssh2Session,
                        channelId: state.id,
                        loop: "inner"
                    )
                    closeShellInternal(state.id, reason: .readError(Int32(bytesRead)))
                    didWork = true
                    continue
                }

                if libssh2_channel_eof(state.channel) != 0 {
                    if !state.batchBuffer.isEmpty {
                        state.continuation.yield(state.batchBuffer)
                    }
                    logger.info("Inner channel EOF")
                    closeShellInternal(state.id, reason: .eof)
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
                    // Off-loop cancellation (probe timeout) marks the request
                    // and resumes its continuation; channel teardown is
                    // deferred to this loop — the only execution context that
                    // reads the inner channel (issue #121). The request stays
                    // in `execRequests` until torn down, keeping
                    // `hasInnerExec` true so the loop does not exit before
                    // the teardown runs.
                    if request.isCancelled {
                        await teardownExecChannel(request)
                        execRequests.removeValue(forKey: requestId)
                        didWork = true
                        continue
                    }
                    guard await ensureInnerExecChannelReady(request) else { continue }

                    guard let execChannel = request.channel else { continue }

                    let bytesRead = libssh2_channel_read_ex(execChannel, 0, &buffer, buffer.count)
                    if bytesRead > 0 {
                        request.output.append(Data(bytes: buffer, count: Int(bytesRead)))
                        didWork = true
                    } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No data yet
                    } else if bytesRead < 0 {
                        logSSHReadFailure(
                            kind: "inner_exec_read_failed",
                            code: Int32(bytesRead),
                            session: innerLibssh2Session,
                            channelId: requestId,
                            loop: "inner"
                        )
                        await finishExecRequest(requestId, error: SSHError.socketError("Inner exec read failed: \(bytesRead)"))
                        continue
                    }

                    let stderrRead = libssh2_channel_read_ex(execChannel, 1, &buffer, buffer.count)
                    if stderrRead > 0 {
                        request.stderr.append(Data(bytes: buffer, count: Int(stderrRead)))
                        didWork = true
                    } else if stderrRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No stderr data yet
                    } else if stderrRead < 0 {
                        logSSHReadFailure(
                            kind: "inner_exec_stderr_read_failed",
                            code: Int32(stderrRead),
                            session: innerLibssh2Session,
                            channelId: requestId,
                            loop: "inner"
                        )
                        await finishExecRequest(requestId, error: SSHError.socketError("Inner exec stderr read failed: \(stderrRead)"))
                        continue
                    }

                    if let currentChannel = request.channel, libssh2_channel_eof(currentChannel) != 0 {
                        await finishExecRequest(requestId, error: nil)
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
        isInner: Bool = false,
        operation: () -> Int32
    ) async -> Int32 {
        for _ in 0..<1_024 {
            if isInner {
                guard isActive,
                      let currentSession = innerLibssh2Session,
                      currentSession == session,
                      innerSocket >= 0,
                      innerAtomicSocket.isUsable else {
                    return -1
                }
            } else {
                guard isActive,
                      let currentSession = libssh2Session,
                      currentSession == session,
                      socket >= 0,
                      atomicSocket.isUsable else {
                    return -1
                }
            }

            let result = operation()
            if result != LIBSSH2_ERROR_EAGAIN {
                return result
            }
            if isInner {
                await waitForInnerSocket()
            } else {
                await waitForSocket()
            }
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
                        let readData = Data(bytes: buffer, count: readCount)
                        #if DEBUG
                        SSHClientUITestDebug.noteReceived(readData)
                        #endif
                        state.batchBuffer.append(readData)
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
                        logSSHReadFailure(
                            kind: "shell_read_failed",
                            code: Int32(bytesRead),
                            session: libssh2Session,
                            channelId: state.id,
                            loop: "outer"
                        )
                        closeShellInternal(state.id, reason: .readError(Int32(bytesRead)))
                        continue
                    }

                    // Check for EOF
                    if libssh2_channel_eof(state.channel) != 0 {
                        if !state.batchBuffer.isEmpty {
                            state.continuation.yield(state.batchBuffer)
                        }
                        logger.info("Channel EOF")
                        closeShellInternal(state.id, reason: .eof)
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
                    // Off-loop cancellation (probe timeout) marks the
                    // request and resumes its continuation; channel teardown
                    // is deferred to this loop — the only execution context
                    // that reads the channel (issue #121). The request stays
                    // in `execRequests` until torn down, keeping the loop
                    // alive (see `shouldOuterIOLoopContinue`) so the
                    // teardown is guaranteed to run.
                    if request.isCancelled {
                        await teardownExecChannel(request)
                        execRequests.removeValue(forKey: requestId)
                        didWork = true
                        continue
                    }
                    guard await ensureExecChannelReady(request) else { continue }

                    guard let execChannel = request.channel else { continue }

                    let bytesRead = libssh2_channel_read_ex(execChannel, 0, &buffer, buffer.count)
                    if bytesRead > 0 {
                        request.output.append(Data(bytes: buffer, count: Int(bytesRead)))
                        didWork = true
                    } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No data yet
                    } else if bytesRead < 0 {
                        logSSHReadFailure(
                            kind: "exec_read_failed",
                            code: Int32(bytesRead),
                            session: libssh2Session,
                            channelId: requestId,
                            loop: "outer"
                        )
                        await finishExecRequest(requestId, error: SSHError.socketError("Exec read failed: \(bytesRead)"))
                        continue
                    }

                    let stderrRead = libssh2_channel_read_ex(execChannel, 1, &buffer, buffer.count)
                    if stderrRead > 0 {
                        request.stderr.append(Data(bytes: buffer, count: Int(stderrRead)))
                        didWork = true
                    } else if stderrRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No stderr data yet
                    } else if stderrRead < 0 {
                        logSSHReadFailure(
                            kind: "exec_stderr_read_failed",
                            code: Int32(stderrRead),
                            session: libssh2Session,
                            channelId: requestId,
                            loop: "outer"
                        )
                        await finishExecRequest(requestId, error: SSHError.socketError("Exec stderr read failed: \(stderrRead)"))
                        continue
                    }

                    if let currentChannel = request.channel, libssh2_channel_eof(currentChannel) != 0 {
                        await finishExecRequest(requestId, error: nil)
                        didWork = true
                    }
                }
            }

            // Exit the outer loop when there are no outer shell channels
            // AND no outer exec requests. Inner (Teleport) shell/exec
            // requests are tracked in the same dictionaries but drained by
            // `innerIOLoop`; they must not keep the outer loop alive (it
            // would spin on `waitForSocket` with no work to do). A request
            // cancelled off-loop stays in `execRequests` until this loop
            // tears its channel down, so it counts as work and keeps the
            // loop alive — guaranteeing the deferred teardown runs
            // (issue #121).
            let hasOuterShell = shellChannels.values.contains { !$0.isInner }
            let hasOuterExec = execRequests.values.contains { !$0.isInner }
            if !Self.shouldOuterIOLoopContinue(
                hasOuterShell: hasOuterShell,
                hasOuterExec: hasOuterExec
            ) {
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

    /// Why a shell channel is being closed. Logged with the monotonic
    /// `diagEventCounter` so CI evidence can order a read failure
    /// (remote/network cause, issue #120) against the close (app-initiated
    /// cause): `shell_read_failed event=N` immediately followed by
    /// `shell_closed reason=read_error event=N+1` means the transport died
    /// first; a bare `shell_closed reason=app_initiated` with no preceding
    /// read failure means the app tore the shell down.
    enum ShellCloseReason {
        case eof
        case readError(Int32)
        case appInitiated
        case loopExit
        case transportInvalidated

        var diagDescription: String {
            switch self {
            case .eof: return "eof"
            case .readError(let code): return "read_error:\(code)"
            case .appInitiated: return "app_initiated"
            case .loopExit: return "loop_exit"
            case .transportInvalidated: return "transport_invalidated"
            }
        }
    }

    func closeShell(_ shellId: UUID) async {
        closeShellInternal(shellId, reason: .appInitiated)
    }

    private func closeShellInternal(_ shellId: UUID, reason: ShellCloseReason) {
        guard let state = shellChannels.removeValue(forKey: shellId) else { return }
        if !state.batchBuffer.isEmpty {
            state.continuation.yield(state.batchBuffer)
        }
        libssh2_channel_close(state.channel)
        libssh2_channel_free(state.channel)
        state.continuation.finish()
        logger.diagError(
            "SSHSession",
            "ssh_diag shell_closed shell=\(shellId.uuidString) reason=\(reason.diagDescription) event=\(nextDiagEventCounter())"
        )
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
            logger.diagError(
                "SSHSession",
                "ssh_diag shell_closed shell=\(state.id.uuidString) reason=loop_exit event=\(nextDiagEventCounter())"
            )
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
            logger.diagError(
                "SSHSession",
                "ssh_diag shell_closed shell=\(state.id.uuidString) reason=transport_invalidated event=\(nextDiagEventCounter())"
            )
        }
    }

    private func failAllExecRequests(error: Error) {
        let requests = execRequests
        execRequests.removeAll()
        for request in requests.values {
            request.channel = nil
            // `resume` is a no-op for a request already completed by the
            // off-loop cancellation path — resuming twice would crash.
            request.resume(throwing: error)
        }
    }

    /// Increment and return the session's monotonic diagnostic counter.
    private func nextDiagEventCounter() -> UInt64 {
        diagEventCounter += 1
        return diagEventCounter
    }

    /// Emit a socket-level read-failure diagnostic (issue #120 evidence).
    /// Combines the libssh2 last-error string, the failing code, a
    /// monotonic event counter, and the affected channel id so CI logs can
    /// order a read failure against a subsequent shell close. The libssh2
    /// error string is IP-redacted; no credentials, hosts, or terminal
    /// content are logged. Mirrored into the on-device diagnostics ring
    /// AND os_log (both are captured by the CI `simctl log show` dump).
    private func logSSHReadFailure(
        kind: String,
        code: Int32,
        session: OpaquePointer?,
        channelId: UUID,
        loop: String
    ) {
        var errmsg: UnsafeMutablePointer<CChar>?
        var errmsgLen: Int32 = 0
        let lastErrno = session.map { libssh2_session_last_errno($0) } ?? 0
        var lastError = "no-session"
        if let session {
            libssh2_session_last_error(session, &errmsg, &errmsgLen, 0)
            if let errmsg {
                lastError = SSHError.redacted(String(cString: errmsg), server: nil)
            }
        }
        logger.diagError(
            "SSHSession",
            "ssh_diag \(kind) id=\(channelId.uuidString) code=\(code) errno=\(lastErrno) libssh2=\(lastError) event=\(nextDiagEventCounter()) loop=\(loop)"
        )
    }

    private func ensureExecChannelReady(_ request: ExecRequest) async -> Bool {
        guard let session = libssh2Session else {
            await finishExecRequest(request.id, error: SSHError.notConnected)
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
                await finishExecRequest(request.id, error: SSHError.channelOpenFailed)
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
                await finishExecRequest(request.id, error: SSHError.unknown("Exec failed: \(execResult)"))
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
    private func ensureInnerExecChannelReady(_ request: ExecRequest) async -> Bool {
        guard let session = innerLibssh2Session,
              innerSocket >= 0,
              innerAtomicSocket.isUsable,
              !hasBeenCleaned else {
            await finishExecRequest(request.id, error: SSHError.notConnected)
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
                await finishExecRequest(request.id, error: SSHError.channelOpenFailed)
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
                await finishExecRequest(request.id, error: SSHError.unknown("Inner exec failed: \(execResult)"))
                return false
            }
            request.isStarted = true
        }

        return true
    }

    /// Loop-side completion of an exec request: removes the request from
    /// `execRequests` (transferring channel ownership to this context),
    /// closes + frees the channel EAGAIN-aware, then resumes the
    /// continuation exactly once. Must only run on the I/O loop that reads
    /// the channel — never from the cancellation/timeout path.
    private func finishExecRequest(_ requestId: UUID, error: Error?) async {
        guard let request = execRequests.removeValue(forKey: requestId) else { return }
        await teardownExecChannel(request)
        if let error = error {
            request.resume(throwing: error)
        } else {
            if !request.stderr.isEmpty {
                // Remote stderr is arbitrary server text and the OSLog/ring
                // merge feeds the shareable diagnostics report: log the byte
                // count only, never the payload.
                logger.debug("Exec command stderr bytes=\(request.stderr.count)")
            }
            let output = String(data: request.output, encoding: .utf8) ?? ""
            request.resume(returning: output)
        }
    }

    /// Close + free an exec request's channel from the owning I/O loop.
    ///
    /// Ownership rule (issue #121): the loop that reads a channel is the
    /// only execution context allowed to close/free it; off-loop
    /// cancellation only marks the request. EAGAIN-aware: on a non-blocking
    /// session a close may need retries before the channel can be freed —
    /// freeing early leaves a dangling entry in the session's channel list
    /// and corrupts subsequent reads on other channels. Runs on the loop,
    /// so it can await socket wakeups between retries. If the session is
    /// already gone the channel is left for `libssh2_session_free` to reap.
    private func teardownExecChannel(_ request: ExecRequest) async {
        guard let channel = request.channel else { return }
        // Claim ownership before any suspension so a concurrent
        // `failAllExecRequests` (session teardown) cannot abandon a channel
        // this context is about to close.
        request.channel = nil
        if request.isInner {
            guard let session = innerLibssh2Session else { return }
            _ = await completeActiveChannelCleanupCall(session: session, isInner: true) {
                libssh2_channel_close(channel)
            }
            _ = await completeActiveChannelCleanupCall(session: session, isInner: true) {
                libssh2_channel_free(channel)
            }
        } else {
            guard let session = libssh2Session else { return }
            _ = await completeActiveChannelCleanupCall(session: session) {
                libssh2_channel_close(channel)
            }
            _ = await completeActiveChannelCleanupCall(session: session) {
                libssh2_channel_free(channel)
            }
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
                #if DEBUG
                SSHClientUITestDebug.noteWrite(data)
                #endif
            } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                // Would block - actually wait for socket to be ready
                await waitForSocket()
            } else {
                #if DEBUG
                SSHClientUITestDebug.noteError("libssh2_channel_write_ex returned \(written)")
                #endif
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
                throw lastTeleportPrepareFailure ?? SSHError.notConnected
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
            // The prepare failed and left no inner session: surface its real
            // failure instead of the generic `.notConnected` (#268).
            throw lastTeleportPrepareFailure ?? SSHError.notConnected
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
        let request = ExecRequest(id: UUID(), command: command, isInner: isInner)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                execRequests[request.id] = request
                let installed = request.install(continuation)
                // Cancel-before-install, both windows: `onCancel` may have
                // fired before the continuation was installed (handled by
                // `install`), or the task may already be cancelled while
                // this body is being scheduled. Either way the request never
                // started, so the freshly registered entry is removed before
                // the loop can pick it up (it has no channel to tear down)
                // and the holder resumes exactly once.
                if !installed || Task.isCancelled {
                    execRequests.removeValue(forKey: request.id)
                    request.cancel()
                }
            }
        }, onCancel: {
            request.cancel()
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
        // Liveness gate (#286): during the deferred-teardown window
        // `libssh2Session` stays non-nil while the session's free is pending;
        // skipping the call there is behaviour-neutral for a healthy session.
        guard isActive, let session = libssh2Session else { return }
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
    /// The Teleport *user* (the SSH identity). For `.faceIDTeleport` this is
    /// the identity that owns the certificate, NOT the SSH username — the
    /// username is resolved at the auth sites to a certificate principal (the
    /// host login, `config.teleportHostLogin`).
    let username: String
    /// The stored Teleport host login (a certificate principal) preference,
    /// or nil. Only meaningful for `.faceIDTeleport`.
    let teleportHostLogin: String?
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
        teleportHostLogin: String? = nil,
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
        self.teleportHostLogin = teleportHostLogin
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
    case hostKeyUnknown(host: String, port: Int, fingerprint: String, keyType: Int)
    case socketError(String)
    case teleportCertMissing
    /// The Teleport SSH username could not be resolved to a principal of the
    /// current certificate (no principals, an ambiguous set, or an unreadable
    /// cert). The connect path clears the credential before throwing, so
    /// readiness flips to `.needsBootstrap` and setup is reachable again.
    case teleportHostLoginUnresolvable(TeleportHostLoginFailure)
    /// A Teleport prepare-step failure (outer channel, proxy-subsystem
    /// request, transport, inner handshake/hostkey/auth) carrying the proxy's
    /// rejection text. The payload is arbitrary server output: it is shown
    /// transiently in `errorDescription` and rendered case-only by
    /// `diagnosticsMessage` (#268).
    case teleportPrepareFailed(String)
    case unknown(String)

    /// Marker prefix for `hostKeyUnknown`'s message. `ConnectionState.failed`
    /// only stores the localized string, so the terminal UI matches on it to
    /// decide which host-key trust affordance to show.
    static let hostKeyUnknownMessageMarker = "Host key is not trusted yet"

    /// The fingerprint embedded in a `hostKeyUnknown` failure message.
    ///
    /// The trust affordance re-reads the presented fingerprint from the
    /// message the banner is showing, so the prompt can be refused when the
    /// pending entry no longer describes that failure.
    static func fingerprint(inFailureMessage message: String) -> String? {
        // The fingerprint is the last parenthesised group: the host itself
        // can contain parentheses, while the base64 fingerprint cannot.
        guard let marker = message.range(of: hostKeyUnknownMessageMarker),
              let open = message[marker.upperBound...].lastIndex(of: "("),
              let close = message[message.index(after: open)...].firstIndex(of: ")") else {
            return nil
        }
        let fingerprint = message[message.index(after: open)..<close]
        return fingerprint.isEmpty ? nil : String(fingerprint)
    }

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
             .hostKeyUnknown,
             .teleportCertMissing,
             .teleportHostLoginUnresolvable,
             .teleportPrepareFailed,
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
        case .hostKeyUnknown(let host, let port, let fingerprint, _):
            return "\(Self.hostKeyUnknownMessageMarker) for \(host):\(port) (\(fingerprint)). Verify the fingerprint with the server owner before continuing."
        case .socketError(let msg): return "Socket error: \(msg)"
        case .teleportCertMissing:
            return String(localized: "Teleport certificate is missing or expired. Sign in with Face ID to refresh it.")
        case .teleportHostLoginUnresolvable(let failure):
            return failure.errorDescription
        case .teleportPrepareFailed(let message):
            return "Teleport connection failed: \(message)"
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

/// Sync file-marker diagnostics for the Teleport handshake paths (bypasses
/// os_log — the simulator's os_log pipeline can wedge on CI, hiding where a
/// stall happens). Append-only markers in `/tmp/vvterm-diag-<pid>.txt`; the
/// teleport-e2e workflow uploads the newest file as an artifact.
///
/// CI-only instrumentation: a few writes per connection.
private final class SyncDiag {
    private let fd: Int32

    init() {
        let path = "/tmp/vvterm-diag-\(getpid()).txt"
        fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }

    func mark(_ s: String) {
        guard fd >= 0 else { return }
        s.withCString { Darwin.write(fd, $0, strlen($0)) }
        _ = Darwin.write(fd, "\n", 1)
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }
}
