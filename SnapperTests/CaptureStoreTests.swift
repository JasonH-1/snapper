import XCTest
@testable import Snapper

final class CaptureStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordsRoundTripAndMissingFilesAreDropped() throws {
        let store = CaptureStore(directory: directory)
        let kept = CaptureRecord(id: UUID(), createdAt: Date(), fileName: "a.jpg", lookID: "boardwalk", strength: 0.8,
                                 isFrontCamera: false, savedLookID: nil, savedStrength: nil)
        let missing = CaptureRecord(id: UUID(), createdAt: Date(), fileName: "b.jpg", lookID: "original", strength: 1,
                                    isFrontCamera: true, savedLookID: nil, savedStrength: nil)
        try store.write(Data([0xFF, 0xD8, 0xFF]), fileName: kept.fileName)
        try store.save([kept, missing])

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.id), [kept.id])
        XCTAssertEqual(loaded.first?.lookID, "boardwalk")
        XCTAssertEqual(loaded.first?.strength, 0.8)

        store.delete(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: kept).path))
    }

    func testSavedStateTracksRecipe() {
        var record = CaptureRecord(id: UUID(), createdAt: Date(), fileName: "a.heic", lookID: "cream", strength: 1,
                                   isFrontCamera: false, savedLookID: nil, savedStrength: nil)
        XCTAssertFalse(record.isSavedWithCurrentRecipe)
        record.savedLookID = "cream"
        record.savedStrength = 1
        XCTAssertTrue(record.isSavedWithCurrentRecipe)
        record.strength = 0.5
        XCTAssertFalse(record.isSavedWithCurrentRecipe)
    }

    func testFileExtensionSniffing() {
        var heif = Data(count: 16)
        heif.replaceSubrange(4..<8, with: Array("ftyp".utf8))
        XCTAssertEqual(CaptureStore.fileExtension(for: heif), "heic")
        XCTAssertEqual(CaptureStore.fileExtension(for: Data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
    }
}
