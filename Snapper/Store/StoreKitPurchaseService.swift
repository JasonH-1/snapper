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
    private(set) var plans: [SubscriptionPlan] = []
    private(set) var plansState: PlansState = .idle

    @ObservationIgnored private var products: [String: Product] = [:]
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private let productIDs: [String]

    /// Last known entitlement, so the UI is right at launch before StoreKit
    /// answers. StoreKit's verified entitlements always win.
    private static let cacheKey = "store.cachedPremium"

    init(productIDs: [String] = AppConfig.subscriptionProductIDs) {
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
            // Yearly first, then by price.
            loaded.sort { lhs, rhs in
                if lhs.period != rhs.period { return lhs.period == .year }
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
        guard let subscription = product.subscription else { return nil }
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
            guard case .verified(let transaction) = verification else {
                throw PurchaseError.verificationFailed
            }
            await transaction.finish()
            await refreshEntitlements()
            return .purchased
        case .pending:
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

    func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let expiration = transaction.expirationDate, expiration < Date() { continue }
            active = true
        }
        if isPremium != active {
            isPremium = active
        }
    }

    private func process(_ update: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = update else { return }
        await transaction.finish()
        await refreshEntitlements()
    }
}
