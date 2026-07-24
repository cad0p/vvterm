#if os(iOS)
import AdServices
import Foundation
import Umami

nonisolated struct AppleAdsAttributionRecord: Codable, Equatable, Sendable {
    let isAttributed: Bool
    let organizationID: Int64?
    let campaignID: Int64?
    let adGroupID: Int64?
    let keywordID: Int64?
    let adID: Int64?
    let countryOrRegion: String?
    let claimType: String?
    let conversionType: String?

    init(
        isAttributed: Bool,
        organizationID: Int64? = nil,
        campaignID: Int64? = nil,
        adGroupID: Int64? = nil,
        keywordID: Int64? = nil,
        adID: Int64? = nil,
        countryOrRegion: String? = nil,
        claimType: String? = nil,
        conversionType: String? = nil
    ) {
        self.isAttributed = isAttributed
        self.organizationID = isAttributed ? organizationID : nil
        self.campaignID = isAttributed ? campaignID : nil
        self.adGroupID = isAttributed ? adGroupID : nil
        self.keywordID = isAttributed ? keywordID : nil
        self.adID = isAttributed ? adID : nil
        self.countryOrRegion = isAttributed ? countryOrRegion : nil
        self.claimType = isAttributed ? claimType?.lowercased() : nil
        self.conversionType = isAttributed ? conversionType?.lowercased() : nil
    }

    var analyticsPayload: [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "is_apple_ads_attributed": .bool(isAttributed)
        ]
        Self.add(organizationID, as: "apple_ads_org_id", to: &payload)
        Self.add(campaignID, as: "apple_ads_campaign_id", to: &payload)
        Self.add(adGroupID, as: "apple_ads_ad_group_id", to: &payload)
        Self.add(keywordID, as: "apple_ads_keyword_id", to: &payload)
        Self.add(adID, as: "apple_ads_ad_id", to: &payload)
        Self.add(countryOrRegion, as: "apple_ads_country_or_region", to: &payload)
        Self.add(claimType, as: "apple_ads_claim_type", to: &payload)
        Self.add(conversionType, as: "apple_ads_conversion_type", to: &payload)
        return payload
    }

    private static func add(
        _ value: Int64?,
        as key: String,
        to payload: inout [String: JSONValue]
    ) {
        guard let value else { return }
        payload[key] = .string(String(value))
    }

    private static func add(
        _ value: String?,
        as key: String,
        to payload: inout [String: JSONValue]
    ) {
        guard let value, !value.isEmpty else { return }
        payload[key] = .string(value)
    }
}

nonisolated protocol AppleAdsAttributionStorage: Sendable {
    func isAnalyticsEnabled() async -> Bool
    func cachedRecord() async -> AppleAdsAttributionRecord?
    func save(_ record: AppleAdsAttributionRecord) async throws
}

nonisolated protocol AppleAdsAttributionTokenProviding: Sendable {
    func attributionToken() async throws -> String
}

nonisolated protocol AppleAdsAttributionHTTPClient: Sendable {
    func exchange(token: String) async throws -> AppleAdsAttributionHTTPResponse
}

nonisolated protocol AppleAdsAttributionSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

nonisolated struct AppleAdsAttributionHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

private nonisolated struct AppleAdsAttributionPayload: Decodable, Sendable {
    let attribution: Bool
    let orgId: Int64?
    let campaignId: Int64?
    let adGroupId: Int64?
    let keywordId: Int64?
    let adId: Int64?
    let countryOrRegion: String?
    let claimType: String?
    let conversionType: String?

    var record: AppleAdsAttributionRecord {
        AppleAdsAttributionRecord(
            isAttributed: attribution,
            organizationID: orgId,
            campaignID: campaignId,
            adGroupID: adGroupId,
            keywordID: keywordId,
            adID: adId,
            countryOrRegion: countryOrRegion,
            claimType: claimType,
            conversionType: conversionType
        )
    }
}

private nonisolated enum AppleAdsAttributionExchangeError: Error, Sendable {
    case unexpectedStatus(Int)
}

private nonisolated enum AppleAdsAttributionResolutionState: Sendable {
    case idle
    case resolving(Task<AppleAdsAttributionRecord?, Never>)
    case finished(AppleAdsAttributionRecord?)
}

nonisolated struct UserDefaultsAppleAdsAttributionStorage: AppleAdsAttributionStorage {
    static let recordKey = "analytics.appleAdsAttribution"

    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    func isAnalyticsEnabled() async -> Bool {
        let defaults = defaults()
        guard defaults.object(forKey: AnalyticsTracker.enabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: AnalyticsTracker.enabledKey)
    }

    func cachedRecord() async -> AppleAdsAttributionRecord? {
        guard let data = defaults().data(forKey: Self.recordKey) else { return nil }
        return try? JSONDecoder().decode(AppleAdsAttributionRecord.self, from: data)
    }

    func save(_ record: AppleAdsAttributionRecord) async throws {
        let data = try JSONEncoder().encode(record)
        defaults().set(data, forKey: Self.recordKey)
    }

    private func defaults() -> UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}

nonisolated struct SystemAppleAdsAttributionTokenProvider: AppleAdsAttributionTokenProviding {
    func attributionToken() async throws -> String {
        // Apple's token API is synchronous and may perform system work. Keep it
        // off the main actor without making the attribution service MainActor-bound.
        try await Task.detached(priority: .utility) {
            try AAAttribution.attributionToken()
        }.value
    }
}

nonisolated struct SystemAppleAdsAttributionHTTPClient: AppleAdsAttributionHTTPClient {
    private static let endpoint = URL(string: "https://api-adservices.apple.com/api/v1/")!

    func exchange(token: String) async throws -> AppleAdsAttributionHTTPResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(token.utf8)
        request.timeoutInterval = 15
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return AppleAdsAttributionHTTPResponse(
            data: data,
            statusCode: response.statusCode
        )
    }
}

nonisolated struct AppleAdsAttributionTaskSleeper: AppleAdsAttributionSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

actor AppleAdsAttributionService {
    static let shared = AppleAdsAttributionService()

    private let storage: any AppleAdsAttributionStorage
    private let tokenProvider: any AppleAdsAttributionTokenProviding
    private let httpClient: any AppleAdsAttributionHTTPClient
    private let sleeper: any AppleAdsAttributionSleeping
    private let retryDelay: Duration
    private let maximumAttempts: Int
    private var resolutionState = AppleAdsAttributionResolutionState.idle

    init(
        storage: any AppleAdsAttributionStorage = UserDefaultsAppleAdsAttributionStorage(),
        tokenProvider: any AppleAdsAttributionTokenProviding = SystemAppleAdsAttributionTokenProvider(),
        httpClient: any AppleAdsAttributionHTTPClient = SystemAppleAdsAttributionHTTPClient(),
        sleeper: any AppleAdsAttributionSleeping = AppleAdsAttributionTaskSleeper(),
        retryDelay: Duration = .seconds(5),
        maximumAttempts: Int = 3
    ) {
        self.storage = storage
        self.tokenProvider = tokenProvider
        self.httpClient = httpClient
        self.sleeper = sleeper
        self.retryDelay = retryDelay
        self.maximumAttempts = max(1, maximumAttempts)
    }

    func prepare() async {
        _ = await attributionRecord()
    }

    func attributionRecord() async -> AppleAdsAttributionRecord? {
        guard await storage.isAnalyticsEnabled() else { return nil }
        if let cached = await storage.cachedRecord() {
            return cached
        }

        switch resolutionState {
        case .resolving(let task):
            return await task.value
        case .finished(let record):
            return record
        case .idle:
            break
        }

        let task = Task<AppleAdsAttributionRecord?, Never> { [
            storage,
            tokenProvider,
            httpClient,
            sleeper,
            retryDelay,
            maximumAttempts
        ] in
            do {
                let token = try await tokenProvider.attributionToken()
                let record = try await Self.exchange(
                    token: token,
                    using: httpClient,
                    sleeper: sleeper,
                    retryDelay: retryDelay,
                    maximumAttempts: maximumAttempts
                )
                guard await storage.isAnalyticsEnabled() else { return nil }
                try await storage.save(record)
                return record
            } catch {
                return nil
            }
        }
        resolutionState = .resolving(task)
        let record = await task.value
        resolutionState = .finished(record)
        return record
    }

    private static func exchange(
        token: String,
        using httpClient: any AppleAdsAttributionHTTPClient,
        sleeper: any AppleAdsAttributionSleeping,
        retryDelay: Duration,
        maximumAttempts: Int
    ) async throws -> AppleAdsAttributionRecord {
        for attempt in 1...maximumAttempts {
            let response: AppleAdsAttributionHTTPResponse
            do {
                response = try await httpClient.exchange(token: token)
            } catch {
                guard attempt < maximumAttempts else { throw error }
                try await sleeper.sleep(for: retryDelay)
                continue
            }

            switch response.statusCode {
            case 200:
                return try JSONDecoder()
                    .decode(AppleAdsAttributionPayload.self, from: response.data)
                    .record
            case 404 where attempt < maximumAttempts,
                 500 where attempt < maximumAttempts:
                try await sleeper.sleep(for: retryDelay)
            default:
                throw AppleAdsAttributionExchangeError.unexpectedStatus(
                    response.statusCode
                )
            }
        }

        throw AppleAdsAttributionExchangeError.unexpectedStatus(500)
    }
}
#endif
