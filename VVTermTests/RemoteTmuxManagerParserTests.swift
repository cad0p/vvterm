import Testing
@testable import VVTerm

struct RemoteTmuxManagerParserTests {

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
        let command = RemoteTmuxManager.shared.attachExistingCommand(sessionName: "team session")
        #expect(command.contains("tmux has-session"))
        #expect(command.contains("attach-session"))
        #expect(command.contains("exec \"${SHELL:-/bin/sh}\" -l"))
    }

    @Test
    func installAndAttachScriptIncludesSessionAndConfig() {
        let script = RemoteTmuxManager.shared.installAndAttachScript(
            sessionName: "vvterm_demo",
            workingDirectory: "/tmp/work dir",
            terminalType: .xtermGhostty
        )
        #expect(script.contains("~/.vvterm/tmux.conf"))
        #expect(script.contains("new-session -A -s"))
        #expect(script.contains("vvterm_demo"))
        #expect(script.contains("/tmp/work dir"))
        #expect(script.contains("set -g default-terminal"))
        #expect(script.contains("xterm-ghostty"))
        #expect(script.contains("set -gq allow-set-title on"))
        #expect(!script.contains("%if"))
        #expect(!script.contains("#{version}"))
    }

    @Test
    func unixConfigWriteExecutesThroughSh() {
        let command = RemoteTmuxManager.shared.configWriteExecutionCommand(
            terminalType: .xtermGhostty,
            backend: .unixTmux
        )

        #expect(command.hasPrefix("sh -lc "))
        #expect(command.contains("mkdir -p ~/.vvterm"))
        #expect(command.contains("> ~/.vvterm/tmux.conf"))
        #expect(command.contains("set -g default-terminal"))
        #expect(command.contains("xterm-ghostty"))
        #expect(command.contains("set -gq allow-set-title on"))
        #expect(!command.contains("%if"))
        #expect(!command.contains("#{version}"))
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
    func windowsCmdPsmuxAttachCommandWrapsPowerShell() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "pmux",
            shellFamily: .cmd,
            powerShellExecutable: "powershell"
        )

        let command = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: "shared",
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
        #expect(!script.contains("sh -lc"))
    }
}
