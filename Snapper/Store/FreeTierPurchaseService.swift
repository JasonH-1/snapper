import Foundation
import Observation

/// Placeholder backend with no products: everyone is on the free tier.
@MainActor
@Observable
final class FreeTierPurchaseService: PurchaseService {
    private(set) var isPremium = false
    private(set) var plans: [SubscriptionPlan] = []
    private(set) var plansState: PlansState = .idle

    func start() {}
    func loadPlans() async { plansState = .failed(PurchaseError.productsUnavailable.localizedDescription) }
    func purchase(_ plan: SubscriptionPlan) async throws -> PurchaseOutcome { throw PurchaseError.productsUnavailable }
    func restore() async throws -> Bool { false }
    func refreshEntitlements() async {}
}
