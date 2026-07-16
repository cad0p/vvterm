#if os(macOS)
import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
struct RemoteTmuxManagerLocalIntegrationTests {
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux")))
    func externalAttachPreservesRealTmuxGlobalOptions() throws {
        let installedTmux = "/opt/homebrew/bin/tmux"

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let root = temporaryDirectory
            .appendingPathComponent("vvterm-dev218-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let fixtureConfig = root.appendingPathComponent("fixture.conf")
        // tmux's default socket suffix exceeds the Unix socket limit inside XCTest's
        // long sandbox path, so the fixture uses a short explicit socket.
        let socket = temporaryDirectory.appendingPathComponent(
            "v218-\(UUID().uuidString.prefix(4))"
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("set -g remain-on-exit on\n".utf8).write(to: fixtureConfig)
        defer {
            try? FileManager.default.removeItem(at: socket)
            try? FileManager.default.removeItem(at: root)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment.removeValue(forKey: "TMUX")

        let sessionName = "external's;session"
        defer {
            _ = try? runTmux(
                installedTmux,
                socket: socket,
                arguments: ["kill-server"],
                environment: environment
            )
        }

        try requireSuccess(runTmux(
            installedTmux,
            socket: socket,
            arguments: [
                "-f", fixtureConfig.path,
                "new-session", "-d",
                "-s", sessionName
            ],
            environment: environment
        ))
        let customOptions = [
            "status": "on",
            "status-right": "#(date +%s) external-status",
            "history-limit": "100000",
            "mouse": "off",
            "default-terminal": "tmux-256color"
        ]
        for (option, value) in customOptions {
            try setGlobalOption(
                option,
                to: value,
                tmux: installedTmux,
                socket: socket,
                environment: environment
            )
        }
        try setGlobalArrayOption(
            "terminal-features",
            to: "xterm*:extkeys",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        try setServerOption(
            "extended-keys",
            to: "off",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        try setGlobalArrayOption(
            "terminal-overrides",
            to: "*256col*:Tc",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )

        let configWrite = RemoteTmuxManager.shared.configWriteExecutionCommand(
            terminalType: .xtermGhostty,
            backend: .unixTmux
        )
        try requireSuccess(run("/bin/sh", ["-c", configWrite], environment: environment))
        let options = [
            "status",
            "status-right",
            "history-limit",
            "mouse",
            "default-terminal",
            "terminal-features",
            "terminal-overrides"
        ]
        let before = try globalOptions(
            options,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let extendedKeysBefore = try serverOption(
            "extended-keys",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )

        let externalAttach = RemoteTmuxManager.shared.attachExistingCommand(
            sessionName: sessionName,
            ownership: .external,
            lifecycleMarkerToken: "integration"
        )
        let socketScopedAttach = """
        tmux() {
          \(installedTmux) -S '\(socket.path)' "$@"
        }
        \(externalAttach)
        """
        let attachResult = try run(
            "/bin/sh",
            ["-c", socketScopedAttach],
            environment: environment
        )
        let detached = TmuxLifecycleMarker.sequence(token: "integration", event: .detached)
        let ended = TmuxLifecycleMarker.sequence(token: "integration", event: .ended)
        #expect(attachResult.output.contains(detached))
        #expect(!attachResult.output.contains(ended))

        let after = try globalOptions(
            options,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let extendedKeysAfter = try serverOption(
            "extended-keys",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        #expect(after == before)
        #expect(extendedKeysAfter == extendedKeysBefore)
    }

    private func setGlobalOption(
        _ option: String,
        to value: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws {
        try requireSuccess(runTmux(
            tmux,
            socket: socket,
            arguments: ["set-option", "-g", option, value],
            environment: environment
        ))
    }

    private func setGlobalArrayOption(
        _ option: String,
        to value: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws {
        try requireSuccess(runTmux(
            tmux,
            socket: socket,
            arguments: ["set-option", "-gu", option],
            environment: environment
        ))
        try requireSuccess(runTmux(
            tmux,
            socket: socket,
            arguments: ["set-option", "-g", "\(option)[0]", value],
            environment: environment
        ))
    }

    private func setServerOption(
        _ option: String,
        to value: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws {
        try requireSuccess(runTmux(
            tmux,
            socket: socket,
            arguments: ["set-option", "-s", option, value],
            environment: environment
        ))
    }

    private func globalOptions(
        _ options: [String],
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: options.map { option in
            let result = try runTmux(
                tmux,
                socket: socket,
                arguments: ["show-options", "-g", option],
                environment: environment
            )
            try requireSuccess(result)
            return (option, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    private func serverOption(
        _ option: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws -> String {
        let result = try runTmux(
            tmux,
            socket: socket,
            arguments: ["show-options", "-s", option],
            environment: environment
        )
        try requireSuccess(result)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runTmux(
        _ executable: String,
        socket: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> CommandResult {
        try run(
            executable,
            ["-S", socket.path] + arguments,
            environment: environment
        )
    }

    private func requireSuccess(_ result: CommandResult) throws {
        guard result.status == 0 else {
            throw NSError(
                domain: "RemoteTmuxManagerLocalIntegrationTests",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.output]
            )
        }
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]
    ) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }
}
#endif
