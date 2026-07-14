import Foundation

// MARK: - Darwin/macOS Stats Collector

/// Stats collector for macOS/Darwin systems using sysctl, vm_stat, etc.
struct DarwinStatsCollector: PlatformStatsCollector {
    private static let periodicProcessLimit = 24
    private static let processorLoadScript = """
        if [ -x /usr/bin/ruby ]; then
            /usr/bin/ruby <<'RUBY' && exit 0
        require 'fiddle'

        lib = Fiddle.dlopen('/usr/lib/libSystem.B.dylib')
        host_self = Fiddle::Function.new(lib['mach_host_self'], [], Fiddle::TYPE_INT)
        host_processor_info = Fiddle::Function.new(
          lib['host_processor_info'],
          [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
          Fiddle::TYPE_INT
        )
        mach_task_self = Fiddle::Function.new(lib['mach_task_self'], [], Fiddle::TYPE_INT)
        vm_deallocate = Fiddle::Function.new(
          lib['vm_deallocate'],
          [Fiddle::TYPE_INT, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG],
          Fiddle::TYPE_INT
        )

        count_ptr = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        info_ptr_ptr = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
        info_count_ptr = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        result = host_processor_info.call(host_self.call, 2, count_ptr, info_ptr_ptr, info_count_ptr)
        exit 1 unless result == 0

        processor_count = count_ptr[0, Fiddle::SIZEOF_INT].unpack1('I!')
        info_count = info_count_ptr[0, Fiddle::SIZEOF_INT].unpack1('I!')
        info_addr = info_ptr_ptr[0, Fiddle::SIZEOF_VOIDP].unpack1('J')
        info = Fiddle::Pointer.new(info_addr)
        values = info[0, info_count * Fiddle::SIZEOF_INT].unpack('i!*')

        (0...processor_count).each do |cpu|
          base = cpu * 4
          puts "#{cpu} #{values[base]} #{values[base + 1]} #{values[base + 2]} #{values[base + 3]}"
        end

        vm_deallocate.call(mach_task_self.call, info_addr, info_count * Fiddle::SIZEOF_INT)
        RUBY
        fi

        xcode-select -p >/dev/null 2>&1 || exit 1
        command -v cc >/dev/null 2>&1 || exit 1
        HELPER="${TMPDIR:-/tmp}/vvterm-cpu-load-v1"
        if [ ! -x "$HELPER" ]; then
            SRC="${HELPER}.$$.c"
            cat > "$SRC" <<'C'
        #include <mach/mach.h>
        #include <stdio.h>

        int main(void) {
            mach_port_t host = mach_host_self();
            natural_t processor_count = 0;
            processor_info_array_t processor_info = 0;
            mach_msg_type_number_t processor_info_count = 0;
            kern_return_t result = host_processor_info(
                host,
                PROCESSOR_CPU_LOAD_INFO,
                &processor_count,
                &processor_info,
                &processor_info_count
            );

            if (result != KERN_SUCCESS || processor_info == 0) {
                return 1;
            }

            for (natural_t cpu = 0; cpu < processor_count; cpu++) {
                integer_t *base = processor_info + (cpu * CPU_STATE_MAX);
                printf(
                    "%u %d %d %d %d\\n",
                    cpu,
                    base[CPU_STATE_USER],
                    base[CPU_STATE_SYSTEM],
                    base[CPU_STATE_IDLE],
                    base[CPU_STATE_NICE]
                );
            }

            vm_deallocate(
                mach_task_self(),
                (vm_address_t)processor_info,
                (vm_size_t)processor_info_count * sizeof(integer_t)
            );
            return 0;
        }
        C
            cc "$SRC" -o "$HELPER" >/dev/null 2>&1 || {
                rm -f "$SRC" "$HELPER"
                exit 1
            }
            rm -f "$SRC"
        fi
        "$HELPER"
        """
    private static let processorLoadCommand = RemoteTerminalBootstrap.wrapPOSIXShellCommand(processorLoadScript)

    func getSystemInfo(client: SSHClient) async throws -> (hostname: String, osInfo: String, cpuCores: Int) {
        let cmd = "uname -srm; echo '---SEP---'; hostname; echo '---SEP---'; sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1"
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
            sysctl -n machdep.cpu.brand_string 2>/dev/null; echo '---SEP---'; \
            sysctl -n machdep.cpu.vendor 2>/dev/null; echo '---SEP---'; \
            sysctl -n hw.physicalcpu 2>/dev/null; echo '---SEP---'; \
            sysctl -n hw.logicalcpu 2>/dev/null; echo '---SEP---'; \
            sysctl -n hw.memsize 2>/dev/null
            """
        let cmd = RemoteTerminalBootstrap.wrapPOSIXShellCommand(profileScript)
        let output = try await client.execute(cmd, timeout: .seconds(5))
        let sections = output.components(separatedBy: "---SEP---")
        let displayJSON = (try? await client.execute(
            "system_profiler SPDisplaysDataType -json 2>/dev/null",
            timeout: .seconds(6)
        )) ?? ""
        let displayText: String
        if displayJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayText = (try? await client.execute(
                "system_profiler SPDisplaysDataType -detailLevel mini 2>/dev/null || system_profiler SPDisplaysDataType 2>/dev/null || true",
                timeout: .seconds(8)
            )) ?? ""
        } else {
            displayText = ""
        }
        let gpus = parseDisplayProfileJSON(displayJSON)
        let fallbackGPUs = gpus.isEmpty ? parseDisplayProfile(displayText) : []

        return HardwareProfile(
            hostname: section(sections, 0),
            osInfo: section(sections, 1),
            architecture: section(sections, 2),
            kernelVersion: section(sections, 3),
            cpuModel: section(sections, 4),
            cpuVendor: section(sections, 5),
            cpuCores: Int(section(sections, 6)) ?? 0,
            cpuThreads: Int(section(sections, 7)) ?? 0,
            memoryTotal: UInt64(section(sections, 8)) ?? 0,
            gpus: gpus + fallbackGPUs,
            collectedAt: Date()
        )
    }

    func collectStats(client: SSHClient, context: StatsCollectionContext) async throws -> ServerStats {
        var stats = ServerStats()

        // Batch commands for macOS
        let batchCmd = """
            LC_ALL=C LANG=C; \
            sysctl -n vm.loadavg 2>/dev/null || uptime | sed 's/.*load average[s]*: //'; echo '---SEP---'; \
            sysctl -n kern.boottime; echo '---SEP---'; \
            sysctl -n hw.memsize; echo '---SEP---'; \
            vm_stat; echo '---SEP---'; \
            netstat -ibn; echo '---SEP---'; \
            sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
            """
        let batchOutput = try await client.execute(batchCmd)
        let sections = batchOutput.components(separatedBy: "---SEP---")

        // Load average (format: { 1.23 4.56 7.89 })
        if sections.count > 0 {
            stats.loadAverage = StatsParsingUtils.parseLoadAverage(sections[0])
        }

        // Uptime from boot time
        if sections.count > 1 {
            stats.uptime = parseBootTime(sections[1])
        }

        // Total memory from sysctl hw.memsize
        var totalMem: UInt64 = 0
        if sections.count > 2 {
            totalMem = UInt64(sections[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        // Memory via vm_stat
        if sections.count > 3 {
            let mem = parseVmStat(sections[3], totalMemory: totalMem)
            stats.memoryTotal = mem.total
            stats.memoryUsed = mem.used
            stats.memoryFree = mem.free
            stats.memoryCached = mem.cached
            stats.memoryBuffers = 0
        }

        // Network via netstat
        if sections.count > 4 {
            let (netRx, netTx) = parseNetstat(sections[4])
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
        }

        let logicalCPUCount = sections.indices.contains(5)
            ? (Int(sections[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
            : 0

        // CPU via top (separate command due to complexity)
        let topOutput = try await client.execute("LC_ALL=C LANG=C top -l 1 -n 0 -s 0 2>/dev/null | grep 'CPU usage' || echo 'CPU usage: 0% user, 0% sys, 100% idle'")
        let cpu = parseTopCpu(topOutput)
        stats.cpuUser = cpu.user
        stats.cpuSystem = cpu.system
        stats.cpuIdle = cpu.idle
        stats.cpuUsage = cpu.user + cpu.system
        stats.cpuIowait = 0
        stats.cpuSteal = 0
        stats.cpuCores = max(logicalCPUCount, 0)
        if let cpuCoreSamples = await collectCPUCoreSamplesIfAvailable(client: client, context: context),
           !cpuCoreSamples.isEmpty {
            stats.cpuCoreSamples = cpuCoreSamples
            stats.cpuCores = max(stats.cpuCores, cpuCoreSamples.count)
        }

        if let collection = try? await UnixProcessTelemetry.collect(
            client: client,
            context: context,
            platform: .darwin,
            logicalProcessorCount: max(logicalCPUCount, 1),
            memoryTotal: totalMem,
            limit: Self.periodicProcessLimit
        ) {
            stats.topProcesses = collection.processes
            stats.processCount = collection.totalCount
        }

        // Volumes
        let dfOutput = try await client.execute("LC_ALL=C LANG=C df -m 2>/dev/null | grep -E '^/dev'")
        stats.volumes = parseDf(dfOutput)

        stats.timestamp = Date()
        return stats
    }

    func collectProcesses(client: SSHClient, context: StatsCollectionContext) async throws -> [ProcessInfo] {
        let systemInfo = try await getSystemInfo(client: client)
        let totalMemoryOutput = try await client.execute("sysctl -n hw.memsize 2>/dev/null")
        let totalMemory = UInt64(totalMemoryOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return try await UnixProcessTelemetry.collect(
            client: client,
            context: context,
            platform: .darwin,
            logicalProcessorCount: max(systemInfo.cpuCores, 1),
            memoryTotal: totalMemory,
            limit: nil
        ).processes
    }

    // MARK: - Parsers

    private func collectCPUCoreSamplesIfAvailable(
        client: SSHClient,
        context: StatsCollectionContext
    ) async -> [CPUCoreSample]? {
        guard let output = try? await client.execute(Self.processorLoadCommand, timeout: .seconds(12)) else {
            return nil
        }

        let parsed = parseProcessorLoadOutput(output, previousValues: context.getCpuCoreValues())
        context.updateCpuCoreValues(parsed.newValues)
        return parsed.samples
    }

    func parseProcessorLoadOutput(
        _ output: String,
        previousValues: [String: LinuxCpuValues]
    ) -> (samples: [CPUCoreSample], newValues: [String: LinuxCpuValues]) {
        var samples: [CPUCoreSample] = []
        var newValues: [String: LinuxCpuValues] = [:]

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 5,
                  let index = Int(parts[0]) else {
                continue
            }

            let identifier = "cpu\(index)"
            let values = LinuxCpuValues(
                user: UInt64(parts[1]) ?? 0,
                nice: UInt64(parts[4]) ?? 0,
                system: UInt64(parts[2]) ?? 0,
                idle: UInt64(parts[3]) ?? 0,
                iowait: 0,
                irq: 0,
                softirq: 0,
                steal: 0
            )
            let sample = makeCPUCoreSample(
                identifier: identifier,
                displayIndex: index + 1,
                current: values,
                previous: previousValues[identifier]
            )
            samples.append(sample)
            newValues[identifier] = values
        }

        samples.sort { lhs, rhs in
            numericCPUIndex(lhs.identifier) < numericCPUIndex(rhs.identifier)
        }

        return (samples, newValues)
    }

    private func makeCPUCoreSample(
        identifier: String,
        displayIndex: Int,
        current: LinuxCpuValues,
        previous: LinuxCpuValues?
    ) -> CPUCoreSample {
        guard let previous else {
            return CPUCoreSample(
                identifier: identifier,
                displayName: String(format: String(localized: "CPU %lld"), Int64(displayIndex)),
                usagePercent: 0,
                userPercent: 0,
                systemPercent: 0,
                iowaitPercent: 0,
                stealPercent: 0,
                idlePercent: 100
            )
        }

        let user = Double(clampedSubtract(current.user, previous.user) + clampedSubtract(current.nice, previous.nice))
        let system = Double(clampedSubtract(current.system, previous.system))
        let idle = Double(clampedSubtract(current.idle, previous.idle))
        let total = user + system + idle
        guard total > 0 else {
            return CPUCoreSample(
                identifier: identifier,
                displayName: String(format: String(localized: "CPU %lld"), Int64(displayIndex)),
                usagePercent: 0,
                userPercent: 0,
                systemPercent: 0,
                iowaitPercent: 0,
                stealPercent: 0,
                idlePercent: 100
            )
        }

        let userPercent = user / total * 100
        let systemPercent = system / total * 100
        let idlePercent = idle / total * 100
        return CPUCoreSample(
            identifier: identifier,
            displayName: String(format: String(localized: "CPU %lld"), Int64(displayIndex)),
            usagePercent: userPercent + systemPercent,
            userPercent: userPercent,
            systemPercent: systemPercent,
            iowaitPercent: 0,
            stealPercent: 0,
            idlePercent: idlePercent
        )
    }

    private func numericCPUIndex(_ identifier: String) -> Int {
        Int(identifier.dropFirst(3)) ?? Int.max
    }

    private func clampedSubtract(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }

    private func parseBootTime(_ output: String) -> TimeInterval {
        // Format: { sec = 1234567890, usec = 123456 } ...
        if let secRange = output.range(of: "sec = "),
           let commaRange = output.range(of: ",", range: secRange.upperBound..<output.endIndex) {
            let secStr = String(output[secRange.upperBound..<commaRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if let bootTime = TimeInterval(secStr) {
                return StatsParsingUtils.uptimeFromBootTime(bootTime)
            }
        }
        return 0
    }

    private func parseVmStat(_ output: String, totalMemory: UInt64) -> (total: UInt64, used: UInt64, free: UInt64, cached: UInt64) {
        var pagesFree: UInt64 = 0
        var pagesActive: UInt64 = 0
        var pagesInactive: UInt64 = 0
        var pagesSpeculative: UInt64 = 0
        var pagesWired: UInt64 = 0
        var pagesCompressed: UInt64 = 0
        var pagesCached: UInt64 = 0
        var pageSize: UInt64 = 16384 // Default to 16KB (Apple Silicon)

        for line in output.components(separatedBy: .newlines) {
            // Extract page size from header
            if line.contains("page size of") {
                if let range = line.range(of: "page size of "),
                   let endRange = line.range(of: " bytes", range: range.upperBound..<line.endIndex) {
                    let sizeStr = String(line[range.upperBound..<endRange.lowerBound])
                    pageSize = UInt64(sizeStr) ?? 16384
                }
                continue
            }

            let parts = line.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }

            let valueStr = parts[1].replacingOccurrences(of: ".", with: "")
            let value = UInt64(valueStr) ?? 0

            switch parts[0] {
            case "Pages free": pagesFree = value
            case "Pages active": pagesActive = value
            case "Pages inactive": pagesInactive = value
            case "Pages speculative": pagesSpeculative = value
            case "Pages wired down": pagesWired = value
            case "Pages occupied by compressor": pagesCompressed = value
            case "File-backed pages": pagesCached = value
            default: break
            }
        }

        let total = totalMemory > 0 ? totalMemory : (pagesFree + pagesActive + pagesInactive + pagesSpeculative + pagesWired + pagesCompressed) * pageSize
        let free = (pagesFree + pagesSpeculative) * pageSize
        let used = (pagesActive + pagesWired + pagesCompressed) * pageSize
        let cached = (pagesInactive + pagesCached) * pageSize

        return (total, used, free, cached)
    }

    private func parseNetstat(_ output: String) -> (rx: UInt64, tx: UInt64) {
        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0

        let lines = output.components(separatedBy: .newlines)
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // Format: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes
            guard parts.count >= 10 else { continue }

            let iface = parts[0]
            let network = parts[2]
            guard network.hasPrefix("<Link#"), shouldIncludeNetworkInterface(iface) else { continue }

            if let ibytes = UInt64(parts[6]), let obytes = UInt64(parts[9]) {
                totalRx += ibytes
                totalTx += obytes
            }
        }

        return (totalRx, totalTx)
    }

    private func shouldIncludeNetworkInterface(_ iface: String) -> Bool {
        let excludedPrefixes = [
            "lo", "gif", "stf", "awdl", "llw", "utun", "bridge", "p2p", "ap", "anpi"
        ]
        return !excludedPrefixes.contains { iface.hasPrefix($0) }
    }

    func parsePs(_ output: String) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []

        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let processLines: ArraySlice<String>
        if lines.first?.lowercased().hasPrefix("pid ") == true {
            processLines = lines.dropFirst()
        } else {
            processLines = lines[...]
        }

        for line in processLines {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 5 else { continue }

            let pid = Int(parts[0]) ?? 0
            let user = parts[1]
            let cpu = Double(parts[2]) ?? 0
            let mem = Double(parts[3]) ?? 0
            let name = parts[4]
            let command = parts.count > 5 ? parts.dropFirst(5).joined(separator: " ") : name

            guard pid > 0 else { continue }
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

    func parseTopCpu(_ output: String) -> (user: Double, system: Double, idle: Double) {
        var user = 0.0
        var system = 0.0
        var idle = 100.0

        let components = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ",")

        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("user") {
                let numStr = trimmed.replacingOccurrences(of: "CPU usage:", with: "")
                    .replacingOccurrences(of: "% user", with: "")
                    .trimmingCharacters(in: .whitespaces)
                user = Double(numStr) ?? 0
            } else if trimmed.contains("sys") {
                let numStr = trimmed.replacingOccurrences(of: "% sys", with: "")
                    .trimmingCharacters(in: .whitespaces)
                system = Double(numStr) ?? 0
            } else if trimmed.contains("idle") {
                let numStr = trimmed.replacingOccurrences(of: "% idle", with: "")
                    .trimmingCharacters(in: .whitespaces)
                idle = Double(numStr) ?? 100
            }
        }

        return (user, system, idle)
    }

    private func parseDf(_ output: String) -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []

        var rawVolumes: [VolumeInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // Format: Filesystem 1M-blocks Used Available Capacity iused ifree %iused Mounted
            guard parts.count >= 9 else { continue }

            let totalMB = UInt64(parts[1]) ?? 0
            let usedMB = UInt64(parts[2]) ?? 0
            let mountPoint = parts[8...].joined(separator: " ")

            if totalMB < 100 { continue }

            rawVolumes.append(VolumeInfo(
                mountPoint: mountPoint,
                used: usedMB * 1024 * 1024,
                total: totalMB * 1024 * 1024
            ))
        }

        if let dataVolume = rawVolumes.first(where: { $0.mountPoint == "/System/Volumes/Data" }) {
            volumes.append(VolumeInfo(
                mountPoint: "/",
                used: dataVolume.used,
                total: dataVolume.total
            ))
        } else if let rootVolume = rawVolumes.first(where: { $0.mountPoint == "/" }) {
            volumes.append(rootVolume)
        }

        volumes.append(contentsOf: rawVolumes.filter { volume in
            volume.mountPoint.hasPrefix("/Volumes/")
        })

        if volumes.isEmpty {
            return rawVolumes.filter { !isDarwinSystemVolume($0.mountPoint) }
        }

        return volumes
    }

    private func isDarwinSystemVolume(_ mountPoint: String) -> Bool {
        mountPoint.hasPrefix("/System/Volumes/")
    }

    private func section(_ sections: [String], _ index: Int) -> String {
        guard sections.indices.contains(index) else { return "" }
        return sections[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parseDisplayProfile(_ output: String) -> [GPUDevice] {
        var devices: [GPUDevice] = []
        var currentName: String?
        var currentVendor = ""
        var currentVRAM: UInt64 = 0
        var inDisplaySection = false

        func flush() {
            guard let currentName, !currentName.isEmpty else { return }
            let lowerName = currentName.lowercased()
            let lowerVendor = currentVendor.lowercased()
            let kind: GPUKind
            if lowerName.contains("apple") || lowerVendor.contains("apple") {
                kind = .apple
            } else if lowerName.contains("amd") || lowerVendor.contains("amd") {
                kind = .amd
            } else if lowerName.contains("intel") || lowerVendor.contains("intel") {
                kind = .intel
            } else if lowerName.contains("nvidia") || lowerVendor.contains("nvidia") {
                kind = .nvidia
            } else {
                kind = .unknown
            }

            devices.append(GPUDevice(
                id: "display-\(devices.count)",
                name: currentName,
                vendor: currentVendor,
                kind: kind,
                driverVersion: "",
                memoryTotal: currentVRAM,
                source: .systemProfiler
            ))
        }

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let leadingSpaces = line.prefix { $0 == " " }.count

            if trimmed == "Displays:" {
                inDisplaySection = true
                continue
            }

            if trimmed.hasSuffix(":"),
               !trimmed.contains("Graphics/Displays:"),
               !trimmed.contains("Displays:"),
               !trimmed.contains("Display:"),
               !trimmed.contains("Resolution:") {
                if inDisplaySection, leadingSpaces > 4 {
                    continue
                }
                inDisplaySection = false
                flush()
                currentName = String(trimmed.dropLast())
                currentVendor = ""
                currentVRAM = 0
            } else if trimmed.hasPrefix("Chipset Model:") {
                if currentName == nil {
                    currentName = valueAfterColon(trimmed)
                }
            } else if trimmed.hasPrefix("Vendor:") {
                currentVendor = valueAfterColon(trimmed)
            } else if trimmed.hasPrefix("VRAM") {
                currentVRAM = parseDarwinMemory(valueAfterColon(trimmed))
            }
        }

        flush()
        return devices
    }

    func parseDisplayProfileJSON(_ output: String) -> [GPUDevice] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPDisplaysDataType"] as? [[String: Any]] else {
            return []
        }

        return entries.enumerated().compactMap { index, entry in
            let model = stringValue(entry["sppci_model"])
                ?? stringValue(entry["_name"])
                ?? stringValue(entry["spdisplays_device-id"])
                ?? ""
            guard !model.isEmpty else { return nil }
            let vendor = normalizeDarwinVendor(stringValue(entry["spdisplays_vendor"]) ?? "")
            let lowerModel = model.lowercased()
            let lowerVendor = vendor.lowercased()
            let kind: GPUKind
            if lowerModel.contains("apple") || lowerVendor.contains("apple") {
                kind = .apple
            } else if lowerModel.contains("amd") || lowerVendor.contains("amd") {
                kind = .amd
            } else if lowerModel.contains("intel") || lowerVendor.contains("intel") {
                kind = .intel
            } else if lowerModel.contains("nvidia") || lowerVendor.contains("nvidia") {
                kind = .nvidia
            } else {
                kind = .unknown
            }

            let memory = parseDarwinMemory(stringValue(entry["spdisplays_vram"]) ?? "")
            return GPUDevice(
                id: "display-\(index)",
                name: model,
                vendor: vendor,
                kind: kind,
                driverVersion: "",
                memoryTotal: memory,
                source: .systemProfiler
            )
        }
    }

    private func valueAfterColon(_ line: String) -> String {
        line.components(separatedBy: ":").dropFirst().joined(separator: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDarwinMemory(_ rawValue: String) -> UInt64 {
        let lower = rawValue.lowercased()
        let numberString = lower.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(numberString) else { return 0 }
        if lower.contains("tb") {
            return UInt64(value * 1_099_511_627_776)
        }
        if lower.contains("gb") {
            return UInt64(value * 1_073_741_824)
        }
        if lower.contains("mb") {
            return UInt64(value * 1_048_576)
        }
        return 0
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func normalizeDarwinVendor(_ vendor: String) -> String {
        vendor
            .replacingOccurrences(of: "sppci_vendor_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
