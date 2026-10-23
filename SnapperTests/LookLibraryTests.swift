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
           {"id": "a", "name": "A", "collection": "c", "lut": "boardwalk.snaplut", "tier": "free"},
           {"id": "b", "name": "B", "collection": "c", "lut": "boardwalk.snaplut", "enabled": false},
           {"id": "x", "name": "X", "collection": "c", "lut": "does-not-exist.cube"}
         ]}
        """
        let manifest = try JSONDecoder().decode(LookManifest.self, from: Data(json.utf8))
        let library = LookLibrary(manifest: manifest)
        XCTAssertEqual(library.looks.map(\.id), ["original", "a"])
        XCTAssertEqual(library.look(id: "a")?.tier, .free)
    }

    /// The camera's look dial: "Look 2/3" within the look's own collection.
    func testLookDialCountsWithinTheCollection() throws {
        let json = """
        {"version": 1,
         "collections": [{"id": "c", "name": "C"}, {"id": "d", "name": "D"}],
         "looks": [
           {"id": "a", "name": "A", "collection": "c", "lut": "boardwalk.snaplut"},
           {"id": "z", "name": "Z", "collection": "d", "lut": "boardwalk.snaplut"},
           {"id": "b", "name": "B", "collection": "c", "lut": "boardwalk.snaplut"},
           {"id": "e", "name": "E", "collection": "c", "lut": "boardwalk.snaplut"}
         ]}
        """
        let library = LookLibrary(manifest: try JSONDecoder().decode(LookManifest.self, from: Data(json.utf8)))
        let b = try XCTUnwrap(library.look(id: "b"))
        let place = try XCTUnwrap(LookDial.position(of: b, in: library))
        XCTAssertEqual(place.index, 1)
        XCTAssertEqual(place.count, 3)
        XCTAssertNil(LookDial.position(of: .original, in: library), "Original has no collection")
    }

    /// Each collection is shown on its own bundled example photo while choosing a look.
    func testEveryCollectionHasAnExamplePhoto() throws {
        let library = LookLibrary.bundled()
        for collection in library.collections {
            let name = try XCTUnwrap(LookSamples.photos[collection.id], "\(collection.id) has no example photo")
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "jpg"), "\(name).jpg is missing")
        }
        XCTAssertNotNil(LookSamples.url(for: .original), "Original falls back to the demo scene")
    }
}
