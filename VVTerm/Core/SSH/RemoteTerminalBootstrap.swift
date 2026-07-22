import Foundation

struct RemoteTerminalEnvironmentVariable: Hashable, Sendable {
    let name: String
    let value: String
}

enum RemoteTerminalType: String, Hashable, Sendable {
    case xterm256Color = "xterm-256color"
    case xtermGhostty = "xterm-ghostty"
}

enum RemoteShellLaunchPlan: Hashable, Sendable {
    case shell
    case exec(String)
}

enum RemoteTerminalBootstrap {
    nonisolated static let defaultTerminalType: RemoteTerminalType = .xterm256Color
    nonisolated static let termProgram = "vvterm"

    nonisolated static func appVersion(bundle: Bundle = .main) -> String {
        (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    nonisolated static func ghosttyTerminfoSource(bundle: Bundle = .main) -> String? {
        let candidates = [
            bundle.url(forResource: "xterm-ghostty", withExtension: "src"),
            bundle.url(forResource: "xterm-ghostty", withExtension: "src", subdirectory: "terminfo"),
            bundle.url(forResource: "xterm-ghostty", withExtension: "src", subdirectory: "Resources/terminfo")
        ]

        for url in candidates.compactMap({ $0 }) {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed + "\n"
                }
            }
        }

        guard let resourcePath = bundle.resourcePath else { return nil }
        let fileManager = FileManager.default
        let paths = [
            (resourcePath as NSString).appendingPathComponent("xterm-ghostty.src"),
            (resourcePath as NSString).appendingPathComponent("terminfo/xterm-ghostty.src"),
            (resourcePath as NSString).appendingPathComponent("Resources/terminfo/xterm-ghostty.src")
        ]

        for path in paths where fileManager.fileExists(atPath: path) {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed + "\n"
                }
            }
        }

        return nil
    }

    nonisolated static func terminalEnvironment(bundle: Bundle = .main) -> [RemoteTerminalEnvironmentVariable] {
        [
            RemoteTerminalEnvironmentVariable(name: "COLORTERM", value: "truecolor"),
            RemoteTerminalEnvironmentVariable(name: "TERM_PROGRAM", value: termProgram),
            RemoteTerminalEnvironmentVariable(name: "TERM_PROGRAM_VERSION", value: appVersion(bundle: bundle))
        ]
    }

    nonisolated static func terminalEnvironmentNames(bundle: Bundle = .main) -> [String] {
        terminalEnvironment(bundle: bundle).map(\.name)
    }

    nonisolated static func terminalEnvironmentDictionary(
        bundle: Bundle = .main,
        terminalType: RemoteTerminalType
    ) -> [String: String] {
        var environment = Dictionary(
            uniqueKeysWithValues: terminalEnvironment(bundle: bundle).map { ($0.name, $0.value) }
        )
        environment["TERM"] = terminalType.rawValue
        return environment
    }

    nonisolated static func environmentExportScript(
        bundle: Bundle = .main,
        terminalType: RemoteTerminalType? = nil
    ) -> String {
        var assignments = terminalEnvironment(bundle: bundle)
            .map { "\($0.name)=\(shellQuoted($0.value))" }
        if let terminalType {
            assignments.insert("TERM=\(shellQuoted(terminalType.rawValue))", at: 0)
        }
        let command = assignments.joined(separator: " ")
        return "export \(command);"
    }

    nonisolated static func defaultLoginShellCommand() -> String {
        """
        if [ -n "$SHELL" ]; then exec "$SHELL" -l; fi;
        if command -v bash >/dev/null 2>&1; then exec bash -l; fi;
        if command -v zsh >/dev/null 2>&1; then exec zsh -l; fi;
        exec sh -l
        """
    }

    nonisolated static func launchPlan(
        startupCommand: String?,
        environment: RemoteEnvironment = .fallbackPOSIX,
        bundle: Bundle = .main
    ) -> RemoteShellLaunchPlan {
        environment.shellProfile.launchPlan(startupCommand: startupCommand, bundle: bundle)
    }

    nonisolated static func moshStartupScript(
        startCommand: String?,
        terminalType: RemoteTerminalType = defaultTerminalType,
        bundle: Bundle = .main
    ) -> String {
        let command = trimmedStartupCommand(startCommand)
            .flatMap { unwrapPOSIXShellInvocationIfNeeded($0) ?? $0 }
            ?? defaultLoginShellCommand()
        return prefixedPOSIXScript(for: command, bundle: bundle, terminalType: terminalType)
    }

    nonisolated static func wrapPOSIXShellCommand(_ script: String) -> String {
        "/bin/sh -lc \(doubleQuotedShellArgument(script))"
    }

    nonisolated static func wrapPowerShellCommand(_ script: String, executableName: String) -> String {
        let data = script.data(using: .utf16LittleEndian) ?? Data()
        return "\(executableName) -NoLogo -NoProfile -EncodedCommand \(data.base64EncodedString())"
    }

    nonisolated static func wrapCmdCommand(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\"", with: "\"\"")
        return "cmd.exe /d /s /k \"\(escaped)\""
    }

    nonisolated static func wrapCmdExecCommand(_ command: String) -> String {
        // Use a direct `cmd /c <command>` form for non-interactive execution.
        // The quoted `/s /c "..."` form has proven unreliable for launching
        // nested PowerShell commands over Windows OpenSSH exec channels.
        "cmd.exe /d /c \(command)"
    }

    nonisolated static func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    nonisolated static func posixPastedPath(_ path: String) -> String {
        shellQuoted(path)
    }

    nonisolated static func directoryChangeCommand(
        for path: String,
        environment: RemoteEnvironment = .fallbackPOSIX
    ) -> String {
        environment.shellProfile.directoryChangeCommand(for: path)
    }

    nonisolated static func posixDirectoryChangeCommand(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "\n" }
        return "cd -- \(shellQuoted(trimmed))\n"
    }

    nonisolated static func powerShellDirectoryChangeCommand(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "\r\n" }
        let resolved = normalizedWindowsPath(from: trimmed) ?? trimmed
        return "Set-Location -LiteralPath \(powerShellQuoted(resolved))\r\n"
    }

    nonisolated static func cmdDirectoryChangeCommand(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "\n" }
        let resolved = normalizedWindowsPath(from: trimmed) ?? trimmed
        let escaped = resolved.replacingOccurrences(of: "\"", with: "\"\"")
        return "cd /d \"\(escaped)\"\r\n"
    }

    nonisolated static func shellPathExport() -> String {
        "export PATH=\"\(shellPathValue())\""
    }

    nonisolated static func tmuxUpdateEnvironmentVariables(bundle: Bundle = .main) -> [String] {
        ["LANG", "LC_ALL", "LC_CTYPE"] + terminalEnvironmentNames(bundle: bundle)
    }

    nonisolated static func tmuxArrayOptionCommands(option: String, values: [String]) -> [String] {
        let reset = "set -gu \(option)"
        let assignments = values.enumerated().map { index, value in
            "set -g \(option)[\(index)] \"\(value)\""
        }
        return [reset] + assignments
    }

    nonisolated static func tmuxEnvironmentCommands(bundle: Bundle = .main) -> [String] {
        terminalEnvironment(bundle: bundle).map { variable in
            "set-environment -g \(variable.name) \"\(variable.value)\""
        }
    }

    nonisolated static func prefixedPOSIXScript(
        for command: String,
        bundle: Bundle = .main,
        terminalType: RemoteTerminalType? = nil
    ) -> String {
        "\(environmentExportScript(bundle: bundle, terminalType: terminalType)) \(command)"
    }

    nonisolated static func prefixedPowerShellScript(for command: String, bundle: Bundle = .main) -> String {
        let environmentSetup = terminalEnvironment(bundle: bundle)
            .map { "$env:\($0.name) = \(powerShellQuoted($0.value))" }
            .joined(separator: "; ")
        return "\(environmentSetup); \(command)"
    }

    nonisolated private static func trimmedStartupCommand(_ startupCommand: String?) -> String? {
        let trimmed = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func unwrapPOSIXShellInvocationIfNeeded(_ command: String) -> String? {
        let prefixes = ["sh -lc ", "/bin/sh -lc "]
        guard let prefix = prefixes.first(where: { command.hasPrefix($0) }) else {
            return nil
        }

        let payload = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }

        if payload.hasPrefix("'"), payload.hasSuffix("'"), payload.count >= 2 {
            let start = payload.index(after: payload.startIndex)
            let end = payload.index(before: payload.endIndex)
            let quoted = String(payload[start..<end])
            return quoted.replacingOccurrences(of: "'\\''", with: "'")
        }

        if payload.hasPrefix("\""), payload.hasSuffix("\""), payload.count >= 2 {
            let start = payload.index(after: payload.startIndex)
            let end = payload.index(before: payload.endIndex)
            let quoted = String(payload[start..<end])
            return unescapeDoubleQuotedShellArgument(quoted)
        }

        return payload
    }

    nonisolated private static func shellPathValue() -> String {
        let paths = [
            "$HOME/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/opt/local/bin",
            "/opt/local/sbin",
            "/snap/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        return paths.joined(separator: ":") + ":$PATH"
    }

    nonisolated private static func doubleQuotedShellArgument(_ value: String) -> String {
        // Fish preserves \` inside double quotes, unlike POSIX shells.
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\"'`'\"")
        return "\"\(escaped)\""
    }

    nonisolated private static func unescapeDoubleQuotedShellArgument(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var index = value.startIndex

        while index < value.endIndex {
            if value[index...].hasPrefix("\"'`'\"") {
                result.append("`")
                index = value.index(index, offsetBy: 5)
                continue
            }

            let character = value[index]
            guard character == "\\" else {
                result.append(character)
                index = value.index(after: index)
                continue
            }

            let nextIndex = value.index(after: index)
            guard nextIndex < value.endIndex else {
                result.append(character)
                break
            }

            let next = value[nextIndex]
            switch next {
            case "\\", "\"", "$":
                result.append(next)
                index = value.index(after: nextIndex)
            default:
                result.append(character)
                index = nextIndex
            }
        }

        return result
    }

    nonisolated private static func powerShellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    nonisolated private static func normalizedWindowsPath(from path: String) -> String? {
        if let directDriveLetter = directWindowsDriveLetter(in: path) {
            let startIndex = path.index(path.startIndex, offsetBy: 2)
            let suffix = startIndex < path.endIndex ? String(path[startIndex...]) : ""
            let normalizedSuffix = suffix.replacingOccurrences(of: "/", with: "\\")
            return "\(directDriveLetter):\(normalizedSuffix)"
        }

        if let oscDriveLetter = oscWindowsDriveLetter(in: path) {
            let startIndex = path.index(path.startIndex, offsetBy: 3)
            let suffix = startIndex < path.endIndex ? String(path[startIndex...]) : ""
            let normalizedSuffix = suffix.replacingOccurrences(of: "/", with: "\\")
            return "\(oscDriveLetter):\(normalizedSuffix)"
        }

        if path.hasPrefix("\\\\") {
            return path
        }

        if path.hasPrefix("//") {
            return "\\\\" + String(path.dropFirst(2)).replacingOccurrences(of: "/", with: "\\")
        }

        return nil
    }

    nonisolated private static func directWindowsDriveLetter(in path: String) -> Character? {
        let scalars = Array(path.unicodeScalars)
        guard scalars.count >= 2 else { return nil }

        func isLetter(_ scalar: UnicodeScalar) -> Bool {
            (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
        }

        if isLetter(scalars[0]), scalars[1] == ":" {
            return Character(scalars[0])
        }

        return nil
    }

    nonisolated private static func oscWindowsDriveLetter(in path: String) -> Character? {
        let scalars = Array(path.unicodeScalars)
        guard scalars.count >= 4 else { return nil }

        func isLetter(_ scalar: UnicodeScalar) -> Bool {
            (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
        }

        guard scalars[0] == "/", isLetter(scalars[1]), scalars[2] == ":", scalars[3] == "/" else {
            return nil
        }
        return Character(scalars[1])
    }
}
