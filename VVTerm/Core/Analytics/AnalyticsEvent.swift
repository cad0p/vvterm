import Foundation
import Umami

nonisolated enum AnalyticsEvent: Hashable, Sendable {
    case appLaunched(isPro: Bool)
    case connectionSucceeded(transport: String)
    case connectionAttempted(transport: String)
    case connectionReconnecting(transport: String)
    case connectionFailed(transport: String, reason: String)
    case paywallViewed(source: String)
    case paywallCTATapped(source: String, productID: String)
    case purchaseStarted(source: String, productID: String)
    case purchaseSucceeded(source: String, productID: String)
    case purchaseCancelled(source: String, productID: String)
    case purchasePending(source: String, productID: String)
    case purchaseFailed(source: String, productID: String, reason: String)
    case limitHit(source: String, generation: String, current: Int, limit: Int)
    case freePlanGenerationAssigned(generation: String, serverCount: Int, reason: String)
    case welcomeCompleted
    case customActionCreated(kind: String)
    case splitPaneCreated
    case reviewPromptRequested
    case analyticsDisabled

    static let maximumStringLength = 128
    static let maximumCount = 1_000_000

    var definition: AnalyticsEventDefinition {
        switch self {
        case .appLaunched(let isPro):
            return .init(name: "app_launched", url: "/app/launch", data: [
                "pro": .bool(isPro)
            ])
        case .connectionSucceeded(let transport):
            return connection(name: "connection_succeeded", transport: transport)
        case .connectionAttempted(let transport):
            return connection(name: "connection_attempted", transport: transport)
        case .connectionReconnecting(let transport):
            return connection(name: "connection_reconnecting", transport: transport)
        case .connectionFailed(let transport, let reason):
            return .init(name: "connection_failed", url: "/app/connection", data: [
                "transport": .string(Self.bounded(transport)),
                "reason": .string(Self.bounded(reason))
            ])
        case .paywallViewed(let source):
            return paywall(name: "paywall_viewed", source: source)
        case .paywallCTATapped(let source, let productID):
            return paywall(name: "paywall_cta_tapped", source: source, productID: productID)
        case .purchaseStarted(let source, let productID):
            return paywall(name: "purchase_started", source: source, productID: productID)
        case .purchaseSucceeded(let source, let productID):
            return paywall(name: "purchase_succeeded", source: source, productID: productID)
        case .purchaseCancelled(let source, let productID):
            return paywall(name: "purchase_cancelled", source: source, productID: productID)
        case .purchasePending(let source, let productID):
            return paywall(name: "purchase_pending", source: source, productID: productID)
        case .purchaseFailed(let source, let productID, let reason):
            var definition = paywall(name: "purchase_failed", source: source, productID: productID)
            definition.data["reason"] = .string(Self.bounded(reason))
            return definition
        case .limitHit(let source, let generation, let current, let limit):
            return .init(name: "limit_hit", url: "/app/limit", data: [
                "source": .string(Self.bounded(source)),
                "generation": .string(Self.bounded(generation)),
                "current": .integer(Self.boundedCount(current)),
                "limit": .integer(Self.boundedCount(limit))
            ])
        case .freePlanGenerationAssigned(let generation, let serverCount, let reason):
            return .init(name: "free_plan_generation_assigned", url: "/app/free-plan", data: [
                "generation": .string(Self.bounded(generation)),
                "server_count": .integer(Self.boundedCount(serverCount)),
                "reason": .string(Self.bounded(reason))
            ])
        case .welcomeCompleted:
            return .init(name: "welcome_completed", url: "/app/welcome")
        case .customActionCreated(let kind):
            return .init(name: "custom_action_created", url: "/app/accessories", data: [
                "kind": .string(Self.bounded(kind))
            ])
        case .splitPaneCreated:
            return .init(name: "split_pane_created", url: "/app/terminal")
        case .reviewPromptRequested:
            return .init(name: "review_prompt_requested", url: "/app/review")
        case .analyticsDisabled:
            return .init(name: "analytics_disabled", url: "/app/settings")
        }
    }

    var name: String { definition.name }

    private func connection(name: String, transport: String) -> AnalyticsEventDefinition {
        .init(name: name, url: "/app/connection", data: [
            "transport": .string(Self.bounded(transport))
        ])
    }

    private func paywall(
        name: String,
        source: String,
        productID: String? = nil
    ) -> AnalyticsEventDefinition {
        var data: [String: JSONValue] = [
            "source": .string(Self.bounded(source))
        ]
        if let productID {
            data["product"] = .string(Self.bounded(productID))
        }
        return .init(name: name, url: "/app/paywall", data: data)
    }

    private static func bounded(_ value: String) -> String {
        String(value.prefix(maximumStringLength))
    }

    private static func boundedCount(_ value: Int) -> Int {
        min(max(value, 0), maximumCount)
    }
}

nonisolated struct AnalyticsEventDefinition: Sendable {
    let name: String
    let url: String
    var data: [String: JSONValue] = [:]
}

nonisolated struct AnalyticsAdmissionController {
    static let deduplicationInterval: TimeInterval = 2
    static let rateLimitWindow: TimeInterval = 60
    static let maximumEventsPerWindow = 60
    static let maximumEventsPerNamePerWindow = 6

    private var windowStart: TimeInterval?
    private var totalCount = 0
    private var countsByName: [String: Int] = [:]
    private var lastEmissionByEvent: [AnalyticsEvent: TimeInterval] = [:]

    static func admitsPersistentLaunch(
        lastEmission: TimeInterval?,
        at timestamp: TimeInterval,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard let lastEmission, timestamp >= lastEmission else { return true }
        return timestamp - lastEmission >= minimumInterval
    }

    mutating func admits(_ event: AnalyticsEvent, at timestamp: TimeInterval) -> Bool {
        resetWindowIfNeeded(at: timestamp)

        if let lastEmission = lastEmissionByEvent[event],
           timestamp >= lastEmission,
           timestamp - lastEmission < Self.deduplicationInterval {
            return false
        }

        guard totalCount < Self.maximumEventsPerWindow else { return false }
        let nameCount = countsByName[event.name, default: 0]
        guard nameCount < Self.maximumEventsPerNamePerWindow else { return false }

        totalCount += 1
        countsByName[event.name] = nameCount + 1
        lastEmissionByEvent[event] = timestamp
        return true
    }

    private mutating func resetWindowIfNeeded(at timestamp: TimeInterval) {
        guard let windowStart,
              timestamp >= windowStart,
              timestamp - windowStart < Self.rateLimitWindow else {
            self.windowStart = timestamp
            totalCount = 0
            countsByName.removeAll(keepingCapacity: true)
            lastEmissionByEvent.removeAll(keepingCapacity: true)
            return
        }
    }
}
