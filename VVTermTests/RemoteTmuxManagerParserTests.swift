import Foundation
import Testing
@testable import VVTerm

private actor TmuxProbeExecutor {
    private var outputs: [Result<String, Error>]
    private var commands: [String] = []

    init(outputs: [Result<String, Error>]) {
        self.outputs = outputs
    }

    func run(command: String, timeout _: Duration?) throws -> String {
        commands.append(command)
        guard !outputs.isEmpty else {
            Issue.record("Unexpected extra command: \(command)")
            return ""
        }
        return try outputs.removeFirst().get()
    }

    func recordedCommands() -> [String] {
        commands
    }
}

enum InjectedTmuxProbeError: CaseIterable, Sendable {
    case timeout
    case disconnected
    case cancelled
    case transport
    case channelOpenFailed
    case shellRequestFailed

    var error: Error {
        switch self {
        case .timeout: return SSHError.timeout
        case .disconnected: return SSHError.notConnected
        case .cancelled: return CancellationError()
        case .transport: return SSHError.socketError("connection reset")
        case .channelOpenFailed: return SSHError.channelOpenFailed
        case .shellRequestFailed: return SSHError.shellRequestFailed
        }
    }

    var expectedFailure: RemoteTmuxProbeFailure {
        switch self {
        case .timeout: return .timeout
        case .disconnected: return .disconnected
        case .cancelled: return .cancelled
        case .transport: return .transport("connection reset")
        case .channelOpenFailed: return .channelOpenFailed
        case .shellRequestFailed: return .shellRequestFailed
        }
    }
}

struct RemoteTmuxManagerParserTests {

    private func resolveAvailability(
        environment: RemoteEnvironment = .fallbackPOSIX,
        outputs: [Result<String, Error>]
    ) async -> (RemoteTmuxAvailability, [String]) {
        let executor = TmuxProbeExecutor(outputs: outputs)
        let availability = await RemoteTmuxManager.shared.tmuxAvailability(
            in: environment
        ) { command, timeout in
            try await executor.run(command: command, timeout: timeout)
        }
        return (availability, await executor.recordedCommands())
    }

    @Test
    func explicitAvailabilityMarkerReportsUnixTmuxAvailable() async {
        let (availability, commands) = await resolveAvailability(outputs: [
            .success("__VVTERM_TMUX_OK__")
        ])

        #expect(availability == .available(.unixTmux))
        #expect(commands.count == 1)
    }

    @Test
    func explicitMissingMarkerConfirmsUnixTmuxMissing() async {
        let (availability, _) = await resolveAvailability(outputs: [
            .success("__VVTERM_TMUX_NO__")
        ])

        #expect(availability == .confirmedMissing)
    }

    @Test(arguments: InjectedTmuxProbeError.allCases)
    func probeErrorsRemainIndeterminate(error: InjectedTmuxProbeError) async {
        let (availability, _) = await resolveAvailability(outputs: [
            .failure(error.error)
        ])

        #expect(availability == .indeterminate(error.expectedFailure))
    }

    @Test(arguments: ["", "unexpected output", "__VVTERM_TMUX_OK____VVTERM_TMUX_NO__"])
    func emptyMalformedAndConflictingProbeOutputRemainIndeterminate(output: String) async {
        let (availability, _) = await resolveAvailability(outputs: [.success(output)])

        #expect(availability == .indeterminate(.invalidResponse))
    }

    @Test
    func unsupportedEnvironmentDoesNotRunTmuxProbe() async {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .unknown(),
            activeShellName: nil,
            powerShellExecutable: "powershell"
        )
        let (availability, commands) = await resolveAvailability(
            environment: environment,
            outputs: []
        )

        #expect(availability == .unsupported)
        #expect(commands.isEmpty)
    }

    @Test
    func windowsConfirmsMissingOnlyAfterEveryCandidateReportsMissing() async {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "pwsh"),
            activeShellName: "pwsh",
            powerShellExecutable: "pwsh"
        )
        let (availability, commands) = await resolveAvailability(
            environment: environment,
            outputs: [
                .success("__VVTERM_TMUX_NO__:psmux"),
                .success("__VVTERM_TMUX_NO__:pmux"),
                .success("__VVTERM_TMUX_NO__:tmux")
            ]
        )

        #expect(availability == .confirmedMissing)
        #expect(commands.count == 3)
    }

    @Test
    func oneIndeterminateWindowsCandidatePreventsFalseMissingResult() async {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "pwsh"),
            activeShellName: "pwsh",
            powerShellExecutable: "pwsh"
        )
        let (availability, _) = await resolveAvailability(
            environment: environment,
            outputs: [
                .failure(SSHError.timeout),
                .success("__VVTERM_TMUX_NO__:pmux"),
                .success("__VVTERM_TMUX_NO__:tmux")
            ]
        )

        #expect(availability == .indeterminate(.timeout))
    }

    @Test
    func laterAvailableWindowsCandidateWinsAfterEarlierIndeterminateProbe() async {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "pwsh"),
            activeShellName: "pwsh",
            powerShellExecutable: "pwsh"
        )
        let (availability, commands) = await resolveAvailability(
            environment: environment,
            outputs: [
                .failure(SSHError.timeout),
                .success("__VVTERM_TMUX_OK__:pmux")
            ]
        )

        #expect(
            availability == .available(.windowsPsmux(
                commandName: "pmux",
                shellFamily: .powershell,
                powerShellExecutable: "pwsh"
            ))
        )
        #expect(commands.count == 2)
    }

    @Test
    func parseWhitespaceFormatFromRealTmuxOutput() {
        let output = """
        aizen-00F43729-7E11-4731-ADFE-603A766AFCF6 1 1
        aizen-7922A0D1-DD37-4530-866F-30C60B0E9C26 0 1
        """

        let sessions = RemoteTmuxManager.shared.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.count == 2)
        #expect(sessions[0].name == "aizen-00F43729-7E11-4731-ADFE-603A766AFCF6")
        #expect(sessions[0].attachedClients == 1)
        #expect(sessions[0].windowCount == 1)
        #expect(!sessions[0].name.hasSuffix(" 1 1"))
        #expect(sessions[1].name == "aizen-7922A0D1-DD37-4530-866F-30C60B0E9C26")
        #expect(sessions[1].attachedClients == 0)
    }

    @Test
    func parseLiteralEscapedTabsFormat() {
        let output = "prod\\t2\\t3\ndev\\t0\\t1\n"

        let sessions = RemoteTmuxManager.shared.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.count == 2)
        #expect(sessions[0] == RemoteTmuxSession(name: "prod", attachedClients: 2, windowCount: 3))
        #expect(sessions[1] == RemoteTmuxSession(name: "dev", attachedClients: 0, windowCount: 1))
    }

    @Test
    func parseTwoFieldFormatDefaultsWindowCountToOne() {
        let output = """
        qa 1
        local 0
        """

        let sessions = RemoteTmuxManager.shared.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.count == 2)
        #expect(sessions[0] == RemoteTmuxSession(name: "qa", attachedClients: 1, windowCount: 1))
        #expect(sessions[1] == RemoteTmuxSession(name: "local", attachedClients: 0, windowCount: 1))
    }

    @Test
    func parseBooleanAttachedFormatFromPsmuxOutput() {
        let output = """
        restored true 1
        detached false 2
        """

        let sessions = RemoteTmuxManager.shared.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.count == 2)
        #expect(sessions[0] == RemoteTmuxSession(name: "restored", attachedClients: 1, windowCount: 1))
        #expect(sessions[1] == RemoteTmuxSession(name: "detached", attachedClients: 0, windowCount: 2))
    }

    @Test
    func parseLegacyListSessionsFormatWhenEnabled() {
        let output = """
        ops: 2 windows (created Sat Feb 14 10:00:00 2026) [80x24] (attached)
        api: 1 windows (created Sat Feb 14 10:01:00 2026) [80x24]
        """

        let sessions = RemoteTmuxManager.shared.parseSessionListOutput(output, allowLegacy: true)
        #expect(sessions.count == 2)
        #expect(sessions[0] == RemoteTmuxSession(name: "ops", attachedClients: 1, windowCount: 2))
        #expect(sessions[1] == RemoteTmuxSession(name: "api", attachedClients: 0, windowCount: 1))
    }

    @Test
    func sortPrefersAttachedThenWindowCountThenName() {
        let output = """
        zeta 1 1
        alpha 1 3
        beta 1 3
        gamma 0 9
        """

        let sessions = RemoteTmuxManager.shared.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.map { $0.name } == ["alpha", "beta", "zeta", "gamma"])
    }

    @Test
    func attachExistingCommandFallsBackToLoginShell() {
        let command = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "team session",
            ownership: .external
        )
        #expect(command.contains("tmux has-session"))
        #expect(command.contains("attach-session"))
        #expect(command.contains("exec \"${SHELL:-/bin/sh}\" -l"))
    }

    @Test
    func managedLifecycleCommandReportsDetachOrSessionEnd() {
        let command = RemoteTmuxManager.shared.attachCommand(
            sessionName: "vvterm_managed",
            workingDirectory: "/work",
            lifecycleMarkerToken: "marker-token"
        )

        #expect(command.contains("new-session -d -s"))
        #expect(command.contains("has-session -t '=vvterm_managed'"))
        #expect(command.contains(TmuxLifecycleMarker.sequence(token: "marker-token", event: .detached)))
        #expect(command.contains(TmuxLifecycleMarker.sequence(token: "marker-token", event: .ended)))
        #expect(command.contains(TmuxLifecycleMarker.sequence(token: "marker-token", event: .creationFailed)))
        #expect(command.contains("vvtermTmuxCreateStatus=$?"))
        #expect(!command.contains("exec tmux"))
    }

    @Test
    func unixSessionPresenceProbeUsesExactSessionAndPrivateMarkers() {
        let command = RemoteTmuxManager.shared.sessionPresenceProbeCommand(
            sessionName: "vvterm_managed",
            backend: .unixTmux,
            existsMarker: "private-exists",
            missingMarker: "private-missing"
        )

        #expect(command.contains("has-session -t"))
        #expect(command.contains("=vvterm_managed"))
        #expect(command.contains("private-exists"))
        #expect(command.contains("private-missing"))
    }

    @Test
    func managedReattachDoesNotRecreateMissingSession() {
        let command = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "vvterm_managed",
            ownership: .managed,
            lifecycleMarkerToken: "marker-token"
        )

        #expect(command.contains("attach-session"))
        #expect(command.contains("set-option -wq -t \"$vvtermWindow\" scroll-on-clear 'off'"))
        #expect(command.contains(TmuxLifecycleMarker.sequence(token: "marker-token", event: .ended)))
        #expect(!command.contains(TmuxLifecycleMarker.sequence(token: "marker-token", event: .creationFailed)))
        #expect(!command.contains("new-session"))
        #expect(!command.contains("exec \"${SHELL:-/bin/sh}\" -l"))
    }

    @Test
    func installAndAttachScriptIncludesScopedManagedConfiguration() {
        let script = RemoteTmuxManager.shared.installAndAttachScript(
            sessionName: "vvterm_demo",
            workingDirectory: "/tmp/work dir",
            terminalType: .xtermGhostty
        )
        #expect(script.contains("new-session -d -s"))
        #expect(script.contains("vvterm_demo"))
        #expect(script.contains("/tmp/work dir"))
        #expect(script.contains("set-option -q -t"))
        #expect(script.contains("status off"))
        #expect(script.contains("RGB,hyperlinks"))
        #expect(script.contains("tmux -u"))
        #expect(!script.contains("~/.vvterm/tmux.conf"))
        #expect(!script.contains("set -g"))
    }

    @Test
    func installOnlyScriptDoesNotEnterUntrackedTmuxSession() {
        let script = RemoteTmuxManager.shared.installAndAttachScript(
            sessionName: "vvterm_demo",
            workingDirectory: "/tmp/work",
            terminalType: .xtermGhostty,
            attachAfterInstall: false
        )

        #expect(script.contains("apt-get install -y tmux"))
        #expect(!script.contains("new-session"))
        #expect(!script.contains("attach-session"))
        #expect(!script.contains("exec tmux"))
        #expect(!script.contains("~/.vvterm/tmux.conf"))
    }

    @Test
    func managedSessionClearBehaviorIsWindowScoped() {
        let create = RemoteTmuxManager.shared.attachCommand(
            sessionName: "vvterm_managed",
            workingDirectory: "/tmp"
        )
        let reattach = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "vvterm_managed",
            ownership: .managed
        )
        let external = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "shared",
            ownership: .external
        )

        let scopedOption = "set-option -wq -t \"$vvtermWindow\" scroll-on-clear 'off'"
        #expect(create.contains(scopedOption))
        #expect(reattach.contains(scopedOption))
        #expect(!external.contains("scroll-on-clear"))
        #expect(!reattach.contains("source-file"))
        #expect(!reattach.contains("~/.vvterm/tmux.conf"))
    }

    @Test
    func managedUnixSessionConfigurationIsScopedToItsSession() {
        let create = RemoteTmuxManager.shared.attachCommand(
            sessionName: "vvterm_managed",
            workingDirectory: "/tmp"
        )
        let reattach = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "vvterm_managed",
            ownership: .managed
        )
        let external = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "shared",
            ownership: .external
        )

        for command in [create, reattach] {
            #expect(command.contains("set-option -q -t '=vvterm_managed:' status off"))
            #expect(command.contains("set-option -q -t '=vvterm_managed:' history-limit 10000"))
            #expect(command.contains("set-option -q -t '=vvterm_managed:' mouse on"))
            #expect(command.contains("set-environment -t '=vvterm_managed' TERM_PROGRAM 'vvterm'"))
            #expect(command.contains("-F '#{window_id} #{window_linked}'"))
            #expect(command.contains("[ \"$vvtermLinked\" = 0 ] || continue"))
            #expect(command.contains("set-hook -t '=vvterm_managed:' 'after-new-window[1000]'"))
            #expect(command.contains("#{==:#{window_linked},0}"))
            #expect(!command.contains("source-file"))
            #expect(!command.contains("-f ~/.vvterm/tmux.conf"))
            #expect(!command.contains("set -g"))
            #expect(!command.contains("bind -n"))
        }

        #expect(!external.contains("set-option"))
        #expect(!external.contains("set-environment"))
        #expect(!external.contains("source-file"))
        #expect(!external.contains("~/.vvterm/tmux.conf"))
    }

    @Test
    func managedUnixCreationBootstrapsLegacyTmuxBeforeStartingTerminalShell() {
        let command = RemoteTmuxManager.shared.attachCommand(
            sessionName: "vvterm_managed",
            workingDirectory: "/tmp"
        )

        #expect(command.contains("tmux -T RGB,hyperlinks -V"))
        #expect(command.contains("tmux -u -T RGB,hyperlinks attach-session"))
        #expect(command.contains("else exec tmux -u attach-session"))
        #expect(command.components(separatedBy: "new-session -d -s").count == 2)
        #expect(!command.contains("-e 'COLORTERM=truecolor'"))
        #expect(command.contains("__vvterm_bootstrap__"))
        #expect(command.contains("new-window -d -t '=vvterm_managed:'"))
        #expect(command.contains("kill-window -t '=vvterm_managed:__vvterm_bootstrap__'"))
        #expect(command.contains("move-window -r -t '=vvterm_managed:'"))
    }

    @Test
    func externalUnixSessionAttachDoesNotLoadVVTermConfiguration() {
        let command = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "external's; $session",
            ownership: .external
        )
        let exactSession = "'=external'\\''s; $session'"

        #expect(command.contains("has-session -t \(exactSession)"))
        #expect(command.contains("attach-session -t \(exactSession)"))
        #expect(!command.contains("source-file"))
        #expect(!command.contains("~/.vvterm/tmux.conf"))
    }

    @Test
    func externalWindowsSessionAttachDoesNotLoadVVTermConfiguration() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )
        let command = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "external team; session",
            ownership: .external,
            backend: backend
        )

        #expect(command.contains("attach-session -d -t $vvtermSession"))
        #expect(!command.contains("source-file"))
        #expect(!command.contains("$vvtermConfig"))
    }

    @Test
    func managedWindowsSessionAttachLoadsVVTermConfiguration() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )
        let command = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "vvterm_managed",
            ownership: .managed,
            backend: backend
        )

        #expect(command.contains("source-file -t $vvtermSession $vvtermConfig"))
        #expect(command.contains("-u attach-session"))
    }

    @Test @MainActor
    func selectedVVTermManagedSessionKeepsManagedClearBehavior() throws {
        let resolver = TmuxAttachResolver()
        let paneId = UUID()
        let sessionName = resolver.managedSessionName(for: paneId)
        let selection = TmuxAttachSelection.attachExisting(sessionName: sessionName)

        resolver.updateAttachmentState(for: paneId, selection: selection) { _ in }
        let ownership = try #require(resolver.sessionOwnership[paneId])
        let command = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: sessionName,
            ownership: ownership
        )

        #expect(ownership == .managed)
        #expect(command.contains("set-option -wq -t \"$vvtermWindow\" scroll-on-clear 'off'"))
        #expect(command.contains("set-hook -t '=\(sessionName):' 'after-new-window[1000]'"))
    }

    @Test @MainActor
    func selectedExternalSessionDoesNotLoadVVTermConfiguration() throws {
        let resolver = TmuxAttachResolver()
        let paneId = UUID()
        let selection = TmuxAttachSelection.attachExisting(sessionName: "shared")

        resolver.updateAttachmentState(for: paneId, selection: selection) { _ in }
        let ownership = try #require(resolver.sessionOwnership[paneId])
        let command = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "shared",
            ownership: ownership
        )

        #expect(ownership == .external)
        #expect(!command.contains("source-file"))
        #expect(!command.contains("~/.vvterm/tmux.conf"))
    }

    @Test @MainActor
    func failedExternalSessionListingPreservesRememberedAttachment() async {
        let resolver = TmuxAttachResolver()
        let paneId = UUID()
        let serverId = UUID()
        resolver.sessionNames[paneId] = "shared-session"
        resolver.sessionOwnership[paneId] = .external

        do {
            _ = try await resolver.resolveSelection(
                for: paneId,
                serverId: serverId,
                client: SSHClient(),
                backend: .unixTmux,
                requestId: UUID(),
                validateOwner: {},
                setPrompt: { _ in }
            )
            Issue.record("A failed session listing should remain a retryable connection error")
        } catch {
            #expect(error is SSHError)
        }

        #expect(resolver.sessionNames[paneId] == "shared-session")
        #expect(resolver.sessionOwnership[paneId] == .external)
    }

    @Test
    func availabilityProbeUsesFallbackPathsAndNonLoginShell() {
        let probe = RemoteTmuxManager.shared.tmuxAvailabilityProbeCommand(okMarker: "__VVTERM_TMUX_OK__")
        #expect(probe.hasPrefix("sh -c "))
        #expect(!probe.contains("sh -lc "))
        #expect(probe.contains("command -v tmux"))
        #expect(probe.contains("/usr/bin/tmux"))
        #expect(probe.contains("/bin/tmux"))
        #expect(probe.contains("/usr/local/bin/tmux"))
        #expect(probe.contains("-V >/dev/null 2>&1"))
        #expect(probe.contains("__VVTERM_TMUX_OK__"))
        #expect(probe.contains("__VVTERM_TMUX_NO__"))
    }

    @Test
    func windowsPsmuxAttachCommandUsesPowerShellAndPsmux() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let command = RemoteTmuxManager.shared.attachCommand(
            sessionName: "vvterm_demo",
            workingDirectory: "C:/Users/me/project",
            backend: backend
        )

        #expect(command.contains("$vvtermPsmux = 'psmux'"))
        #expect(command.contains("has-session -t $vvtermSession"))
        #expect(command.contains("attach-session -d -t $vvtermSession"))
        #expect(command.contains("new-session -A -s $vvtermSession -c $vvtermWorkingDirectory"))
        #expect(command.contains("'C:\\Users\\me\\project'"))
        #expect(command.contains("$HOME + '\\.vvterm\\psmux.conf'"))
        #expect(!command.contains("$vvtermExactSession"))
        #expect(!command.contains("sh -lc"))
        #expect(!command.contains("export PATH"))
        #expect(!command.contains("mkdir -p"))
        #expect(!command.contains("printf"))
        #expect(!command.contains("uname"))
        #expect(!command.contains("exec tmux"))
    }

    @Test
    func windowsPsmuxLifecycleCommandReportsDetachOrSessionEnd() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let command = RemoteTmuxManager.shared.attachCommand(
            sessionName: "vvterm_demo",
            workingDirectory: "C:/work",
            backend: backend,
            lifecycleMarkerToken: "marker-token"
        )

        #expect(command.contains("has-session -t $vvtermSession"))
        #expect(command.contains("[Console]::Out.Write"))
        #expect(command.contains("marker-token"))
        #expect(command.contains("detached"))
        #expect(command.contains("ended"))
        #expect(command.contains("creationFailed"))
        #expect(command.contains("$vvtermTmuxCreateStatus = $LASTEXITCODE"))
    }

    @Test
    func windowsCmdPsmuxAttachCommandWrapsPowerShell() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "pmux",
            shellFamily: .cmd,
            powerShellExecutable: "powershell"
        )

        let command = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "shared",
            ownership: .external,
            backend: backend
        )

        #expect(command.hasPrefix("powershell -NoLogo -NoProfile -EncodedCommand "))
    }

    @Test
    func windowsPowerShellAttachExistingFallsBackToInteractiveShell() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let command = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "shared",
            ownership: .external,
            backend: backend
        )

        #expect(command.contains("} else {"))
        #expect(command.contains("& 'pwsh'"))
    }

    @Test
    func windowsPsmuxAvailabilityProbeConfirmsTmuxAliasWithPsmuxExtension() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "tmux",
            shellFamily: .powershell,
            powerShellExecutable: "powershell"
        )

        let probe = RemoteTmuxManager.shared.windowsPsmuxAvailabilityProbeCommand(
            commandName: "tmux",
            backend: backend,
            requirePsmuxExtension: true
        )

        #expect(probe.contains("Get-Command 'tmux'"))
        #expect(probe.contains("list-commands"))
        #expect(probe.contains("dump-state"))
        #expect(probe.contains("claim-session"))
        #expect(probe.contains("__VVTERM_TMUX_OK__:tmux"))
        #expect(probe.contains("__VVTERM_TMUX_NO__:tmux"))
    }

    @Test
    func windowsPsmuxInstallScriptUsesWindowsPackageManagersAndConfig() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let script = RemoteTmuxManager.shared.installAndAttachScript(
            sessionName: "vvterm_demo",
            workingDirectory: "C:/work",
            terminalType: .xtermGhostty,
            backend: backend
        )

        #expect(script.contains("Set-Content -Encoding UTF8 -NoNewline -Path $vvtermConfigPath"))
        #expect(script.contains("$HOME + '\\.vvterm\\psmux.conf'"))
        #expect(script.contains("winget install --id marlocarlo.psmux"))
        #expect(script.contains("scoop bucket add psmux https://github.com/psmux/scoop-psmux"))
        #expect(script.contains("choco install psmux -y"))
        #expect(script.contains("cargo install psmux"))
        #expect(script.contains("function Get-VVTermPsmuxCommand"))
        #expect(script.contains("Get-Command pmux -ErrorAction SilentlyContinue"))
        #expect(script.contains("$vvtermPsmux = $vvtermPsmuxCommand.Source"))
        #expect(script.contains("set -g allow-set-title on"))
        #expect(!script.contains("%if"))
        #expect(script.contains("set -g terminal-features[0] \"*:hyperlinks\""))
        #expect(!script.contains("irm "))
        #expect(!script.contains("WheelUpPane"))
        #expect(!script.contains("WheelDownPane"))
        #expect(!script.contains("scroll-on-clear"))
        #expect(!script.contains("sh -lc"))
    }
}
