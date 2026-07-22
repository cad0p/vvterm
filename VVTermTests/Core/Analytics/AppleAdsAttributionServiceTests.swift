#if os(iOS)
import Foundation
import Testing
import Umami
@testable import VVTerm

private nonisolated enum TestAppleAdsError: Error, Sendable {
    case unavailable
}

private nonisolated enum TestAppleAdsHTTPOutcome: Sendable {
    case response(AppleAdsAttributionHTTPResponse)
    case failure
}

private actor TestAppleAdsStorage: AppleAdsAttributionStorage {
    private var enabled: Bool
    private var record: AppleAdsAttributionRecord?
    private var saveCount = 0

    init(enabled: Bool = true, record: AppleAdsAttributionRecord? = nil) {
        self.enabled = enabled
        self.record = record
    }

    func isAnalyticsEnabled() async -> Bool {
        enabled
    }

    func cachedRecord() async -> AppleAdsAttributionRecord? {
        record
    }

    func save(_ record: AppleAdsAttributionRecord) async throws {
        self.record = record
        saveCount += 1
    }

    func savedRecord() -> AppleAdsAttributionRecord? {
        record
    }

    func numberOfSaves() -> Int {
        saveCount
    }
}

private actor TestAppleAdsTokenProvider: AppleAdsAttributionTokenProviding {
    private var calls = 0

    func attributionToken() async throws -> String {
        calls += 1
        return "test-token"
    }

    func callCount() -> Int {
        calls
    }
}

private actor TestAppleAdsHTTPClient: AppleAdsAttributionHTTPClient {
    private var outcomes: [TestAppleAdsHTTPOutcome]
    private var calls = 0

    init(_ outcomes: [TestAppleAdsHTTPOutcome]) {
        self.outcomes = outcomes
    }

    func exchange(token: String) async throws -> AppleAdsAttributionHTTPResponse {
        calls += 1
        guard !outcomes.isEmpty else { throw TestAppleAdsError.unavailable }
        switch outcomes.removeFirst() {
        case .response(let response):
            return response
        case .failure:
            throw TestAppleAdsError.unavailable
        }
    }

    func callCount() -> Int {
        calls
    }
}

private actor TestAppleAdsSleeper: AppleAdsAttributionSleeping {
    private var calls = 0

    func sleep(for duration: Duration) async throws {
        calls += 1
    }

    func callCount() -> Int {
        calls
    }
}

@Suite(.serialized)
@MainActor
struct AppleAdsAttributionServiceTests {
    @Test
    func attributedResponseIsPersistedAndEnrichesPurchaseEvents() async throws {
        let storage = TestAppleAdsStorage()
        let tokenProvider = TestAppleAdsTokenProvider()
        let client = TestAppleAdsHTTPClient([
            .response(response("""
            {
              "attribution": true,
              "orgId": 40669820,
              "campaignId": 542370539,
              "conversionType": "Download",
              "claimType": "Click",
              "adGroupId": 542317095,
              "countryOrRegion": "US",
              "keywordId": 87675432,
              "adId": 542317136
            }
            """))
        ])
        let service = makeService(
            storage: storage,
            tokenProvider: tokenProvider,
            client: client
        )

        let record = try #require(await service.attributionRecord())
        let savedRecord = await storage.savedRecord()
        #expect(record == savedRecord)
        #expect(await storage.numberOfSaves() == 1)
        #expect(record.analyticsPayload["is_apple_ads_attributed"] == .bool(true))
        #expect(record.analyticsPayload["apple_ads_campaign_id"] == .string("542370539"))
        #expect(record.analyticsPayload["apple_ads_claim_type"] == .string("click"))
        #expect(record.analyticsPayload["apple_ads_conversion_type"] == .string("download"))

        let defaults = temporaryDefaults()
        defer { clear(defaults) }
        defaults.set(true, forKey: AnalyticsTracker.enabledKey)
        let tracker = AnalyticsTracker(
            defaults: defaults,
            appleAdsAttribution: service
        )
        let event = try #require(await tracker.preparedEvent(
            .purchaseStarted(source: "settings", productID: "pro.yearly")
        ))

        #expect(event.data?["source"] == .string("settings"))
        #expect(event.data?["product"] == .string("pro.yearly"))
        #expect(event.data?["platform"] != nil)
        #expect(event.data?["version"] != nil)
        #expect(event.data?["apple_ads_campaign_id"] == .string("542370539"))
    }

    @Test
    func organicResponsePersistsOnlyTheOrganicMarker() async throws {
        let storage = TestAppleAdsStorage()
        let service = makeService(
            storage: storage,
            client: TestAppleAdsHTTPClient([
                .response(response("""
                {
                  "attribution": false,
                  "campaignId": 999,
                  "adGroupId": 888
                }
                """))
            ])
        )

        let record = try #require(await service.attributionRecord())
        #expect(record.isAttributed == false)
        #expect(record.campaignID == nil)
        #expect(record.adGroupID == nil)
        #expect(record.analyticsPayload == [
            "is_apple_ads_attributed": .bool(false)
        ])
        let savedRecord = await storage.savedRecord()
        #expect(record == savedRecord)
    }

    @Test
    func cachedRecordPreventsAnotherTokenExchange() async {
        let cached = AppleAdsAttributionRecord(
            isAttributed: true,
            campaignID: 123
        )
        let storage = TestAppleAdsStorage(record: cached)
        let tokenProvider = TestAppleAdsTokenProvider()
        let client = TestAppleAdsHTTPClient([])
        let service = makeService(
            storage: storage,
            tokenProvider: tokenProvider,
            client: client
        )

        #expect(await service.attributionRecord() == cached)
        #expect(await service.attributionRecord() == cached)
        #expect(await tokenProvider.callCount() == 0)
        #expect(await client.callCount() == 0)
    }

    @Test
    func disabledAnalyticsPreventsCollectionAndEventPreparation() async {
        let storage = TestAppleAdsStorage(enabled: false)
        let tokenProvider = TestAppleAdsTokenProvider()
        let client = TestAppleAdsHTTPClient([])
        let service = makeService(
            storage: storage,
            tokenProvider: tokenProvider,
            client: client
        )

        #expect(await service.attributionRecord() == nil)
        #expect(await tokenProvider.callCount() == 0)
        #expect(await client.callCount() == 0)

        let defaults = temporaryDefaults()
        defer { clear(defaults) }
        defaults.set(false, forKey: AnalyticsTracker.enabledKey)
        let tracker = AnalyticsTracker(
            defaults: defaults,
            appleAdsAttribution: service
        )
        #expect(await tracker.preparedEvent(.appLaunched(isPro: false)) == nil)
    }

    @Test
    func appleNotFoundResponseRetriesThenPersistsSuccess() async throws {
        let storage = TestAppleAdsStorage()
        let client = TestAppleAdsHTTPClient([
            .response(response("", statusCode: 404)),
            .response(response("{\"attribution\":false}"))
        ])
        let sleeper = TestAppleAdsSleeper()
        let service = makeService(
            storage: storage,
            client: client,
            sleeper: sleeper
        )

        let record = try #require(await service.attributionRecord())
        #expect(record.isAttributed == false)
        #expect(await client.callCount() == 2)
        #expect(await sleeper.callCount() == 1)
        #expect(await storage.numberOfSaves() == 1)
    }

    @Test
    func networkFailuresUseBoundedRetriesWithoutPersisting() async {
        let storage = TestAppleAdsStorage()
        let client = TestAppleAdsHTTPClient([
            .failure,
            .failure,
            .failure
        ])
        let sleeper = TestAppleAdsSleeper()
        let service = makeService(
            storage: storage,
            client: client,
            sleeper: sleeper
        )

        #expect(await service.attributionRecord() == nil)
        #expect(await service.attributionRecord() == nil)
        #expect(await client.callCount() == 3)
        #expect(await sleeper.callCount() == 2)
        #expect(await storage.savedRecord() == nil)
    }

    @Test
    func malformedSuccessResponseIsIgnoredWithoutPersisting() async {
        let storage = TestAppleAdsStorage()
        let client = TestAppleAdsHTTPClient([
            .response(response("{\"campaignId\":123}"))
        ])
        let service = makeService(storage: storage, client: client)

        #expect(await service.attributionRecord() == nil)
        #expect(await client.callCount() == 1)
        #expect(await storage.savedRecord() == nil)
    }

    private func makeService(
        storage: TestAppleAdsStorage,
        tokenProvider: TestAppleAdsTokenProvider = TestAppleAdsTokenProvider(),
        client: TestAppleAdsHTTPClient,
        sleeper: TestAppleAdsSleeper = TestAppleAdsSleeper()
    ) -> AppleAdsAttributionService {
        AppleAdsAttributionService(
            storage: storage,
            tokenProvider: tokenProvider,
            httpClient: client,
            sleeper: sleeper,
            retryDelay: .zero,
            maximumAttempts: 3
        )
    }

    private func response(
        _ body: String,
        statusCode: Int = 200
    ) -> AppleAdsAttributionHTTPResponse {
        AppleAdsAttributionHTTPResponse(
            data: Data(body.utf8),
            statusCode: statusCode
        )
    }

    private func temporaryDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AppleAdsAttributionServiceTests.\(UUID().uuidString)")!
    }

    private func clear(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}
#endif
