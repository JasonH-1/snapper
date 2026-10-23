import Foundation
import OSLog
import StoreKit

/// StoreKit 2 implementation of `PurchaseService`. The App Store (via the
/// person's Apple ID) is the only source of truth: no accounts, no server.
@MainActor
@Observable
final class StoreKitPurchaseService: PurchaseService {
    private(set) var isPremium: Bool {
        didSet { UserDefaults.standard.set(isPremium, forKey: Self.cacheKey) }
    }
    private(set) var ownsLifetime = false
    private(set) var hasActiveSubscription = false
    private(set) var subscriptionWillRenew = false
    private(set) var plans: [SubscriptionPlan] = []
    private(set) var plansState: PlansState = .idle

    @ObservationIgnored private var products: [String: Product] = [:]
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var statusUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private let productIDs: [String]

    /// Last known entitlement, so the UI is right at launch before StoreKit
    /// answers. StoreKit's verified entitlements always win.
    private static let cacheKey = "store.cachedPremium"

    init(productIDs: [String] = AppConfig.premiumProductIDs) {
        self.productIDs = productIDs
        isPremium = UserDefaults.standard.bool(forKey: Self.cacheKey)
    }

    func start() {
        guard updatesTask == nil else { return }
        // Renewals, refunds, Ask to Buy approvals and purchases made on other
        // devices arrive here.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.process(update)
            }
        }
        // Turning auto-renew off or back on changes only the renewal info,
        // which arrives here rather than as a transaction.
        statusUpdatesTask = Task { [weak self] in
            for await _ in Product.SubscriptionInfo.Status.updates {
                await self?.refreshEntitlements()
            }
        }
        Task { await refreshEntitlements() }
    }

    // MARK: - Plans

    func loadPlans() async {
        guard plansState != .loading else { return }
        if plansState == .loaded, !plans.isEmpty { return }
        plansState = .loading
        do {
            let storeProducts = try await Product.products(for: productIDs)
            var loaded: [SubscriptionPlan] = []
            for product in storeProducts {
                if let plan = await makePlan(from: product) {
                    loaded.append(plan)
                }
            }
            // Yearly first, then by price (monthly, then lifetime).
            loaded.sort { lhs, rhs in
                if (lhs.period == .year) != (rhs.period == .year) { return lhs.period == .year }
                return lhs.price < rhs.price
            }
            guard !loaded.isEmpty else {
                plansState = .failed(PurchaseError.productsUnavailable.localizedDescription)
                return
            }
            products = Dictionary(uniqueKeysWithValues: storeProducts.map { ($0.id, $0) })
            plans = loaded
            plansState = .loaded
        } catch {
            Logger.store.error("Loading products failed: \(error.localizedDescription, privacy: .public)")
            plansState = .failed(PurchaseError.network.localizedDescription)
        }
    }

    private func makePlan(from product: Product) async -> SubscriptionPlan? {
        guard let subscription = product.subscription else {
            guard product.type == .nonConsumable else { return nil }
            return SubscriptionPlan(id: product.id,
                                    displayName: product.displayName,
                                    displayPrice: product.displayPrice,
                                    price: product.price,
                                    period: .lifetime,
                                    freeTrial: nil,
                                    monthlyEquivalent: nil)
        }
        let period = Self.period(of: subscription.subscriptionPeriod)
        var trial: SubscriptionPlan.FreeTrial?
        if let offer = subscription.introductoryOffer,
           offer.paymentMode == .freeTrial,
           await subscription.isEligibleForIntroOffer {
            trial = Self.trialDescription(offer.period)
        }
        var monthly: String?
        if period == .year {
            monthly = (product.price / 12).formatted(product.priceFormatStyle)
        }
        return SubscriptionPlan(id: product.id,
                                displayName: product.displayName,
                                displayPrice: product.displayPrice,
                                price: product.price,
                                period: period,
                                freeTrial: trial,
                                monthlyEquivalent: monthly)
    }

    private static func period(of period: Product.SubscriptionPeriod) -> SubscriptionPlan.Period {
        switch period.unit {
        case .year: return .year
        case .week: return .week
        case .day: return period.value >= 7 ? .week : .month
        default: return period.value >= 12 ? .year : .month
        }
    }

    private static func trialDescription(_ period: Product.SubscriptionPeriod) -> SubscriptionPlan.FreeTrial {
        let days: Int
        switch period.unit {
        case .day: days = period.value
        case .week: days = period.value * 7
        case .month: days = period.value * 30
        case .year: days = period.value * 365
        @unknown default: days = period.value
        }
        if period.unit == .month {
            return SubscriptionPlan.FreeTrial(duration: String(localized: "\(period.value) month"),
                                              shortLabel: String(localized: "\(period.value)-Month"))
        }
        return SubscriptionPlan.FreeTrial(duration: String(localized: "\(days) days"),
                                          shortLabel: String(localized: "\(days)-Day"))
    }

    // MARK: - Purchasing

    func purchase(_ plan: SubscriptionPlan) async throws -> PurchaseOutcome {
        guard let product = products[plan.id] else { throw PurchaseError.productsUnavailable }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch let error as StoreKitError {
            switch error {
            case .userCancelled:
                return .cancelled
            case .networkError:
                throw PurchaseError.network
            default:
                throw PurchaseError.failed(error.localizedDescription)
            }
        } catch {
            throw PurchaseError.failed(error.localizedDescription)
        }

        switch result {
        case .success(let verification):
            guard let transaction = Self.verified(verification, from: "Purchase") else {
                throw PurchaseError.verificationFailed
            }
            await transaction.finish()
            await refreshEntitlements()
            return .purchased
        case .pending:
            Logger.store.notice("Purchase of \(plan.id, privacy: .public) is pending")
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws -> Bool {
        do {
            try await AppStore.sync()
        } catch let error as StoreKitError {
            if case .userCancelled = error { return isPremium }
            // Offline: fall back to the transactions StoreKit has cached on device.
            await refreshEntitlements()
            if isPremium { return true }
            if case .networkError = error { throw PurchaseError.network }
            throw PurchaseError.failed(error.localizedDescription)
        } catch {
            await refreshEntitlements()
            if isPremium { return true }
            throw PurchaseError.network
        }
        await refreshEntitlements()
        return isPremium
    }

    // MARK: - Entitlements

    /// Premium is active while Lifetime is owned or a subscription is current.
    /// Lifetime has no expiry, so only a refund (revocation) takes it away.
    func refreshEntitlements() async {
        var owned: [UInt64: Transaction] = [:]
        // currentEntitlements includes expired transactions during an active
        // billing grace period. StoreKit determines access, not this date.
        for await result in Transaction.currentEntitlements {
            if let transaction = Self.verified(result, from: "Entitlement") {
                owned[transaction.id] = transaction
            }
        }
        // On an iPhone running a build from Xcode, currentEntitlements came
        // back empty for every purchase, even a new one with no refunds, while
        // each product's latest transaction showed it. So each product's
        // latest purchase also counts until it expires.
        for productID in productIDs {
            guard let result = await Transaction.latest(for: productID),
                  let transaction = Self.verified(result, from: "Latest"),
                  transaction.expirationDate.map({ $0 > .now }) ?? true else { continue }
            owned[transaction.id] = transaction
        }

        var lifetime = false
        var subscribed = false
        var renews = false
        for transaction in owned.values {
            guard productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  !transaction.isUpgraded else { continue }
            if transaction.productType == .nonConsumable {
                lifetime = true
                continue
            }
            subscribed = true
            if await Self.willRenew(transaction) { renews = true }
        }
        if ownsLifetime != lifetime { ownsLifetime = lifetime }
        if hasActiveSubscription != subscribed { hasActiveSubscription = subscribed }
        if subscriptionWillRenew != renews { subscriptionWillRenew = renews }
        let active = lifetime || subscribed
        Logger.store.info("Entitlements: lifetime \(lifetime), subscription \(subscribed), renews \(renews)")
        if isPremium != active {
            isPremium = active
        }
    }

    /// Whether the subscription behind `transaction` is set to renew, from its
    /// group's renewal info. If that can't be read, assume it renews, so the
    /// person still hears how to cancel it.
    private static func willRenew(_ transaction: Transaction) async -> Bool {
        guard let status = await transaction.subscriptionStatus,
              case .verified(let renewal) = status.renewalInfo else { return true }
        return renewal.willAutoRenew
    }

    private func process(_ update: VerificationResult<Transaction>) async {
        guard let transaction = Self.verified(update, from: "Update") else { return }
        await transaction.finish()
        await refreshEntitlements()
    }

    /// The transaction if StoreKit verified it. Logs it either way, saying
    /// where it came from.
    private static func verified(_ result: VerificationResult<Transaction>, from source: String) -> Transaction? {
        switch result {
        case .verified(let transaction):
            Logger.store.info("\(source, privacy: .public) \(transaction.productID, privacy: .public) (\(describe(transaction), privacy: .public))")
            return transaction
        case .unverified(let transaction, let error):
            Logger.store.error("\(source, privacy: .public) \(transaction.productID, privacy: .public) failed verification: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// What the logs need to tell a missing entitlement apart: which store
    /// signed it, and whether it was refunded or has run out.
    private static func describe(_ transaction: Transaction) -> String {
        var parts = ["id \(transaction.id)", "environment \(transaction.environment.rawValue)"]
        if let revoked = transaction.revocationDate { parts.append("refunded \(revoked.formatted())") }
        if let expires = transaction.expirationDate { parts.append("expires \(expires.formatted())") }
        return parts.joined(separator: ", ")
    }
}
