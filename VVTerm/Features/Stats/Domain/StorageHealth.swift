import Foundation

/// Opaque identity for a physical storage device.
///
/// The value is for correlation only. It must never be rendered as a device path
/// or sent to analytics.
nonisolated struct StorageDeviceIdentity: Hashable, Sendable {
    let namespace: String
    let opaqueValue: String

    init(namespace: String, opaqueValue: String) {
        self.namespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.opaqueValue = opaqueValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

nonisolated enum StorageHealthUnavailableReason: String, Hashable, Sendable {
    case unsupported
    case toolMissing
    case permissionDenied
    case unmapped
    case virtualDevice
    case networkVolume
    case invalidResponse
}

nonisolated enum StorageHealthCapability: Hashable, Sendable {
    case supported
    case unavailable(StorageHealthUnavailableReason)
}

nonisolated enum StorageHealthState: Int, Hashable, Sendable {
    case unknown = 0
    case healthy = 1
    case warning = 2
    case failing = 3
}

nonisolated enum StorageHealthSource: String, Hashable, Sendable {
    case smartctl
    case emmc
    case darwinDiskUtility
    case windowsStorage
    case bsdNative
}

nonisolated enum StorageHealthAttributeValue: Hashable, Sendable {
    case integer(UInt64)
    case decimal(Double)
    case text(String)
    case boolean(Bool)
}

/// A whitelisted platform-specific value that is safe to display.
/// Parsers intentionally omit serial numbers, device paths, and raw payloads.
nonisolated struct StorageHealthAttribute: Hashable, Sendable {
    let key: String
    let label: String
    let value: StorageHealthAttributeValue
    let unit: String?

    init(
        key: String,
        label: String,
        value: StorageHealthAttributeValue,
        unit: String? = nil
    ) {
        self.key = key
        self.label = label
        self.value = value
        self.unit = unit
    }
}

nonisolated enum EMMCPreEOLStatus: UInt8, Hashable, Sendable {
    case unknown = 0
    case normal = 1
    case warning = 2
    case urgent = 3
}

/// JEDEC reports lifetime consumption as a coarse bucket, not an exact
/// remaining-life percentage.
nonisolated enum EMMCLifetimeBucket: Hashable, Sendable {
    case unknown
    case estimatedUsage(lowerPercent: Int, upperPercent: Int)
    case exceededMaximumEstimate
    case reserved(UInt8)
}

nonisolated struct EMMCLifetimeEstimate: Hashable, Sendable {
    let rawValue: UInt8
    let bucket: EMMCLifetimeBucket

    init(rawValue: UInt8) {
        self.rawValue = rawValue
        switch rawValue {
        case 0:
            bucket = .unknown
        case 1...10:
            let lower = Int(rawValue - 1) * 10
            bucket = .estimatedUsage(lowerPercent: lower, upperPercent: lower + 10)
        case 11:
            bucket = .exceededMaximumEstimate
        default:
            bucket = .reserved(rawValue)
        }
    }
}

nonisolated struct EMMCHealth: Hashable, Sendable {
    let preEOL: EMMCPreEOLStatus
    let lifetimeTypeA: EMMCLifetimeEstimate?
    let lifetimeTypeB: EMMCLifetimeEstimate?
}

nonisolated struct StorageHealthMetrics: Hashable, Sendable {
    var temperatureCelsius: Double?
    var maximumTemperatureCelsius: Double?
    /// Consumed endurance. This is deliberately not named "remaining".
    var percentageUsed: Double?
    var availableSparePercent: Double?
    var availableSpareThresholdPercent: Double?
    var powerOnHours: UInt64?
    var powerCycleCount: UInt64?
    var unsafeShutdownCount: UInt64?
    var mediaErrorCount: UInt64?
    var errorLogEntryCount: UInt64?
    var readErrorsCorrected: UInt64?
    var readErrorsUncorrected: UInt64?
    var writeErrorsCorrected: UInt64?
    var writeErrorsUncorrected: UInt64?
    var startStopCycleCount: UInt64?
    var loadUnloadCycleCount: UInt64?
    var emmc: EMMCHealth?
}

nonisolated struct StorageHealthReport: Hashable, Sendable {
    let deviceID: StorageDeviceIdentity
    var state: StorageHealthState
    var metrics: StorageHealthMetrics
    var sources: Set<StorageHealthSource>
    var attributes: [StorageHealthAttribute]

    init(
        deviceID: StorageDeviceIdentity,
        state: StorageHealthState = .unknown,
        metrics: StorageHealthMetrics = StorageHealthMetrics(),
        sources: Set<StorageHealthSource>,
        attributes: [StorageHealthAttribute] = []
    ) {
        self.deviceID = deviceID
        self.state = state
        self.metrics = metrics
        self.sources = sources
        self.attributes = attributes
    }
}

nonisolated enum StorageHealthResult: Hashable, Sendable {
    case report(StorageHealthReport)
    case unavailable(StorageHealthUnavailableReason)

    var capability: StorageHealthCapability {
        switch self {
        case .report:
            return .supported
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }
}
