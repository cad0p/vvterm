import Testing
@testable import VVTerm

struct RemoteTerminalBootstrapTests {
    private let posixEnvironment = RemoteEnvironment(
        platform: .linux,
        shellProfile: .posix(shellName: "zsh"),
        activeShellName: "zsh",
        powerShellExecutable: nil
    )

    private let powerShellEnvironment = RemoteEnvironment(
        platform: .windows,
        shellProfile: .powershell(executableName: "powershell"),
        activeShellName: "powershell",
        powerShellExecutable: "powershell"
    )

    private let pwshEnvironment = RemoteEnvironment(
        platform: .windows,
        shellProfile: .powershell(executableName: "pwsh"),
        activeShellName: "pwsh",
        powerShellExecutable: "pwsh"
    )

    private let cmdEnvironment = RemoteEnvironment(
        platform: .windows,
        shellProfile: .cmd,
        activeShellName: "cmd.exe",
        powerShellExecutable: nil
    )

    @Test
    func launchPlanWithoutStartupCommandUsesPOSIXLoginShellBootstrap() {
        let plan = RemoteTerminalBootstrap.launchPlan(startupCommand: nil, environment: posixEnvironment)

        switch plan {
        case .shell:
            Issue.record("Expected POSIX login shell bootstrap when no startup command is provided")
        case .exec(let command):
            #expect(command.hasPrefix("/bin/sh -lc \""))
            #expect(command.contains("exec \\\"\\$SHELL\\\" -l"))
            #expect(command.contains("TERM_PROGRAM"))
        }
    }

    @Test
    func launchPlanWithoutStartupCommandUsesInteractiveShellForCmd() {
        let plan = RemoteTerminalBootstrap.launchPlan(startupCommand: nil, environment: cmdEnvironment)

        switch plan {
        case .shell:
            #expect(Bool(true))
        case .exec:
            Issue.record("Expected plain shell launch for cmd.exe when no startup command is provided")
        }
    }

    @Test
    func launchPlanWithStartupCommandUsesPOSIXExecWrapper() {
        let plan = RemoteTerminalBootstrap.launchPlan(startupCommand: "echo hi", environment: posixEnvironment)

        switch plan {
        case .shell:
            Issue.record("Expected exec launch when a startup command is provided")
        case .exec(let command):
            #expect(command.hasPrefix("/bin/sh -lc \""))
            #expect(command.contains("echo hi"))
            #expect(command.contains("TERM_PROGRAM"))
        }
    }

    @Test
    func posixWrapperRoundTripsShellMetacharactersForMosh() {
        let script = #"printf '%s\n' "$HOME" "$(printf 'nested')" '`' '\path'"#
        let wrapped = RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
        let moshScript = RemoteTerminalBootstrap.moshStartupScript(startCommand: wrapped)

        #expect(wrapped.hasPrefix("/bin/sh -lc \""))
        #expect(moshScript.contains(script))
    }

    @Test
    func launchPlanWithStartupCommandUsesEncodedPowerShellWrapper() {
        let plan = RemoteTerminalBootstrap.launchPlan(startupCommand: "Write-Output 'hi'", environment: powerShellEnvironment)

        switch plan {
        case .shell:
            Issue.record("Expected exec launch when a PowerShell startup command is provided")
        case .exec(let command):
            #expect(command.hasPrefix("powershell -NoLogo -NoProfile -EncodedCommand "))
        }
    }

    @Test
    func launchPlanWithStartupCommandKeepsPwshExecutable() {
        let plan = RemoteTerminalBootstrap.launchPlan(startupCommand: "Write-Output 'hi'", environment: pwshEnvironment)

        switch plan {
        case .shell:
            Issue.record("Expected exec launch when a pwsh startup command is provided")
        case .exec(let command):
            #expect(command.hasPrefix("pwsh -NoLogo -NoProfile -EncodedCommand "))
        }
    }

    @Test
    func directoryChangeCommandUsesPOSIXCdForUnixPaths() {
        let command = RemoteTerminalBootstrap.directoryChangeCommand(for: "/var/www/app's", environment: posixEnvironment)

        #expect(command == "cd -- '/var/www/app'\\''s'\n")
    }

    @Test
    func directoryChangeCommandUsesPowerShellForWindowsPaths() {
        let command = RemoteTerminalBootstrap.directoryChangeCommand(for: #"C:\Users\O'Hara\repo"#, environment: powerShellEnvironment)

        #expect(command == "Set-Location -LiteralPath 'C:\\Users\\O''Hara\\repo'\r\n")
    }

    @Test
    func directoryChangeCommandNormalizesOSCStyleWindowsPaths() {
        let command = RemoteTerminalBootstrap.directoryChangeCommand(for: "/C:/Users/test/project", environment: powerShellEnvironment)

        #expect(command == "Set-Location -LiteralPath 'C:\\Users\\test\\project'\r\n")
    }

    @Test
    func directoryChangeCommandUsesCmdSyntaxForCmdProfile() {
        let command = RemoteTerminalBootstrap.directoryChangeCommand(for: #"C:\Users\test\project"#, environment: cmdEnvironment)

        #expect(command == "cd /d \"C:\\Users\\test\\project\"\r\n")
    }

    @Test
    func posixPastedPathQuotesShellSensitiveRemotePaths() {
        let pastedPath = RemoteTerminalBootstrap.posixPastedPath("/tmp/vv term/file's name.png")

        #expect(pastedPath == "'/tmp/vv term/file'\\''s name.png'")
    }
}
