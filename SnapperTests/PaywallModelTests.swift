import Observation
import XCTest
@testable import Snapper

/// A purchase backend that never talks to the App Store.
@MainActor
@Observable
final class FakePurchaseService: PurchaseService {
    var isPremium = false
    var ownsLifetime = false
    var hasActiveSubscription = false
    var plans: [SubscriptionPlan] = []
    var plansState: PlansState = .idle
    var nextOutcome: PurchaseOutcome = .purchased

    func start() {}

    func loadPlans() async {
        plans = [
            SubscriptionPlan(id: "yearly", displayName: "Yearly", displayPrice: "$19.99", price: Decimal(string: "19.99")!,
                             period: .year, freeTrial: .init(duration: "7 days", shortLabel: "7-Day"), monthlyEquivalent: "$1.67"),
            SubscriptionPlan(id: "monthly", displayName: "Monthly", displayPrice: "$3.99", price: Decimal(string: "3.99")!,
                             period: .month, freeTrial: nil, monthlyEquivalent: nil),
            SubscriptionPlan(id: "lifetime", displayName: "Lifetime", displayPrice: "$39.99", price: Decimal(string: "39.99")!,
                             period: .lifetime, freeTrial: nil, monthlyEquivalent: nil),
        ]
        plansState = .loaded
    }

    func purchase(_ plan: SubscriptionPlan) async throws -> PurchaseOutcome {
        if nextOutcome == .purchased {
            isPremium = true
            if plan.period.renews { hasActiveSubscription = true } else { ownsLifetime = true }
        }
        return nextOutcome
    }

    func restore() async throws -> Bool { isPremium }
    func refreshEntitlements() async {}
}

final class PaywallModelTests: XCTestCase {
    @MainActor
    private func makeModel(store: FakePurchaseService) -> PaywallModel {
        PaywallModel(context: .upgrade, store: store, library: .bundled(), renderer: PhotoRenderer(), photoURL: nil)
    }

    @MainActor
    func testDefaultsToYearlyAndComputesSavings() async {
        let store = FakePurchaseService()
        let model = makeModel(store: store)
        await model.load()
        XCTAssertEqual(model.selectedPlan?.id, "yearly", "yearly stays preselected next to lifetime")
        XCTAssertEqual(model.plans.map(\.id), ["yearly", "monthly", "lifetime"])
        // 19.99 vs 12 × 3.99 = 47.88 → 58% saved.
        XCTAssertEqual(model.yearlySavingsPercent, 58)
        XCTAssertFalse(model.slides.isEmpty, "showcase slides render from bundled photos")
    }

    @MainActor
    func testPurchaseUnlocks() async {
        let store = FakePurchaseService()
        let model = makeModel(store: store)
        await model.load()
        await model.purchase()
        XCTAssertTrue(model.didUnlock)
        XCTAssertNil(model.alert)
    }

    @MainActor
    func testLifetimePurchaseUnlocksWithoutASubscription() async throws {
        let store = FakePurchaseService()
        let model = makeModel(store: store)
        await model.load()
        let lifetime = try XCTUnwrap(model.plans.first { $0.period == .lifetime })
        XCTAssertFalse(lifetime.period.renews)
        XCTAssertNil(lifetime.freeTrial)
        model.selectedPlanID = lifetime.id
        await model.purchase()
        XCTAssertTrue(model.didUnlock)
        XCTAssertTrue(store.ownsLifetime)
        XCTAssertFalse(store.hasActiveSubscription)
    }

    @MainActor
    func testPendingPurchaseExplainsItself() async {
        let store = FakePurchaseService()
        store.nextOutcome = .pending
        let model = makeModel(store: store)
        await model.load()
        await model.purchase()
        XCTAssertFalse(model.didUnlock)
        if case .pending = model.alert {} else { XCTFail("expected the pending alert") }
    }

    @MainActor
    func testRestoreWithNothingToRestore() async {
        let model = makeModel(store: FakePurchaseService())
        await model.restore()
        if case .nothingToRestore = model.alert {} else { XCTFail("expected the nothing-to-restore alert") }
    }
}
