import StoreKit
import Foundation
import Combine
import os.log

// MARK: - Store Manager

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()
    static let reviewModeCode = ReviewModeCode.value

    @Published var isPro: Bool = false
    @Published var isLifetime: Bool = false
    @Published var subscriptionStatus: Product.SubscriptionInfo.Status?
    @Published var products: [Product] = []
    @Published var purchaseState: PurchaseState = .idle
    @Published var restoreState: RestoreState = .idle
    @Published private(set) var isReviewModeEnabled: Bool = false
    @Published private(set) var lastPurchasedProductId: String?
    private(set) var activePaywallSource: PaywallSource = .general
    private(set) var hasPresentedPaywallThisLaunch = false

    private var updateListenerTask: Task<Void, Error>?
    private var reviewModeExpiryTask: Task<Void, Never>?
    private var reviewModeExpiresAt: Date?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Store")
    private let reviewModeDuration: TimeInterval = 60 * 60 * 5

    // MARK: - Sorted Products

    var monthlyProduct: Product? {
        products.first { $0.id == VVTermProducts.proMonthly }
    }

    var yearlyProduct: Product? {
        products.first { $0.id == VVTermProducts.proYearly }
    }

    var lifetimeProduct: Product? {
        products.first { $0.id == VVTermProducts.proLifetime }
    }

    // MARK: - Initialization

    private init() {
        updateListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            await checkEntitlements()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        let maxRetries = 3
        for attempt in 0..<maxRetries {
            do {
                products = try await Product.products(for: VVTermProducts.allProducts)
                logger.info("Loaded \(self.products.count) products")
                return
            } catch {
                logger.error("Failed to load products (attempt \(attempt + 1)/\(maxRetries)): \(error.localizedDescription)")
                if attempt < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                }
            }
        }
    }

    // MARK: - Paywall Presentation

    func notePaywallPresented(source: PaywallSource) {
        activePaywallSource = source
        hasPresentedPaywallThisLaunch = true
        EngagementTracker.shared.notePaywallPresented()
        AnalyticsTracker.shared.trackPaywallViewed(source: source.rawValue)
    }

    func notePaywallCTATapped(product: Product) {
        AnalyticsTracker.shared.trackPaywallCTATapped(
            source: activePaywallSource.rawValue,
            productId: product.id
        )
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        purchaseState = .purchasing
        lastPurchasedProductId = nil
        AnalyticsTracker.shared.trackPurchaseStarted(
            source: activePaywallSource.rawValue,
            productId: product.id
        )
        logger.info("Purchasing \(product.id)")

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await checkEntitlements()
                applySuccessfulPurchase(of: product)

            case .userCancelled:
                AnalyticsTracker.shared.trackPurchaseCancelled(
                    source: activePaywallSource.rawValue,
                    productId: product.id
                )
                applyIdlePurchaseState(logMessage: "Purchase cancelled by user")

            case .pending:
                AnalyticsTracker.shared.trackPurchasePending(
                    source: activePaywallSource.rawValue,
                    productId: product.id
                )
                applyIdlePurchaseState(logMessage: "Purchase pending")

            @unknown default:
                purchaseState = .idle
            }
        } catch {
            AnalyticsTracker.shared.trackPurchaseFailed(
                source: activePaywallSource.rawValue,
                productId: product.id,
                reason: String(describing: type(of: error))
            )
            purchaseState = .failed(error.localizedDescription)
            logger.error("Purchase failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Restore Purchases

    func restorePurchases() async {
        restoreState = .restoring
        logger.info("Restoring purchases")
        do {
            try await AppStore.sync()
            await checkEntitlements()
            applyRestoreResult(hasAccess: isPro)
        } catch {
            restoreState = .failed(error.localizedDescription)
            logger.error("Failed to restore purchases: \(error.localizedDescription)")
        }
    }

    // MARK: - Check Entitlements

    func checkEntitlements() async {
        refreshReviewModeState()
        var hasAccess = false
        var hasLifetime = false

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                switch transaction.productID {
                case VVTermProducts.proMonthly,
                     VVTermProducts.proYearly:
                    hasAccess = true
                case VVTermProducts.proLifetime:
                    hasAccess = true
                    hasLifetime = true
                default:
                    break
                }
            }
        }

        // Check subscription status for billing retry / grace period
        var activeStatus: Product.SubscriptionInfo.Status?
        if let product = monthlyProduct ?? yearlyProduct,
           let statuses = try? await product.subscription?.status {
            activeStatus = statuses.first {
                $0.state == .subscribed || $0.state == .inGracePeriod
            } ?? statuses.first

            if !hasAccess {
                for status in statuses {
                    if case .verified = status.transaction,
                       status.state == .inBillingRetryPeriod || status.state == .inGracePeriod {
                        hasAccess = true
                        break
                    }
                }
            }
        }

        applyEntitlements(hasAccess: hasAccess, hasLifetime: hasLifetime, status: activeStatus)
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await self.checkEntitlements()
                    await transaction.finish()
                }
            }
        }
    }

    // MARK: - Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(let unverifiedValue, let verificationError):
            if let transaction = unverifiedValue as? Transaction {
                logger.error(
                    """
                    StoreKit transaction verification failed for product \
                    \(transaction.productID, privacy: .public), transaction \
                    \(String(transaction.id), privacy: .public): \
                    \(String(describing: verificationError), privacy: .public)
                    """
                )
            } else {
                logger.error(
                    """
                    StoreKit verification failed for \
                    \(String(describing: T.self), privacy: .public): \
                    \(String(describing: verificationError), privacy: .public)
                    """
                )
            }
            throw StoreError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Subscription Info

    var subscriptionExpirationDate: Date? {
        guard let status = subscriptionStatus else { return nil }
        guard case .verified(let transaction) = status.transaction else { return nil }
        return transaction.expirationDate
    }

    var isSubscriptionActive: Bool {
        guard let status = subscriptionStatus else { return isLifetime }
        return status.state == .subscribed || status.state == .inGracePeriod
    }

    var hasActiveSubscriptionWithLifetime: Bool {
        guard isLifetime, let status = subscriptionStatus else { return false }
        return status.state == .subscribed || status.state == .inGracePeriod
    }

    // MARK: - Review Mode

    @discardableResult
    func enableReviewMode(code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.caseInsensitiveCompare(Self.reviewModeCode) == .orderedSame else {
            logger.warning("Review mode activation failed (invalid code)")
            return false
        }
        setReviewModeEnabled(true)
        return true
    }

    func setReviewModeEnabled(_ enabled: Bool) {
        guard isReviewModeEnabled != enabled else { return }
        isReviewModeEnabled = enabled

        if enabled {
            isPro = true
            isLifetime = false
            subscriptionStatus = nil
            reviewModeExpiresAt = Date().addingTimeInterval(reviewModeDuration)
            scheduleReviewModeExpiry()
            logger.info("Review mode enabled")
        } else {
            reviewModeExpiresAt = nil
            reviewModeExpiryTask?.cancel()
            reviewModeExpiryTask = nil
            logger.info("Review mode disabled")
            Task { await checkEntitlements() }
        }
    }

    private func scheduleReviewModeExpiry() {
        reviewModeExpiryTask?.cancel()
        guard let expiresAt = reviewModeExpiresAt else { return }
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        reviewModeExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                self?.refreshReviewModeState()
            }
        }
    }

    private func refreshReviewModeState() {
        guard isReviewModeEnabled else { return }
        if let expiresAt = reviewModeExpiresAt, Date() >= expiresAt {
            setReviewModeEnabled(false)
        }
    }

    private func applySuccessfulPurchase(of product: Product) {
        lastPurchasedProductId = product.id
        purchaseState = .purchased
        AnalyticsTracker.shared.trackPurchase(
            source: activePaywallSource.rawValue,
            productId: product.id
        )
        AnalyticsTracker.shared.trackPurchaseSucceeded(
            source: activePaywallSource.rawValue,
            productId: product.id
        )
        logger.info("Purchase successful: \(product.id)")
    }

    private func applyIdlePurchaseState(logMessage: String) {
        purchaseState = .idle
        logger.info("\(logMessage)")
    }

    private func applyRestoreResult(hasAccess: Bool) {
        restoreState = .restored(hasAccess: hasAccess)
        logger.info("Purchases restored")
    }

    private func applyEntitlements(
        hasAccess: Bool,
        hasLifetime: Bool,
        status: Product.SubscriptionInfo.Status?
    ) {
        isPro = hasAccess || isReviewModeEnabled
        isLifetime = hasLifetime
        subscriptionStatus = status
        AnalyticsTracker.shared.trackAppLaunched(isPro: isPro)
        logger.info("Entitlements checked: isPro=\(hasAccess), isLifetime=\(hasLifetime), reviewMode=\(self.isReviewModeEnabled)")
    }
}
