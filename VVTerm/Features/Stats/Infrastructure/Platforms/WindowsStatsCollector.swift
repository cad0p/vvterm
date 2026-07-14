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
    private let gpuTimeout: Duration = .seconds(8)
    private let periodicProcessLimit = 24

    func getSystemInfo(client: SSHClient) async throws -> (hostname: String, osInfo: String, cpuCores: Int) {
        let environment = await client.remoteEnvironment()
        let hostname = ((try? await executeCMD("hostname", using: client, timeout: shellInfoTimeout))?
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let osInfo = ((try? await executeCMD("ver", using: client, timeout: shellInfoTimeout))?
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

        let environmentCPUCount = (try? await executeCMD("echo %NUMBER_OF_PROCESSORS%", using: client, timeout: shellInfoTimeout))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
        let wmicCPUCount = (try? await executeCMD(
            "wmic computersystem get NumberOfLogicalProcessors /value",
            using: client,
            timeout: shellInfoTimeout
        )).flatMap { output in
            parseWMICKeyValueOutput(output)["NumberOfLogicalProcessors"]?.first.flatMap(Int.init)
        }
        let cpuCoresCMD = max(wmicCPUCount ?? environmentCPUCount, 1)

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

    func collectProfile(client: SSHClient) async throws -> HardwareProfile {
        let systemInfo = try await getSystemInfo(client: client)

        let cpuOutput = (try? await executePowerShell(
            using: client,
            script: """
            $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1;
            Write-Output $cpu.Name;
            Write-Output '---SEP---';
            Write-Output $cpu.Manufacturer;
            Write-Output '---SEP---';
            Write-Output $cpu.NumberOfCores;
            Write-Output '---SEP---';
            Write-Output $cpu.NumberOfLogicalProcessors
            """,
            timeout: shellInfoTimeout,
            probeName: "profile_cpu"
        )) ?? ""
        let cpuSections = cpuOutput.components(separatedBy: "---SEP---")

        let memoryOutput = (try? await executePowerShell(
            using: client,
            script: "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory",
            timeout: shellInfoTimeout,
            probeName: "profile_memory"
        )) ?? ""

        let nvidiaGPUOutput = (try? await executePowerShell(
            using: client,
            script: nvidiaSMIQueryScript(fields: "index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,driver_version"),
            timeout: gpuTimeout,
            probeName: "profile_nvidia_gpu"
        )) ?? ""

        let gpuOutput = (try? await executePowerShell(
            using: client,
            script: """
            Get-CimInstance Win32_VideoController | ForEach-Object {
                Write-Output ('{0}|{1}|{2}|{3}|{4}|{5}' -f $_.Name, $_.AdapterCompatibility, $_.AdapterRAM, $_.DriverVersion, $_.PNPDeviceID, $_.Status)
            }
            """,
            timeout: shellInfoTimeout,
            probeName: "profile_gpu"
        )) ?? ""
        let nvidiaGPUs = parseWindowsNvidiaGPUs(nvidiaGPUOutput)
        let wmiGPUs = parseWindowsGPUs(gpuOutput).filter { device in
            guard !nvidiaGPUs.isEmpty else { return true }
            return device.kind != .nvidia
        }

        return HardwareProfile(
            hostname: systemInfo.hostname,
            osInfo: systemInfo.osInfo,
            architecture: "",
            kernelVersion: "",
            cpuModel: section(cpuSections, 0),
            cpuVendor: section(cpuSections, 1),
            cpuCores: Int(section(cpuSections, 2)) ?? 0,
            cpuThreads: Int(section(cpuSections, 3)) ?? systemInfo.cpuCores,
            memoryTotal: UInt64(memoryOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            gpus: nvidiaGPUs + wmiGPUs,
            collectedAt: Date()
        )
    }

    func collectStats(client: SSHClient, context: StatsCollectionContext) async throws -> ServerStats {
        var stats = ServerStats()
        let environment = await client.remoteEnvironment()
        let preferCMD = environment.shellProfile.family == .cmd

        if let cpuUsage = try? await collectCPUUsagePowerShell(client: client) {
            applyCPU(cpuUsage, to: &stats)
        } else if preferCMD {
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

            let netTx = network.tx
            stats.networkTxTotal = netTx

            let speeds = StatsParsingUtils.calculateNetworkSpeed(
                currentRx: netRx,
                currentTx: netTx,
                prevRx: prevRx,
                prevTx: prevTx,
                prevTimestamp: previousTimestamp,
                now: now
            )
            stats.networkRxSpeed = speeds.rxSpeed
            stats.networkTxSpeed = speeds.txSpeed

            context.updateNetwork(rx: stats.networkRxTotal, tx: netTx, timestamp: Date())
        }

        // Load average (Windows doesn't have this, approximate from CPU)
        stats.loadAverage = (stats.cpuUsage / 100, stats.cpuUsage / 100, stats.cpuUsage / 100)

        let processCollectionTimestamp = Date()
        if context.shouldCollectPeriodicProcesses(
            now: processCollectionTimestamp,
            minimumInterval: 5
        ) {
            var collectedProcesses: [ProcessInfo] = []
            if let processOutput = try? await executePowerShell(
                using: client,
                script: powerShellProcessScript(limit: periodicProcessLimit),
                timeout: topProcessesTimeout,
                probeName: "top_processes"
            ) {
                collectedProcesses = parseProcesses(processOutput)
            } else if preferCMD,
                      let processOutput = try? await executeCMD(
                        "wmic path Win32_PerfFormattedData_PerfProc_Process get IDProcess,Name,PercentProcessorTime,WorkingSet /format:csv",
                        using: client,
                        timeout: topProcessesTimeout
                      ) {
                let logicalProcessors: Int
                if stats.cpuCores > 0 {
                    logicalProcessors = stats.cpuCores
                } else {
                    logicalProcessors = (try? await getSystemInfo(client: client))?.cpuCores ?? 1
                }
                collectedProcesses = Array(parseWMICProcesses(
                    processOutput,
                    memoryTotal: stats.memoryTotal,
                    logicalProcessorCount: max(logicalProcessors, 1)
                ).prefix(periodicProcessLimit))
            }
            context.updatePeriodicProcesses(collectedProcesses, timestamp: processCollectionTimestamp)
        }
        stats.topProcesses = context.getPeriodicProcesses()

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

        stats.gpuSamples = await collectGPUSamplesIfNeeded(client: client, context: context)

        stats.timestamp = Date()
        return stats
    }

    func collectProcesses(client: SSHClient, context: StatsCollectionContext) async throws -> [ProcessInfo] {
        if let processOutput = try? await executePowerShell(
            using: client,
            script: powerShellProcessScript(limit: nil),
            timeout: topProcessesTimeout,
            probeName: "top_processes_full"
        ) {
            return parseProcesses(processOutput)
        }

        let memory = (try? await collectMemoryCMD(client: client)) ?? (total: 0, used: 0, free: 0)
        let processOutput = try await executeCMD(
            "wmic path Win32_PerfFormattedData_PerfProc_Process get IDProcess,Name,PercentProcessorTime,WorkingSet /format:csv",
            using: client,
            timeout: topProcessesTimeout
        )
        let logicalProcessors = (try? await getSystemInfo(client: client))?.cpuCores ?? 1
        return parseWMICProcesses(
            processOutput,
            memoryTotal: memory.total,
            logicalProcessorCount: max(logicalProcessors, 1)
        )
    }

    private func powerShellProcessScript(limit: Int?) -> String {
        let limitClause = limit.map { " | Select-Object -First \($0)" } ?? ""
        return """
        $os = Get-CimInstance Win32_OperatingSystem;
        $totalMemory = [double]$os.TotalVisibleMemorySize * 1024;
        $logicalProcessors = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors;
        if ($logicalProcessors -le 0) { $logicalProcessors = [Environment]::ProcessorCount };
        $logicalProcessors = [math]::Max($logicalProcessors, 1);
        Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
          Where-Object { $_.IDProcess -gt 0 -and $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
          Sort-Object PercentProcessorTime -Descending\(limitClause) |
          ForEach-Object {
            $cpu = [double]$_.PercentProcessorTime / $logicalProcessors;
            $memoryBytes = [double]$_.WorkingSet;
            $memoryPercent = if ($totalMemory -gt 0) { ($memoryBytes / $totalMemory) * 100 } else { 0 };
            $name = ([string]$_.Name).Replace('|', '/');
            Write-Output ('{0}|{1}|{2}|{3}|{4}' -f $_.IDProcess, $name, [math]::Round($cpu,1), [math]::Round($memoryPercent,1), [uint64]$memoryBytes)
          }
        """
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

    private func applyCPU(_ cpuUsage: WindowsCPUUsage, to stats: inout ServerStats) {
        let usage = min(max(cpuUsage.usagePercent, 0), 100)
        let user = min(max(cpuUsage.userPercent, 0), 100)
        let system = min(max(cpuUsage.systemPercent, 0), 100)

        stats.cpuUsage = usage
        if user > 0 || system > 0 {
            stats.cpuUser = user
            stats.cpuSystem = system
        } else {
            stats.cpuUser = usage * 0.7
            stats.cpuSystem = usage * 0.3
        }
        stats.cpuIdle = max(100 - usage, 0)
        stats.cpuIowait = 0
        stats.cpuSteal = 0
        stats.cpuCoreSamples = cpuUsage.coreSamples
        if !cpuUsage.coreSamples.isEmpty {
            stats.cpuCores = cpuUsage.coreSamples.count
        }
    }

    private func collectCPUUsagePowerShell(client: SSHClient) async throws -> WindowsCPUUsage {
        let output = try await executePowerShell(
            using: client,
            script: """
            $counters = @(
              '\\Processor(*)\\% Processor Time',
              '\\Processor(*)\\% User Time',
              '\\Processor(*)\\% Privileged Time'
            );
            $sample = Get-Counter -Counter $counters -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop;
            $rows = @{};
            $total = @{ Usage = 0.0; User = 0.0; System = 0.0 };
            foreach ($counterSample in $sample.CounterSamples) {
              $instance = [string]$counterSample.InstanceName;
              if ([string]::IsNullOrWhiteSpace($instance)) { continue };
              $path = ([string]$counterSample.Path).ToLowerInvariant();
              $metric = '';
              if ($path.Contains('% processor time')) { $metric = 'Usage' }
              elseif ($path.Contains('% user time')) { $metric = 'User' }
              elseif ($path.Contains('% privileged time')) { $metric = 'System' }
              else { continue };
              $value = [math]::Round([double]$counterSample.CookedValue, 1);
              if ($instance -eq '_total') {
                $total[$metric] = $value;
                continue;
              }
              if ($instance -notmatch '^\\d+$') { continue };
              if (-not $rows.ContainsKey($instance)) {
                $rows[$instance] = @{ Usage = 0.0; User = 0.0; System = 0.0 };
              }
              $rows[$instance][$metric] = $value;
            }
            Write-Output ('TOTAL|{0}|{1}|{2}' -f $total['Usage'], $total['User'], $total['System']);
            $rows.Keys | Sort-Object {[int]$_} | ForEach-Object {
              $row = $rows[$_];
              Write-Output ('CORE|{0}|{1}|{2}|{3}' -f $_, $row['Usage'], $row['User'], $row['System']);
            }
            """,
            timeout: cpuTimeout,
            probeName: "cpu_usage_per_core"
        )
        return parseWindowsCPUUsage(output)
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

    private func collectGPUSamplesIfNeeded(client: SSHClient, context: StatsCollectionContext) async -> [GPUSample] {
        guard context.shouldCollectGPU() else {
            return context.getGPUSamples()
        }

        let now = Date()

        if let output = try? await executePowerShell(
            using: client,
            script: nvidiaSMIQueryScript(fields: "index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,driver_version"),
            timeout: gpuTimeout,
            probeName: "gpu_nvidia_samples"
        ) {
            let samples = parseWindowsNvidiaSamples(output, timestamp: now)
            if !samples.isEmpty {
                context.updateGPUSamples(samples, timestamp: now)
                return samples
            }
        }

        if let output = try? await executePowerShell(
            using: client,
            script: windowsGPUCounterScript(),
            timeout: gpuTimeout,
            probeName: "gpu_perf_samples"
        ) {
            let samples = parseWindowsGPUCounterSamples(output, timestamp: now)
            if !samples.isEmpty {
                context.updateGPUSamples(samples, timestamp: now)
                return samples
            }
        }

        context.markGPUCollected(at: now)
        return context.getGPUSamples()
    }

    private func nvidiaSMIQueryScript(fields: String) -> String {
        """
        $nvidia = Get-Command nvidia-smi -ErrorAction SilentlyContinue;
        if ($nvidia) {
          & $nvidia.Source --query-gpu=\(fields) --format=csv,noheader,nounits 2>$null
        }
        """
    }

    private func windowsGPUCounterScript() -> String {
        """
        $rows = @{};
        function Ensure-Row([string]$phys) {
          if (-not $rows.ContainsKey($phys)) {
            $rows[$phys] = @{ Util = 0.0; Used = 0.0; Limit = 0.0 };
          }
        }
        $engineCounter = Get-Counter '\\GPU Engine(*)\\Utilization Percentage' -ErrorAction SilentlyContinue;
        if ($engineCounter) {
          foreach ($sample in $engineCounter.CounterSamples) {
            $instance = [string]$sample.InstanceName;
            if ($instance -match '_phys_(\\d+)') {
              $phys = $matches[1];
              Ensure-Row $phys;
              $rows[$phys]['Util'] = [double]$rows[$phys]['Util'] + [double]$sample.CookedValue;
            }
          }
        }
        $memoryUsage = Get-Counter '\\GPU Adapter Memory(*)\\Dedicated Usage' -ErrorAction SilentlyContinue;
        if ($memoryUsage) {
          foreach ($sample in $memoryUsage.CounterSamples) {
            $instance = [string]$sample.InstanceName;
            if ($instance -match '_phys_(\\d+)') {
              $phys = $matches[1];
              Ensure-Row $phys;
              $rows[$phys]['Used'] = [math]::Max([double]$rows[$phys]['Used'], [double]$sample.CookedValue);
            }
          }
        }
        $memoryLimit = Get-Counter '\\GPU Adapter Memory(*)\\Dedicated Limit' -ErrorAction SilentlyContinue;
        if ($memoryLimit) {
          foreach ($sample in $memoryLimit.CounterSamples) {
            $instance = [string]$sample.InstanceName;
            if ($instance -match '_phys_(\\d+)') {
              $phys = $matches[1];
              Ensure-Row $phys;
              $rows[$phys]['Limit'] = [math]::Max([double]$rows[$phys]['Limit'], [double]$sample.CookedValue);
            }
          }
        }
        $rows.Keys | Sort-Object {[int]$_} | ForEach-Object {
          $row = $rows[$_];
          Write-Output ('PERF|windows-phys-{0}|{1}|{2}|{3}' -f $_, [math]::Round([double]$row['Util'], 1), [uint64][math]::Max([double]$row['Used'], 0), [uint64][math]::Max([double]$row['Limit'], 0));
        }
        """
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

    func parseProcesses(_ output: String) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 4 else { continue }

            let pid = Int(parts[0]) ?? 0
            let name = parts[1]
            let cpu = parseWindowsDouble(parts[2]) ?? 0
            let mem = parseWindowsDouble(parts[3]) ?? 0
            let memoryBytes = parts.count > 4 ? UInt64(parts[4]) : nil

            processes.append(ProcessInfo(
                pid: pid,
                name: name,
                cpuPercent: min(max(cpu.isFinite ? cpu : 0, 0), 100),
                memoryPercent: min(max(mem.isFinite ? mem : 0, 0), 100),
                memoryBytes: memoryBytes
            ))
        }

        return processes
    }

    func parseVolumes(_ output: String) -> [VolumeInfo] {
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

    func parseWMICVolumes(_ output: String) -> [VolumeInfo] {
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

    func parseWMICProcesses(
        _ output: String,
        memoryTotal: UInt64,
        logicalProcessorCount: Int = 1
    ) -> [ProcessInfo] {
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

            let rawCPU = parseWindowsDouble(fields[3]) ?? 0
            let workingSet = UInt64(fields[4]) ?? 0
            let cpuPercent = min(max(rawCPU / Double(max(logicalProcessorCount, 1)), 0), 100)
            let memoryPercent = memoryTotal > 0 ? (Double(workingSet) / Double(memoryTotal) * 100) : 0

            processes.append(ProcessInfo(
                pid: pid,
                name: name,
                cpuPercent: cpuPercent,
                memoryPercent: memoryPercent,
                memoryBytes: workingSet
            ))
        }

        return processes
            .sorted { lhs, rhs in
                if lhs.cpuPercent == rhs.cpuPercent {
                    return lhs.memoryPercent > rhs.memoryPercent
                }
                return lhs.cpuPercent > rhs.cpuPercent
            }
            .map { $0 }
    }

    func parseWindowsGPUs(_ output: String) -> [GPUDevice] {
        var devices: [GPUDevice] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 1 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let vendor = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let driver = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let pnpDeviceID = parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let status = parts.count > 5 ? parts[5].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let lower = "\(name) \(vendor)".lowercased()
            let kind: GPUKind
            if lower.contains("nvidia") {
                kind = .nvidia
            } else if lower.contains("amd") || lower.contains("radeon") || lower.contains("advanced micro devices") {
                kind = .amd
            } else if lower.contains("intel") {
                kind = .intel
            } else {
                kind = .unknown
            }
            guard isPhysicalWindowsGPU(name: name, vendor: vendor, pnpDeviceID: pnpDeviceID, status: status, kind: kind) else {
                continue
            }
            let rawMemory = parts.count > 2 ? (UInt64(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) : 0
            let memory = normalizedWindowsAdapterRAM(rawMemory, kind: kind)

            devices.append(GPUDevice(
                id: "windows-phys-\(devices.count)",
                name: name,
                vendor: vendor,
                kind: kind,
                driverVersion: driver,
                memoryTotal: memory,
                source: .wmi
            ))
        }

        return devices
    }

    func parseWindowsNvidiaGPUs(_ output: String) -> [GPUDevice] {
        parseCSVRows(output).compactMap { fields in
            guard fields.count >= 9 else { return nil }
            let index = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !index.isEmpty, !name.isEmpty else { return nil }
            let memoryTotalMB = UInt64(fields[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return GPUDevice(
                id: "nvidia-\(index)",
                name: name,
                vendor: "NVIDIA",
                kind: .nvidia,
                driverVersion: fields[8].trimmingCharacters(in: .whitespacesAndNewlines),
                memoryTotal: memoryTotalMB * 1_048_576,
                source: .nvidiaSMI
            )
        }
    }

    func parseWindowsNvidiaSamples(_ output: String, timestamp: Date) -> [GPUSample] {
        parseCSVRows(output).compactMap { fields in
            guard fields.count >= 9 else { return nil }
            let index = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !index.isEmpty else { return nil }
            let utilization = parseWindowsDouble(fields[3])
            let memoryUsedMB = UInt64(fields[4].trimmingCharacters(in: .whitespacesAndNewlines))
            let memoryTotalMB = UInt64(fields[5].trimmingCharacters(in: .whitespacesAndNewlines))
            let temperature = parseWindowsDouble(fields[6])
            let power = parseWindowsDouble(fields[7])

            return GPUSample(
                deviceID: "nvidia-\(index)",
                utilizationPercent: utilization.map { min(max($0, 0), 100) },
                memoryUsed: memoryUsedMB.map { $0 * 1_048_576 },
                memoryTotal: memoryTotalMB.map { $0 * 1_048_576 },
                temperatureCelsius: temperature,
                powerWatts: power,
                processes: [],
                source: .nvidiaSMI,
                timestamp: timestamp
            )
        }
    }

    func parseWindowsGPUCounterSamples(_ output: String, timestamp: Date) -> [GPUSample] {
        output.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 5, parts[0] == "PERF" else { return nil }

            let deviceID = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let utilization = parseWindowsDouble(parts[2])
            let memoryUsed = UInt64(parts[3].trimmingCharacters(in: .whitespacesAndNewlines))
            let rawMemoryTotal = UInt64(parts[4].trimmingCharacters(in: .whitespacesAndNewlines))
            let memoryTotal = rawMemoryTotal.flatMap { $0 > 0 ? $0 : nil }
            guard utilization != nil || memoryUsed != nil || memoryTotal != nil else { return nil }

            return GPUSample(
                deviceID: deviceID,
                utilizationPercent: utilization.map { min(max($0, 0), 100) },
                memoryUsed: memoryUsed,
                memoryTotal: memoryTotal,
                temperatureCelsius: nil,
                powerWatts: nil,
                processes: [],
                source: .wmi,
                timestamp: timestamp
            )
        }
    }

    func parseWindowsCPUUsage(_ output: String) -> WindowsCPUUsage {
        var usage = 0.0
        var user = 0.0
        var system = 0.0
        var samples: [CPUCoreSample] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "|")

            if parts.count >= 4, parts[0] == "TOTAL" {
                usage = parseWindowsDouble(parts[1]) ?? 0
                user = parseWindowsDouble(parts[2]) ?? 0
                system = parseWindowsDouble(parts[3]) ?? 0
                continue
            }

            guard parts.count >= 5, parts[0] == "CORE" else { continue }
            let identifier = parts[1]
            let coreUsage = min(max(parseWindowsDouble(parts[2]) ?? 0, 0), 100)
            let coreUser = min(max(parseWindowsDouble(parts[3]) ?? 0, 0), 100)
            let coreSystem = min(max(parseWindowsDouble(parts[4]) ?? 0, 0), 100)
            let displayIndex = (Int(identifier) ?? samples.count) + 1
            samples.append(CPUCoreSample(
                identifier: "cpu\(identifier)",
                displayName: String(format: String(localized: "CPU %lld"), Int64(displayIndex)),
                usagePercent: coreUsage,
                userPercent: coreUser,
                systemPercent: coreSystem,
                iowaitPercent: 0,
                stealPercent: 0,
                idlePercent: max(100 - coreUsage, 0)
            ))
        }

        samples.sort { lhs, rhs in
            numericSuffix(lhs.identifier) < numericSuffix(rhs.identifier)
        }

        return WindowsCPUUsage(
            usagePercent: min(max(usage, 0), 100),
            userPercent: min(max(user, 0), 100),
            systemPercent: min(max(system, 0), 100),
            coreSamples: samples
        )
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

    private func parseWindowsDouble(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Double(trimmed) {
            return parsed
        }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
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
        return parseWindowsDouble(rawValue)
    }

    func parseNetstatInterfaceStats(_ output: String) -> (rx: UInt64, tx: UInt64) {
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

    private func parseCSVRows(_ output: String) -> [[String]] {
        output.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return parseCSVLine(trimmed).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private func isPhysicalWindowsGPU(
        name: String,
        vendor: String,
        pnpDeviceID: String,
        status: String,
        kind: GPUKind
    ) -> Bool {
        if !status.isEmpty, status.caseInsensitiveCompare("OK") != .orderedSame {
            return false
        }

        let haystack = "\(name) \(vendor) \(pnpDeviceID)".lowercased()
        let virtualMarkers = [
            "virtual",
            "remote display",
            "indirect display",
            "mirage",
            "mirror driver",
            "microsoft basic render",
            "microsoft basic display",
            "vmware",
            "virtualbox",
            "hyper-v",
            "parallels",
            "citrix",
            "spice",
            "qxl",
            "sudomaker",
            "gameviewer"
        ]
        if virtualMarkers.contains(where: { haystack.contains($0) }) {
            return false
        }

        if kind != .unknown {
            return true
        }

        return haystack.contains("pci\\ven_")
    }

    private func normalizedWindowsAdapterRAM(_ rawValue: UInt64, kind: GPUKind) -> UInt64 {
        guard rawValue > 0 else { return 0 }

        // Win32_VideoController.AdapterRAM is commonly capped/truncated around
        // 4 GB for modern discrete GPUs. Prefer live NVIDIA/perf samples for
        // real VRAM and avoid surfacing a precise but wrong profile value.
        if (kind == .nvidia || kind == .amd) && rawValue >= 3_750_000_000 {
            return 0
        }

        return rawValue
    }

    private func numericSuffix(_ identifier: String) -> Int {
        let digits = identifier.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits)) ?? Int.max
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

    private func section(_ sections: [String], _ index: Int) -> String {
        guard sections.indices.contains(index) else { return "" }
        return sections[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct WindowsCPUUsage {
    let usagePercent: Double
    let userPercent: Double
    let systemPercent: Double
    let coreSamples: [CPUCoreSample]
}
