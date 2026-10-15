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

    @MainActor
    func testLoadsYearlyFirstWithFreeTrial() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let service = StoreKitPurchaseService()
        await service.loadPlans()

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
