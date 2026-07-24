import Foundation

struct ServerStats {
    // System
    var hostname: String = ""
    var osInfo: String = ""
    var cpuCores: Int = 0

    // CPU detailed
    var cpuUsage: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cpuIowait: Double = 0
    var cpuSteal: Double = 0
    var cpuIdle: Double = 0

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
    var timestamp: Date = Date()

    var memoryPercent: Double {
        guard memoryTotal > 0 else { return 0 }
        return Double(memoryUsed) / Double(memoryTotal) * 100
    }
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
    let cpuPercent: Double
    let memoryPercent: Double
}

struct StatsPoint: Identifiable {
    let timestamp: Date
    let value: Double

    var id: TimeInterval { timestamp.timeIntervalSince1970 }
}
