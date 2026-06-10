import Foundation
import Combine

/// Tracks lightweight usage signals (successful connections, distinct usage days)
/// and decides when to surface the one-time Pro intro and App Store review requests.
/// All signals stay on-device in UserDefaults.
@MainActor
final class EngagementTracker: ObservableObject {
    static let shared = EngagementTracker()

    /// Drives the one-time post-first-connection Pro intro presentation.
    @Published var shouldShowProIntro = false
    /// Incremented when a root view should call the system review request action.
    @Published private(set) var reviewRequestToken = 0

    private enum Keys {
        static let successfulConnectionCount = "engagement.successfulConnectionCount"
        static let usageDayCount = "engagement.usageDayCount"
        static let lastUsageDay = "engagement.lastUsageDay"
        static let hasShownProIntro = "engagement.hasShownProIntro"
        static let lastReviewRequest = "engagement.lastReviewRequest"
    }

    private static let reviewMinimumConnections = 3
    private static let reviewMinimumUsageDays = 2
    private static let reviewCooldown: TimeInterval = 60 * 60 * 24 * 60
    private static let proIntroPresentationDelay: TimeInterval = 0.6

    private let defaults = UserDefaults.standard
    private var connectionsCountedThisLaunch: Set<UUID> = []
    private var paywallPresentedThisLaunch = false
    private var proIntroScheduled = false

    private init() {}

    var successfulConnectionCount: Int {
        defaults.integer(forKey: Keys.successfulConnectionCount)
    }

    private var usageDayCount: Int {
        defaults.integer(forKey: Keys.usageDayCount)
    }

    private var hasShownProIntro: Bool {
        defaults.bool(forKey: Keys.hasShownProIntro)
    }

    // MARK: - Signals

    /// Counts a session or pane that reached a connected state, once per launch per id,
    /// so reconnect cycles within a launch do not inflate the totals.
    func recordSuccessfulConnection(id: UUID, transport: String) {
        guard !connectionsCountedThisLaunch.contains(id) else { return }
        connectionsCountedThisLaunch.insert(id)
        AnalyticsTracker.shared.trackConnectionSucceeded(transport: transport)
        defaults.set(successfulConnectionCount + 1, forKey: Keys.successfulConnectionCount)

        let today = Calendar.current.startOfDay(for: Date())
        let lastDay = (defaults.object(forKey: Keys.lastUsageDay) as? Date).map {
            Calendar.current.startOfDay(for: $0)
        }
        if lastDay != today {
            defaults.set(today, forKey: Keys.lastUsageDay)
            defaults.set(usageDayCount + 1, forKey: Keys.usageDayCount)
        }
    }

    /// Called when the user leaves a terminal context: a tab closes, the shell exits,
    /// or (iOS) navigation returns to the server list. Never called over a live terminal.
    func noteTerminalSessionEnded(otherTerminalsActive: Bool, isPro: Bool) {
        guard !otherTerminalsActive else { return }
        // Failed or Pro-blocked open attempts also land here (back-nav, closing a
        // failed tab). Only act in launches where a connection actually succeeded,
        // so prompts never follow a failure.
        guard !connectionsCountedThisLaunch.isEmpty else { return }

        if !isPro, !hasShownProIntro, successfulConnectionCount >= 1 {
            // If another paywall already appeared this launch, skip without
            // consuming the one shot — the intro fires on a later session end.
            if !paywallPresentedThisLaunch {
                scheduleProIntro()
            }
            return
        }

        maybeRequestReview()
    }

    /// Review requests stay quiet for the rest of a launch where any paywall appeared,
    /// so the two asks never stack.
    func notePaywallPresented() {
        paywallPresentedThisLaunch = true
    }

    /// The persisted one-shot flag is set when the intro actually appears, so a
    /// presentation lost to app termination does not consume the only opportunity.
    func markProIntroShown() {
        defaults.set(true, forKey: Keys.hasShownProIntro)
    }

    func requestReviewAfterPurchase() {
        fireReviewRequestIfOutsideCooldown()
    }

    // MARK: - Decisions

    private func scheduleProIntro() {
        guard !proIntroScheduled, !shouldShowProIntro else { return }
        proIntroScheduled = true
        // Delay past the navigation transition so sheet presentation is not dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.proIntroPresentationDelay) { [weak self] in
            self?.proIntroScheduled = false
            self?.shouldShowProIntro = true
        }
    }

    private func maybeRequestReview() {
        guard !paywallPresentedThisLaunch else { return }
        guard successfulConnectionCount >= Self.reviewMinimumConnections,
              usageDayCount >= Self.reviewMinimumUsageDays else { return }
        fireReviewRequestIfOutsideCooldown()
    }

    private func fireReviewRequestIfOutsideCooldown() {
        if let last = defaults.object(forKey: Keys.lastReviewRequest) as? Date,
           Date().timeIntervalSince(last) < Self.reviewCooldown {
            return
        }
        defaults.set(Date(), forKey: Keys.lastReviewRequest)
        AnalyticsTracker.shared.trackReviewPromptRequested()
        reviewRequestToken += 1
    }
}
