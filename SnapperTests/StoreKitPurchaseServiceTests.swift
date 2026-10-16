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

    @MainActor
    func testLoadsYearlyFirstWithFreeTrial() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let service = StoreKitPurchaseService()
        await service.loadPlans()
        try skipIfStoreKitTestingUnavailable(service)

        XCTAssertEqual(service.plansState, .loaded)
        XCTAssertEqual(service.plans.map(\.id), [AppConfig.yearlyProductID, AppConfig.monthlyProductID])
        let yearly = try XCTUnwrap(service.plans.first)
        XCTAssertEqual(yearly.period, .year)
        XCTAssertNotNil(yearly.freeTrial, "yearly plan advertises the free trial to eligible people")
        XCTAssertNotNil(yearly.monthlyEquivalent)
        XCTAssertNil(service.plans.last?.freeTrial)
        XCTAssertFalse(service.isPremium)
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
