import XCTest
@testable import Snapper

final class SmokeTests: XCTestCase {
    func testBundleLoads() {
        XCTAssertNotNil(Bundle.main.bundleIdentifier)
    }
}
