import XCTest
@testable import Snapper

final class LookLibraryTests: XCTestCase {
    func testBundledManifestLoadsEveryLook() throws {
        let library = LookLibrary.bundled()
        XCTAssertEqual(library.looks.first, .original)
        XCTAssertGreaterThan(library.looks.count, 1, "filters.json should list looks")
        XCTAssertFalse(library.collections.isEmpty)
        for look in library.looks where !look.isOriginal {
            let lut = try XCTUnwrap(LUTStore.shared.lut(for: look), "\(look.id) has no readable LUT")
            XCTAssertEqual(lut.dimension, 33, look.id)
            XCTAssertNotNil(library.collection(for: look), "\(look.id) has an unknown collection")
        }
    }

    func testLookIDsAreUnique() {
        let ids = LookLibrary.bundled().looks.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testDisabledAndMissingLooksAreSkipped() throws {
        let json = """
        {"version": 1,
         "collections": [{"id": "c", "name": "C"}],
         "looks": [
           {"id": "a", "name": "A", "collection": "c", "lut": "boardwalk.cube", "tier": "free"},
           {"id": "b", "name": "B", "collection": "c", "lut": "boardwalk.cube", "enabled": false},
           {"id": "x", "name": "X", "collection": "c", "lut": "does-not-exist.cube"}
         ]}
        """
        let manifest = try JSONDecoder().decode(LookManifest.self, from: Data(json.utf8))
        let library = LookLibrary(manifest: manifest)
        XCTAssertEqual(library.looks.map(\.id), ["original", "a"])
        XCTAssertEqual(library.look(id: "a")?.tier, .free)
    }
}
