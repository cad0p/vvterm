import Foundation
import Combine
import os.log

// MARK: - Server Stats Collector

/// Main stats collector that uses a shared SSH connection when available
@MainActor
final class ServerStatsCollector: ObservableObject {
    @Published var stats = ServerStats()
    @Published var cpuHistory: [StatsPoint] = []
    @Published var memoryHistory: [StatsPoint] = []
    @Published var isCollecting = false
    @Published var connectionError: String?

    private var collectTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "Stats")

    // Own SSH client for stats collection
    private var sshClient: SSHClient?
    private var ownsClient = false

    // Platform detection and collector
    private var remotePlatform: RemotePlatform = .unknown
    private var platformCollector: PlatformStatsCollector?
    private let context = StatsCollectionContext()

    // MARK: - Collection Control

    func startCollecting(for server: Server, using sharedClient: SSHClient? = nil) async {
        guard !isCollecting else { return }
        isCollecting = true
        connectionError = nil
        resetCollectionState()

        // Use shared client if available, otherwise create one
        let client: SSHClient
        let ownsClient: Bool
        if let sharedClient {
            client = sharedClient
            ownsClient = false
        } else {
            client = SSHClient()
            ownsClient = true
        }
        configureConnectionState(client: client, ownsClient: ownsClient)

        // Get credentials
        let credentials: ServerCredentials
        do {
            credentials = try KeychainManager.shared.getCredentials(for: server)
        } catch {
            finishCollection(withError: "No credentials found")
            return
        }

        // Connect in background
        collectTask = Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }

            do {
                try await SSHConnectionOperationService.shared.runWithConnection(
                    using: client,
                    server: server,
                    credentials: credentials,
                    disconnectWhenDone: ownsClient
                ) { connectedClient in
                    await MainActor.run {
                        self.connectionError = nil
                    }

                    while !Task.isCancelled {
                        let shouldContinue = await MainActor.run { self.isCollecting }
                        guard shouldContinue else { break }

                        await self.collectStats(client: connectedClient)
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            } catch {
                await MainActor.run {
                    self.finishCollection(withError: error.localizedDescription)
                }
            }
            await MainActor.run { [weak self] in
                self?.finishCollection()
            }
        }
    }

    func stopCollecting() {
        isCollecting = false
        collectTask?.cancel()
        collectTask = nil

        // Disconnect SSH only if we own the connection
        if ownsClient, let client = sshClient {
            Task.detached {
                await client.disconnect()
            }
        }
        clearConnectionState()
    }

    // MARK: - Stats Collection

    private func collectStats(client: SSHClient) async {
        do {
            // Detect platform and create collector on first run
            if remotePlatform == .unknown {
                remotePlatform = await client.remotePlatform()
                platformCollector = remotePlatform.createCollector()

                logger.info("Detected remote platform: \(self.remotePlatform.rawValue)")

                // Get initial system info
                let systemInfo = try await platformCollector?.getSystemInfo(client: client)
                await MainActor.run {
                    self.applySystemInfo(systemInfo)
                }
            }

            // Collect stats using platform-specific collector
            guard let collector = platformCollector else { return }

            var newStats = try await collector.collectStats(client: client, context: context)

            // Preserve system info
            let existingStats = await MainActor.run { self.stats }
            newStats.hostname = existingStats.hostname
            newStats.osInfo = existingStats.osInfo
            newStats.cpuCores = existingStats.cpuCores

            // Update on main thread
            await MainActor.run {
                self.applyCollectedStats(newStats)
            }

        } catch {
            logger.error("Failed to collect stats: \(error.localizedDescription)")
            await MainActor.run {
                self.finishCollection(withError: error.localizedDescription)
            }
        }
    }

    private func resetCollectionState() {
        context.reset()
        remotePlatform = .unknown
        platformCollector = nil
    }

    private func configureConnectionState(client: SSHClient, ownsClient: Bool) {
        self.sshClient = client
        self.ownsClient = ownsClient
    }

    private func clearConnectionState() {
        sshClient = nil
        ownsClient = false
    }

    private func finishCollection(withError error: String? = nil) {
        connectionError = error
        isCollecting = false
        clearConnectionState()
    }

    private func applySystemInfo(_ systemInfo: (hostname: String, osInfo: String, cpuCores: Int)?) {
        stats.hostname = systemInfo?.hostname ?? ""
        stats.osInfo = systemInfo?.osInfo ?? ""
        stats.cpuCores = systemInfo?.cpuCores ?? 1
    }

    private func applyCollectedStats(_ newStats: ServerStats) {
        stats = newStats

        cpuHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.cpuUsage))
        memoryHistory.append(StatsPoint(timestamp: newStats.timestamp, value: Double(newStats.memoryUsed)))

        if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        if memoryHistory.count > 60 { memoryHistory.removeFirst() }
    }
}
