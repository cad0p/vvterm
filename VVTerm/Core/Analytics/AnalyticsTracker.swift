import Foundation
import Umami
#if os(iOS)
import UIKit
#endif

/// Anonymous product analytics sent to the self-hosted Umami instance.
/// Every event is faceless: feature names, counts, and app context only —
/// never commands, server addresses, usernames, or anything identifying.
/// Fully disabled via the "Help Improve VVTerm" toggle in Settings.
@MainActor
final class AnalyticsTracker {
    static let shared = AnalyticsTracker()

    static let enabledKey = "analytics.enabled"

    private static let endpoint = URL(string: "https://analytics.vivy.app")!
    /// Website ID on the shared Umami instance (same one the website uses).
    /// Swap for a dedicated app website ID once created in the dashboard.
    private static let websiteId = "22711a63-9ec0-491c-ad86-71cb0b6ad4dd"

    private let client: UmamiTrackerClient
    private let defaults = UserDefaults.standard
    private var hasTrackedLaunch = false

    private init() {
        client = UmamiTrackerClient(configuration: .init(baseURL: Self.endpoint))
        defaults.register(defaults: [Self.enabledKey: true])
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    // MARK: - Events

    /// Fired once per launch, after the first entitlement check so the tier is accurate.
    func trackAppLaunched(isPro: Bool) {
        guard !hasTrackedLaunch else { return }
        hasTrackedLaunch = true
        send(name: "app_launched", url: "/app/launch", data: ["pro": .string(String(isPro))])
    }

    func trackConnectionSucceeded(transport: String) {
        send(name: "connection_succeeded", url: "/app/connection", data: ["transport": .string(transport)])
    }

    func trackPaywallViewed(source: String) {
        send(name: "paywall_viewed", url: "/app/paywall", data: ["source": .string(source)])
    }

    func trackPaywallCTATapped(source: String, productId: String) {
        send(name: "paywall_cta_tapped", url: "/app/paywall", data: [
            "source": .string(source),
            "product": .string(productId)
        ])
    }

    func trackPurchaseStarted(source: String, productId: String) {
        send(name: "purchase_started", url: "/app/paywall", data: [
            "source": .string(source),
            "product": .string(productId)
        ])
    }

    func trackPurchase(source: String, productId: String) {
        send(name: "purchased", url: "/app/paywall", data: [
            "source": .string(source),
            "product": .string(productId)
        ])
    }

    func trackPurchaseSucceeded(source: String, productId: String) {
        send(name: "purchase_succeeded", url: "/app/paywall", data: [
            "source": .string(source),
            "product": .string(productId)
        ])
    }

    func trackPurchaseCancelled(source: String, productId: String) {
        send(name: "purchase_cancelled", url: "/app/paywall", data: [
            "source": .string(source),
            "product": .string(productId)
        ])
    }

    func trackPurchasePending(source: String, productId: String) {
        send(name: "purchase_pending", url: "/app/paywall", data: [
            "source": .string(source),
            "product": .string(productId)
        ])
    }

    func trackPurchaseFailed(source: String, productId: String, reason: String) {
        send(name: "purchase_failed", url: "/app/paywall", data: [
            "source": .string(source),
            "product": .string(productId),
            "reason": .string(reason)
        ])
    }

    func trackLimitHit(source: String, generation: String, current: Int, limit: Int) {
        send(name: "\(source)_hit", url: "/app/limit", data: [
            "source": .string(source),
            "generation": .string(generation),
            "current": .string(String(current)),
            "limit": .string(String(limit))
        ])
    }

    func trackFreePlanGenerationAssigned(generation: String, serverCount: Int, reason: String) {
        send(name: "free_plan_generation_assigned", url: "/app/free-plan", data: [
            "generation": .string(generation),
            "server_count": .string(String(serverCount)),
            "reason": .string(reason)
        ])
    }

    func trackWelcomeCompleted() {
        send(name: "welcome_completed", url: "/app/welcome")
    }

    func trackCustomActionCreated(kind: String) {
        send(name: "custom_action_created", url: "/app/accessories", data: ["kind": .string(kind)])
    }

    func trackSplitPaneCreated() {
        send(name: "split_pane_created", url: "/app/terminal")
    }

    func trackReviewPromptRequested() {
        send(name: "review_prompt_requested", url: "/app/review")
    }

    func trackAnalyticsDisabled() {
        send(name: "analytics_disabled", url: "/app/settings")
    }

    // MARK: - Transport

    private func send(name: String, url: String, data: [String: JSONValue] = [:]) {
        guard isEnabled else { return }
        var payload = data
        payload["platform"] = .string(Self.platform)
        payload["version"] = .string(Self.appVersion)
        let event = TrackEventRequest(
            source: .website(Self.websiteId),
            data: payload,
            title: "VVTerm App",
            url: url,
            name: name
        )
        Task.detached(priority: .utility) { [client] in
            _ = try? await client.track(event)
        }
    }

    private static let platform: String = {
        #if os(macOS)
        return "macos"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }()

    private static let appVersion: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
}
