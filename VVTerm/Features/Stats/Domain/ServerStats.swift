import Foundation

struct ServerStats {
    // System
    var hostname: String = ""
    var osInfo: String = ""
    var hardware: HardwareProfile = .empty
    var cpuCores: Int = 0

    // CPU detailed
    var cpuUsage: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cpuIowait: Double = 0
    var cpuSteal: Double = 0
    var cpuIdle: Double = 0
    var cpuCoreSamples: [CPUCoreSample] = []

    // Memory detailed (in bytes)
    var memoryTotal: UInt64 = 0
    var memoryUsed: UInt64 = 0
    var memoryFree: UInt64 = 0
    var memoryCached: UInt64 = 0
    var memoryBuffers: UInt64 = 0

    // Network (speed in bytes/sec, total in bytes)
    var networkRxSpeed: UInt64 = 0
    var networkTxSpeed: UInt64 = 0
    var networkRxTotal: UInt64 = 0
    var networkTxTotal: UInt64 = 0

    // Volumes
    var volumes: [VolumeInfo] = []

    // System
    var loadAverage: (Double, Double, Double) = (0, 0, 0)
    var uptime: TimeInterval = 0
    var processCount: Int = 0
    var topProcesses: [ProcessInfo] = []
    var gpuSamples: [GPUSample] = []
    var docker = DockerStats()
    var timestamp: Date = Date()

    var memoryPercent: Double {
        guard memoryTotal > 0 else { return 0 }
        return Double(memoryUsed) / Double(memoryTotal) * 100
    }
}

struct CPUCoreSample: Identifiable {
    let identifier: String
    let displayName: String
    let usagePercent: Double
    let userPercent: Double
    let systemPercent: Double
    let iowaitPercent: Double
    let stealPercent: Double
    let idlePercent: Double

    var id: String { identifier }
}

struct VolumeInfo: Identifiable {
    let mountPoint: String
    let used: UInt64
    let total: UInt64

    var id: String { mountPoint }

    var percent: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total) * 100
    }
}

struct ProcessInfo: Identifiable {
    var id: Int { pid }
    let pid: Int
    let name: String
    /// Share of total logical CPU capacity used during the latest sample interval.
    /// A value of 100 means the process saturated the whole machine, not one core.
    let cpuPercent: Double
    /// Resident physical memory divided by total visible physical memory.
    let memoryPercent: Double
    /// Resident physical memory in bytes when the platform exposes it.
    let memoryBytes: UInt64?
    let user: String
    let command: String

    init(
        pid: Int,
        name: String,
        cpuPercent: Double,
        memoryPercent: Double,
        memoryBytes: UInt64? = nil,
        user: String = "",
        command: String = ""
    ) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.memoryBytes = memoryBytes
        self.user = user
        self.command = command.isEmpty ? name : command
    }
}

struct StatsPoint: Identifiable {
    let timestamp: Date
    let value: Double

    var id: TimeInterval { timestamp.timeIntervalSince1970 }
}
