import StoreKit
import StoreKitTest
import XCTest
@testable import Snapper

/// Exercises the StoreKit 2 service against `Config/Snapper.storekit`, so the
/// local configuration and the purchase code are checked together.
final class StoreKitPurchaseServiceTests: XCTestCase {
    private func makeSession() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "Snapper")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        UserDefaults.standard.removeObject(forKey: "store.cachedPremium")
        return session
    }

    /// Hosted CI runners can't configure StoreKit's test daemon; there the
    /// workflow sets this flag and these tests skip instead of failing.
    @MainActor
    private func skipIfStoreKitTestingUnavailable(_ service: StoreKitPurchaseService) throws {
        guard service.plans.isEmpty,
              ProcessInfo.processInfo.environment["SNAPPER_SKIP_STOREKIT_INTEGRATION"] == "1" else { return }
        throw XCTSkip("StoreKit testing is unavailable on this runner; run these tests from Xcode.")
    }

    /// SKTestSession applies a change a moment after the call returns, so wait
    /// up to ten seconds for the service to see it, refreshing if asked to.
    @MainActor
    private func wait(for service: StoreKitPurchaseService, refreshing: Bool = false,
                      until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while true {
            if refreshing { await service.refreshEntitlements() }
            if condition() || Date() >= deadline { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    func testLoadsYearlyFirstWithFreeTrial() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let service = StoreKitPurchaseService()
        await service.loadPlans()
        try skipIfStoreKitTestingUnavailable(service)

        XCTAssertEqual(service.plansState, .loaded)
        XCTAssertEqual(service.plans.map(\.id),
                       [AppConfig.yearlyProductID, AppConfig.monthlyProductID, AppConfig.lifetimeProductID])
        let yearly = try XCTUnwrap(service.plans.first)
        XCTAssertEqual(yearly.period, .year)
        XCTAssertNotNil(yearly.freeTrial, "yearly plan advertises the free trial to eligible people")
        XCTAssertNotNil(yearly.monthlyEquivalent)
        XCTAssertNil(service.plans.last?.freeTrial)
        XCTAssertEqual(service.plans.last?.period, .lifetime)
        XCTAssertFalse(service.isPremium)
    }

    @MainActor
    func testLifetimePurchaseUnlocksPremiumAndRestores() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let service = StoreKitPurchaseService()
        await service.loadPlans()
        try skipIfStoreKitTestingUnavailable(service)
        let lifetime = try XCTUnwrap(service.plans.first { $0.period == .lifetime })
        XCTAssertNil(lifetime.freeTrial)

        let outcome = try await service.purchase(lifetime)

        XCTAssertEqual(outcome, .purchased)
        XCTAssertTrue(service.isPremium)
        XCTAssertTrue(service.ownsLifetime)
        XCTAssertFalse(service.hasActiveSubscription)
        XCTAssertFalse(service.subscriptionWillRenew, "Lifetime never renews")

        // A fresh install with no cached state gets it back from Restore.
        UserDefaults.standard.removeObject(forKey: "store.cachedPremium")
        let reinstalled = StoreKitPurchaseService()
        XCTAssertFalse(reinstalled.isPremium)
        let restored = try await reinstalled.restore()
        XCTAssertTrue(restored)
        XCTAssertTrue(reinstalled.ownsLifetime)
    }

    @MainActor
    func testPurchaseUnlocksPremium() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let service = StoreKitPurchaseService()
        await service.loadPlans()
        try skipIfStoreKitTestingUnavailable(service)
        let monthly = try XCTUnwrap(service.plans.first { $0.period == .month })

        let outcome = try await service.purchase(monthly)

        XCTAssertEqual(outcome, .purchased)
        XCTAssertTrue(service.isPremium)
        XCTAssertTrue(service.hasActiveSubscription)
        XCTAssertTrue(service.subscriptionWillRenew)
    }

    /// Someone who owns Lifetime and turns off auto-renew keeps the
    /// subscription until it ends, but nothing will renew, so the app stops
    /// pointing them at Manage Subscription.
    @MainActor
    func testTurningOffAutoRenewEndsRenewalButNotTheSubscription() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let service = StoreKitPurchaseService()
        await service.loadPlans()
        try skipIfStoreKitTestingUnavailable(service)
        let monthly = try XCTUnwrap(service.plans.first { $0.period == .month })
        let lifetime = try XCTUnwrap(service.plans.first { $0.period == .lifetime })
        _ = try await service.purchase(monthly)
        _ = try await service.purchase(lifetime)
        XCTAssertTrue(service.ownsLifetimeWithRenewingSubscription, "buying Lifetime cancels nothing")

        let subscription = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == monthly.id })
        try session.disableAutoRenewForTransaction(identifier: subscription.identifier)
        try await wait(for: service, refreshing: true) { !service.subscriptionWillRenew }

        XCTAssertTrue(service.hasActiveSubscription, "it runs to the end of the period")
        XCTAssertFalse(service.subscriptionWillRenew)
        XCTAssertFalse(service.ownsLifetimeWithRenewingSubscription)
        XCTAssertTrue(service.isPremium)
        // Not followed by session.expireSubscription: in about one run in
        // four it doesn't take effect within ten seconds.
    }

    /// Turning off auto-renew produces no transaction, so the service has to
    /// hear about it from the subscription status updates.
    @MainActor
    func testNoticesAutoRenewTurnedOffWhileRunning() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let service = StoreKitPurchaseService()
        await service.loadPlans()
        try skipIfStoreKitTestingUnavailable(service)
        service.start()
        let monthly = try XCTUnwrap(service.plans.first { $0.period == .month })
        _ = try await service.purchase(monthly)
        XCTAssertTrue(service.subscriptionWillRenew)

        let subscription = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == monthly.id })
        try session.disableAutoRenewForTransaction(identifier: subscription.identifier)
        try await wait(for: service) { !service.subscriptionWillRenew }

        XCTAssertFalse(service.subscriptionWillRenew)
        XCTAssertTrue(service.hasActiveSubscription)
    }

    @MainActor
    func testBillingGracePeriodRetainsPremiumAfterTransactionExpires() async throws {
        let session = try makeSession()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let service = StoreKitPurchaseService()
        await service.loadPlans()
        try skipIfStoreKitTestingUnavailable(service)
        session.timeRate = .oneRenewalEveryThirtySeconds
        session.billingGracePeriodIsEnabled = true
        session.shouldEnterBillingRetryOnRenewal = true
        let monthly = try XCTUnwrap(service.plans.first { $0.period == .month })
        _ = try await service.purchase(monthly)

        // StoreKit testing moves the transaction's expiration date into the
        // grace window, so it can't show the App Store's case of an
        // already-passed date during grace; this checks Premium holds in grace.
        let deadline = Date().addingTimeInterval(50)
        var sawGracePeriod = false
        while Date() < deadline {
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result, transaction.productID == monthly.id,
                      let status = await transaction.subscriptionStatus, status.state == .inGracePeriod else { continue }
                sawGracePeriod = true
            }
            if sawGracePeriod { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(sawGracePeriod, "the fixture must reach the billing grace period")
        await service.refreshEntitlements()
        XCTAssertTrue(service.isPremium)
        XCTAssertTrue(service.hasActiveSubscription)
    }

    @MainActor
    func testRestoreWithNothingPurchasedStaysFree() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let service = StoreKitPurchaseService()
        await service.refreshEntitlements()
        XCTAssertFalse(service.isPremium)
    }
}
