import Foundation
import StoreKit

nonisolated enum AnalyticsMode: Equatable, Sendable {
    case disabled
    case production
}

nonisolated enum AnalyticsEnvironmentPolicy {
    static func mode(
        userEnabled: Bool,
        isDevelopmentBuild: Bool,
        isSimulator: Bool,
        isPreview: Bool,
        isRunningTests: Bool,
        isVerifiedProductionInstall: Bool
    ) -> AnalyticsMode {
        guard userEnabled,
              !isDevelopmentBuild,
              !isSimulator,
              !isPreview,
              !isRunningTests,
              isVerifiedProductionInstall else {
            return .disabled
        }
        return .production
    }

    static func currentInstallMode() async -> AnalyticsMode {
        #if DEBUG || targetEnvironment(simulator)
        return .disabled
        #else
        let environment = Foundation.ProcessInfo.processInfo.environment
        let isPreview = environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil

        guard !isPreview, !isRunningTests else {
            return .disabled
        }

        guard let appTransaction = try? await AppTransaction.shared else {
            return .disabled
        }
        let isVerifiedProductionInstall: Bool
        switch appTransaction {
        case .verified(let transaction):
            isVerifiedProductionInstall = transaction.environment == .production
        case .unverified:
            isVerifiedProductionInstall = false
        }

        return mode(
            userEnabled: true,
            isDevelopmentBuild: false,
            isSimulator: false,
            isPreview: isPreview,
            isRunningTests: isRunningTests,
            isVerifiedProductionInstall: isVerifiedProductionInstall
        )
        #endif
    }
}

actor AnalyticsModeResolver {
    typealias Provider = @Sendable () async -> AnalyticsMode

    private let provider: Provider
    private var resolution: Task<AnalyticsMode, Never>?

    init(provider: @escaping Provider) {
        self.provider = provider
    }

    func mode() async -> AnalyticsMode {
        if let resolution {
            return await resolution.value
        }

        let provider = provider
        let resolution = Task { await provider() }
        self.resolution = resolution
        return await resolution.value
    }
}
