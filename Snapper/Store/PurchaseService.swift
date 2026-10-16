import Foundation
import Observation

/// A subscription plan as the app presents it. Deliberately free of StoreKit
/// types so another purchase backend (e.g. RevenueCat) can supply plans too.
struct SubscriptionPlan: Identifiable, Hashable, Sendable {
    enum Period: Sendable, Hashable {
        case week, month, year

        var unitName: String {
            switch self {
            case .week: String(localized: "week")
            case .month: String(localized: "month")
            case .year: String(localized: "year")
            }
        }

        var adjective: String {
            switch self {
            case .week: String(localized: "Weekly")
            case .month: String(localized: "Monthly")
            case .year: String(localized: "Yearly")
            }
        }
    }

    struct FreeTrial: Sendable, Hashable {
        /// e.g. "1 week" / "7 days".
        let duration: String
        /// e.g. "7-day" for button copy.
        let shortLabel: String
    }

    let id: String
    let displayName: String
    /// Localized price string from the store, e.g. "$19.99".
    let displayPrice: String
    let price: Decimal
    let period: Period
    /// Present only when the person is eligible for the trial.
    let freeTrial: FreeTrial?
    /// Price per month for yearly plans, formatted in the store's currency.
    let monthlyEquivalent: String?
}

enum PurchaseOutcome: Sendable, Equatable {
    case purchased
    case pending
    case cancelled
}

enum PurchaseError: LocalizedError, Equatable {
    case productsUnavailable
    case verificationFailed
    case network
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .productsUnavailable:
            String(localized: "Subscriptions aren't available right now. Please try again later.")
        case .verificationFailed:
            String(localized: "The purchase couldn't be verified. You haven't been charged twice; try Restore Purchases.")
        case .network:
            String(localized: "Couldn't reach the App Store. Check your connection and try again.")
        case .failed(let reason):
            reason
        }
    }
}

enum PlansState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// Everything the app needs from a purchase backend. All purchase code lives
/// behind this protocol: StoreKit 2 today (`StoreKitPurchaseService`), any
/// other SDK tomorrow without touching the UI.
@MainActor
protocol PurchaseService: AnyObject, Observable {
    /// Whether Premium is active (including during a free trial or grace period).
    var isPremium: Bool { get }
    var plans: [SubscriptionPlan] { get }
    var plansState: PlansState { get }

    /// Begins listening for transactions; call once at launch.
    func start()
    func loadPlans() async
    func purchase(_ plan: SubscriptionPlan) async throws -> PurchaseOutcome
    /// Syncs with the App Store. Returns whether Premium is active afterwards.
    func restore() async throws -> Bool
    func refreshEntitlements() async
}
