import XCTest
@testable import Snapper

final class LUTStoreTests: XCTestCase {
    private let looks = LookLibrary.bundled().looks.filter { !$0.isOriginal }

    func testKeepsOnlyTheMostRecentlyUsedLUTs() throws {
        let store = LUTStore(capacity: 3)
        store.preload(Array(looks.prefix(3)))
        XCTAssertEqual(store.cachedFiles, looks.prefix(3).compactMap(\.lutFile))
        XCTAssertNotNil(store.lut(for: looks[0])) // now the most recent
        XCTAssertNotNil(store.lut(for: looks[3])) // pushes out looks[1], the least recent
        XCTAssertEqual(store.cachedFiles, [looks[2], looks[0], looks[3]].compactMap(\.lutFile))
    }

    func testEvictedLookLoadsAgain() throws {
        let store = LUTStore(capacity: 1)
        let first = try XCTUnwrap(store.lut(for: looks[0]))
        XCTAssertNotNil(store.lut(for: looks[1]))
        XCTAssertEqual(store.cachedFiles, [looks[1]].compactMap(\.lutFile))
        let again = try XCTUnwrap(store.lut(for: looks[0]))
        XCTAssertEqual(again.dimension, first.dimension)
        XCTAssertEqual(again.data, first.data)
    }

    func testConcurrentLoadsStayWithinCapacity() {
        let store = LUTStore(capacity: 4)
        let looks = looks
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            XCTAssertNotNil(store.lut(for: looks[i % 8]))
        }
        XCTAssertEqual(store.cachedFiles.count, 4)
        XCTAssertEqual(Set(store.cachedFiles).count, 4)
    }

    func testOriginalNeedsNoLUT() {
        let store = LUTStore()
        XCTAssertNil(store.lut(for: .original))
        XCTAssertTrue(store.cachedFiles.isEmpty)
    }
}
