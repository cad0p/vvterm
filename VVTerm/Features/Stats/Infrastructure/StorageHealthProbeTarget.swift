/// Infrastructure-only addressing for a health probe. Locators are never
/// persisted, rendered, or included in a health report.
nonisolated struct StorageHealthProbeTarget: Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case linux(devicePath: String, isEMMC: Bool)
        case darwin(nativeIdentifier: String, smartctlDevicePath: String?)
        case windows(diskNumber: UInt32)
        case freeBSD(devicePath: String)
        case openBSD(devicePath: String)
        case netBSD(devicePath: String)
    }

    let deviceID: StorageDeviceIdentity
    let kind: Kind
}
