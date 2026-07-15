import Foundation
import Testing
@testable import VVTerm

struct RemoteTerminalTypeResolverTests {
    private let posixEnvironment = RemoteEnvironment(
        platform: .linux,
        shellProfile: .posix(shellName: "zsh"),
        activeShellName: "zsh",
        powerShellExecutable: nil
    )

    private let cmdEnvironment = RemoteEnvironment(
        platform: .windows,
        shellProfile: .cmd,
        activeShellName: "cmd.exe",
        powerShellExecutable: nil
    )

    private let terminfoSource = """
    xterm-ghostty|ghostty|Ghostty,
    \tcolors#256,
    """

    actor FakeExecutor {
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
            switch outputs.removeFirst() {
            case .success(let output):
                return output
            case .failure(let error):
                throw error
            }
        }

        func recordedCommands() -> [String] {
            commands
        }
    }

    @Test
    func resolveFallsBackForNonPOSIXRemotesWithoutExecutingCommands() async {
        let executor = FakeExecutor(outputs: [])

        let terminalType = await RemoteTerminalTypeResolver.resolve(
            environment: cmdEnvironment,
            execute: { command, timeout in
                try await executor.run(command: command, timeout: timeout)
            },
            terminfoSource: terminfoSource
        )

        #expect(terminalType == .xterm256Color)
        #expect(await executor.recordedCommands().isEmpty)
    }

    @Test
    func resolveUsesGhosttyWhenInstallCommandFindsExistingEntry() async {
        let executor = FakeExecutor(outputs: [
            .success("__VVTERM_XTERM_GHOSTTY_INSTALLED__")
        ])

        let terminalType = await RemoteTerminalTypeResolver.resolve(
            environment: posixEnvironment,
            execute: { command, timeout in
                try await executor.run(command: command, timeout: timeout)
            },
            terminfoSource: terminfoSource
        )

        let commands = await executor.recordedCommands()
        #expect(terminalType == .xtermGhostty)
        #expect(commands.count == 1)
        #expect(commands[0].contains("infocmp -x xterm-ghostty"))
        #expect(commands[0].contains("tic -x -"))
    }

    @Test
    func probeCommandChecksCompiledTerminfoLocationsWhenInfocmpIsUnavailable() {
        let command = RemoteTerminalTypeResolver.probeCommand()

        #expect(command.contains("vvterm_has_xterm_ghostty_terminfo"))
        #expect(command.contains("$HOME/.terminfo"))
        #expect(command.contains("/x/xterm-ghostty"))
        #expect(command.contains("/78/xterm-ghostty"))
    }

    @Test
    func resolveInstallsGhosttyTerminfoWhenProbeMisses() async {
        let executor = FakeExecutor(outputs: [
            .success("__VVTERM_XTERM_GHOSTTY_INSTALLED__")
        ])

        let terminalType = await RemoteTerminalTypeResolver.resolve(
            environment: posixEnvironment,
            execute: { command, timeout in
                try await executor.run(command: command, timeout: timeout)
            },
            terminfoSource: terminfoSource
        )

        let commands = await executor.recordedCommands()
        #expect(terminalType == .xtermGhostty)
        #expect(commands.count == 1)
        #expect(commands[0].contains("tic -x -"))
        #expect(commands[0].contains("xterm-ghostty|ghostty|Ghostty"))
    }

    @Test
    func resolveFallsBackWhenInstallationFails() async {
        let executor = FakeExecutor(outputs: [
            .success("__VVTERM_XTERM_GHOSTTY_INSTALL_FAILED__")
        ])

        let terminalType = await RemoteTerminalTypeResolver.resolve(
            environment: posixEnvironment,
            execute: { command, timeout in
                try await executor.run(command: command, timeout: timeout)
            },
            terminfoSource: terminfoSource
        )

        #expect(terminalType == .xterm256Color)
    }
}
