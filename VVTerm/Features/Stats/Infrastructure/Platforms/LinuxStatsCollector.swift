import Foundation

// MARK: - Linux Stats Collector

/// Stats collector for Linux systems using /proc filesystem
struct LinuxStatsCollector: PlatformStatsCollector {
    private let bytesPerKiB: UInt64 = 1_024
    private let bytesPerMiB: UInt64 = 1_048_576
    private let bytesPerGiB: UInt64 = 1_073_741_824
    private let bytesPerTiB: UInt64 = 1_099_511_627_776
    private let bytesPerPiB: UInt64 = 1_125_899_906_842_624
    private let periodicProcessLimit = 24

    func getSystemInfo(client: SSHClient) async throws -> (hostname: String, osInfo: String, cpuCores: Int) {
        let cmd = "uname -srm; echo '---SEP---'; hostname; echo '---SEP---'; nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1"
        let output = try await client.execute(cmd)
        let parts = output.components(separatedBy: "---SEP---")

        let osInfo = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let hostname = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let cpuCores = parts.count > 2 ? Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1 : 1

        return (hostname, osInfo, cpuCores)
    }

    func collectProfile(client: SSHClient) async throws -> HardwareProfile {
        let profileScript = """
            LC_ALL=C LANG=C; \
            hostname 2>/dev/null; echo '---SEP---'; \
            uname -srm 2>/dev/null; echo '---SEP---'; \
            uname -m 2>/dev/null; echo '---SEP---'; \
            uname -r 2>/dev/null; echo '---SEP---'; \
            (lscpu 2>/dev/null || cat /proc/cpuinfo 2>/dev/null); echo '---SEP---'; \
            grep -m1 '^MemTotal:' /proc/meminfo 2>/dev/null; echo '---SEP---'; \
            (nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader,nounits 2>/dev/null || true); echo '---SEP---'; \
            (lspci -mm 2>/dev/null | grep -Ei 'VGA|3D|Display' || true)
            """
        let cmd = RemoteTerminalBootstrap.wrapPOSIXShellCommand(profileScript)
        let output = try await client.execute(cmd, timeout: .seconds(5))
        let sections = output.components(separatedBy: "---SEP---")
        let hostname = sections[safe: 0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let osInfo = sections[safe: 1]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let architecture = sections[safe: 2]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kernelVersion = sections[safe: 3]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cpu = parseCPUProfile(sections[safe: 4] ?? "")
        let memoryTotal = parseMemTotal(sections[safe: 5] ?? "")
        let nvidiaGPUs = parseNvidiaProfile(sections[safe: 6] ?? "")
        let pciGPUs = parsePCIGPUs(sections[safe: 7] ?? "", existingIDs: Set(nvidiaGPUs.map(\.id)))

        return HardwareProfile(
            hostname: hostname,
            osInfo: osInfo,
            architecture: architecture,
            kernelVersion: kernelVersion,
            cpuModel: cpu.model,
            cpuVendor: cpu.vendor,
            cpuCores: cpu.cores,
            cpuThreads: cpu.threads,
            memoryTotal: memoryTotal,
            gpus: nvidiaGPUs + pciGPUs,
            collectedAt: Date()
        )
    }

    func collectStats(client: SSHClient, context: StatsCollectionContext) async throws -> ServerStats {
        var stats = ServerStats()

        // Batch multiple /proc reads in one command
        let batchCmd = """
            grep '^cpu' /proc/stat; echo '---SEP---'; \
            cat /proc/meminfo; echo '---SEP---'; \
            cat /proc/net/dev; echo '---SEP---'; \
            cat /proc/loadavg; echo '---SEP---'; \
            cat /proc/uptime; echo '---SEP---'; \
            ls -d /proc/[0-9]* 2>/dev/null | wc -l
            """
        let batchOutput = try await client.execute(batchCmd)
        let sections = batchOutput.components(separatedBy: "---SEP---")

        var missingCpu = true
        var missingMem = true
        var missingNet = true
        var missingLoad = true
        var missingUptime = true
        var missingProcCount = true

        // CPU stats
        if sections.count > 0 {
            if isProcStatValid(sections[0]) {
                let prevCpu = context.getCpuValues()
                let cpuResult = parseProcStat(sections[0], prevValues: prevCpu)
                stats.cpuUser = cpuResult.result.user
                stats.cpuSystem = cpuResult.result.system
                stats.cpuIowait = cpuResult.result.iowait
                stats.cpuSteal = cpuResult.result.steal
                stats.cpuIdle = cpuResult.result.idle
                stats.cpuUsage = cpuResult.result.total
                context.updateCpuValues(cpuResult.newValues)
                let coreResult = parseProcStatCores(sections[0], prevValues: context.getCpuCoreValues())
                stats.cpuCoreSamples = coreResult.samples
                stats.cpuCores = coreResult.samples.count
                context.updateCpuCoreValues(coreResult.newValues)
                missingCpu = false
            }
        }

        // Memory stats
        if sections.count > 1 {
            if isProcMeminfoValid(sections[1]) {
                let mem = parseProcMeminfo(sections[1])
                stats.memoryTotal = mem.total
                stats.memoryUsed = mem.used
                stats.memoryFree = mem.free
                stats.memoryCached = mem.cached
                stats.memoryBuffers = mem.buffers
                missingMem = false
            }
        }

        // Network stats
        if sections.count > 2 {
            if isProcNetDevValid(sections[2]) {
                let (netRx, netTx) = parseProcNetDev(sections[2])
                let now = Date()
                let (prevRx, prevTx, prevTime) = context.getNetworkPrev()

                let speeds = StatsParsingUtils.calculateNetworkSpeed(
                    currentRx: netRx, currentTx: netTx,
                    prevRx: prevRx, prevTx: prevTx,
                    prevTimestamp: prevTime, now: now
                )
                stats.networkRxSpeed = speeds.rxSpeed
                stats.networkTxSpeed = speeds.txSpeed
                stats.networkRxTotal = netRx
                stats.networkTxTotal = netTx

                context.updateNetwork(rx: netRx, tx: netTx, timestamp: now)
                missingNet = false
            }
        }

        // Load average
        if sections.count > 3 {
            let load = StatsParsingUtils.parseLoadAverage(sections[3])
            if load.0 > 0 || load.1 > 0 || load.2 > 0 {
                stats.loadAverage = load
                missingLoad = false
            } else if !sections[3].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stats.loadAverage = load
                missingLoad = false
            }
        }

        // Uptime
        if sections.count > 4 {
            let uptimeStr = sections[4].trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first ?? "0"
            if let uptime = TimeInterval(uptimeStr), uptime > 0 {
                stats.uptime = uptime
                missingUptime = false
            }
        }

        // Process count
        if sections.count > 5 {
            if let count = Int(sections[5].trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 {
                stats.processCount = count
                missingProcCount = false
            }
        }

        let needsFallback = missingCpu || missingMem || missingNet || missingLoad || missingUptime || missingProcCount
        var fallbackSections: [String] = []

        if needsFallback {
            let fallbackCmd = """
                export LC_ALL=C LANG=C; \
                top -bn1 2>/dev/null | head -20; echo '---SEP---'; \
                free -b 2>/dev/null; echo '---SEP---'; \
                uptime 2>/dev/null; echo '---SEP---'; \
                for i in /sys/class/net/*; do \
                  n=$(basename "$i"); \
                  [ "$n" = "lo" ] && continue; \
                  rx=$(cat "$i/statistics/rx_bytes" 2>/dev/null); \
                  tx=$(cat "$i/statistics/tx_bytes" 2>/dev/null); \
                  [ -n "$rx" ] && [ -n "$tx" ] && echo "$n $rx $tx"; \
                done; echo '---SEP---'; \
                (ip -s link 2>/dev/null || ifconfig -a 2>/dev/null); echo '---SEP---'; \
                (ps -e 2>/dev/null | wc -l)
                """
            let fallbackOutput = try await client.execute(RemoteTerminalBootstrap.wrapPOSIXShellCommand(fallbackCmd))
            fallbackSections = fallbackOutput.components(separatedBy: "---SEP---")

            let topOutput = fallbackSections.count > 0 ? fallbackSections[0] : ""
            let freeOutput = fallbackSections.count > 1 ? fallbackSections[1] : ""
            let uptimeOutput = fallbackSections.count > 2 ? fallbackSections[2] : ""
            let sysClassNetOutput = fallbackSections.count > 3 ? fallbackSections[3] : ""
            let ipOrIfconfigOutput = fallbackSections.count > 4 ? fallbackSections[4] : ""
            let procCountOutput = fallbackSections.count > 5 ? fallbackSections[5] : ""

            if missingCpu, let cpu = parseTopCpu(topOutput) {
                stats.cpuUser = cpu.user
                stats.cpuSystem = cpu.system
                stats.cpuIowait = cpu.iowait
                stats.cpuSteal = cpu.steal
                stats.cpuIdle = cpu.idle
                stats.cpuUsage = cpu.total
            }

            if missingMem {
                if let mem = parseFreeMemory(freeOutput) ?? parseTopMemory(topOutput) {
                    stats.memoryTotal = mem.total
                    stats.memoryUsed = mem.used
                    stats.memoryFree = mem.free
                    stats.memoryCached = mem.cached
                    stats.memoryBuffers = mem.buffers
                }
            }

            if missingLoad {
                let load = parseUptimeLoadAverage(uptimeOutput)
                if load.0 > 0 || load.1 > 0 || load.2 > 0 {
                    stats.loadAverage = load
                }
            }

            if missingUptime {
                let uptime = parseUptimeSeconds(uptimeOutput)
                if uptime > 0 {
                    stats.uptime = uptime
                }
            }

            if missingNet {
                let netTotals = parseSysClassNet(sysClassNetOutput) ?? parseIpLinkOrIfconfig(ipOrIfconfigOutput)
                if let netTotals {
                    let now = Date()
                    let (prevRx, prevTx, prevTime) = context.getNetworkPrev()
                    let speeds = StatsParsingUtils.calculateNetworkSpeed(
                        currentRx: netTotals.rx, currentTx: netTotals.tx,
                        prevRx: prevRx, prevTx: prevTx,
                        prevTimestamp: prevTime, now: now
                    )
                    stats.networkRxSpeed = speeds.rxSpeed
                    stats.networkTxSpeed = speeds.txSpeed
                    stats.networkRxTotal = netTotals.rx
                    stats.networkTxTotal = netTotals.tx
                    context.updateNetwork(rx: netTotals.rx, tx: netTotals.tx, timestamp: now)
                }
            }

            if missingProcCount, let count = Int(procCountOutput.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 {
                stats.processCount = count
            }
        }

        // Volumes (separate command for reliability)
        let dfOutput = try await client.execute(
            RemoteTerminalBootstrap.wrapPOSIXShellCommand("LC_ALL=C LANG=C df -BM -P -x tmpfs -x devtmpfs -x squashfs 2>/dev/null")
        )
        stats.volumes = parseDfVolumes(dfOutput)

        // Process CPU is calculated from /proc deltas so it reflects this sampling
        // interval and is normalized to total machine capacity on every platform.
        if let collection = try? await UnixProcessTelemetry.collect(
            client: client,
            context: context,
            platform: .linux,
            logicalProcessorCount: max(stats.cpuCores, 1),
            memoryTotal: stats.memoryTotal,
            limit: periodicProcessLimit
        ) {
            stats.topProcesses = collection.processes
            stats.processCount = max(stats.processCount, collection.totalCount)
        }

        // Process count fallback if still missing
        if stats.processCount == 0 {
            let procCount = try await client.execute("ps -e 2>/dev/null | wc -l")
            stats.processCount = Int(procCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        stats.gpuSamples = await collectGPUSamplesIfNeeded(client: client, context: context)
        stats.timestamp = Date()
        return stats
    }

    func collectProcesses(client: SSHClient, context: StatsCollectionContext) async throws -> [ProcessInfo] {
        let systemInfo = try await getSystemInfo(client: client)
        let memoryOutput = try await client.execute("cat /proc/meminfo 2>/dev/null")
        let memory = parseProcMeminfo(memoryOutput)
        return try await UnixProcessTelemetry.collect(
            client: client,
            context: context,
            platform: .linux,
            logicalProcessorCount: max(systemInfo.cpuCores, 1),
            memoryTotal: memory.total,
            limit: nil
        ).processes
    }

    // MARK: - Parsers

    private func isProcStatValid(_ output: String) -> Bool {
        let firstLine = output.components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("cpu ") } ?? output
        let components = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        return components.count >= 8 && components.first == "cpu"
    }

    private func isProcMeminfoValid(_ output: String) -> Bool {
        output.contains("MemTotal:")
    }

    private func isProcNetDevValid(_ output: String) -> Bool {
        output.contains(":") && output.contains("bytes")
    }

    func parseProcStat(_ output: String, prevValues: LinuxCpuValues?) -> (result: CpuResult, newValues: LinuxCpuValues) {
        let firstLine = output.components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("cpu ") } ?? output
        guard let current = parseCpuValues(firstLine) else {
            let zeroValues = LinuxCpuValues(user: 0, nice: 0, system: 0, idle: 0, iowait: 0, irq: 0, softirq: 0, steal: 0)
            return (CpuResult(total: 0, user: 0, system: 0, iowait: 0, steal: 0, idle: 100), zeroValues)
        }

        return (calculateCpuResult(current: current, previous: prevValues), current)
    }

    func parseProcStatCores(
        _ output: String,
        prevValues: [String: LinuxCpuValues]
    ) -> (samples: [CPUCoreSample], newValues: [String: LinuxCpuValues]) {
        var samples: [CPUCoreSample] = []
        var newValues: [String: LinuxCpuValues] = [:]

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard let identifier = parts.first,
                  identifier.hasPrefix("cpu"),
                  identifier != "cpu",
                  let values = parseCpuValues(trimmed) else {
                continue
            }

            let result = calculateCpuResult(current: values, previous: prevValues[identifier])
            let indexText = String(identifier.dropFirst(3))
            let displayIndex = (Int(indexText) ?? samples.count) + 1
            samples.append(CPUCoreSample(
                identifier: identifier,
                displayName: String(format: String(localized: "CPU %lld"), Int64(displayIndex)),
                usagePercent: result.total,
                userPercent: result.user,
                systemPercent: result.system,
                iowaitPercent: result.iowait,
                stealPercent: result.steal,
                idlePercent: result.idle
            ))
            newValues[identifier] = values
        }

        samples.sort { lhs, rhs in
            numericCPUIndex(lhs.identifier) < numericCPUIndex(rhs.identifier)
        }

        return (samples, newValues)
    }

    private func parseCpuValues(_ line: String) -> LinuxCpuValues? {
        let components = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard components.count >= 8 else {
            return nil
        }

        let user = UInt64(components[1]) ?? 0
        let nice = UInt64(components[2]) ?? 0
        let system = UInt64(components[3]) ?? 0
        let idle = UInt64(components[4]) ?? 0
        let iowait = UInt64(components[5]) ?? 0
        let irq = UInt64(components[6]) ?? 0
        let softirq = UInt64(components[7]) ?? 0
        let steal = components.count > 8 ? (UInt64(components[8]) ?? 0) : 0

        return LinuxCpuValues(
            user: user, nice: nice, system: system, idle: idle,
            iowait: iowait, irq: irq, softirq: softirq, steal: steal
        )
    }

    private func calculateCpuResult(current: LinuxCpuValues, previous: LinuxCpuValues?) -> CpuResult {
        if let prev = previous {
            let dUser = Double(clampedAdd(clampedSubtract(current.user, prev.user), clampedSubtract(current.nice, prev.nice)))
            let dSystem = Double(
                clampedAdd(
                    clampedAdd(clampedSubtract(current.system, prev.system), clampedSubtract(current.irq, prev.irq)),
                    clampedSubtract(current.softirq, prev.softirq)
                )
            )
            let dIdle = Double(clampedSubtract(current.idle, prev.idle))
            let dIowait = Double(clampedSubtract(current.iowait, prev.iowait))
            let dSteal = Double(clampedSubtract(current.steal, prev.steal))

            let total = dUser + dSystem + dIdle + dIowait + dSteal
            if total > 0 {
                return CpuResult(
                    total: (dUser + dSystem + dIowait + dSteal) / total * 100,
                    user: dUser / total * 100,
                    system: dSystem / total * 100,
                    iowait: dIowait / total * 100,
                    steal: dSteal / total * 100,
                    idle: dIdle / total * 100
                )
            }
        }

        return CpuResult(total: 0, user: 0, system: 0, iowait: 0, steal: 0, idle: 100)
    }

    private func numericCPUIndex(_ identifier: String) -> Int {
        Int(identifier.dropFirst(3)) ?? Int.max
    }

    private func parseTopCpu(_ output: String) -> CpuResult? {
        let line = output.components(separatedBy: .newlines).first { line in
            line.lowercased().contains("cpu(s)") || line.lowercased().contains("%cpu")
        }
        guard let cpuLine = line else { return nil }

        func extract(_ token: String) -> Double? {
            let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*"# + token
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(cpuLine.startIndex..<cpuLine.endIndex, in: cpuLine)
            guard let match = regex.firstMatch(in: cpuLine, options: [], range: range),
                  let valueRange = Range(match.range(at: 1), in: cpuLine) else { return nil }
            return Double(cpuLine[valueRange])
        }

        let user = extract("us") ?? 0
        let system = extract("sy") ?? 0
        let idle = extract("id") ?? max(0, 100 - user - system)
        let iowait = extract("wa") ?? 0
        let steal = extract("st") ?? 0
        let total = max(0, min(100, user + system + iowait + steal))

        return CpuResult(total: total, user: user, system: system, iowait: iowait, steal: steal, idle: idle)
    }

    private func parseCPUProfile(_ output: String) -> (model: String, vendor: String, cores: Int, threads: Int) {
        var model = ""
        var vendor = ""
        var cores = 0
        var threads = 0
        var coresPerSocket = 0
        var sockets = 0

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Model name:") {
                model = valueAfterColon(trimmed)
            } else if trimmed.hasPrefix("Vendor ID:") {
                vendor = valueAfterColon(trimmed)
            } else if trimmed.hasPrefix("CPU(s):"), threads == 0 {
                threads = Int(valueAfterColon(trimmed)) ?? 0
            } else if trimmed.hasPrefix("Core(s) per socket:") {
                coresPerSocket = Int(valueAfterColon(trimmed)) ?? 0
            } else if trimmed.hasPrefix("Socket(s):") {
                sockets = Int(valueAfterColon(trimmed)) ?? 0
            } else if trimmed.hasPrefix("model name"), model.isEmpty {
                model = valueAfterColon(trimmed)
            } else if trimmed.hasPrefix("vendor_id"), vendor.isEmpty {
                vendor = valueAfterColon(trimmed)
            } else if trimmed.hasPrefix("processor") {
                threads += 1
            }
        }

        if coresPerSocket > 0 && sockets > 0 {
            cores = coresPerSocket * sockets
        } else {
            cores = threads
        }

        return (model, vendor, max(cores, 0), max(threads, cores))
    }

    private func parseMemTotal(_ output: String) -> UInt64 {
        let parts = output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2,
              let kib = UInt64(parts[1]) else {
            return 0
        }
        return bytesFromKiB(kib) ?? 0
    }

    private func parseNvidiaProfile(_ output: String) -> [GPUDevice] {
        output
            .components(separatedBy: .newlines)
            .compactMap { line -> GPUDevice? in
                let parts = line.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard parts.count >= 4,
                      !parts[0].isEmpty else {
                    return nil
                }

                let memoryMiB = UInt64(parts[3]) ?? 0
                return GPUDevice(
                    id: "nvidia-\(parts[0])",
                    name: parts[1],
                    vendor: "NVIDIA",
                    kind: .nvidia,
                    driverVersion: parts[2],
                    memoryTotal: multiplyBytes(memoryMiB, by: bytesPerMiB) ?? 0,
                    source: .nvidiaSMI
                )
            }
    }

    private func parsePCIGPUs(_ output: String, existingIDs: Set<String>) -> [GPUDevice] {
        var devices: [GPUDevice] = []
        for (index, line) in output.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            let kind: GPUKind
            let vendor: String
            if lower.contains("nvidia") {
                kind = .nvidia
                vendor = "NVIDIA"
            } else if lower.contains("amd") || lower.contains("advanced micro devices") || lower.contains("ati") {
                kind = .amd
                vendor = "AMD"
            } else if lower.contains("intel") {
                kind = .intel
                vendor = "Intel"
            } else {
                kind = .unknown
                vendor = ""
            }

            if kind == .nvidia, existingIDs.contains(where: { $0.hasPrefix("nvidia-") }) {
                continue
            }

            let id = "pci-\(index)"
            guard !existingIDs.contains(id) else { continue }
            devices.append(GPUDevice(
                id: id,
                name: parsePCIDeviceName(trimmed, vendor: vendor),
                vendor: vendor,
                kind: kind,
                driverVersion: "",
                memoryTotal: 0,
                source: .unknown
            ))
        }
        return devices
    }

    private func parsePCIDeviceName(_ line: String, vendor: String) -> String {
        let quotedParts = line.components(separatedBy: "\"").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if quotedParts.count >= 4 {
            return quotedParts[3].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if quotedParts.count >= 2 {
            return quotedParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return vendor.isEmpty ? line : line.replacingOccurrences(of: vendor, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func collectGPUSamplesIfNeeded(client: SSHClient, context: StatsCollectionContext) async -> [GPUSample] {
        guard context.shouldCollectGPU() else {
            return context.getGPUSamples()
        }

        let now = Date()
        let output = (try? await client.execute(
            "nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null || true",
            timeout: .seconds(4)
        )) ?? ""
        let samples = parseNvidiaSamples(output, timestamp: now)
        guard !samples.isEmpty else {
            context.markGPUCollected(at: now)
            return context.getGPUSamples()
        }

        context.updateGPUSamples(samples, timestamp: now)
        return samples
    }

    func parseNvidiaSamples(_ output: String, timestamp: Date) -> [GPUSample] {
        output
            .components(separatedBy: .newlines)
            .compactMap { line -> GPUSample? in
                let parts = line.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard parts.count >= 6,
                      !parts[0].isEmpty else {
                    return nil
                }

                let memoryUsedMiB = UInt64(parts[2])
                let memoryTotalMiB = UInt64(parts[3])
                return GPUSample(
                    deviceID: "nvidia-\(parts[0])",
                    utilizationPercent: Double(parts[1]),
                    memoryUsed: memoryUsedMiB.flatMap { multiplyBytes($0, by: bytesPerMiB) },
                    memoryTotal: memoryTotalMiB.flatMap { multiplyBytes($0, by: bytesPerMiB) },
                    temperatureCelsius: Double(parts[4]),
                    powerWatts: parseOptionalDouble(parts[5]),
                    processes: [],
                    source: .nvidiaSMI,
                    timestamp: timestamp
                )
            }
    }

    private func parseOptionalDouble(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "[Not Supported]",
              trimmed != "N/A" else {
            return nil
        }
        return Double(trimmed)
    }

    private func valueAfterColon(_ line: String) -> String {
        line.components(separatedBy: ":").dropFirst().joined(separator: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parseProcMeminfo(_ output: String) -> (total: UInt64, used: UInt64, free: UInt64, cached: UInt64, buffers: UInt64) {
        var total: UInt64 = 0
        var free: UInt64 = 0
        var available: UInt64 = 0
        var buffers: UInt64 = 0
        var cached: UInt64 = 0
        var sReclaimable: UInt64 = 0
        var shmem: UInt64 = 0

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }

            let valueStr = parts[1].components(separatedBy: .whitespaces).first ?? "0"
            let value = UInt64(valueStr) ?? 0

            switch parts[0] {
            case "MemTotal": total = bytesFromKiB(value) ?? 0
            case "MemFree": free = bytesFromKiB(value) ?? 0
            case "MemAvailable": available = bytesFromKiB(value) ?? 0
            case "Buffers": buffers = bytesFromKiB(value) ?? 0
            case "Cached": cached = bytesFromKiB(value) ?? 0
            case "SReclaimable": sReclaimable = bytesFromKiB(value) ?? 0
            case "Shmem": shmem = bytesFromKiB(value) ?? 0
            default: break
            }
        }

        let actualCached = clampedAdd(cached, sReclaimable)
        let used: UInt64
        if available > 0 {
            used = clampedSubtract(total, available)
        } else {
            // MemAvailable was added after the original /proc/meminfo fields and
            // can also be hidden by restricted proc mounts. Match free(1)'s
            // fallback instead of treating the whole machine as used.
            let reclaimable = clampedAdd(clampedAdd(free, buffers), actualCached)
            used = min(clampedAdd(clampedSubtract(total, reclaimable), shmem), total)
        }
        return (total, used, free, actualCached, buffers)
    }

    private func parseFreeMemory(_ output: String) -> (total: UInt64, used: UInt64, free: UInt64, cached: UInt64, buffers: UInt64)? {
        let lines = output.components(separatedBy: .newlines)
        guard let memLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Mem:") }) else { return nil }
        let parts = memLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 4 else { return nil }

        let total = UInt64(parts[1]) ?? 0
        let used = UInt64(parts[2]) ?? 0
        let free = UInt64(parts[3]) ?? 0
        let cached = parts.count > 5 ? (UInt64(parts[5]) ?? 0) : 0

        return (total, used, free, cached, 0)
    }

    private func parseTopMemory(_ output: String) -> (total: UInt64, used: UInt64, free: UInt64, cached: UInt64, buffers: UInt64)? {
        let line = output.components(separatedBy: .newlines).first { line in
            line.lowercased().contains("mem") && line.contains("total")
        }
        guard let memLine = line else { return nil }

        func extract(_ token: String) -> Double? {
            let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*"# + token
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(memLine.startIndex..<memLine.endIndex, in: memLine)
            guard let match = regex.firstMatch(in: memLine, options: [], range: range),
                  let valueRange = Range(match.range(at: 1), in: memLine) else { return nil }
            return Double(memLine[valueRange])
        }

        let totalValue = extract("total") ?? 0
        let freeValue = extract("free") ?? 0
        let usedValue = extract("used") ?? 0
        let cachedValue = extract("buff/cache") ?? 0

        let unit: Double
        if memLine.lowercased().contains("gib") {
            unit = 1_073_741_824
        } else if memLine.lowercased().contains("mib") {
            unit = 1_048_576
        } else if memLine.lowercased().contains("kib") {
            unit = 1024
        } else {
            unit = 1_048_576
        }

        let total = UInt64(totalValue * unit)
        let free = UInt64(freeValue * unit)
        let used = UInt64(usedValue * unit)
        let cached = UInt64(cachedValue * unit)

        return (total, used, free, cached, 0)
    }

    private func parseUptimeLoadAverage(_ output: String) -> (Double, Double, Double) {
        let lower = output.lowercased()
        if let range = lower.range(of: "load average:") {
            let suffix = output[range.upperBound...]
            let cleaned = String(suffix).replacingOccurrences(of: ",", with: " ")
            return StatsParsingUtils.parseLoadAverage(cleaned)
        }
        if let range = lower.range(of: "load averages:") {
            let suffix = output[range.upperBound...]
            let cleaned = String(suffix).replacingOccurrences(of: ",", with: " ")
            return StatsParsingUtils.parseLoadAverage(cleaned)
        }
        return (0, 0, 0)
    }

    private func parseUptimeSeconds(_ output: String) -> TimeInterval {
        guard let range = output.lowercased().range(of: " up ") else { return 0 }
        let suffix = output[range.upperBound...]
        let parts = suffix.components(separatedBy: ",")

        var totalSeconds: TimeInterval = 0
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("day") {
                let dayValue = trimmed.components(separatedBy: .whitespaces).first ?? "0"
                totalSeconds += (Double(dayValue) ?? 0) * 86400
            } else if trimmed.contains("min") {
                let minValue = trimmed.components(separatedBy: .whitespaces).first ?? "0"
                totalSeconds += (Double(minValue) ?? 0) * 60
            } else if trimmed.contains(":") {
                let timeParts = trimmed.components(separatedBy: ":")
                if timeParts.count == 2 {
                    let hours = Double(timeParts[0].trimmingCharacters(in: .whitespaces)) ?? 0
                    let minutes = Double(timeParts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    totalSeconds += hours * 3600 + minutes * 60
                }
            }
        }

        return totalSeconds
    }

    private func parseProcNetDev(_ output: String) -> (rx: UInt64, tx: UInt64) {
        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0

        for line in output.components(separatedBy: .newlines) {
            guard line.contains(":") && !line.contains("lo:") else { continue }

            let parts = line.components(separatedBy: ":").last?
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty } ?? []

            guard parts.count >= 9 else { continue }

            totalRx = clampedAdd(totalRx, UInt64(parts[0]) ?? 0)
            totalTx = clampedAdd(totalTx, UInt64(parts[8]) ?? 0)
        }

        return (totalRx, totalTx)
    }

    private func parseSysClassNet(_ output: String) -> (rx: UInt64, tx: UInt64)? {
        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0
        var found = false

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 3 else { continue }
            let rx = UInt64(parts[1]) ?? 0
            let tx = UInt64(parts[2]) ?? 0
            totalRx = clampedAdd(totalRx, rx)
            totalTx = clampedAdd(totalTx, tx)
            found = true
        }

        return found ? (totalRx, totalTx) : nil
    }

    private func parseIpLinkOrIfconfig(_ output: String) -> (rx: UInt64, tx: UInt64)? {
        let lines = output.components(separatedBy: .newlines)

        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0
        var currentIface: String?
        var expectRx = false
        var expectTx = false
        var found = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let ifaceMatch = trimmed.range(of: #"^\d+:\s*([^:]+):"#, options: .regularExpression) {
                let start = trimmed[ifaceMatch].split(separator: " ").dropFirst().first ?? ""
                currentIface = String(start).replacingOccurrences(of: ":", with: "")
                continue
            }

            if trimmed.hasPrefix("RX:") {
                expectRx = true
                continue
            }
            if trimmed.hasPrefix("TX:") {
                expectTx = true
                continue
            }

            if expectRx {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let iface = currentIface, iface != "lo", parts.count > 0, let rx = UInt64(parts[0]) {
                    totalRx = clampedAdd(totalRx, rx)
                    found = true
                }
                expectRx = false
                continue
            }

            if expectTx {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let iface = currentIface, iface != "lo", parts.count > 0, let tx = UInt64(parts[0]) {
                    totalTx = clampedAdd(totalTx, tx)
                    found = true
                }
                expectTx = false
                continue
            }
        }

        if found {
            return (totalRx, totalTx)
        }

        let rxRegex = try? NSRegularExpression(pattern: #"RX.*bytes\s+([0-9]+)"#, options: [.caseInsensitive])
        let txRegex = try? NSRegularExpression(pattern: #"TX.*bytes\s+([0-9]+)"#, options: [.caseInsensitive])

        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = rxRegex?.firstMatch(in: line, options: [], range: range),
               let valueRange = Range(match.range(at: 1), in: line),
               let rx = UInt64(line[valueRange]) {
                totalRx = clampedAdd(totalRx, rx)
                found = true
            }
            if let match = txRegex?.firstMatch(in: line, options: [], range: range),
               let valueRange = Range(match.range(at: 1), in: line),
               let tx = UInt64(line[valueRange]) {
                totalTx = clampedAdd(totalTx, tx)
                found = true
            }
        }

        return found ? (totalRx, totalTx) : nil
    }

    func parseDfVolumes(_ output: String) -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let defaultUnit = lines.first.flatMap(dfUnitMultiplier)
        let volumeLines = defaultUnit == nil ? lines : Array(lines.dropFirst())

        for line in volumeLines {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 6 else { continue }

            let mountPoint = parts[5...].joined(separator: " ")
            guard
                let totalBytes = parseDfByteCount(parts[1], defaultUnit: defaultUnit),
                let usedBytes = parseDfByteCount(parts[2], defaultUnit: defaultUnit)
            else { continue }
            if totalBytes < 100 * bytesPerMiB { continue }

            volumes.append(VolumeInfo(
                mountPoint: mountPoint,
                used: usedBytes,
                total: totalBytes
            ))
        }

        return volumes
    }

    func parsePs(_ output: String) -> [ProcessInfo] {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let firstLine = lines.first else { return [] }

        if firstLine.lowercased().hasPrefix("user ") {
            return parseAuxProcesses(lines)
        }

        return parseProcessTable(lines)
    }

    private func parseProcessTable(_ lines: [String]) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []

        for line in lines {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 5 else { continue }

            guard let pid = Int(parts[0]) else { continue }
            let user = parts[1]
            let cpu = Double(parts[2]) ?? 0
            let mem = Double(parts[3]) ?? 0
            let name = parts[4]
            let command = parts.count > 5 ? parts.dropFirst(5).joined(separator: " ") : name

            processes.append(ProcessInfo(
                pid: pid,
                name: name,
                cpuPercent: cpu,
                memoryPercent: mem,
                user: user,
                command: command
            ))
        }

        return processes
    }

    private func parseAuxProcesses(_ lines: [String]) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []

        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 11 else { continue }

            let pid = Int(parts[1]) ?? 0
            let cpu = Double(parts[2]) ?? 0
            let mem = Double(parts[3]) ?? 0
            let user = parts[0]
            let name = parts[10]
            let command = parts.dropFirst(10).joined(separator: " ")

            processes.append(ProcessInfo(
                pid: pid,
                name: name,
                cpuPercent: cpu,
                memoryPercent: mem,
                user: user,
                command: command
            ))
        }

        return processes
    }

    private func clampedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }

    private func clampedSubtract(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }

    private func bytesFromKiB(_ value: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: bytesPerKiB)
        return result.overflow ? nil : result.partialValue
    }

    private func bytesFromMiB(_ value: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: bytesPerMiB)
        return result.overflow ? nil : result.partialValue
    }

    private func bytesFromGiB(_ value: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: bytesPerGiB)
        return result.overflow ? nil : result.partialValue
    }

    private func bytesFromTiB(_ value: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: bytesPerTiB)
        return result.overflow ? nil : result.partialValue
    }

    private func bytesFromPiB(_ value: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: bytesPerPiB)
        return result.overflow ? nil : result.partialValue
    }

    private func dfUnitMultiplier(_ header: String) -> UInt64? {
        let normalized = header.lowercased()
        if normalized.contains("1k-blocks") || normalized.contains("1024-blocks") {
            return bytesPerKiB
        }
        if normalized.contains("512-blocks") {
            return 512
        }
        if normalized.contains("1m-blocks") {
            return bytesPerMiB
        }
        if normalized.contains("1g-blocks") {
            return bytesPerGiB
        }
        return nil
    }

    private func parseDfByteCount(_ rawValue: String, defaultUnit: UInt64?) -> UInt64? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let numeric = UInt64(trimmed) {
            guard let defaultUnit else { return numeric }
            return multiplyBytes(numeric, by: defaultUnit)
        }

        let numberPart = trimmed.prefix { $0.isNumber || $0 == "." }
        let suffixPart = trimmed.dropFirst(numberPart.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard !numberPart.isEmpty, let value = Double(numberPart), value.isFinite, value >= 0 else {
            return nil
        }

        let multiplier: Double
        switch suffixPart {
        case "K", "KB", "KI", "KIB":
            multiplier = Double(bytesPerKiB)
        case "M", "MB", "MI", "MIB":
            multiplier = Double(bytesPerMiB)
        case "G", "GB", "GI", "GIB":
            multiplier = Double(bytesPerGiB)
        case "T", "TB", "TI", "TIB":
            multiplier = Double(bytesPerTiB)
        case "P", "PB", "PI", "PIB":
            multiplier = Double(bytesPerPiB)
        case "B":
            multiplier = 1
        case "":
            guard let defaultUnit else { return nil }
            multiplier = Double(defaultUnit)
        default:
            return nil
        }

        let bytes = value * multiplier
        guard bytes.isFinite, bytes <= Double(UInt64.max) else { return nil }
        return UInt64(bytes.rounded())
    }

    private func multiplyBytes(_ value: UInt64, by multiplier: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: multiplier)
        return result.overflow ? nil : result.partialValue
    }
}

// MARK: - CPU Result Helper

struct CpuResult {
    let total: Double
    let user: Double
    let system: Double
    let iowait: Double
    let steal: Double
    let idle: Double
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
