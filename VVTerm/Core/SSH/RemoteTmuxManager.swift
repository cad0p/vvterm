import Foundation

struct RemoteTmuxSession: Hashable {
    let name: String
    let attachedClients: Int
    let windowCount: Int
}

enum RemoteTmuxBackend: Hashable, Sendable {
    case unixTmux
    case windowsPsmux(commandName: String, shellFamily: RemoteShellFamily, powerShellExecutable: String?)

    nonisolated var isWindows: Bool {
        if case .windowsPsmux = self {
            return true
        }
        return false
    }
}

actor RemoteTmuxManager {
    enum CommandContext {
        case startupExec
        case interactiveShell
    }

    static let shared = RemoteTmuxManager()

    private let configDirectory = "~/.vvterm"
    private let configPath = "~/.vvterm/tmux.conf"
    private let availabilityTimeout: Duration = .seconds(8)
    private let listTimeout: Duration = .seconds(12)
    private let configTimeout: Duration = .seconds(20)
    private let killTimeout: Duration = .seconds(10)
    private let cleanupTimeout: Duration = .seconds(20)
    private let pathTimeout: Duration = .seconds(10)

    private init() {}

    func tmuxBackend(using client: SSHClient) async -> RemoteTmuxBackend? {
        let environment = await client.remoteEnvironment()
        guard environment.supportsTmuxRuntime else { return nil }

        if environment.platform == .windows {
            return await windowsPsmuxBackend(for: environment, using: client)
        }

        let okMarker = "__VVTERM_TMUX_OK__"
        let command = tmuxAvailabilityProbeCommand(okMarker: okMarker)
        let output = try? await client.execute(command, timeout: availabilityTimeout)
        return output?.contains(okMarker) == true ? .unixTmux : nil
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

    func isTmuxAvailable(using client: SSHClient) async -> Bool {
        await tmuxBackend(using: client) != nil
    }

    func listSessions(using client: SSHClient) async -> [RemoteTmuxSession] {
        guard let backend = await tmuxBackend(using: client) else { return [] }
        let candidates = listSessionCommands(backend: backend)

        for (index, command) in candidates.enumerated() {
            guard let output = try? await client.execute(command, timeout: listTimeout) else { continue }
            let sessions = parseSessionListOutput(output, allowLegacy: index == candidates.count - 1)

            if !sessions.isEmpty {
                return sessions
            }
        }

        return []
    }

    func prepareConfig(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async {
        let backend: RemoteTmuxBackend?
        if let explicitBackend {
            backend = explicitBackend
        } else {
            backend = await tmuxBackend(using: client)
        }
        guard let backend else { return }
        let command = configWriteExecutionCommand(terminalType: terminalType, backend: backend)
        _ = try? await client.execute(command, timeout: configTimeout)
    }

    nonisolated func configWriteExecutionCommand(
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        let configWrite = configWriteCommand(terminalType: terminalType, backend: backend)
        return backend.isWindows
            ? configWrite
            : "sh -lc \(RemoteTerminalBootstrap.shellQuoted(configWrite))"
    }

    nonisolated func attachCommand(
        sessionName: String,
        workingDirectory: String,
        context: CommandContext = .startupExec,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleMarkerToken: String? = nil
    ) -> String {
        let body = attachOrCreateBody(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            context: context,
            backend: backend,
            lifecycleMarkerToken: lifecycleMarkerToken
        )
        return commandString(for: body, context: context, backend: backend)
    }

    nonisolated func attachExistingCommand(
        sessionName: String,
        context: CommandContext = .startupExec,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleMarkerToken: String? = nil
    ) -> String {
        let body = attachExistingBody(
            sessionName: sessionName,
            missingCommand: lifecycleMarkerToken == nil
                ? missingSessionCommand(for: context, backend: backend)
                : lifecycleMissingSessionCommand(backend: backend),
            backend: backend,
            lifecycleMarkerToken: lifecycleMarkerToken
        )
        return commandString(for: body, context: context, backend: backend)
    }

    nonisolated func attachExistingExecCommand(
        sessionName: String,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        attachExistingCommand(sessionName: sessionName, context: .interactiveShell, backend: backend)
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
        let tmuxProbe = tmuxCommand(includeUTF8: false, includeConfig: false)
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport()); \
        if \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null || \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
        printf '%s' \(exists); else printf '%s' \(missing); fi
        """
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    nonisolated func attachExecCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        attachCommand(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            context: .interactiveShell,
            backend: backend
        )
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
            context: .startupExec,
            backend: backend
        )
        let configWrite = configWriteCommand(terminalType: terminalType, backend: backend)
        let afterInstall = attachAfterInstall ? attach : ":"

        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        \(configWrite);
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

    func killSession(named sessionName: String, using client: SSHClient) async {
        guard let backend = await tmuxBackend(using: client) else { return }
        let command = killSessionCommand(named: sessionName, backend: backend)
        _ = try? await client.execute(command, timeout: killTimeout)
    }

    func cleanupLegacySessions(using client: SSHClient) async {
        guard let backend = await tmuxBackend(using: client) else { return }
        guard backend == .unixTmux else { return }
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

    func cleanupDetachedSessions(deviceId: String, keeping sessionNames: Set<String>, using client: SSHClient) async {
        let prefix = "vvterm_\(deviceId)_"
        let keep = sessionNames
        let sessions = await listSessions(using: client)

        for session in sessions {
            guard session.name.hasPrefix(prefix) else { continue }
            guard session.attachedClients == 0 else { continue }
            guard !keep.contains(session.name) else { continue }
            await killSession(named: session.name, using: client)
        }
    }

    func currentPath(sessionName: String, using client: SSHClient) async -> String? {
        guard let backend = await tmuxBackend(using: client) else { return nil }
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

    nonisolated private func commandString(for body: String, context: CommandContext) -> String {
        commandString(for: body, context: context, backend: .unixTmux)
    }

    nonisolated private func commandString(
        for body: String,
        context: CommandContext,
        backend: RemoteTmuxBackend
    ) -> String {
        if backend.isWindows {
            return body
        }

        switch context {
        case .startupExec:
            return body
        case .interactiveShell:
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
        }
    }

    nonisolated private func missingSessionCommand(for context: CommandContext) -> String {
        missingSessionCommand(for: context, backend: .unixTmux)
    }

    nonisolated private func missingSessionCommand(
        for context: CommandContext,
        backend: RemoteTmuxBackend
    ) -> String {
        if backend.isWindows {
            switch context {
            case .startupExec:
                return windowsDefaultShellCommand(backend: backend)
            case .interactiveShell:
                return ""
            }
        }

        switch context {
        case .startupExec:
            return "exec \"${SHELL:-/bin/sh}\" -l"
        case .interactiveShell:
            return ":"
        }
    }

    nonisolated private func attachOrCreateBody(
        sessionName: String,
        workingDirectory: String,
        context: CommandContext = .startupExec,
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
            reportsCreationFailure: true
        )
    }

    nonisolated private func attachExistingBody(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleMarkerToken: String? = nil,
        reportsCreationFailure: Bool = false
    ) -> String {
        if case .windowsPsmux = backend {
            return windowsAttachExistingCommand(
                sessionName: sessionName,
                missingCommand: missingCommand,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken,
                reportsCreationFailure: reportsCreationFailure
            )
        }

        let exactSession = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let plainSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let tmuxProbe = tmuxCommand(includeUTF8: false, includeConfig: false)
        let tmuxAttach = tmuxCommand(includeUTF8: true, includeConfig: true)
        let tmuxSource = tmuxCommand(includeUTF8: false, includeConfig: false)
        let processReplacement = lifecycleMarkerToken == nil ? "exec " : ""
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
        \(tmuxSource) source-file \(configPath) >/dev/null 2>&1 || true; \(processReplacement)\(tmuxAttach) attach-session -t \(exactSession); \
        elif \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
        \(tmuxSource) source-file \(configPath) >/dev/null 2>&1 || true; \(processReplacement)\(tmuxAttach) attach-session -t \(plainSession); \
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
        let tmux = tmuxCommand(includeUTF8: true, includeConfig: true)
        let processReplacement = lifecycleMarkerToken == nil ? "exec " : ""
        return "\(processReplacement)\(tmux) new-session -A -s \(escapedSession) -c \(escapedDir)"
    }

    nonisolated private func lifecycleMissingSessionCommand(backend: RemoteTmuxBackend) -> String {
        backend.isWindows ? "$null" : ":"
    }

    nonisolated private func tmuxCommand(
        includeUTF8: Bool,
        includeConfig: Bool
    ) -> String {
        var parts = ["tmux"]
        if includeUTF8 {
            parts.append("-u")
        }
        if includeConfig {
            parts.append("-f \(configPath)")
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

    private func windowsPsmuxBackend(
        for environment: RemoteEnvironment,
        using client: SSHClient
    ) async -> RemoteTmuxBackend? {
        let shellFamily = environment.shellProfile.family
        let powerShellExecutable = environment.powerShellExecutable ?? environment.shellProfile.executableName

        for commandName in ["psmux", "pmux"] {
            let backend = RemoteTmuxBackend.windowsPsmux(
                commandName: commandName,
                shellFamily: shellFamily,
                powerShellExecutable: powerShellExecutable
            )
            let output = try? await client.execute(
                windowsPsmuxAvailabilityProbeCommand(commandName: commandName, backend: backend, requirePsmuxExtension: false),
                timeout: availabilityTimeout
            )
            if output?.contains("__VVTERM_TMUX_OK__:\(commandName)") == true {
                return backend
            }
        }

        let tmuxBackend = RemoteTmuxBackend.windowsPsmux(
            commandName: "tmux",
            shellFamily: shellFamily,
            powerShellExecutable: powerShellExecutable
        )
        let output = try? await client.execute(
            windowsPsmuxAvailabilityProbeCommand(commandName: "tmux", backend: tmuxBackend, requirePsmuxExtension: true),
            timeout: availabilityTimeout
        )
        if output?.contains("__VVTERM_TMUX_OK__:tmux") == true {
            return tmuxBackend
        }

        return nil
    }

    nonisolated func windowsPsmuxAvailabilityProbeCommand(
        commandName: String,
        backend: RemoteTmuxBackend,
        requirePsmuxExtension: Bool
    ) -> String {
        let marker = "__VVTERM_TMUX_OK__:\(commandName)"
        let script = """
        $cmd = Get-Command \(powerShellQuoted(commandName)) -ErrorAction SilentlyContinue
        if ($cmd) {
          & $cmd.Source -V *> $null
          if ($LASTEXITCODE -eq 0) {
            $vvtermCommands = (& $cmd.Source list-commands 2>$null) -join "`n"
            if (-not \(requirePsmuxExtension ? "$true" : "$false") -or $vvtermCommands.Contains('dump-state') -or $vvtermCommands.Contains('claim-session')) {
              Write-Output \(powerShellQuoted(marker))
            }
          }
        }
        """
        return windowsShellCommand(powerShellScript: script, backend: backend)
    }

    nonisolated private func listSessionCommands(backend: RemoteTmuxBackend) -> [String] {
        switch backend {
        case .unixTmux:
            let tmux = tmuxCommand(includeUTF8: false, includeConfig: false)
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
            let tmux = tmuxCommand(includeUTF8: false, includeConfig: false)
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
            let tmux = tmuxCommand(includeUTF8: false, includeConfig: false)
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
        reportsCreationFailure: Bool = false
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsAttachExistingPowerShell(
                sessionName: sessionName,
                missingCommand: missingCommand,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken,
                reportsCreationFailure: reportsCreationFailure
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
            reportsCreationFailure: true
        )
    }

    nonisolated private func windowsAttachExistingPowerShell(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend,
        commandExpression: String? = nil,
        lifecycleMarkerToken: String? = nil,
        reportsCreationFailure: Bool = false
    ) -> String {
        guard case .windowsPsmux(let commandName, _, _) = backend else { return missingCommand }
        let psmuxExpression = commandExpression ?? powerShellQuoted(commandName)
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
        $vvtermConfig = \(windowsConfigPathPowerShellExpression())
        $vvtermSession = \(powerShellQuoted(sessionName))
        & $vvtermPsmux has-session -t $vvtermSession 2>$null
        if ($LASTEXITCODE -eq 0) {
          & $vvtermPsmux -f $vvtermConfig source-file $vvtermConfig 2>$null
          & $vvtermPsmux -u -f $vvtermConfig attach-session -d -t $vvtermSession
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

    nonisolated private func configWriteCommand(
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        if backend.isWindows {
            return windowsConfigWriteCommand(terminalType: terminalType, backend: backend)
        }

        let lines = configLines(
            terminalType: terminalType,
            includeWheelBindings: true,
            quietAllowSetTitle: true
        )
        let quotedLines = lines.map { "\"\(escapeForDoubleQuotes($0))\"" }.joined(separator: " ")
        return "mkdir -p \(configDirectory); printf '%s\\n' \(quotedLines) > \(configPath)"
    }

    nonisolated private func configLines(
        terminalType: RemoteTerminalType,
        includeWheelBindings: Bool,
        quietAllowSetTitle: Bool
    ) -> [String] {
        let themeName = UserDefaults.standard.string(forKey: CloudKitSyncConstants.terminalThemeNameKey) ?? "Aizen Dark"
        let modeStyle = ThemeColorParser.tmuxModeStyle(for: themeName)
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
        lines.append(contentsOf: titlePropagationConfigLines(quietAllowSetTitle: quietAllowSetTitle))
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
            "# Selection highlighting in copy-mode (from theme: \(themeName))",
            "set -g mode-style \"\(modeStyle)\""
        ])

        if includeWheelBindings {
            lines.append(contentsOf: [
                "",
                "# Smart mouse scroll: copy-mode at shell, passthrough in TUI apps",
                "bind -n WheelUpPane if -F '#{||:#{mouse_any_flag},#{alternate_on}}' 'send-keys -M' 'copy-mode -eH; send-keys -M'",
                "bind -n WheelDownPane if -F '#{||:#{mouse_any_flag},#{alternate_on}}' 'send-keys -M' 'send-keys -M'"
            ])
        } else {
            lines.append(contentsOf: [
                "",
                "# Use psmux's native scroll behavior on Windows"
            ])
        }

        return lines
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
        let lines = configLines(
            terminalType: terminalType,
            includeWheelBindings: false,
            quietAllowSetTitle: false
        )
        let content = lines.joined(separator: "\n") + "\n"
        return """
        $vvtermConfigDirectory = \(windowsConfigDirectoryPowerShellExpression())
        $vvtermConfigPath = \(windowsConfigPathPowerShellExpression())
        New-Item -ItemType Directory -Force -Path $vvtermConfigDirectory | Out-Null
        @'
        \(content)'@ | Set-Content -Encoding UTF8 -NoNewline -Path $vvtermConfigPath
        """
    }

    nonisolated private func titlePropagationConfigLines(quietAllowSetTitle: Bool) -> [String] {
        [
            quietAllowSetTitle ? "set -gq allow-set-title on" : "set -g allow-set-title on",
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

    nonisolated private func escapeForDoubleQuotes(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "$", with: "\\$")
        escaped = escaped.replacingOccurrences(of: "`", with: "\\`")
        return escaped
    }
}
