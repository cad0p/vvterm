import Foundation

// MARK: - Windows Stats Collector

/// Stats collector for Windows systems via OpenSSH.
/// Prefers cmd.exe-friendly probes on cmd-hosted sessions and PowerShell on PowerShell-hosted sessions.
struct WindowsStatsCollector: PlatformStatsCollector {
    private let shellInfoTimeout: Duration = .seconds(5)
    private let cpuTimeout: Duration = .seconds(8)
    private let memoryTimeout: Duration = .seconds(8)
    private let uptimeTimeout: Duration = .seconds(8)
    private let processCountTimeout: Duration = .seconds(6)
    private let networkTimeout: Duration = .seconds(6)
    private let topProcessesTimeout: Duration = .seconds(8)
    private let volumesTimeout: Duration = .seconds(6)

    func getSystemInfo(client: SSHClient) async throws -> (hostname: String, osInfo: String, cpuCores: Int) {
        let environment = await client.remoteEnvironment()
        let hostname = ((try? await executeCMD("hostname", using: client, timeout: shellInfoTimeout))?
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let osInfo = ((try? await executeCMD("ver", using: client, timeout: shellInfoTimeout))?
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

        let cpuCoresCMD = (try? await executeCMD("echo %NUMBER_OF_PROCESSORS%", using: client, timeout: shellInfoTimeout))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1

        if environment.shellProfile.family == .cmd {
            return (hostname, osInfo, cpuCoresCMD)
        }

        if let cpuCoresOutput = try? await executePowerShell(
            using: client,
            script: "(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors",
            timeout: shellInfoTimeout,
            probeName: "cpu_cores"
        ) {
            let cpuCores = Int(cpuCoresOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? cpuCoresCMD
            return (hostname, osInfo, cpuCores)
        }

        return (hostname, osInfo, cpuCoresCMD)
    }

    func collectStats(client: SSHClient, context: StatsCollectionContext) async throws -> ServerStats {
        var stats = ServerStats()
        let environment = await client.remoteEnvironment()
        let preferCMD = environment.shellProfile.family == .cmd

        if preferCMD {
            if let cpuPercent = try? await collectCPUUsageCMD(client: client) {
                applyCPU(cpuPercent, to: &stats)
            }
        } else if let cpuOutput = try? await executePowerShell(
            using: client,
            script: "Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average",
            timeout: cpuTimeout,
            probeName: "cpu_usage"
        ) {
            let cpuPercent = Double(cpuOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            applyCPU(cpuPercent, to: &stats)
        }

        if preferCMD {
            if let memory = try? await collectMemoryCMD(client: client) {
                stats.memoryTotal = memory.total
                stats.memoryUsed = memory.used
                stats.memoryFree = memory.free
            }
        } else if let memoryOutput = try? await executePowerShell(
            using: client,
            script: """
            $os = Get-CimInstance Win32_OperatingSystem;
            Write-Output ($os.TotalVisibleMemorySize * 1024);
            Write-Output '---SEP---';
            Write-Output (($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 1024);
            Write-Output '---SEP---';
            Write-Output ($os.FreePhysicalMemory * 1024)
            """,
            timeout: memoryTimeout,
            probeName: "memory"
        ) {
            let sections = memoryOutput.components(separatedBy: "---SEP---")
            if sections.count > 0 {
                stats.memoryTotal = UInt64(sections[0].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
            if sections.count > 1 {
                stats.memoryUsed = UInt64(sections[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
            if sections.count > 2 {
                stats.memoryFree = UInt64(sections[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        }
        stats.memoryCached = 0
        stats.memoryBuffers = 0

        if preferCMD {
            if let uptime = try? await collectUptimeCMD(client: client) {
                stats.uptime = uptime
            }
        } else if let uptimeOutput = try? await executePowerShell(
            using: client,
            script: """
            $os = Get-CimInstance Win32_OperatingSystem;
            Write-Output ([int]((Get-Date) - $os.LastBootUpTime).TotalSeconds)
            """,
            timeout: uptimeTimeout,
            probeName: "uptime"
        ) {
            stats.uptime = TimeInterval(uptimeOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        if preferCMD, let tasklistOutput = try? await executeCMD("tasklist /NH", using: client, timeout: processCountTimeout) {
            stats.processCount = tasklistOutput
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("INFO:") }
                .count
        } else if let processCountOutput = try? await executePowerShell(
            using: client,
            script: "(Get-Process).Count",
            timeout: processCountTimeout,
            probeName: "process_count"
        ) {
            stats.processCount = Int(processCountOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        if let network = try? await (preferCMD ? collectNetworkStatsCMD(client: client) : collectNetworkStats(client: client)) {
            let netRx = network.rx
            stats.networkRxTotal = netRx

            let now = Date()
            let (prevRx, prevTx, previousTimestamp) = context.getNetworkPrev()

            if let previousTimestamp, prevRx > 0 {
                let elapsed = now.timeIntervalSince(previousTimestamp)
                if elapsed > 0 {
                    stats.networkRxSpeed = UInt64(Double(netRx - prevRx) / elapsed)
                }
            }
            let netTx = network.tx
            stats.networkTxTotal = netTx

            if let previousTimestamp, prevTx > 0 {
                let elapsed = now.timeIntervalSince(previousTimestamp)
                if elapsed > 0 {
                    stats.networkTxSpeed = UInt64(Double(netTx - prevTx) / elapsed)
                }
            }

            context.updateNetwork(rx: stats.networkRxTotal, tx: netTx, timestamp: Date())
        }

        // Load average (Windows doesn't have this, approximate from CPU)
        stats.loadAverage = (stats.cpuUsage / 100, stats.cpuUsage / 100, stats.cpuUsage / 100)

        if preferCMD {
            if let processOutput = try? await executeCMD(
                "wmic path Win32_PerfFormattedData_PerfProc_Process get IDProcess,Name,PercentProcessorTime,WorkingSetPrivate /format:csv",
                using: client,
                timeout: topProcessesTimeout
            ) {
                stats.topProcesses = parseWMICProcesses(processOutput, memoryTotal: stats.memoryTotal)
            }
        } else if let processOutput = try? await executePowerShell(
            using: client,
            script: "Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object { Write-Output ('{0}|{1}|{2}|{3}' -f $_.Id, $_.ProcessName, [math]::Round($_.CPU,1), [math]::Round($_.WorkingSet64/1MB,1)) }",
            timeout: topProcessesTimeout,
            probeName: "top_processes"
        ) {
            stats.topProcesses = parseProcesses(processOutput)
        }

        if preferCMD {
            if let volumeOutput = try? await executeCMD(
                "wmic logicaldisk where \"DriveType=3\" get Caption,FreeSpace,Size /value",
                using: client,
                timeout: volumesTimeout
            ) {
                stats.volumes = parseWMICVolumes(volumeOutput)
            }
        } else if let volumeOutput = try? await executePowerShell(
            using: client,
            script: "Get-PSDrive -PSProvider FileSystem | Where-Object {$_.Used -gt 0} | ForEach-Object { Write-Output ('{0}|{1}|{2}' -f $_.Name, $_.Used, ($_.Used + $_.Free)) }",
            timeout: volumesTimeout,
            probeName: "volumes"
        ) {
            stats.volumes = parseVolumes(volumeOutput)
        }

        stats.timestamp = Date()
        return stats
    }

    private func applyCPU(_ cpuPercent: Double, to stats: inout ServerStats) {
        let clamped = min(max(cpuPercent, 0), 100)
        stats.cpuUsage = clamped
        stats.cpuUser = clamped * 0.7
        stats.cpuSystem = clamped * 0.3
        stats.cpuIdle = 100 - clamped
        stats.cpuIowait = 0
        stats.cpuSteal = 0
    }

    private func collectNetworkStats(client: SSHClient) async throws -> (rx: UInt64, tx: UInt64) {
        let output = try await executePowerShell(
            using: client,
            script: """
            $stats = Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Where-Object {$_.Name -notlike '*Loopback*'};
            $rx = ($stats | Measure-Object -Property ReceivedBytes -Sum).Sum;
            $tx = ($stats | Measure-Object -Property SentBytes -Sum).Sum;
            Write-Output $rx;
            Write-Output '---SEP---';
            Write-Output $tx
            """,
            timeout: networkTimeout,
            probeName: "network"
        )
        let sections = output.components(separatedBy: "---SEP---")
        let rx = sections.indices.contains(0) ? UInt64(sections[0].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        let tx = sections.indices.contains(1) ? UInt64(sections[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        return (rx, tx)
    }

    private func collectCPUUsageCMD(client: SSHClient) async throws -> Double {
        if let output = try? await executeCMD(
            "typeperf \"\\\\Processor(_Total)\\\\% Processor Time\" -sc 1",
            using: client,
            timeout: cpuTimeout
        ), let value = parseTypeperfValue(output) {
            return value
        }

        let output = try await executeCMD(
            "wmic cpu get loadpercentage /value",
            using: client,
            timeout: cpuTimeout
        )
        let values = parseWMICKeyValueOutput(output)["LoadPercentage"]?
            .compactMap { Double($0) } ?? []
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func collectMemoryCMD(client: SSHClient) async throws -> (total: UInt64, used: UInt64, free: UInt64) {
        let output = try await executeCMD(
            "wmic OS get FreePhysicalMemory,TotalVisibleMemorySize /value",
            using: client,
            timeout: memoryTimeout
        )
        let values = parseWMICKeyValueOutput(output)
        let freeKB = UInt64(values["FreePhysicalMemory"]?.first ?? "") ?? 0
        let totalKB = UInt64(values["TotalVisibleMemorySize"]?.first ?? "") ?? 0
        let free = freeKB * 1024
        let total = totalKB * 1024
        return (total, total >= free ? total - free : 0, free)
    }

    private func collectUptimeCMD(client: SSHClient) async throws -> TimeInterval {
        let output = try await executeCMD(
            "wmic os get lastbootuptime /value",
            using: client,
            timeout: uptimeTimeout
        )
        let lastBoot = parseWMICKeyValueOutput(output)["LastBootUpTime"]?.first ?? ""
        guard let bootDate = parseWMIDate(lastBoot) else { return 0 }
        return max(Date().timeIntervalSince(bootDate), 0)
    }

    private func collectNetworkStatsCMD(client: SSHClient) async throws -> (rx: UInt64, tx: UInt64) {
        let output = try await executeCMD(
            "netstat -e",
            using: client,
            timeout: networkTimeout
        )
        return parseNetstatInterfaceStats(output)
    }

    private func executePowerShell(
        using client: SSHClient,
        script: String,
        timeout: Duration,
        probeName: String
    ) async throws -> String {
        let command = try await powerShellCommand(using: client, script: script)
        return try await execute(command: command, using: client, timeout: timeout)
    }

    private func executeCMD(
        _ command: String,
        using client: SSHClient,
        timeout: Duration
    ) async throws -> String {
        try await execute(command: "cmd.exe /d /c \(command)", using: client, timeout: timeout)
    }

    private func execute(
        command: String,
        using client: SSHClient,
        timeout: Duration
    ) async throws -> String {
        try await client.execute(command, timeout: timeout)
    }

    private func powerShellCommand(using client: SSHClient, script: String) async throws -> String {
        let environment = await client.remoteEnvironment()
        if environment.shellProfile.family == .powershell {
            return script
        }

        guard let executable = environment.powerShellExecutable else {
            throw SSHError.unknown("Windows stats require a working PowerShell runtime on the remote host")
        }
        let wrapped = RemoteTerminalBootstrap.wrapPowerShellCommand(script, executableName: executable)
        if environment.shellProfile.family == .cmd {
            return RemoteTerminalBootstrap.wrapCmdExecCommand(wrapped)
        }
        return wrapped
    }

    // MARK: - Parsers

    private func parseProcesses(_ output: String) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 4 else { continue }

            let pid = Int(parts[0]) ?? 0
            let name = parts[1]
            let cpu = Double(parts[2]) ?? 0
            let mem = Double(parts[3]) ?? 0

            processes.append(ProcessInfo(pid: pid, name: name, cpuPercent: cpu, memoryPercent: mem))
        }

        return processes
    }

    private func parseVolumes(_ output: String) -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 3 else { continue }

            let mountPoint = parts[0] + ":\\"
            let used = UInt64(parts[1]) ?? 0
            let total = UInt64(parts[2]) ?? 0

            if total < 100 * 1024 * 1024 { continue } // Skip volumes < 100MB

            volumes.append(VolumeInfo(
                mountPoint: mountPoint,
                used: used,
                total: total
            ))
        }

        return volumes
    }

    private func parseWMICVolumes(_ output: String) -> [VolumeInfo] {
        let entries = parseWMICEntries(output)
        return entries.compactMap { entry in
            guard
                let caption = entry["Caption"],
                let free = UInt64(entry["FreeSpace"] ?? ""),
                let total = UInt64(entry["Size"] ?? "")
            else {
                return nil
            }

            if total < 100 * 1024 * 1024 {
                return nil
            }

            return VolumeInfo(
                mountPoint: caption.hasSuffix("\\") ? caption : "\(caption)\\",
                used: total >= free ? total - free : 0,
                total: total
            )
        }
    }

    private func parseWMICProcesses(_ output: String, memoryTotal: UInt64) -> [ProcessInfo] {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else { return [] }

        var processes: [ProcessInfo] = []
        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.count >= 5 else { continue }

            let pid = Int(fields[1]) ?? 0
            let name = fields[2]
            if pid <= 0 || name.isEmpty || name == "_Total" || name == "Idle" {
                continue
            }

            let rawCPU = Double(fields[3]) ?? 0
            let workingSet = UInt64(fields[4]) ?? 0
            let cpuPercent = min(max(rawCPU, 0), 100)
            let memoryPercent = memoryTotal > 0 ? (Double(workingSet) / Double(memoryTotal) * 100) : 0

            processes.append(ProcessInfo(
                pid: pid,
                name: name,
                cpuPercent: cpuPercent,
                memoryPercent: memoryPercent
            ))
        }

        return processes
            .sorted { lhs, rhs in
                if lhs.cpuPercent == rhs.cpuPercent {
                    return lhs.memoryPercent > rhs.memoryPercent
                }
                return lhs.cpuPercent > rhs.cpuPercent
            }
            .prefix(5)
            .map { $0 }
    }

    private func parseWMICKeyValueOutput(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }

            let key = String(trimmed[..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key, default: []].append(value)
        }
        return result
    }

    private func parseWMICEntries(_ output: String) -> [[String: String]] {
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
        let sections = normalized.components(separatedBy: "\n\n")
        return sections.compactMap { section in
            var entry: [String: String] = [:]
            for rawLine in section.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<separator])
                let value = String(line[line.index(after: separator)...])
                if !key.isEmpty, !value.isEmpty {
                    entry[key] = value
                }
            }
            return entry.isEmpty ? nil : entry
        }
    }

    private func parseTypeperfValue(_ output: String) -> Double? {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let lastLine = lines.last else { return nil }
        let fields = parseCSVLine(lastLine)
        guard let rawValue = fields.last?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) else {
            return nil
        }
        let normalized = rawValue.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }

    private func parseNetstatInterfaceStats(_ output: String) -> (rx: UInt64, tx: UInt64) {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("bytes") else { continue }

            let parts = trimmed
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard parts.count >= 3 else { continue }

            let rx = UInt64(parts[1]) ?? 0
            let tx = UInt64(parts[2]) ?? 0
            return (rx, tx)
        }
        return (0, 0)
    }

    private func parseCSVLine(_ line: String) -> [String] {
        guard !line.isEmpty else { return [] }

        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let character = iterator.next() {
            switch character {
            case "\"":
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        current.append("\"")
                    } else {
                        inQuotes = false
                        if next == "," {
                            fields.append(current)
                            current = ""
                        } else {
                            current.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            case "," where !inQuotes:
                fields.append(current)
                current = ""
            default:
                current.append(character)
            }
        }

        fields.append(current)
        return fields
    }

    private func parseWMIDate(_ raw: String) -> Date? {
        guard raw.count >= 21 else { return nil }

        let year = Int(raw.prefix(4)) ?? 0
        let month = Int(raw.dropFirst(4).prefix(2)) ?? 1
        let day = Int(raw.dropFirst(6).prefix(2)) ?? 1
        let hour = Int(raw.dropFirst(8).prefix(2)) ?? 0
        let minute = Int(raw.dropFirst(10).prefix(2)) ?? 0
        let second = Int(raw.dropFirst(12).prefix(2)) ?? 0

        let signIndex = raw.index(raw.startIndex, offsetBy: 21)
        guard signIndex < raw.endIndex else { return nil }
        let signCharacter = raw[signIndex]
        let offsetDigits = String(raw.dropFirst(22).prefix(3))
        let offsetMinutes = Int(offsetDigits) ?? 0
        let signedOffset = signCharacter == "-" ? -offsetMinutes : offsetMinutes

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: signedOffset * 60)
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
