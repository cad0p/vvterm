import Foundation
import os.log

nonisolated struct RemoteTmuxSession: Hashable, Sendable {
    let name: String
    let attachedClients: Int
    let windowCount: Int
}

nonisolated enum TmuxSessionOwnership: String, Codable, Hashable, Sendable {
    case managed
    case external
}

nonisolated enum RemoteTmuxBackend: Hashable, Sendable {
    case unixTmux
    case windowsPsmux(commandName: String, shellFamily: RemoteShellFamily, powerShellExecutable: String?)

    nonisolated var isWindows: Bool {
        if case .windowsPsmux = self {
            return true
        }
        return false
    }
}

nonisolated enum RemoteTmuxProbeFailure: Hashable, Sendable {
    case cancelled
    case timeout
    case disconnected
    case transport(String)
    case channelOpenFailed
    case shellRequestFailed
    case invalidResponse
    case commandFailed(String)

    nonisolated var retryError: Error {
        switch self {
        case .cancelled:
            return CancellationError()
        case .timeout:
            return SSHError.timeout
        case .disconnected:
            return SSHError.notConnected
        case .transport(let message):
            return SSHError.socketError(message)
        case .channelOpenFailed:
            return SSHError.channelOpenFailed
        case .shellRequestFailed:
            return SSHError.shellRequestFailed
        case .invalidResponse:
            return SSHError.unknown("Unable to verify tmux availability")
        case .commandFailed(let message):
            return SSHError.unknown(message)
        }
    }

    nonisolated static func resolve(_ error: Error) -> Self {
        if error is CancellationError {
            return .cancelled
        }
        guard let sshError = error as? SSHError else {
            return .commandFailed(error.localizedDescription)
        }
        switch sshError {
        case .timeout:
            return .timeout
        case .notConnected:
            return .disconnected
        case .connectionFailed(let message), .socketError(let message):
            return .transport(message)
        case .channelOpenFailed:
            return .channelOpenFailed
        case .shellRequestFailed:
            return .shellRequestFailed
        default:
            return .commandFailed(sshError.localizedDescription)
        }
    }

    nonisolated var logDescription: String {
        switch self {
        case .cancelled: return "cancelled"
        case .timeout: return "timeout"
        case .disconnected: return "disconnected"
        case .transport: return "transport failure"
        case .channelOpenFailed: return "channel open failure"
        case .shellRequestFailed: return "shell request failure"
        case .invalidResponse: return "invalid response"
        case .commandFailed: return "command failure"
        }
    }
}

nonisolated enum RemoteTmuxAvailability: Hashable, Sendable {
    case unsupported
    case available(RemoteTmuxBackend)
    case confirmedMissing
    case indeterminate(RemoteTmuxProbeFailure)

    nonisolated var backend: RemoteTmuxBackend? {
        guard case .available(let backend) = self else { return nil }
        return backend
    }

    nonisolated var logDescription: String {
        switch self {
        case .unsupported: return "unsupported"
        case .available(let backend): return "available (\(String(describing: backend)))"
        case .confirmedMissing: return "confirmed missing"
        case .indeterminate(let failure): return "indeterminate (\(failure.logDescription))"
        }
    }
}

actor RemoteTmuxManager {
    static let shared = RemoteTmuxManager()

    private let availabilityTimeout: Duration = .seconds(8)
    private let listTimeout: Duration = .seconds(12)
    private let configTimeout: Duration = .seconds(20)
    private let killTimeout: Duration = .seconds(10)
    private let cleanupTimeout: Duration = .seconds(20)
    private let pathTimeout: Duration = .seconds(10)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm",
        category: "Tmux"
    )

    private init() {}

    func tmuxAvailability(using client: SSHClient) async -> RemoteTmuxAvailability {
        let probeId = UUID().uuidString
        let startedAt = ContinuousClock.now
        logger.info("Starting tmux availability probe \(probeId, privacy: .public)")
        let environment = await client.remoteEnvironment()
        guard !Task.isCancelled else {
            return .indeterminate(.cancelled)
        }
        let result = await tmuxAvailability(in: environment) { command, timeout in
            try await client.execute(command, timeout: timeout)
        }
        let elapsed = startedAt.duration(to: ContinuousClock.now)
        logger.info(
            "Tmux availability probe \(probeId, privacy: .public) resolved \(result.logDescription, privacy: .public) after \(String(describing: elapsed), privacy: .public)"
        )
        return result
    }

    func tmuxAvailability(
        in environment: RemoteEnvironment,
        execute: RemoteEnvironmentResolver.CommandExecutor
    ) async -> RemoteTmuxAvailability {
        guard !Task.isCancelled else { return .indeterminate(.cancelled) }
        guard environment.supportsTmuxRuntime else { return .unsupported }

        if environment.platform == .windows {
            return await windowsPsmuxAvailability(for: environment, execute: execute)
        }

        let okMarker = "__VVTERM_TMUX_OK__"
        let command = tmuxAvailabilityProbeCommand(okMarker: okMarker)
        do {
            let output = try await execute(command, availabilityTimeout)
            try Task.checkCancellation()
            return classifyAvailabilityOutput(
                output,
                availableMarker: okMarker,
                missingMarker: "__VVTERM_TMUX_NO__",
                backend: .unixTmux
            )
        } catch {
            return .indeterminate(.resolve(error))
        }
    }

    private func availableBackend(using client: SSHClient) async -> RemoteTmuxBackend? {
        await tmuxAvailability(using: client).backend
    }

    private func resolveBackend(
        _ explicitBackend: RemoteTmuxBackend?,
        using client: SSHClient
    ) async -> RemoteTmuxBackend? {
        if let explicitBackend {
            return explicitBackend
        }
        return await availableBackend(using: client)
    }

    func tmuxInstallBackend(using client: SSHClient) async -> RemoteTmuxBackend? {
        let environment = await client.remoteEnvironment()
        guard environment.supportsTmuxRuntime else { return nil }

        if environment.platform == .windows {
            return .windowsPsmux(
                commandName: "psmux",
                shellFamily: environment.shellProfile.family,
                powerShellExecutable: environment.powerShellExecutable ?? environment.shellProfile.executableName
            )
        }

        return .unixTmux
    }

    func listSessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async throws -> [RemoteTmuxSession] {
        let candidates = listSessionCommands(backend: backend)
        var lastError: Error?
        var completedProbe = false

        for (index, command) in candidates.enumerated() {
            do {
                let output = try await client.execute(command, timeout: listTimeout)
                completedProbe = true
                let sessions = parseSessionListOutput(output, allowLegacy: index == candidates.count - 1)

                if !sessions.isEmpty {
                    return sessions
                }
            } catch {
                lastError = error
            }
        }

        if completedProbe {
            return []
        }
        throw lastError ?? SSHError.unknown("Unable to list tmux sessions")
    }

    func prepareConfig(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async {
        let backend = await resolveBackend(explicitBackend, using: client)
        guard let backend, case .windowsPsmux = backend else { return }
        let command = windowsConfigWriteCommand(terminalType: terminalType, backend: backend)
        _ = try? await client.execute(command, timeout: configTimeout)
    }

    nonisolated func attachCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleMarkerToken: String? = nil
    ) -> String {
        let body = attachOrCreateBody(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend,
            lifecycleMarkerToken: lifecycleMarkerToken
        )
        return body
    }

    nonisolated func attachExistingCommand(
        sessionName: String,
        ownership: TmuxSessionOwnership,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleMarkerToken: String? = nil
    ) -> String {
        let body = attachExistingBody(
            sessionName: sessionName,
            missingCommand: lifecycleMarkerToken == nil
                ? missingSessionCommand(backend: backend)
                : lifecycleMissingSessionCommand(backend: backend),
            backend: backend,
            lifecycleMarkerToken: lifecycleMarkerToken,
            ownership: ownership
        )
        return body
    }

    nonisolated func sessionPresenceProbeCommand(
        sessionName: String,
        backend: RemoteTmuxBackend = .unixTmux,
        existsMarker: String,
        missingMarker: String
    ) -> String {
        if case .windowsPsmux(let commandName, _, _) = backend {
            let script = """
            $vvtermPsmux = \(powerShellQuoted(commandName))
            $vvtermSession = \(powerShellQuoted(sessionName))
            & $vvtermPsmux has-session -t $vvtermSession 2>$null
            if ($LASTEXITCODE -eq 0) {
              [Console]::Out.Write(\(powerShellQuoted(existsMarker)))
            } else {
              [Console]::Out.Write(\(powerShellQuoted(missingMarker)))
            }
            """
            return windowsShellCommand(powerShellScript: script, backend: backend)
        }

        let exactSession = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let plainSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let exists = RemoteTerminalBootstrap.shellQuoted(existsMarker)
        let missing = RemoteTerminalBootstrap.shellQuoted(missingMarker)
        let tmuxProbe = tmuxCommand(includeUTF8: false)
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport()); \
        if \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null || \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
        printf '%s' \(exists); else printf '%s' \(missing); fi
        """
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    nonisolated func installAndAttachScript(
        sessionName: String,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend = .unixTmux,
        attachAfterInstall: Bool = true
    ) -> String {
        if backend.isWindows {
            return windowsInstallAndAttachScript(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                terminalType: terminalType,
                backend: backend,
                attachAfterInstall: attachAfterInstall
            )
        }

        let attach = attachCommand(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend
        )
        let afterInstall = attachAfterInstall ? attach : ":"

        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        if command -v tmux >/dev/null 2>&1; then
          \(afterInstall);
        else
          if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi;
          OS_NAME="$(uname -s)";
          if [ "$OS_NAME" = "Darwin" ]; then
            if command -v brew >/dev/null 2>&1; then
              brew install tmux;
            elif command -v port >/dev/null 2>&1; then
              $SUDO port install tmux;
            else
              echo "No supported package manager found for macOS.";
            fi;
          elif [ "$OS_NAME" = "Linux" ]; then
            if command -v apt-get >/dev/null 2>&1; then
              $SUDO apt-get update && $SUDO apt-get install -y tmux;
            elif command -v dnf >/dev/null 2>&1; then
              $SUDO dnf install -y tmux;
            elif command -v yum >/dev/null 2>&1; then
              $SUDO yum install -y tmux;
            elif command -v pacman >/dev/null 2>&1; then
              $SUDO pacman -Sy --noconfirm tmux;
            elif command -v apk >/dev/null 2>&1; then
              $SUDO apk add tmux;
            elif command -v zypper >/dev/null 2>&1; then
              $SUDO zypper -n install tmux;
            elif command -v xbps-install >/dev/null 2>&1; then
              $SUDO xbps-install -Sy tmux;
            elif command -v opkg >/dev/null 2>&1; then
              $SUDO opkg update && $SUDO opkg install tmux;
            elif command -v emerge >/dev/null 2>&1; then
              $SUDO emerge app-misc/tmux;
            elif command -v pkg >/dev/null 2>&1; then
              $SUDO pkg install -y tmux;
            else
              echo "No supported package manager found for Linux.";
            fi;
          else
            echo "Unsupported OS: $OS_NAME";
          fi;
        fi;
        if command -v tmux >/dev/null 2>&1; then \(afterInstall); else echo "tmux installation failed."; fi
        """
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    func sendScript(_ script: String, using client: SSHClient, shellId: UUID) async {
        let payload = script.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        try? await client.write(data, to: shellId)
    }

    func killSession(
        named sessionName: String,
        using client: SSHClient,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async {
        let backend = await resolveBackend(explicitBackend, using: client)
        guard let backend else { return }
        let command = killSessionCommand(named: sessionName, backend: backend)
        _ = try? await client.execute(command, timeout: killTimeout)
    }

    func cleanupLegacySessions(
        using client: SSHClient,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async {
        let backend = await resolveBackend(explicitBackend, using: client)
        guard let backend else { return }
        guard case .unixTmux = backend else { return }
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        if command -v tmux >/dev/null 2>&1; then
          tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null | awk '$1 ~ /^vvterm_[0-9a-fA-F-]+$/ && $2 == 0 { print $1 }' | while IFS= read -r name; do
            tmux kill-session -t "$name" 2>/dev/null || true;
          done;
        fi
        """
        let command = "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
        _ = try? await client.execute(command, timeout: cleanupTimeout)
    }

    func cleanupDetachedSessions(
        deviceId: String,
        keeping sessionNames: Set<String>,
        using client: SSHClient,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async {
        let backend = await resolveBackend(explicitBackend, using: client)
        guard let backend else { return }
        let prefix = "vvterm_\(deviceId)_"
        let keep = sessionNames
        let sessions: [RemoteTmuxSession]
        do {
            sessions = try await listSessions(using: client, backend: backend)
        } catch {
            logger.warning("Unable to list detached tmux sessions during cleanup: \(error.localizedDescription, privacy: .public)")
            return
        }

        for session in sessions {
            guard session.name.hasPrefix(prefix) else { continue }
            guard session.attachedClients == 0 else { continue }
            guard !keep.contains(session.name) else { continue }
            await killSession(named: session.name, using: client, backend: backend)
        }
    }

    func currentPath(
        sessionName: String,
        using client: SSHClient,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async -> String? {
        let backend = await resolveBackend(explicitBackend, using: client)
        guard let backend else { return nil }
        let command = currentPathCommand(sessionName: sessionName, backend: backend)
        guard let output = try? await client.execute(command, timeout: pathTimeout) else { return nil }
        let trimmed = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private func shellDirectoryArgument(_ value: String) -> String {
        if value == "~" {
            return "$HOME"
        }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    nonisolated private func missingSessionCommand(backend: RemoteTmuxBackend) -> String {
        if backend.isWindows {
            return windowsDefaultShellCommand(backend: backend)
        }
        return "exec \"${SHELL:-/bin/sh}\" -l"
    }

    nonisolated private func attachOrCreateBody(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleMarkerToken: String? = nil
    ) -> String {
        if case .windowsPsmux = backend {
            return windowsAttachOrCreateCommand(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken
            )
        }

        let createCommand = createSessionCommand(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend,
            lifecycleMarkerToken: lifecycleMarkerToken
        )
        return attachExistingBody(
            sessionName: sessionName,
            missingCommand: createCommand,
            backend: backend,
            lifecycleMarkerToken: lifecycleMarkerToken,
            reportsCreationFailure: true,
            ownership: .managed
        )
    }

    nonisolated private func attachExistingBody(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleMarkerToken: String? = nil,
        reportsCreationFailure: Bool = false,
        ownership: TmuxSessionOwnership
    ) -> String {
        if case .windowsPsmux = backend {
            return windowsAttachExistingCommand(
                sessionName: sessionName,
                missingCommand: missingCommand,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken,
                reportsCreationFailure: reportsCreationFailure,
                ownership: ownership
            )
        }

        let exactSession = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let plainSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let tmuxProbe = tmuxCommand(includeUTF8: false)
        let usesManagedConfiguration = ownership == .managed
        let replacesProcess = lifecycleMarkerToken == nil
        let managedConfiguration = usesManagedConfiguration
            ? "\(managedSessionConfigurationCommand(sessionName: sessionName)); \(managedWindowsConfigurationCommand(sessionName: sessionName)); "
            : ""
        let exactAttach = tmuxAttachCommand(
            target: exactSession,
            replacesProcess: replacesProcess,
            advertisesManagedFeatures: usesManagedConfiguration
        )
        let plainAttach = tmuxAttachCommand(
            target: plainSession,
            replacesProcess: replacesProcess,
            advertisesManagedFeatures: usesManagedConfiguration
        )
        let creationStatusCapture = reportsCreationFailure && lifecycleMarkerToken != nil
            ? "; vvtermTmuxCreateStatus=$?"
            : ""

        let lifecycleReport: String
        if let lifecycleMarkerToken {
            let detached = RemoteTerminalBootstrap.shellQuoted(
                TmuxLifecycleMarker.sequence(token: lifecycleMarkerToken, event: .detached)
            )
            let ended = RemoteTerminalBootstrap.shellQuoted(
                TmuxLifecycleMarker.sequence(token: lifecycleMarkerToken, event: .ended)
            )
            if reportsCreationFailure {
                let creationFailed = RemoteTerminalBootstrap.shellQuoted(
                    TmuxLifecycleMarker.sequence(token: lifecycleMarkerToken, event: .creationFailed)
                )
                lifecycleReport = """
                ; if [ "${vvtermTmuxCreateStatus:-0}" -ne 0 ]; then printf '%s' \(creationFailed); \
                elif \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null || \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
                printf '%s' \(detached); else printf '%s' \(ended); fi
                """
            } else {
                lifecycleReport = """
                ; if \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null || \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
                printf '%s' \(detached); else printf '%s' \(ended); fi
                """
            }
        } else {
            lifecycleReport = ""
        }

        return """
        \(RemoteTerminalBootstrap.shellPathExport()); \
        if \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null; then \
        \(managedConfiguration)\(exactAttach); \
        elif \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
        \(managedConfiguration)\(plainAttach); \
        else \(missingCommand)\(creationStatusCapture); fi\(lifecycleReport)
        """
    }

    nonisolated private func createSessionCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleMarkerToken: String? = nil
    ) -> String {
        if case .windowsPsmux = backend {
            return windowsCreateSessionCommand(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                backend: backend
            )
        }

        let escapedDir = shellDirectoryArgument(workingDirectory)
        let escapedSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let exactSession = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let sessionWindowTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName):")
        let bootstrapWindowName = "__vvterm_bootstrap__"
        let escapedBootstrapWindow = RemoteTerminalBootstrap.shellQuoted(bootstrapWindowName)
        let bootstrapWindowTarget = RemoteTerminalBootstrap.shellQuoted(
            "=\(sessionName):\(bootstrapWindowName)"
        )
        let tmux = tmuxCommand(includeUTF8: false)
        let sessionConfiguration = managedSessionConfigurationCommand(sessionName: sessionName)
        let windowsConfiguration = managedWindowsConfigurationCommand(sessionName: sessionName)
        let createBootstrap = "\(tmux) new-session -d -s \(escapedSession) -n \(escapedBootstrapWindow) -c \(escapedDir) \(RemoteTerminalBootstrap.shellQuoted("sleep 86400"))"
        let createTerminalWindow = "\(tmux) new-window -d -t \(sessionWindowTarget) -c \(escapedDir)"
        let removeBootstrap = "\(tmux) kill-window -t \(bootstrapWindowTarget)"
        let renumberWindows = "\(tmux) move-window -r -t \(sessionWindowTarget)"
        let removeFailedSession = "\(tmux) kill-session -t \(exactSession) 2>/dev/null"
        let attach = tmuxAttachCommand(
            target: escapedSession,
            replacesProcess: lifecycleMarkerToken == nil,
            advertisesManagedFeatures: true
        )
        return """
        if \(createBootstrap) 2>/dev/null; then \
        if \(sessionConfiguration) && \
        \(createTerminalWindow) 2>/dev/null && \
        \(removeBootstrap) 2>/dev/null && \
        \(renumberWindows) 2>/dev/null && \
        \(windowsConfiguration); then \(attach); \
        else \(removeFailedSession); false; fi; \
        elif \(tmux) has-session -t \(exactSession) 2>/dev/null; then \
        \(sessionConfiguration); \(windowsConfiguration); \(attach); \
        else false; fi
        """
    }

    nonisolated private func managedSessionConfigurationCommand(sessionName: String) -> String {
        let tmux = tmuxCommand(includeUTF8: false)
        let sessionOptionTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName):")
        let sessionEnvironmentTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let paneTitle = RemoteTerminalBootstrap.shellQuoted("#{pane_title}")

        var commands = [
            "\(tmux) set-option -q -t \(sessionOptionTarget) status off",
            "\(tmux) set-option -q -t \(sessionOptionTarget) history-limit 10000",
            "\(tmux) set-option -q -t \(sessionOptionTarget) mouse on",
            "\(tmux) set-option -q -t \(sessionOptionTarget) set-titles on",
            "\(tmux) set-option -q -t \(sessionOptionTarget) set-titles-string \(paneTitle)"
        ]
        commands.append(contentsOf: RemoteTerminalBootstrap.terminalEnvironment().map { variable in
            let value = RemoteTerminalBootstrap.shellQuoted(variable.value)
            return "\(tmux) set-environment -t \(sessionEnvironmentTarget) \(variable.name) \(value)"
        })
        return commands.joined(separator: " && ")
    }

    nonisolated private func managedWindowsConfigurationCommand(sessionName: String) -> String {
        let tmux = tmuxCommand(includeUTF8: false)
        let sessionTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName):")
        let settings = [
            (name: "allow-passthrough", value: "on"),
            (name: "allow-set-title", value: "on"),
            (name: "mode-style", value: tmuxThemeConfiguration().modeStyle),
            // `clear` sends E3 followed by 2J. Keep this override on each
            // managed window so the visible grid is not restored into history.
            (name: "scroll-on-clear", value: "off")
        ]
        let existingWindowCommands = settings.map { setting in
            let value = RemoteTerminalBootstrap.shellQuoted(setting.value)
            return "\(tmux) set-option -wq -t \"$vvtermWindow\" \(setting.name) \(value)"
        }.joined(separator: " && ")
        let futureWindowCommands = settings.map { setting in
            let value = RemoteTerminalBootstrap.shellQuoted(setting.value)
            return "set-option -wq \(setting.name) \(value)"
        }.joined(separator: " ; ")
        // Window options belong to the window object, so skip linked windows
        // that may also be visible in a user's external session.
        let windowListingFormat = RemoteTerminalBootstrap.shellQuoted(
            "#{window_id} #{window_linked}"
        )
        let unlinkedWindowCondition = RemoteTerminalBootstrap.shellQuoted(
            "#{==:#{window_linked},0}"
        )
        let guardedFutureWindowCommands = [
            "if-shell -F",
            unlinkedWindowCondition,
            RemoteTerminalBootstrap.shellQuoted(futureWindowCommands)
        ].joined(separator: " ")
        // A stable array index makes reattach idempotent without replacing
        // other session-local after-new-window hooks.
        let hookName = RemoteTerminalBootstrap.shellQuoted("after-new-window[1000]")
        let hookCommand = RemoteTerminalBootstrap.shellQuoted(guardedFutureWindowCommands)

        return """
        (vvtermWindows="$(\(tmux) list-windows -t \(sessionTarget) -F \(windowListingFormat) 2>/dev/null)" || exit 1; \
        printf '%s\\n' "$vvtermWindows" | while IFS=' ' read -r vvtermWindow vvtermLinked; do \
        [ "$vvtermLinked" = 0 ] || continue; \(existingWindowCommands) || exit 1; done || exit 1; \
        \(tmux) set-hook -t \(sessionTarget) \(hookName) \(hookCommand) 2>/dev/null || true)
        """
    }

    nonisolated private func tmuxAttachCommand(
        target: String,
        replacesProcess: Bool,
        advertisesManagedFeatures: Bool
    ) -> String {
        let processReplacement = replacesProcess ? "exec " : ""
        let tmux = tmuxCommand(includeUTF8: true)
        let attach = "\(processReplacement)\(tmux) attach-session -t \(target)"
        guard advertisesManagedFeatures else { return attach }

        let features = "-T RGB,hyperlinks"
        return "if tmux \(features) -V >/dev/null 2>&1; then \(processReplacement)\(tmux) \(features) attach-session -t \(target); else \(attach); fi"
    }

    nonisolated private func lifecycleMissingSessionCommand(backend: RemoteTmuxBackend) -> String {
        backend.isWindows ? "$null" : ":"
    }

    nonisolated private func tmuxCommand(
        includeUTF8: Bool
    ) -> String {
        var parts = ["tmux"]
        if includeUTF8 {
            parts.append("-u")
        }
        return parts.joined(separator: " ")
    }

    nonisolated func tmuxAvailabilityProbeCommand(okMarker: String) -> String {
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        VVTERM_TMUX_BIN="";
        if command -v tmux >/dev/null 2>&1; then
          VVTERM_TMUX_BIN="$(command -v tmux 2>/dev/null)";
        fi;
        if [ -z "$VVTERM_TMUX_BIN" ]; then
          for candidate in /usr/bin/tmux /bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux /snap/bin/tmux; do
            if [ -x "$candidate" ]; then
              VVTERM_TMUX_BIN="$candidate";
              break;
            fi;
          done;
        fi;
        if [ -n "$VVTERM_TMUX_BIN" ] && "$VVTERM_TMUX_BIN" -V >/dev/null 2>&1; then
          printf '\(okMarker)';
        else
          printf '__VVTERM_TMUX_NO__';
        fi
        """
        return "sh -c \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    private func windowsPsmuxAvailability(
        for environment: RemoteEnvironment,
        execute: RemoteEnvironmentResolver.CommandExecutor
    ) async -> RemoteTmuxAvailability {
        let shellFamily = environment.shellProfile.family
        let powerShellExecutable = environment.powerShellExecutable ?? environment.shellProfile.executableName
        var firstIndeterminateFailure: RemoteTmuxProbeFailure?

        for (commandName, requirePsmuxExtension) in [
            ("psmux", false),
            ("pmux", false),
            ("tmux", true)
        ] {
            let backend = RemoteTmuxBackend.windowsPsmux(
                commandName: commandName,
                shellFamily: shellFamily,
                powerShellExecutable: powerShellExecutable
            )
            do {
                let output = try await execute(
                    windowsPsmuxAvailabilityProbeCommand(
                        commandName: commandName,
                        backend: backend,
                        requirePsmuxExtension: requirePsmuxExtension
                    ),
                    availabilityTimeout
                )
                try Task.checkCancellation()
                let resolution = classifyAvailabilityOutput(
                    output,
                    availableMarker: "__VVTERM_TMUX_OK__:\(commandName)",
                    missingMarker: "__VVTERM_TMUX_NO__:\(commandName)",
                    backend: backend
                )
                switch resolution {
                case .available:
                    return resolution
                case .indeterminate(let failure):
                    firstIndeterminateFailure = firstIndeterminateFailure ?? failure
                case .confirmedMissing:
                    break
                case .unsupported:
                    assertionFailure("A supported Windows tmux probe resolved as unsupported")
                }
            } catch {
                firstIndeterminateFailure = firstIndeterminateFailure ?? .resolve(error)
            }
        }

        if let firstIndeterminateFailure {
            return .indeterminate(firstIndeterminateFailure)
        }
        return .confirmedMissing
    }

    nonisolated func windowsPsmuxAvailabilityProbeCommand(
        commandName: String,
        backend: RemoteTmuxBackend,
        requirePsmuxExtension: Bool
    ) -> String {
        let availableMarker = "__VVTERM_TMUX_OK__:\(commandName)"
        let missingMarker = "__VVTERM_TMUX_NO__:\(commandName)"
        let script = """
        $vvtermAvailable = $false
        $cmd = Get-Command \(powerShellQuoted(commandName)) -ErrorAction SilentlyContinue
        if ($cmd) {
          & $cmd.Source -V *> $null
          if ($LASTEXITCODE -eq 0) {
            $vvtermCommands = (& $cmd.Source list-commands 2>$null) -join "`n"
            if (-not \(requirePsmuxExtension ? "$true" : "$false") -or $vvtermCommands.Contains('dump-state') -or $vvtermCommands.Contains('claim-session')) {
              $vvtermAvailable = $true
            }
          }
        }
        if ($vvtermAvailable) {
          Write-Output \(powerShellQuoted(availableMarker))
        } else {
          Write-Output \(powerShellQuoted(missingMarker))
        }
        """
        return windowsShellCommand(powerShellScript: script, backend: backend)
    }

    nonisolated private func classifyAvailabilityOutput(
        _ output: String,
        availableMarker: String,
        missingMarker: String,
        backend: RemoteTmuxBackend
    ) -> RemoteTmuxAvailability {
        let reportsAvailable = output.contains(availableMarker)
        let reportsMissing = output.contains(missingMarker)
        switch (reportsAvailable, reportsMissing) {
        case (true, false):
            return .available(backend)
        case (false, true):
            return .confirmedMissing
        case (false, false), (true, true):
            return .indeterminate(.invalidResponse)
        }
    }

    nonisolated private func listSessionCommands(backend: RemoteTmuxBackend) -> [String] {
        switch backend {
        case .unixTmux:
            let tmux = tmuxCommand(includeUTF8: false)
            let bodies = [
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions -F '#{session_name} #{session_attached} #{session_windows}' 2>/dev/null",
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null",
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions 2>/dev/null"
            ]
            return bodies.map { "sh -lc \(RemoteTerminalBootstrap.shellQuoted($0))" }

        case .windowsPsmux(let commandName, _, _):
            return [
                windowsPsmuxListSessionsCommand(commandName: commandName, format: "#{session_name} #{session_attached} #{session_windows}", backend: backend),
                windowsPsmuxListSessionsCommand(commandName: commandName, format: "#{session_name} #{session_attached}", backend: backend),
                windowsShellCommand(
                    powerShellScript: "& \(powerShellQuoted(commandName)) list-sessions 2>$null",
                    backend: backend
                )
            ]
        }
    }

    nonisolated private func windowsPsmuxListSessionsCommand(
        commandName: String,
        format: String,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: "& \(powerShellQuoted(commandName)) list-sessions -F \(powerShellQuoted(format)) 2>$null",
            backend: backend
        )
    }

    nonisolated func parseSessionListOutput(
        _ output: String,
        allowLegacy: Bool
    ) -> [RemoteTmuxSession] {
        var sessions: [RemoteTmuxSession] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            if let parsed = parseSessionLine(line) {
                sessions.append(
                    RemoteTmuxSession(
                        name: parsed.name,
                        attachedClients: parsed.attachedClients,
                        windowCount: parsed.windowCount
                    )
                )
                continue
            }
            if allowLegacy, let parsed = parseLegacySessionLine(line) {
                sessions.append(parsed)
            }
        }
        return sortSessions(sessions)
    }

    nonisolated private func parseSessionLine(_ line: String) -> (name: String, attachedClients: Int, windowCount: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Handle both real tabs and literal "\t" output formats.
        let normalized = trimmed.replacingOccurrences(of: "\\t", with: "\t")
        if let parsed = parseTabSeparatedSessionLine(normalized) {
            return parsed
        }

        // Parse rightmost numeric fields; name may contain spaces.
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard !parts.isEmpty else { return nil }

        if parts.count >= 3,
           let attached = parseAttachedClients(String(parts[parts.count - 2])),
           let windows = Int(parts[parts.count - 1]) {
            let name = parts[0..<(parts.count - 2)].map(String.init).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (name, max(0, attached), max(1, windows))
        }

        if parts.count >= 2,
           let attached = parseAttachedClients(String(parts[parts.count - 1])) {
            let name = parts[0..<(parts.count - 1)].map(String.init).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (name, max(0, attached), 1)
        }

        return nil
    }

    nonisolated private func parseTabSeparatedSessionLine(_ line: String) -> (name: String, attachedClients: Int, windowCount: Int)? {
        guard line.contains("\t") else { return nil }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let name = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let attachedClients: Int
        if parts.count >= 2 {
            attachedClients = parseAttachedClients(String(parts[1])) ?? 0
        } else {
            attachedClients = 0
        }

        let windowCount: Int
        if parts.count >= 3 {
            windowCount = Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        } else {
            windowCount = 1
        }

        return (name, max(0, attachedClients), max(1, windowCount))
    }

    nonisolated private func parseAttachedClients(_ rawValue: String) -> Int? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let count = Int(value) {
            return count
        }

        switch value.lowercased() {
        case "true", "yes", "attached":
            return 1
        case "false", "no", "detached":
            return 0
        default:
            return nil
        }
    }

    nonisolated private func parseLegacySessionLine(_ line: String) -> RemoteTmuxSession? {
        // Example legacy output:
        // "name: 1 windows (created ...) [80x24] (attached)"
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let colonIndex = trimmed.firstIndex(of: ":") else { return nil }

        let name = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let remainder = trimmed[trimmed.index(after: colonIndex)...]
        let tokens = remainder.split(whereSeparator: { $0.isWhitespace || $0 == ":" })
        let firstNumericToken = tokens.first(where: { Int($0) != nil })
        let windows = firstNumericToken.flatMap { Int($0) } ?? 1
        let attached = trimmed.contains("(attached)") ? 1 : 0

        return RemoteTmuxSession(
            name: name,
            attachedClients: max(0, attached),
            windowCount: max(1, windows)
        )
    }

    nonisolated private func sortSessions(_ sessions: [RemoteTmuxSession]) -> [RemoteTmuxSession] {
        sessions.sorted { lhs, rhs in
            if lhs.attachedClients != rhs.attachedClients {
                return lhs.attachedClients > rhs.attachedClients
            }
            if lhs.windowCount != rhs.windowCount {
                return lhs.windowCount > rhs.windowCount
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    nonisolated private func killSessionCommand(named sessionName: String, backend: RemoteTmuxBackend) -> String {
        switch backend {
        case .unixTmux:
            let quoted = RemoteTerminalBootstrap.shellQuoted(sessionName)
            let tmux = tmuxCommand(includeUTF8: false)
            let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) kill-session -t \(quoted) 2>/dev/null || true"
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"

        case .windowsPsmux(let commandName, _, _):
            let script = "& \(powerShellQuoted(commandName)) kill-session -t \(powerShellQuoted(sessionName)) 2>$null"
            return windowsShellCommand(powerShellScript: script, backend: backend)
        }
    }

    nonisolated private func currentPathCommand(sessionName: String, backend: RemoteTmuxBackend) -> String {
        switch backend {
        case .unixTmux:
            let quotedSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
            let tmux = tmuxCommand(includeUTF8: false)
            let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-panes -t \(quotedSession) -F '#{pane_current_path}' 2>/dev/null | head -n 1"
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"

        case .windowsPsmux(let commandName, _, _):
            let script = "& \(powerShellQuoted(commandName)) list-panes -t \(powerShellQuoted(sessionName)) -F '#{pane_current_path}' 2>$null | Select-Object -First 1"
            return windowsShellCommand(powerShellScript: script, backend: backend)
        }
    }

    nonisolated private func windowsAttachOrCreateCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend,
        lifecycleMarkerToken: String?
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsAttachOrCreatePowerShell(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken
            ),
            backend: backend
        )
    }

    nonisolated private func windowsAttachExistingCommand(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend,
        lifecycleMarkerToken: String?,
        reportsCreationFailure: Bool = false,
        ownership: TmuxSessionOwnership
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsAttachExistingPowerShell(
                sessionName: sessionName,
                missingCommand: missingCommand,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken,
                reportsCreationFailure: reportsCreationFailure,
                ownership: ownership
            ),
            backend: backend
        )
    }

    nonisolated private func windowsAttachOrCreatePowerShell(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend,
        commandExpression: String? = nil,
        lifecycleMarkerToken: String? = nil
    ) -> String {
        let createCommand = windowsCreateSessionPowerShell(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend,
            commandExpression: commandExpression
        )
        return windowsAttachExistingPowerShell(
            sessionName: sessionName,
            missingCommand: createCommand,
            backend: backend,
            commandExpression: commandExpression,
            lifecycleMarkerToken: lifecycleMarkerToken,
            reportsCreationFailure: true,
            ownership: .managed
        )
    }

    nonisolated private func windowsAttachExistingPowerShell(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend,
        commandExpression: String? = nil,
        lifecycleMarkerToken: String? = nil,
        reportsCreationFailure: Bool = false,
        ownership: TmuxSessionOwnership
    ) -> String {
        guard case .windowsPsmux(let commandName, _, _) = backend else { return missingCommand }
        let psmuxExpression = commandExpression ?? powerShellQuoted(commandName)
        let usesManagedConfiguration = ownership == .managed
        let configDeclaration = usesManagedConfiguration
            ? "$vvtermConfig = \(windowsConfigPathPowerShellExpression())"
            : ""
        let attachCommand = usesManagedConfiguration
            ? """
              & $vvtermPsmux source-file -t $vvtermSession $vvtermConfig 2>$null
              & $vvtermPsmux -u attach-session -d -t $vvtermSession
              """
            : "& $vvtermPsmux -u attach-session -d -t $vvtermSession"
        let lifecycleReport: String
        if let lifecycleMarkerToken {
            let detached = powerShellQuoted(
                TmuxLifecycleMarker.sequence(token: lifecycleMarkerToken, event: .detached)
            )
            let ended = powerShellQuoted(
                TmuxLifecycleMarker.sequence(token: lifecycleMarkerToken, event: .ended)
            )
            let sessionPresenceReport = """
            & $vvtermPsmux has-session -t $vvtermSession 2>$null
            if ($LASTEXITCODE -eq 0) {
              [Console]::Out.Write(\(detached))
            } else {
              [Console]::Out.Write(\(ended))
            }
            """
            if reportsCreationFailure {
                let creationFailed = powerShellQuoted(
                    TmuxLifecycleMarker.sequence(token: lifecycleMarkerToken, event: .creationFailed)
                )
                lifecycleReport = """
                if ($null -ne $vvtermTmuxCreateStatus -and $vvtermTmuxCreateStatus -ne 0) {
                  [Console]::Out.Write(\(creationFailed))
                } else {
                  \(sessionPresenceReport)
                }
                """
            } else {
                lifecycleReport = sessionPresenceReport
            }
        } else {
            lifecycleReport = ""
        }

        return """
        $vvtermPsmux = \(psmuxExpression)
        \(configDeclaration)
        $vvtermSession = \(powerShellQuoted(sessionName))
        & $vvtermPsmux has-session -t $vvtermSession 2>$null
        if ($LASTEXITCODE -eq 0) {
        \(indentPowerShell(attachCommand, spaces: 2))
        } else {
        \(indentPowerShell(missingCommand, spaces: 2))
        \(reportsCreationFailure && lifecycleMarkerToken != nil ? "  $vvtermTmuxCreateStatus = $LASTEXITCODE" : "")
        }
        \(lifecycleReport)
        """
    }

    nonisolated private func windowsCreateSessionCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsCreateSessionPowerShell(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                backend: backend
            ),
            backend: backend
        )
    }

    nonisolated private func windowsCreateSessionPowerShell(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend,
        commandExpression: String? = nil
    ) -> String {
        guard case .windowsPsmux(let commandName, _, _) = backend else { return "" }
        let psmuxExpression = commandExpression ?? powerShellQuoted(commandName)
        return """
        $vvtermPsmux = \(psmuxExpression)
        $vvtermConfig = \(windowsConfigPathPowerShellExpression())
        $vvtermSession = \(powerShellQuoted(sessionName))
        $vvtermWorkingDirectory = \(windowsWorkingDirectoryExpression(workingDirectory))
        & $vvtermPsmux -u -f $vvtermConfig new-session -A -s $vvtermSession -c $vvtermWorkingDirectory
        """
    }

    nonisolated private func windowsDefaultShellCommand(backend: RemoteTmuxBackend) -> String {
        guard case .windowsPsmux(_, let shellFamily, let powerShellExecutable) = backend else { return "" }
        switch shellFamily {
        case .powershell:
            let executable = powerShellExecutable ?? "powershell"
            return "& \(powerShellQuoted(executable))"
        case .cmd:
            return "cmd.exe"
        case .unknown, .posix:
            if let executable = powerShellExecutable {
                return "& \(powerShellQuoted(executable))"
            }
            return ""
        }
    }

    nonisolated private func windowsConfigLines(
        terminalType: RemoteTerminalType
    ) -> [String] {
        // psmux runs one server per session. VVTerm loads this global-looking
        // config only into the explicitly targeted managed-session server.
        let theme = tmuxThemeConfiguration()
        var lines = [
            "# VVTerm tmux configuration",
            "# Auto-generated by VVTerm - changes will be overwritten",
            "",
            "# Preserve true-color and terminal metadata when attaching",
        ]
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxArrayOptionCommands(
            option: "update-environment",
            values: RemoteTerminalBootstrap.tmuxUpdateEnvironmentVariables()
        ))
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxEnvironmentCommands())
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxArrayOptionCommands(
            option: "terminal-features",
            values: ["*:hyperlinks"]
        ))
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxArrayOptionCommands(
            option: "terminal-overrides",
            values: ["\(terminalType.rawValue):RGB"]
        ))
        lines.append(contentsOf: [
            "",
            "# Allow OSC sequences to pass through (title updates, etc.)",
            "set -g allow-passthrough on",
            "",
            "# Publish the active pane title to the outer VVTerm terminal"
        ])
        lines.append(contentsOf: titlePropagationConfigLines())
        lines.append(contentsOf: [
            "",
            "# Hide status bar",
            "set -g status off",
            "",
            "# Increase scrollback buffer",
            "set -g history-limit 10000",
            "",
            "# Enable mouse support",
            "set -g mouse on",
            "",
            "# Set default terminal with true color support",
            "set -g default-terminal \"\(terminalType.rawValue)\"",
            "",
            "# Selection highlighting in copy-mode (from theme: \(theme.name))",
            "set -g mode-style \"\(theme.modeStyle)\""
        ])

        lines.append(contentsOf: [
            "",
            "# Use psmux's native scroll behavior on Windows"
        ])

        return lines
    }

    nonisolated private func tmuxThemeConfiguration() -> (name: String, modeStyle: String) {
        let name = UserDefaults.standard.string(
            forKey: CloudKitSyncConstants.terminalThemeNameKey
        ) ?? "Aizen Dark"
        return (name, ThemeColorParser.tmuxModeStyle(for: name))
    }

    nonisolated private func windowsConfigWriteCommand(
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsConfigWritePowerShell(terminalType: terminalType),
            backend: backend
        )
    }

    nonisolated private func windowsConfigWritePowerShell(
        terminalType: RemoteTerminalType
    ) -> String {
        let lines = windowsConfigLines(terminalType: terminalType)
        let content = lines.joined(separator: "\n") + "\n"
        return """
        $vvtermConfigDirectory = \(windowsConfigDirectoryPowerShellExpression())
        $vvtermConfigPath = \(windowsConfigPathPowerShellExpression())
        New-Item -ItemType Directory -Force -Path $vvtermConfigDirectory | Out-Null
        @'
        \(content)'@ | Set-Content -Encoding UTF8 -NoNewline -Path $vvtermConfigPath
        """
    }

    nonisolated private func titlePropagationConfigLines() -> [String] {
        [
            "set -g allow-set-title on",
            "set -g set-titles on",
            "set -g set-titles-string \"#{pane_title}\""
        ]
    }

    nonisolated private func windowsInstallAndAttachScript(
        sessionName: String,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend,
        attachAfterInstall: Bool
    ) -> String {
        let configWrite = windowsConfigWritePowerShell(terminalType: terminalType)
        let attach = windowsAttachOrCreatePowerShell(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend,
            commandExpression: "$vvtermPsmuxCommand.Source"
        )
        let afterInstall = attachAfterInstall ? attach : "Write-Output 'psmux installation completed.'"
        let script = """
        \(configWrite)
        function Get-VVTermPsmuxCommand {
          $cmd = Get-Command psmux -ErrorAction SilentlyContinue
          if (-not $cmd) {
            $cmd = Get-Command pmux -ErrorAction SilentlyContinue
          }
          return $cmd
        }
        $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
        $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        if (-not $vvtermPsmuxInstalled -and (Get-Command winget -ErrorAction SilentlyContinue)) {
          winget install --id marlocarlo.psmux --accept-package-agreements --accept-source-agreements
          $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
          $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        }
        if (-not $vvtermPsmuxInstalled -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
          scoop bucket add psmux https://github.com/psmux/scoop-psmux
          scoop install psmux
          $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
          $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        }
        if (-not $vvtermPsmuxInstalled -and (Get-Command choco -ErrorAction SilentlyContinue)) {
          choco install psmux -y
          $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
          $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        }
        if (-not $vvtermPsmuxInstalled -and (Get-Command cargo -ErrorAction SilentlyContinue)) {
          cargo install psmux
          $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
          $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        }
        if ($vvtermPsmuxInstalled) {
        \(indentPowerShell(afterInstall, spaces: 2))
        } else {
          Write-Output 'psmux installation failed or no supported package manager was found.'
        }
        """
        return windowsShellCommand(powerShellScript: script, backend: backend)
    }

    nonisolated private func windowsShellCommand(
        powerShellScript: String,
        backend: RemoteTmuxBackend
    ) -> String {
        guard case .windowsPsmux(_, let shellFamily, let powerShellExecutable) = backend else {
            return powerShellScript
        }

        switch shellFamily {
        case .powershell:
            return powerShellScript
        case .cmd, .unknown, .posix:
            let executable = powerShellExecutable ?? "powershell"
            return RemoteTerminalBootstrap.wrapPowerShellCommand(
                powerShellScript,
                executableName: executable
            )
        }
    }

    nonisolated private func windowsConfigPathPowerShellExpression() -> String {
        "$HOME + \(powerShellQuoted("\\.vvterm\\psmux.conf"))"
    }

    nonisolated private func windowsConfigDirectoryPowerShellExpression() -> String {
        "$HOME + \(powerShellQuoted("\\.vvterm"))"
    }

    nonisolated private func windowsWorkingDirectoryExpression(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "$HOME" }
        if trimmed == "~" || trimmed == "$HOME" || trimmed == "%USERPROFILE%" {
            return "$HOME"
        }
        return powerShellQuoted(normalizedWindowsPath(trimmed))
    }

    nonisolated private func normalizedWindowsPath(_ value: String) -> String {
        let normalizedSlashes = value.replacingOccurrences(of: "/", with: "\\")
        if value.count >= 2 {
            let prefix = value.prefix(2)
            let drive = prefix.prefix(1)
            if drive.range(of: #"^[A-Za-z]$"#, options: .regularExpression) != nil,
               prefix.dropFirst() == ":" {
                return normalizedSlashes
            }
        }

        if value.count >= 3,
           value.first == "/",
           let drive = value.dropFirst().first,
           drive.isLetter {
            let remainder = value.dropFirst(2)
            let normalizedRemainder = remainder.replacingOccurrences(of: "/", with: "\\")
            return "\(drive.uppercased()):\(normalizedRemainder)"
        }

        return value
    }

    nonisolated private func powerShellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    nonisolated private func indentPowerShell(_ value: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : prefix + line
            }
            .joined(separator: "\n")
    }

}
