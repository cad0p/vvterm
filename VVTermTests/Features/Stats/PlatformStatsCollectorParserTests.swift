import XCTest
@testable import VVTerm

final class PlatformStatsCollectorParserTests: XCTestCase {
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

    func testWindowsGPUParserUsesVideoControllerRows() {
        let output = """
        NVIDIA RTX 4090|NVIDIA|25757220864|555.42
        Intel UHD Graphics|Intel Corporation|1073741824|31.0
        """

        let devices = WindowsStatsCollector().parseWindowsGPUs(output)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].kind, .nvidia)
        XCTAssertEqual(devices[0].memoryTotal, 25_757_220_864)
        XCTAssertEqual(devices[1].kind, .intel)
    }

    func testWindowsProcessParserReturnsAllRows() {
        let output = """
        10|System|100.0|50.0
        20|Terminal|12.5|200.0
        30|Code|2.0|512.0
        """

        let processes = WindowsStatsCollector().parseProcesses(output)

        XCTAssertEqual(processes.count, 3)
        XCTAssertEqual(processes[1].name, "Terminal")
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
}
