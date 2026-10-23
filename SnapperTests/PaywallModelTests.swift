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
    var subscriptionWillRenew = false
    var plans: [SubscriptionPlan] = []
    var plansState: PlansState = .idle
    var nextOutcome: PurchaseOutcome = .purchased
    /// What the next entitlement check finds, as after an offer code is redeemed.
    var premiumAfterRefresh: Bool?
    /// How many entitlement checks a purchase takes to show up, as on a
    /// device whose store is a moment behind; 0 shows it at once.
    var purchaseShowsAfterRefreshes = 0
    private var latePurchase: (plan: SubscriptionPlan, refreshesLeft: Int)?

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
            if purchaseShowsAfterRefreshes > 0 {
                latePurchase = (plan, purchaseShowsAfterRefreshes)
            } else {
                grant(plan)
            }
        }
        return nextOutcome
    }

    private func grant(_ plan: SubscriptionPlan) {
        isPremium = true
        if plan.period.renews {
            hasActiveSubscription = true
            subscriptionWillRenew = true
        } else {
            ownsLifetime = true
        }
    }

    func restore() async throws -> Bool { isPremium }
    func refreshEntitlements() async {
        if let premiumAfterRefresh { isPremium = premiumAfterRefresh }
        if let late = latePurchase {
            if late.refreshesLeft <= 1 {
                latePurchase = nil
                grant(late.plan)
            } else {
                latePurchase = (late.plan, late.refreshesLeft - 1)
            }
        }
    }
}

final class PaywallModelTests: XCTestCase {
    @MainActor
    private func makeModel(store: FakePurchaseService, context: PaywallContext = .upgrade) -> PaywallModel {
        PaywallModel(context: context, store: store, library: .bundled(), renderer: PhotoRenderer(), photoURL: nil)
    }

    @MainActor
    private func makeSubscriber() -> FakePurchaseService {
        let store = FakePurchaseService()
        store.isPremium = true
        store.hasActiveSubscription = true
        store.subscriptionWillRenew = true
        return store
    }

    /// A subscriber who has turned off auto-renew: still Premium until the
    /// period ends, but nothing will renew.
    @MainActor
    private func makeCancelledSubscriber() -> FakePurchaseService {
        let store = makeSubscriber()
        store.subscriptionWillRenew = false
        return store
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
        XCTAssertFalse(model.showsSubscriptionReminder)
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
    func testSwitchToLifetimeOffersOnlyLifetimePreselected() async {
        let model = makeModel(store: makeSubscriber(), context: .switchToLifetime)
        await model.load()
        XCTAssertTrue(model.offersOnlyLifetime)
        XCTAssertEqual(model.plans.map(\.id), ["lifetime"], "a subscriber isn't offered another subscription")
        XCTAssertEqual(model.selectedPlanID, "lifetime")
        XCTAssertEqual(model.selectedPlan?.period, .lifetime)
        XCTAssertNotEqual(model.title, makeModel(store: makeSubscriber()).title)
    }

    @MainActor
    func testSubscriberBuyingLifetimeIsToldTheSubscriptionKeepsRenewing() async {
        let store = makeSubscriber()
        let model = makeModel(store: store, context: .switchToLifetime)
        await model.load()
        await model.purchase()
        XCTAssertTrue(store.ownsLifetime)
        XCTAssertTrue(store.hasActiveSubscription, "nothing is cancelled automatically")
        XCTAssertTrue(model.showsSubscriptionReminder)
        XCTAssertFalse(model.didUnlock, "the paywall stays open to show the reminder")
        XCTAssertNil(model.alert)
    }

    @MainActor
    func testSubscriberWhoAlreadyCancelledIsNotToldToCancelAgain() async {
        let store = makeCancelledSubscriber()
        let model = makeModel(store: store, context: .switchToLifetime)
        await model.load()
        XCTAssertFalse(model.subscriptionWillRenew, "the switch paywall says the subscription won't renew")
        await model.purchase()
        XCTAssertTrue(store.ownsLifetime)
        XCTAssertTrue(store.hasActiveSubscription, "the cancelled subscription runs to the end of its period")
        XCTAssertFalse(store.ownsLifetimeWithRenewingSubscription)
        XCTAssertFalse(model.showsSubscriptionReminder, "there is nothing left to cancel")
        XCTAssertTrue(model.didUnlock)
        XCTAssertNil(model.alert)
    }

    @MainActor
    func testCancellingAfterLifetimeEndsTheCancelGuidance() async {
        let store = makeSubscriber()
        let model = makeModel(store: store, context: .switchToLifetime)
        await model.load()
        XCTAssertTrue(model.subscriptionWillRenew)
        await model.purchase()
        XCTAssertTrue(store.ownsLifetimeWithRenewingSubscription, "Settings says once where to cancel")

        // The person turns off auto-renew in Manage Subscription.
        store.subscriptionWillRenew = false

        XCTAssertTrue(store.hasActiveSubscription)
        XCTAssertTrue(store.isPremium)
        XCTAssertFalse(store.ownsLifetimeWithRenewingSubscription, "the cancel footer goes away")
    }

    @MainActor
    func testCancelledSwitchChangesNothing() async {
        let store = makeSubscriber()
        store.nextOutcome = .cancelled
        let model = makeModel(store: store, context: .switchToLifetime)
        await model.load()
        await model.purchase()
        XCTAssertFalse(store.ownsLifetime)
        XCTAssertFalse(model.showsSubscriptionReminder)
        XCTAssertFalse(model.didUnlock)
        XCTAssertNil(model.alert)
    }

    @MainActor
    func testRestoringOnlyASubscriptionDoesNotCountAsLifetime() async {
        let store = makeSubscriber()
        let model = makeModel(store: store, context: .switchToLifetime)
        await model.restore()
        XCTAssertFalse(model.didUnlock)
        XCTAssertFalse(model.showsSubscriptionReminder)
        if case .nothingToRestore = model.alert {} else { XCTFail("expected the nothing-to-restore alert") }
    }

    @MainActor
    func testRestoringLifetimeAlongsideASubscriptionShowsTheReminder() async {
        let store = makeSubscriber()
        store.ownsLifetime = true
        let model = makeModel(store: store, context: .switchToLifetime)
        await model.restore()
        XCTAssertTrue(model.showsSubscriptionReminder)
        XCTAssertNil(model.alert)
    }

    @MainActor
    func testRestoringLifetimeAlongsideACancelledSubscriptionJustUnlocks() async {
        let store = makeCancelledSubscriber()
        store.ownsLifetime = true
        let model = makeModel(store: store, context: .switchToLifetime)
        await model.restore()
        XCTAssertFalse(model.showsSubscriptionReminder)
        XCTAssertTrue(model.didUnlock)
        XCTAssertNil(model.alert)
    }

    /// On a device the store can be a moment behind: a purchase that shows up
    /// a few checks later still closes the paywall instead of leaving the
    /// plans on screen.
    @MainActor
    func testPurchaseThatShowsUpLateStillUnlocks() async {
        let store = FakePurchaseService()
        store.purchaseShowsAfterRefreshes = 3
        let model = makeModel(store: store)
        await model.load()
        await model.purchase()
        XCTAssertTrue(store.isPremium)
        XCTAssertTrue(model.didUnlock)
        XCTAssertNil(model.alert)
    }

    /// Yearly first, then Lifetime from the same paywall, with the store
    /// behind: once Lifetime shows, the reminder about the renewing
    /// subscription appears, not a silent close and not the plans again.
    @MainActor
    func testLifetimeShowingUpLateBesideASubscriptionShowsTheReminder() async {
        let store = makeSubscriber()
        store.purchaseShowsAfterRefreshes = 3
        let model = makeModel(store: store)
        await model.load()
        model.selectedPlanID = "lifetime"
        await model.purchase()
        XCTAssertTrue(store.ownsLifetime)
        XCTAssertTrue(model.showsSubscriptionReminder)
        XCTAssertFalse(model.didUnlock)
    }

    /// Premium that arrives while the paywall is open and nothing is being
    /// bought (later than the purchase's own wait, or from Ask to Buy)
    /// closes it; for a subscriber switching to Lifetime, only Lifetime does.
    @MainActor
    func testPremiumArrivingLaterClosesThePaywall() async {
        let store = FakePurchaseService()
        let model = makeModel(store: store)
        await model.load()
        model.entitlementsChanged()
        XCTAssertFalse(model.didUnlock, "nothing has arrived yet")
        store.isPremium = true
        store.hasActiveSubscription = true
        model.entitlementsChanged()
        XCTAssertTrue(model.didUnlock)

        let subscriber = makeCancelledSubscriber()
        let switching = makeModel(store: subscriber, context: .switchToLifetime)
        await switching.load()
        switching.entitlementsChanged()
        XCTAssertFalse(switching.didUnlock, "the subscription alone isn't Lifetime")
        subscriber.ownsLifetime = true
        switching.entitlementsChanged()
        XCTAssertTrue(switching.didUnlock)
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
    func testRedeemedCodeUnlocks() async {
        let store = FakePurchaseService()
        store.premiumAfterRefresh = true
        let model = makeModel(store: store)
        XCTAssertTrue(model.offersCodeRedemption)
        await model.codeRedemptionEnded(.success(()))
        XCTAssertTrue(model.didUnlock)
        XCTAssertNil(model.alert)
    }

    @MainActor
    func testClosingTheCodeSheetWithoutACodeKeepsThePaywall() async {
        let model = makeModel(store: FakePurchaseService())
        await model.codeRedemptionEnded(.success(()))
        XCTAssertFalse(model.didUnlock)
        XCTAssertNil(model.alert, "the sheet already explains a code it couldn't use")
    }

    @MainActor
    func testCodeSheetErrorIsShown() async {
        let model = makeModel(store: FakePurchaseService())
        await model.codeRedemptionEnded(.failure(PurchaseError.network))
        XCTAssertFalse(model.didUnlock)
        if case .error = model.alert {} else { XCTFail("expected the error alert") }
    }

    @MainActor
    func testSubscribersSwitchingToLifetimeAreNotOfferedCodes() async {
        let store = makeSubscriber()
        let model = makeModel(store: store, context: .switchToLifetime)
        XCTAssertFalse(model.offersCodeRedemption)
        await model.codeRedemptionEnded(.success(()))
        XCTAssertFalse(model.didUnlock, "an active subscription isn't a newly redeemed code")
    }

    @MainActor
    func testRestoreWithNothingToRestore() async {
        let model = makeModel(store: FakePurchaseService())
        await model.restore()
        if case .nothingToRestore = model.alert {} else { XCTFail("expected the nothing-to-restore alert") }
    }

    @MainActor
    func testOnboardingOfferLeadsWithTheTrialAndTheNewestCollection() async {
        let model = makeModel(store: FakePurchaseService(), context: .intro)
        await model.load()
        XCTAssertTrue(model.isIntro)
        XCTAssertFalse(makeModel(store: FakePurchaseService()).isIntro)
        XCTAssertEqual(model.selectedPlan?.freeTrial?.shortLabel, "7-Day", "the trial plan is preselected")
        XCTAssertEqual(model.slides.first?.look.collectionID, "digicam")
    }

    @MainActor
    func testFinishingOnboardingOffersPremiumOnceToFreeUsersOnly() throws {
        for isPremium in [false, true] {
            let name = "PaywallModelTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let store = FakePurchaseService()
            store.isPremium = isPremium
            let app = AppModel(store: store, settings: AppSettings(defaults: defaults))
            XCTAssertTrue(app.needsOnboarding)
            app.finishOnboarding()
            XCTAssertFalse(app.needsOnboarding)
            if isPremium {
                XCTAssertNil(app.paywall, "subscribers go straight to the camera")
            } else {
                XCTAssertEqual(app.paywall?.context.id, "intro")
            }
        }
    }
}
