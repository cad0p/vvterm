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
    case btrfs
    case zfs
    case darwinDiskUtility
    case windowsStorage
    case bsdNative
}

nonisolated enum StorageHealthFindingSeverity: Int, Hashable, Sendable {
    case information = 0
    case warning = 1
    case critical = 2
}

nonisolated enum StorageHealthFindingTiming: Hashable, Sendable {
    case current
    case historical
}

/// Closed set of evidence that can explain a non-healthy storage state.
/// Associated values are bounded, privacy-safe supporting values only.
nonisolated enum StorageHealthFindingKind: Hashable, Sendable {
    case sourceReportedHealth(String)
    case smartOverallFailure
    case smartCurrentPrefailThreshold
    case smartPastThreshold
    case smartErrorLog
    case smartSelfTestLog
    case nvmeCriticalWarning(bit: UInt8)
    case ataAttribute(name: String)
    case scsiErrorHistory(read: UInt64, write: UInt64, media: UInt64)
    case emmcPreEOL(EMMCPreEOLStatus)
    case emmcLifetimeExceeded
    case poolState(String)
    case deviceErrors(read: UInt64, write: UInt64, checksum: UInt64)
    case missingMember
    case partialCoverage

    var stableID: String {
        switch self {
        case .sourceReportedHealth(let value): "source-health:\(value.lowercased())"
        case .smartOverallFailure: "smart-overall-failure"
        case .smartCurrentPrefailThreshold: "smart-current-prefail"
        case .smartPastThreshold: "smart-past-threshold"
        case .smartErrorLog: "smart-error-log"
        case .smartSelfTestLog: "smart-self-test-log"
        case .nvmeCriticalWarning(let bit): "nvme-critical:\(bit)"
        case .ataAttribute(let name): "ata-attribute:\(name.lowercased())"
        case .scsiErrorHistory(let read, let write, let media):
            "scsi-errors:\(read):\(write):\(media)"
        case .emmcPreEOL(let status): "emmc-pre-eol:\(status.rawValue)"
        case .emmcLifetimeExceeded: "emmc-lifetime-exceeded"
        case .poolState(let state): "pool-state:\(state.lowercased())"
        case .deviceErrors(let read, let write, let checksum):
            "device-errors:\(read):\(write):\(checksum)"
        case .missingMember: "missing-member"
        case .partialCoverage: "partial-coverage"
        }
    }
}

nonisolated struct StorageHealthFinding: Hashable, Sendable, Identifiable {
    let kind: StorageHealthFindingKind
    let severity: StorageHealthFindingSeverity
    let timing: StorageHealthFindingTiming
    let source: StorageHealthSource

    var id: String {
        "\(kind.stableID)|\(source.rawValue)|\(timing == .current ? "current" : "historical")"
    }

    init(
        kind: StorageHealthFindingKind,
        severity: StorageHealthFindingSeverity,
        timing: StorageHealthFindingTiming = .current,
        source: StorageHealthSource
    ) {
        self.kind = kind
        self.severity = severity
        self.timing = timing
        self.source = source
    }
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
    var sourceState: StorageHealthState
    var metrics: StorageHealthMetrics
    var sources: Set<StorageHealthSource>
    var findings: [StorageHealthFinding]
    var attributes: [StorageHealthAttribute]

    var state: StorageHealthState {
        findings.reduce(sourceState) { state, finding in
            let findingState: StorageHealthState
            switch finding.severity {
            case .information:
                findingState = .unknown
            case .warning:
                findingState = .warning
            case .critical:
                findingState = .failing
            }
            return state.rawValue >= findingState.rawValue ? state : findingState
        }
    }

    init(
        deviceID: StorageDeviceIdentity,
        state: StorageHealthState = .unknown,
        metrics: StorageHealthMetrics = StorageHealthMetrics(),
        sources: Set<StorageHealthSource>,
        findings: [StorageHealthFinding] = [],
        attributes: [StorageHealthAttribute] = []
    ) {
        self.deviceID = deviceID
        sourceState = state
        self.metrics = metrics
        self.sources = sources
        self.findings = findings
        self.attributes = attributes
    }
}

nonisolated enum StorageDeviceHealthResult: Hashable, Sendable {
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

nonisolated enum StorageTopologyKind: Hashable, Sendable {
    case physicalDevice
    case btrfs
    case zfs
}

nonisolated enum StorageHealthMemberRole: Hashable, Sendable {
    case data
    case cache
    case log
    case spare
    case special
}

nonisolated enum StorageHealthCoverage: Hashable, Sendable {
    case complete
    case partial
}

nonisolated struct StorageHealthMemberReport: Hashable, Sendable, Identifiable {
    let id: StorageDeviceIdentity
    let role: StorageHealthMemberRole
    let ordinal: Int
    let result: StorageDeviceHealthResult
    let findings: [StorageHealthFinding]

    init(
        id: StorageDeviceIdentity,
        role: StorageHealthMemberRole,
        ordinal: Int,
        result: StorageDeviceHealthResult,
        findings: [StorageHealthFinding] = []
    ) {
        self.id = id
        self.role = role
        self.ordinal = ordinal
        self.result = result
        self.findings = findings
    }

    var state: StorageHealthState {
        let deviceState: StorageHealthState
        switch result {
        case .report(let report): deviceState = report.state
        case .unavailable: deviceState = .unknown
        }
        return findings.reduce(deviceState) { state, finding in
            let findingState: StorageHealthState
            switch finding.severity {
            case .information: findingState = .unknown
            case .warning: findingState = .warning
            case .critical: findingState = .failing
            }
            return state.rawValue >= findingState.rawValue ? state : findingState
        }
    }
}

nonisolated struct StorageHealthVolumeReport: Hashable, Sendable {
    let topology: StorageTopologyKind
    let name: String?
    let coverage: StorageHealthCoverage
    let findings: [StorageHealthFinding]
    let members: [StorageHealthMemberReport]

    var state: StorageHealthState {
        let poolState = findings.reduce(StorageHealthState.unknown) { state, finding in
            let findingState: StorageHealthState
            switch finding.severity {
            case .information: findingState = .unknown
            case .warning: findingState = .warning
            case .critical: findingState = .failing
            }
            return state.rawValue >= findingState.rawValue ? state : findingState
        }
        return members.reduce(poolState) { state, member in
            state.rawValue >= member.state.rawValue ? state : member.state
        }
    }
}

nonisolated enum StorageHealthResult: Hashable, Sendable {
    case report(StorageHealthVolumeReport)
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
