import XCTest
@testable import VVTerm

final class PlatformStatsCollectorParserTests: XCTestCase {
    func testProcessCPUPercentagesUseTotalMachineCapacityOverSampleInterval() {
        let context = StatsCollectionContext()
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(context.processCPUPercentages(
            cumulativeCPUTimeByPID: [42: 10],
            timestamp: start,
            logicalProcessorCount: 8
        ).isEmpty)

        let percentages = context.processCPUPercentages(
            cumulativeCPUTimeByPID: [42: 12],
            timestamp: start.addingTimeInterval(2),
            logicalProcessorCount: 8
        )

        XCTAssertEqual(percentages[42] ?? -1, 12.5, accuracy: 0.001)
    }

    func testPeriodicProcessCachePreservesLastGoodSample() {
        let context = StatsCollectionContext()
        let process = ProcessInfo(pid: 42, name: "worker", cpuPercent: 25, memoryPercent: 5)

        context.updatePeriodicProcesses([process], timestamp: Date(timeIntervalSince1970: 100))
        context.updatePeriodicProcesses([], timestamp: Date(timeIntervalSince1970: 105))

        XCTAssertEqual(context.getPeriodicProcesses().map(\.pid), [42])
        XCTAssertFalse(context.shouldCollectPeriodicProcesses(
            now: Date(timeIntervalSince1970: 106),
            minimumInterval: 5
        ))
    }

    func testUnixProcessParserUsesResidentBytesAndIntervalCPU() {
        let output = """
          1124 root 0:12.50 87.4 262144 python server.py
          2048 uy 1:02.25 12.0 524288 ollama serve
        """

        let rows = UnixProcessTelemetry.parseProcessRows(output)
        let processes = UnixProcessTelemetry.makeProcesses(
            from: rows,
            intervalCPUPercentages: [1124: 25],
            memoryTotal: 4_294_967_296
        )

        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].cpuPercent, 25, accuracy: 0.001)
        XCTAssertEqual(processes[0].memoryBytes, 268_435_456)
        XCTAssertEqual(processes[0].memoryPercent, 6.25, accuracy: 0.001)
        XCTAssertEqual(processes[0].command, "python server.py")
    }

    func testUnixProcessCommandsForceInvariantLocale() {
        XCTAssertTrue(UnixProcessTelemetry.processDetailsCommand(
            platform: .darwin,
            limit: 24,
            pids: nil
        ).contains("LC_ALL=C LANG=C"))
        XCTAssertTrue(UnixProcessTelemetry.processDetailsCommand(
            platform: .linux,
            limit: nil,
            pids: nil
        ).contains("LC_ALL=C LANG=C"))
    }

    func testBSDPeriodicProcessCommandsAreSortedAndOnDemandIsUnbounded() {
        for platform in [RemotePlatform.freebsd, .openbsd, .netbsd] {
            let periodic = UnixProcessTelemetry.processDetailsCommand(
                platform: platform,
                limit: 24,
                pids: nil
            )
            XCTAssertTrue(periodic.contains("sort -k4 -nr"))
            XCTAssertTrue(periodic.contains("head -n 24"))

            let full = UnixProcessTelemetry.processDetailsCommand(
                platform: platform,
                limit: nil,
                pids: nil
            )
            XCTAssertFalse(full.contains("head -n"))
        }
    }

    func testUnixCPUTimeParserHandlesDaysAndFractionalSeconds() {
        XCTAssertEqual(UnixProcessTelemetry.parseCPUTime("1-02:03:04.50") ?? -1, 93_784.5, accuracy: 0.001)
        XCTAssertEqual(UnixProcessTelemetry.parseCPUTime("12:34.25") ?? -1, 754.25, accuracy: 0.001)
    }

    func testDarwinDisplayJSONParsesGPUWithoutDisplayRows() {
        let output = """
        {
          "SPDisplaysDataType" : [
            {
              "_name" : "Apple M1 Pro",
              "spdisplays_vendor" : "sppci_vendor_Apple",
              "sppci_cores" : "16",
              "sppci_device_type" : "spdisplays_gpu",
              "sppci_model" : "Apple M1 Pro",
              "spdisplays_ndrvs" : [
                { "_name" : "Color LCD", "_spdisplays_pixels" : "3024 x 1964" }
              ]
            }
          ]
        }
        """

        let devices = DarwinStatsCollector().parseDisplayProfileJSON(output)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.name, "Apple M1 Pro")
        XCTAssertEqual(devices.first?.vendor, "Apple")
        XCTAssertEqual(devices.first?.kind, .apple)
    }

    func testDarwinDisplayTextDoesNotTreatDisplaysAsGPUs() {
        let output = """
        Graphics/Displays:

            Apple M1 Pro:

              Chipset Model: Apple M1 Pro
              Type: GPU
              Total Number of Cores: 16
              Vendor: Apple (0x106b)
              Displays:
                Color LCD:
                  Resolution: 3024 x 1964 Retina
        """

        let devices = DarwinStatsCollector().parseDisplayProfile(output)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.name, "Apple M1 Pro")
        XCTAssertEqual(devices.first?.vendor, "Apple (0x106b)")
    }

    func testDarwinProcessParserHandlesNoHeaderFullProcessRows() {
        let output = """
          123 root 12.5 1.2 /usr/bin/python python server.py
          456 uy 1.0 0.4 /bin/zsh -zsh
        """

        let processes = DarwinStatsCollector().parsePs(output)

        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].pid, 123)
        XCTAssertEqual(processes[0].user, "root")
        XCTAssertEqual(processes[0].name, "/usr/bin/python")
        XCTAssertEqual(processes[0].command, "python server.py")
    }

    func testDarwinTopCPUParserHandlesCPUUsageLine() {
        let cpu = DarwinStatsCollector().parseTopCpu("CPU usage: 12.34% user, 5.66% sys, 82.00% idle")

        XCTAssertEqual(cpu.user, 12.34, accuracy: 0.001)
        XCTAssertEqual(cpu.system, 5.66, accuracy: 0.001)
        XCTAssertEqual(cpu.idle, 82.0, accuracy: 0.001)
    }

    func testDarwinProcessorLoadParserCalculatesPerCoreUsage() {
        let previous = """
        0 100 50 850 0
        1 200 100 700 0
        """
        let current = """
        0 140 70 890 0
        1 220 130 750 0
        """
        let collector = DarwinStatsCollector()
        let previousValues = collector.parseProcessorLoadOutput(previous, previousValues: [:]).newValues

        let parsed = collector.parseProcessorLoadOutput(current, previousValues: previousValues)

        XCTAssertEqual(parsed.samples.count, 2)
        XCTAssertEqual(parsed.samples[0].displayName, "CPU 1")
        XCTAssertEqual(parsed.samples[0].usagePercent, 60, accuracy: 0.001)
        XCTAssertEqual(parsed.samples[1].usagePercent, 50, accuracy: 0.001)
    }

    func testLinuxDfParserKeepsFirstDataRowAndOverlayRoot() {
        let output = """
        Filesystem     1M-blocks  Used Available Use% Mounted on
        overlay           100000 70000     30000  70% /
        /dev/sda1         200000 50000    150000  25% /data
        """

        let volumes = LinuxStatsCollector().parseDfVolumes(output)

        XCTAssertEqual(volumes.count, 2)
        XCTAssertEqual(volumes[0].mountPoint, "/")
        XCTAssertEqual(volumes[0].used, 70_000 * 1_048_576)
    }

    func testLinuxProcStatCoreParserCalculatesPerCorePercentages() {
        let previous = """
        cpu  100 0 50 850 0 0 0 0
        cpu0 50 0 25 425 0 0 0 0
        cpu1 50 0 25 425 0 0 0 0
        """
        let current = """
        cpu  140 0 70 890 0 0 0 0
        cpu0 70 0 35 445 0 0 0 0
        cpu1 70 0 35 445 0 0 0 0
        """
        let collector = LinuxStatsCollector()
        let previousValues = collector.parseProcStatCores(previous, prevValues: [:]).newValues

        let result = collector.parseProcStatCores(current, prevValues: previousValues)

        XCTAssertEqual(result.samples.count, 2)
        XCTAssertEqual(result.samples[0].usagePercent, 60, accuracy: 0.001)
        XCTAssertEqual(result.samples[0].displayName, "CPU 1")
    }

    func testLinuxNvidiaSampleParserNormalizesMemory() {
        let samples = LinuxStatsCollector().parseNvidiaSamples(
            "0, 76, 14336, 24576, 62, 284.5",
            timestamp: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].deviceID, "nvidia-0")
        XCTAssertEqual(samples[0].utilizationPercent, 76)
        XCTAssertEqual(samples[0].memoryUsed, 14_336 * 1_048_576)
    }

    func testLinuxProcessParserHandlesFullRows() {
        let output = """
          1124 root 62.4 18.2 python python server.py
          2048 uy 18.0 24.9 ollama ollama serve
        """

        let processes = LinuxStatsCollector().parsePs(output)

        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].user, "root")
        XCTAssertEqual(processes[0].command, "python server.py")
    }

    func testLinuxMemoryParserFallsBackWhenMemAvailableIsMissing() {
        let output = """
        MemTotal:       1000000 kB
        MemFree:         100000 kB
        Buffers:          50000 kB
        Cached:          300000 kB
        SReclaimable:     50000 kB
        Shmem:            25000 kB
        """

        let memory = LinuxStatsCollector().parseProcMeminfo(output)

        XCTAssertEqual(memory.used, 525_000 * 1_024)
    }

    func testWindowsGPUParserFiltersVirtualAdaptersAndAvoidsCappedVRAM() {
        let output = """
        GameViewer Virtual Display Adapter|GameViewer|0|1.0|ROOT\\DISPLAY\\0000|OK
        SudoMaker Virtual Display Adapter|SudoMaker|0|1.0|ROOT\\DISPLAY\\0001|OK
        NVIDIA GeForce RTX 3060|NVIDIA|4293918720|555.42|PCI\\VEN_10DE&DEV_2504|OK
        Intel UHD Graphics|Intel Corporation|1073741824|31.0|PCI\\VEN_8086&DEV_9A49|OK
        """

        let devices = WindowsStatsCollector().parseWindowsGPUs(output)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].kind, .nvidia)
        XCTAssertEqual(devices[0].memoryTotal, 0)
        XCTAssertEqual(devices[1].kind, .intel)
        XCTAssertEqual(devices[1].memoryTotal, 1_073_741_824)
    }

    func testWindowsNvidiaParserUsesSMIForRealVRAM() {
        let output = "0, NVIDIA GeForce RTX 3060, GPU-abc, 45, 2048, 12288, 63, 120.5, 555.42"

        let devices = WindowsStatsCollector().parseWindowsNvidiaGPUs(output)
        let samples = WindowsStatsCollector().parseWindowsNvidiaSamples(
            output,
            timestamp: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, "nvidia-0")
        XCTAssertEqual(devices[0].memoryTotal, 12_288 * 1_048_576)
        XCTAssertEqual(samples[0].utilizationPercent, 45)
        XCTAssertEqual(samples[0].memoryUsed, 2_048 * 1_048_576)
        XCTAssertEqual(samples[0].memoryTotal, 12_288 * 1_048_576)
    }

    func testWindowsGPUCounterParserReadsPerfRows() {
        let samples = WindowsStatsCollector().parseWindowsGPUCounterSamples(
            "PERF|windows-phys-0|125.4|2147483648|8589934592",
            timestamp: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].deviceID, "windows-phys-0")
        XCTAssertEqual(samples[0].utilizationPercent, 100)
        XCTAssertEqual(samples[0].memoryUsed, 2_147_483_648)
        XCTAssertEqual(samples[0].memoryTotal, 8_589_934_592)
    }

    func testWindowsGPUCounterParserTreatsZeroMemoryLimitAsMissing() {
        let samples = WindowsStatsCollector().parseWindowsGPUCounterSamples(
            "PERF|windows-phys-0|25.0|2147483648|0",
            timestamp: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].deviceID, "windows-phys-0")
        XCTAssertEqual(samples[0].utilizationPercent, 25)
        XCTAssertEqual(samples[0].memoryUsed, 2_147_483_648)
        XCTAssertNil(samples[0].memoryTotal)
    }

    func testWindowsCPUParserReadsPerCoreCounters() {
        let output = """
        TOTAL|24.5|18.0|6.5
        CORE|0|12.0|8.0|4.0
        CORE|1|88.5|70.0|18.5
        """

        let usage = WindowsStatsCollector().parseWindowsCPUUsage(output)

        XCTAssertEqual(usage.usagePercent, 24.5)
        XCTAssertEqual(usage.userPercent, 18.0)
        XCTAssertEqual(usage.systemPercent, 6.5)
        XCTAssertEqual(usage.coreSamples.count, 2)
        XCTAssertEqual(usage.coreSamples[1].displayName, "CPU 2")
        XCTAssertEqual(usage.coreSamples[1].usagePercent, 88.5)
    }

    func testWindowsCPUParserReadsLocalizedDecimalCommas() {
        let output = """
        TOTAL|24,5|18,0|6,5
        CORE|0|12,0|8,0|4,0
        CORE|1|88,5|70,0|18,5
        """

        let usage = WindowsStatsCollector().parseWindowsCPUUsage(output)

        XCTAssertEqual(usage.usagePercent, 24.5)
        XCTAssertEqual(usage.userPercent, 18.0)
        XCTAssertEqual(usage.systemPercent, 6.5)
        XCTAssertEqual(usage.coreSamples.count, 2)
        XCTAssertEqual(usage.coreSamples[1].usagePercent, 88.5)
        XCTAssertEqual(usage.coreSamples[1].systemPercent, 18.5)
    }

    func testWindowsProcessParserReturnsAllRows() {
        let output = """
        10|System|100.0|50.0|2147483648
        20|Terminal|12.5|20.0|858993459
        30|Code|2.0|12.5|536870912
        """

        let processes = WindowsStatsCollector().parseProcesses(output)

        XCTAssertEqual(processes.count, 3)
        XCTAssertEqual(processes[1].name, "Terminal")
        XCTAssertEqual(processes[1].memoryBytes, 858_993_459)
    }

    func testWindowsWMICProcessParserNormalizesCPUAndMemoryPercent() {
        let output = """
        Node,IDProcess,Name,PercentProcessorTime,WorkingSet
        HOST,100,python,320,1073741824
        HOST,200,code,40,536870912
        """

        let processes = WindowsStatsCollector().parseWMICProcesses(
            output,
            memoryTotal: 4_294_967_296,
            logicalProcessorCount: 8
        )

        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].cpuPercent, 40)
        XCTAssertEqual(processes[0].memoryPercent, 25)
        XCTAssertEqual(processes[1].cpuPercent, 5)
        XCTAssertEqual(processes[1].memoryPercent, 12.5)
    }

    func testWindowsWMICProcessParserReadsLocalizedDecimalCommaCPU() {
        let output = """
        Node,IDProcess,Name,PercentProcessorTime,WorkingSet
        HOST,100,python,"320,0",1073741824
        """

        let processes = WindowsStatsCollector().parseWMICProcesses(
            output,
            memoryTotal: 4_294_967_296,
            logicalProcessorCount: 8
        )

        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes[0].cpuPercent, 40)
    }

    func testWindowsWMICVolumeParserHandlesDriveRows() {
        let output = """
        Caption=C:
        FreeSpace=1073741824
        Size=10737418240

        Caption=D:
        FreeSpace=2147483648
        Size=21474836480
        """

        let volumes = WindowsStatsCollector().parseWMICVolumes(output)

        XCTAssertEqual(volumes.count, 2)
        XCTAssertEqual(volumes[0].mountPoint, "C:\\")
        XCTAssertEqual(volumes[0].used, 9_663_676_416)
    }

    func testWindowsNetstatParserReadsBytesLine() {
        let totals = WindowsStatsCollector().parseNetstatInterfaceStats(
            "Bytes                  123456789      987654321"
        )

        XCTAssertEqual(totals.rx, 123_456_789)
        XCTAssertEqual(totals.tx, 987_654_321)
    }

    func testDockerParserMergesContainerRowsWithStatsRows() {
        let psOutput = """
        {"ID":"abcdef1234567890","Names":"api","Image":"ghcr.io/app/api:latest","Command":"./api","CreatedAt":"2026-07-06 10:00:00 +0000 UTC","RunningFor":"2 hours ago","Ports":"0.0.0.0:8080->8080/tcp","Status":"Up 2 hours (healthy)","State":"running"}
        {"ID":"fedcba9876543210","Names":"db","Image":"postgres:16","Command":"docker-entrypoint.sh","CreatedAt":"2026-07-06 09:00:00 +0000 UTC","RunningFor":"3 hours ago","Ports":"5432/tcp","Status":"Exited (0) 1 hour ago","State":"exited"}
        """
        let statsOutput = """
        {"Container":"abcdef123456","Name":"api","CPUPerc":"12.50%","MemUsage":"512MiB / 2GiB","MemPerc":"25.00%","NetIO":"1.5GB / 200MB","BlockIO":"4MB / 8MB","PIDs":"8"}
        """

        let docker = DockerStatsCollector().parseContainers(
            psOutput: psOutput,
            statsOutput: statsOutput,
            timestamp: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(docker.isAvailable)
        XCTAssertEqual(docker.containers.count, 2)
        XCTAssertEqual(docker.runningCount, 1)
        XCTAssertEqual(docker.stoppedCount, 1)
        XCTAssertEqual(docker.containers[0].displayName, "api")
        XCTAssertEqual(docker.containers[0].health, .healthy)
        XCTAssertEqual(docker.containers[0].cpuPercent, 12.5)
        XCTAssertEqual(docker.containers[0].memoryUsed, 512 * 1_048_576)
        XCTAssertEqual(docker.containers[0].memoryLimit, 2 * 1_073_741_824)
        XCTAssertEqual(docker.networkRx, 1_500_000_000)
        XCTAssertEqual(docker.networkTx, 200_000_000)
    }

    func testDockerParserAcceptsStatsRowsWithoutPsRows() {
        let statsOutput = """
        {"Container":"redis","Name":"redis","CPUPerc":"0,25%","MemUsage":"128MiB / 1GiB","MemPerc":"12,50%","NetIO":"2kB / 1kB","BlockIO":"0B / 0B","PIDs":"5"}
        """

        let docker = DockerStatsCollector().parseContainers(psOutput: "", statsOutput: statsOutput)

        XCTAssertEqual(docker.containers.count, 1)
        XCTAssertEqual(docker.containers[0].displayName, "redis")
        XCTAssertEqual(docker.containers[0].state, .running)
        XCTAssertEqual(docker.containers[0].cpuPercent, 0.25)
        XCTAssertEqual(docker.containers[0].memoryPercent, 12.5)
        XCTAssertEqual(docker.containers[0].networkRx, 2_000)
        XCTAssertEqual(docker.containers[0].networkTx, 1_000)
    }

    func testDockerParserDeduplicatesRunningAndRecentRows() {
        let psOutput = """
        {"ID":"abcdef1234567890","Names":"api","Image":"ghcr.io/app/api:latest","Status":"Up 2 hours","State":"running"}
        {"ID":"abcdef1234567890","Names":"api","Image":"ghcr.io/app/api:latest","Status":"Up 2 hours","State":"running"}
        """

        let docker = DockerStatsCollector().parseContainers(psOutput: psOutput, statsOutput: "")

        XCTAssertEqual(docker.containers.count, 1)
        XCTAssertEqual(docker.containers[0].displayName, "api")
    }

    func testDockerCommandsUsePowerShellQuotingOnWindowsPowerShell() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "powershell"),
            activeShellName: "powershell",
            powerShellExecutable: "powershell"
        )
        let collector = DockerStatsCollector()

        XCTAssertEqual(
            collector.psCommands(platform: .windows, environment: environment, limit: 24),
            [
                "docker ps --no-trunc --format '{{json .}}' 2>&1",
                "docker ps -a --no-trunc --last 24 --format '{{json .}}' 2>&1"
            ]
        )
        XCTAssertEqual(
            collector.statsCommand(platform: .windows, environment: environment, containerIDs: ["abcdef123456"]),
            "docker stats --no-stream --format '{{json .}}' abcdef123456 2>&1"
        )
        XCTAssertEqual(
            collector.shellCommand(
                for: "docker ps --no-trunc --format '{{json .}}' 2>&1",
                platform: .windows,
                environment: environment
            ),
            "docker ps --no-trunc --format '{{json .}}' 2>&1"
        )
    }

    func testDockerCommandsWrapCmdOnWindowsCMD() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .cmd,
            activeShellName: "cmd.exe",
            powerShellExecutable: "powershell"
        )
        let collector = DockerStatsCollector()
        let command = collector.statsCommand(
            platform: .windows,
            environment: environment,
            containerIDs: ["abcdef123456", "unsafe;id"]
        )

        XCTAssertEqual(
            command,
            "docker stats --no-stream --format \"{{json .}}\" abcdef123456 unsafeid 2>&1"
        )
        XCTAssertEqual(
            collector.shellCommand(for: command, platform: .windows, environment: environment),
            "cmd.exe /d /c docker stats --no-stream --format \"{{json .}}\" abcdef123456 unsafeid 2>&1"
        )
    }

    func testDockerActionCommandSanitizesContainerID() throws {
        let container = DockerContainer(
            id: "abcdef123456; rm -rf /",
            name: "api",
            image: "api:latest",
            command: "api",
            state: .running,
            status: "Up",
            health: .none,
            createdAt: "",
            runningFor: "",
            ports: "",
            cpuPercent: 0,
            memoryPercent: 0,
            memoryUsed: nil,
            memoryLimit: nil,
            networkRx: nil,
            networkTx: nil,
            blockRead: nil,
            blockWrite: nil,
            pids: nil
        )

        let collector = DockerStatsCollector()

        XCTAssertEqual(try collector.actionCommand(.start, container: container), "docker start abcdef123456rm-rf 2>&1")
        XCTAssertEqual(try collector.actionCommand(.stop, container: container), "docker stop abcdef123456rm-rf 2>&1")
        XCTAssertEqual(try collector.actionCommand(.restart, container: container), "docker restart abcdef123456rm-rf 2>&1")
    }

    func testDockerCommandsUsePosixQuotingOnUnix() {
        let collector = DockerStatsCollector()

        XCTAssertEqual(
            collector.psCommands(platform: .linux, environment: .fallbackPOSIX, limit: nil),
            ["docker ps -a --no-trunc --format '{{json .}}' 2>&1"]
        )
        XCTAssertEqual(
            collector.shellCommand(
                for: "docker ps -a --no-trunc --format '{{json .}}' 2>&1",
                platform: .linux,
                environment: .fallbackPOSIX
            ),
            "docker ps -a --no-trunc --format '{{json .}}' 2>&1"
        )
    }

    func testDockerSizeParserHandlesBinaryAndDecimalUnits() {
        let collector = DockerStatsCollector()

        XCTAssertEqual(collector.parseSize("512MiB"), 512 * 1_048_576)
        XCTAssertEqual(collector.parseSize("1.5GB"), 1_500_000_000)
        XCTAssertEqual(collector.parseSize("2,5 kB"), 2_500)
        XCTAssertEqual(collector.parseSize("64B"), 64)
    }
}
