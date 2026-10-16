import ImageIO
import UniformTypeIdentifiers
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
        var recipe = PhotoRecipe(lookID: "boardwalk", strength: 0.8)
        recipe.adjustments.brightness = 0.2
        recipe.crop = PhotoCrop(rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5), shape: .free,
                                straighten: -2.5, quarterTurns: 1, isFlipped: true)
        let kept = CaptureRecord(fileName: "a.jpg", source: .imported, recipe: recipe)
        let missing = CaptureRecord(fileName: "b.jpg", isFrontCamera: true, recipe: .untouched)
        try store.write(Data([0xFF, 0xD8, 0xFF]), fileName: kept.fileName)
        try store.save([kept, missing])

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.id), [kept.id])
        XCTAssertEqual(loaded.first?.recipe, recipe)
        XCTAssertEqual(loaded.first?.source, .imported)
        XCTAssertEqual(loaded.first?.initialRecipe, recipe)

        store.delete(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: kept).path))
    }

    /// Records written before the Library had the look, strength and shape
    /// at the top level; they must still load, with the shape as the crop.
    func testRecordsFromEarlierBuildsStillLoad() throws {
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","createdAt":700000000,"fileName":"old.heic","lookID":"cream","strength":0.6,
          "isFrontCamera":true,"aspect":"1:1","savedLookID":"cream","savedStrength":0.6},
         {"id":"\(UUID().uuidString)","createdAt":690000000,"fileName":"older.jpg","lookID":"original","strength":1,
          "isFrontCamera":false}]
        """
        let records = try JSONDecoder().decode([CaptureRecord].self, from: Data(json.utf8))
        XCTAssertEqual(records.count, 2)

        let first = records[0]
        XCTAssertEqual(first.id, id)
        XCTAssertEqual(first.source, .camera)
        XCTAssertTrue(first.isFrontCamera)
        XCTAssertEqual(first.recipe.lookID, "cream")
        XCTAssertEqual(first.recipe.strength, 0.6)
        XCTAssertEqual(first.recipe.crop.shape, .square)
        XCTAssertTrue(first.isSavedWithCurrentRecipe, "a saved photo stays saved")
        XCTAssertFalse(first.isEdited)

        let second = records[1]
        XCTAssertEqual(second.recipe, .untouched)
        XCTAssertFalse(second.isSaved)

        // And they are written back in the new shape.
        let reencoded = try JSONDecoder().decode([CaptureRecord].self, from: JSONEncoder().encode(records))
        XCTAssertEqual(reencoded, records)
    }

    func testSavedStateTracksRecipe() {
        var record = CaptureRecord(fileName: "a.heic", recipe: PhotoRecipe(lookID: "cream"))
        XCTAssertFalse(record.isSavedWithCurrentRecipe)
        XCTAssertFalse(record.isSaved)
        record.savedRecipe = record.recipe
        XCTAssertTrue(record.isSavedWithCurrentRecipe)
        record.strength = 0.5
        XCTAssertFalse(record.isSavedWithCurrentRecipe)
        record.strength = 1
        record.recipe.adjustments.warmth = 0.3
        XCTAssertFalse(record.isSavedWithCurrentRecipe, "slider changes need saving again")
        record.recipe.adjustments = .none
        record.recipe.crop.rotateClockwise()
        XCTAssertFalse(record.isSavedWithCurrentRecipe, "crop changes need saving again")
        XCTAssertTrue(record.isSaved)
        XCTAssertTrue(record.isEdited)
    }

    func testFileExtensionSniffing() {
        var heif = Data(count: 16)
        heif.replaceSubrange(4..<8, with: Array("ftyp".utf8))
        XCTAssertEqual(CaptureStore.fileExtension(for: heif), "heic")
        XCTAssertEqual(CaptureStore.fileExtension(for: Data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
        XCTAssertEqual(CaptureStore.fileExtension(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])), "png")
    }

    func testTakenDateIsReadFromMetadata() throws {
        let data = try TestImages.jpeg(width: 40, height: 30, exif: [
            kCGImagePropertyExifDateTimeOriginal: "2024:06:02 18:30:05",
            kCGImagePropertyExifOffsetTimeOriginal: "+09:00",
        ])
        let info = CaptureStore.inspectImage(data)
        XCTAssertTrue(info.isReadable)
        let expected = ISO8601DateFormatter().date(from: "2024-06-02T09:30:05Z")
        XCTAssertEqual(info.takenAt, expected)

        XCTAssertFalse(CaptureStore.inspectImage(Data("not a photo".utf8)).isReadable)
        XCTAssertNil(CaptureStore.inspectImage(try TestImages.jpeg(width: 4, height: 4)).takenAt)
    }
}

@MainActor
final class CaptureLibraryImportTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testImportKeepsAPrivateCopyWithNoLook() async throws {
        let store = CaptureStore(directory: directory)
        let library = CaptureLibrary(library: LookLibrary.bundled(), renderer: PhotoRenderer(), store: store)
        let data = try TestImages.jpeg(width: 64, height: 48, exif: [kCGImagePropertyExifDateTimeOriginal: "2023:01:05 08:00:00"])

        let record = try await library.importPhoto(data)
        XCTAssertEqual(record.source, .imported)
        XCTAssertTrue(record.isImported)
        XCTAssertEqual(record.recipe, .untouched)
        XCTAssertFalse(record.isEdited)
        XCTAssertNotNil(record.takenAt)
        XCTAssertEqual(library.records.first?.id, record.id)
        XCTAssertNotNil(library.thumbnails[record.id], "imports get a thumbnail straight away")
        XCTAssertEqual(try Data(contentsOf: store.url(for: record)), data, "the copy is byte for byte")

        // Unreadable files are refused and leave nothing behind.
        do {
            try await library.importPhoto(Data("nope".utf8))
            XCTFail("expected the import to fail")
        } catch {}
        XCTAssertEqual(library.records.count, 1)
    }

    func testImportsPickedTogetherKeepTheirOrder() async throws {
        let library = CaptureLibrary(library: LookLibrary.bundled(), renderer: PhotoRenderer(),
                                     store: CaptureStore(directory: directory))
        let now = Date()
        let first = try await library.importPhoto(TestImages.jpeg(width: 8, height: 8), createdAt: now)
        let second = try await library.importPhoto(TestImages.jpeg(width: 8, height: 8), createdAt: now.addingTimeInterval(-1))
        XCTAssertEqual(library.records.map(\.id), [first.id, second.id], "the first picked stays on top")
    }

    func testRecipeEditsAreKeptAndSavedStateFollows() async throws {
        let library = CaptureLibrary(library: LookLibrary.bundled(), renderer: PhotoRenderer(),
                                     store: CaptureStore(directory: directory))
        let record = try await library.importPhoto(TestImages.jpeg(width: 8, height: 8))
        var recipe = record.recipe
        recipe.lookID = "cream"
        recipe.adjustments.fade = 0.4
        library.updateRecipe(id: record.id, recipe)
        XCTAssertEqual(library.record(id: record.id)?.recipe, recipe)
        XCTAssertEqual(library.record(id: record.id)?.isEdited, true)
        library.markSaved(id: record.id)
        XCTAssertEqual(library.record(id: record.id)?.isSavedWithCurrentRecipe, true)
    }
}

/// Small generated photos for tests.
enum TestImages {
    static func jpeg(width: Int, height: Int, orientation: Int = 1, exif: [CFString: Any]? = nil) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if let exif {
            properties[kCGImagePropertyExifDictionary] = exif
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
