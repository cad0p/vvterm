import Foundation
import Umami
#if os(iOS)
import UIKit
#endif

/// Anonymous product analytics sent only from verified production App Store installs.
/// Events contain feature names, bounded values, and app context only — never commands,
/// server addresses, usernames, or other identifying content.
@MainActor
final class AnalyticsTracker {
    static let shared = AnalyticsTracker()

    nonisolated static let enabledKey = "analytics.enabled"

    private static let websiteID = "22711a63-9ec0-491c-ad86-71cb0b6ad4dd"
    private static let lastLaunchKey = "analytics.lastTrackedLaunch"
    private static let minimumLaunchInterval: TimeInterval = 5 * 60
    private static let maximumPropertyCount = 16
    private static let appleAdsPropertyKeys: Set<String> = [
        "is_apple_ads_attributed",
        "apple_ads_org_id",
        "apple_ads_campaign_id",
        "apple_ads_ad_group_id",
        "apple_ads_keyword_id",
        "apple_ads_ad_id",
        "apple_ads_country_or_region",
        "apple_ads_claim_type",
        "apple_ads_conversion_type"
    ]

    private let defaults: UserDefaults
    private let modeResolver: AnalyticsModeResolver
    private let deliveryQueue: AnalyticsDeliveryQueue
    #if os(iOS)
    private let appleAdsAttribution: AppleAdsAttributionService
    #endif
    private var admission = AnalyticsAdmissionController()
    private var hasTrackedLaunch = false

    private init() {
        let defaults = UserDefaults.standard
        let productionTransport = AnalyticsProductionTransport()
        self.defaults = defaults
        modeResolver = AnalyticsModeResolver {
            await AnalyticsEnvironmentPolicy.currentInstallMode()
        }
        deliveryQueue = AnalyticsDeliveryQueue { event in
            await productionTransport.send(event)
        }
        #if os(iOS)
        appleAdsAttribution = .shared
        #endif
        defaults.register(defaults: [Self.enabledKey: true])
    }

    #if os(iOS)
    init(
        defaults: UserDefaults,
        appleAdsAttribution: AppleAdsAttributionService,
        modeProvider: @escaping AnalyticsModeResolver.Provider = { .production },
        delivery: @escaping AnalyticsDeliveryQueue.Delivery = { _ in }
    ) {
        self.defaults = defaults
        self.appleAdsAttribution = appleAdsAttribution
        modeResolver = AnalyticsModeResolver(provider: modeProvider)
        deliveryQueue = AnalyticsDeliveryQueue(delivery: delivery)
        defaults.register(defaults: [Self.enabledKey: true])
    }
    #endif

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    func prepareAppleAdsAttribution() {
        #if os(iOS)
        guard isEnabled else { return }
        Task(priority: .utility) { [modeResolver, appleAdsAttribution] in
            guard await modeResolver.mode() == .production else { return }
            await appleAdsAttribution.prepare()
        }
        #endif
    }

    // MARK: - Events

    /// Fired after the first entitlement check. A persistent five-minute guard also
    /// bounds crash/relaunch loops that the once-per-process guard cannot catch.
    func trackAppLaunched(isPro: Bool) {
        guard !hasTrackedLaunch else { return }
        hasTrackedLaunch = true
        send(.appLaunched(isPro: isPro), minimumPersistentInterval: Self.minimumLaunchInterval)
    }

    func trackConnectionSucceeded(transport: String) {
        send(.connectionSucceeded(transport: transport))
    }

    func trackConnectionAttempted(transport: String) {
        send(.connectionAttempted(transport: transport))
    }

    func trackConnectionReconnecting(transport: String) {
        send(.connectionReconnecting(transport: transport))
    }

    func trackConnectionFailed(transport: String, reason: String) {
        send(.connectionFailed(transport: transport, reason: reason))
    }

    func trackPaywallViewed(source: String) {
        send(.paywallViewed(source: source))
    }

    func trackPaywallCTATapped(source: String, productId: String) {
        send(.paywallCTATapped(source: source, productID: productId))
    }

    func trackPurchaseStarted(source: String, productId: String) {
        send(.purchaseStarted(source: source, productID: productId))
    }

    func trackPurchaseSucceeded(source: String, productId: String) {
        send(.purchaseSucceeded(source: source, productID: productId))
    }

    func trackPurchaseCancelled(source: String, productId: String) {
        send(.purchaseCancelled(source: source, productID: productId))
    }

    func trackPurchasePending(source: String, productId: String) {
        send(.purchasePending(source: source, productID: productId))
    }

    func trackPurchaseFailed(source: String, productId: String, reason: String) {
        send(.purchaseFailed(source: source, productID: productId, reason: reason))
    }

    func trackLimitHit(source: String, generation: String, current: Int, limit: Int) {
        send(.limitHit(source: source, generation: generation, current: current, limit: limit))
    }

    func trackFreePlanGenerationAssigned(generation: String, serverCount: Int, reason: String) {
        send(.freePlanGenerationAssigned(
            generation: generation,
            serverCount: serverCount,
            reason: reason
        ))
    }

    func trackWelcomeCompleted() {
        send(.welcomeCompleted)
    }

    func trackCustomActionCreated(kind: String) {
        send(.customActionCreated(kind: kind))
    }

    func trackSplitPaneCreated() {
        send(.splitPaneCreated)
    }

    func trackReviewPromptRequested() {
        send(.reviewPromptRequested)
    }

    func trackAnalyticsDisabled() {
        send(.analyticsDisabled)
    }

    // MARK: - Transport

    private func send(
        _ event: AnalyticsEvent,
        minimumPersistentInterval: TimeInterval? = nil
    ) {
        // Capture the user's setting synchronously so analytics_disabled can be
        // emitted immediately before the setting is switched off.
        guard isEnabled else { return }
        Task(priority: .utility) { [weak self, modeResolver] in
            guard await modeResolver.mode() == .production, let self else { return }
            let now = Date().timeIntervalSince1970
            guard self.admit(
                event,
                at: now,
                minimumPersistentInterval: minimumPersistentInterval
            ) else { return }
            guard let request = await self.makeEvent(event) else { return }
            await self.deliveryQueue.enqueue(request)
        }
    }

    private func admit(
        _ event: AnalyticsEvent,
        at timestamp: TimeInterval,
        minimumPersistentInterval: TimeInterval?
    ) -> Bool {
        if let minimumPersistentInterval {
            let lastEmission = (defaults.object(forKey: Self.lastLaunchKey) as? Date)?
                .timeIntervalSince1970
            guard AnalyticsAdmissionController.admitsPersistentLaunch(
                lastEmission: lastEmission,
                at: timestamp,
                minimumInterval: minimumPersistentInterval
            ) else { return false }
        }
        guard admission.admits(event, at: timestamp) else { return false }
        if minimumPersistentInterval != nil {
            defaults.set(Date(timeIntervalSince1970: timestamp), forKey: Self.lastLaunchKey)
        }
        return true
    }

    func preparedEvent(_ event: AnalyticsEvent) async -> TrackEventRequest? {
        guard isEnabled, await modeResolver.mode() == .production else { return nil }
        return await makeEvent(event)
    }

    private func makeEvent(_ event: AnalyticsEvent) async -> TrackEventRequest? {
        #if os(iOS)
        let attribution = await appleAdsAttribution.attributionRecord()?.analyticsPayload ?? [:]
        #else
        let attribution: [String: JSONValue] = [:]
        #endif

        let definition = event.definition
        let payload = Self.enrichedPayload(definition.data, attribution: attribution)
        guard payload.count <= Self.maximumPropertyCount else { return nil }
        return TrackEventRequest(
            source: .website(Self.websiteID),
            data: payload,
            title: "VVTerm App",
            url: definition.url,
            name: definition.name
        )
    }

    static func enrichedPayload(
        _ data: [String: JSONValue],
        attribution: [String: JSONValue]
    ) -> [String: JSONValue] {
        var payload = data
        for (key, value) in attribution where appleAdsPropertyKeys.contains(key) {
            if key == "is_apple_ads_attributed" {
                if case .bool = value {
                    payload[key] = value
                }
            } else if case .string(let string) = value {
                payload[key] = .string(String(string.prefix(AnalyticsEvent.maximumStringLength)))
            }
        }
        payload["platform"] = .string(Self.platform)
        payload["version"] = .string(Self.appVersion)
        payload["build"] = .string(Self.buildNumber)
        return payload
    }

    private static let platform: String = {
        #if os(macOS)
        return "macos"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }()

    private static let appVersion = AnalyticsTracker.boundedBundleValue("CFBundleShortVersionString")
    private static let buildNumber = AnalyticsTracker.boundedBundleValue("CFBundleVersion")

    private static func boundedBundleValue(_ key: String) -> String {
        let value = Bundle.main.infoDictionary?[key] as? String ?? "unknown"
        return String(value.prefix(AnalyticsEvent.maximumStringLength))
    }
}
