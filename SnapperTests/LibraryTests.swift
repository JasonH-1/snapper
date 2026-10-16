import XCTest
@testable import Snapper

final class LookCatalogTests: XCTestCase {
    private let library = LookLibrary.bundled()

    func testCategoriesFollowFavoritesRecentThenCollections() throws {
        let looks = library.looks.filter { !$0.isOriginal }
        let favorite = try XCTUnwrap(looks.first)
        let recent = try XCTUnwrap(looks.last)
        let catalog = LookCatalog(library: library, favoriteIDs: [favorite.id], recentIDs: [recent.id, "original", "missing"])

        XCTAssertEqual(catalog.categories.prefix(2), [.favorites, .recent])
        XCTAssertEqual(Array(catalog.categories.dropFirst(2)), library.collections.map { .collection($0.id) })
        XCTAssertEqual(catalog.section(for: .recent)?.looks.map(\.id), [recent.id], "Original and unknown ids are skipped")
        XCTAssertNil(catalog.section(for: .favorites)?.count, "only collections show counts")
        XCTAssertNotNil(catalog.section(for: .collection(library.collections[0].id))?.count)

        XCTAssertEqual(catalog.entries.first?.id, LookCatalog.originalEntryID)
        XCTAssertEqual(Set(catalog.entries.map(\.id)).count, catalog.entries.count, "entry ids are unique")
    }

    func testEmptyFavoritesAndRecentAreHidden() {
        let catalog = LookCatalog(library: library, favoriteIDs: [], recentIDs: [])
        XCTAssertFalse(catalog.categories.contains(.favorites))
        XCTAssertFalse(catalog.categories.contains(.recent))
    }

    /// Tapping a chip jumps to its first look; scrolling onto a look lights its chip.
    func testCategoryJumps() throws {
        let catalog = LookCatalog(library: library, favoriteIDs: [], recentIDs: [])
        for section in catalog.sections {
            let first = try XCTUnwrap(catalog.firstEntryID(of: section.category))
            XCTAssertEqual(catalog.category(ofEntry: first), section.category)
            XCTAssertEqual(catalog.entries.first { $0.id == first }?.look.id, section.looks.first?.id)
        }
        XCTAssertEqual(catalog.category(ofEntry: LookCatalog.originalEntryID), catalog.sections.first?.category,
                       "Original belongs to the first chip")
        XCTAssertNil(catalog.category(ofEntry: "nope"))
    }

    func testSelectedLookIsFoundInItsCollection() throws {
        let look = try XCTUnwrap(library.looks.last { !$0.isOriginal })
        let catalog = LookCatalog(library: library, favoriteIDs: [look.id], recentIDs: [])
        let entry = try XCTUnwrap(catalog.entryID(forLook: look.id))
        XCTAssertEqual(catalog.category(ofEntry: entry), .collection(try XCTUnwrap(look.collectionID)))
        let favoriteEntry = try XCTUnwrap(catalog.entryID(forLook: look.id, preferring: .favorites))
        XCTAssertEqual(catalog.category(ofEntry: favoriteEntry), .favorites)
        XCTAssertEqual(catalog.entryID(forLook: Look.original.id), LookCatalog.originalEntryID)
    }
}

final class LibrarySectionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func record(_ date: Date) -> CaptureRecord {
        CaptureRecord(createdAt: date, fileName: "x.jpg", recipe: .untouched)
    }

    func testPhotosAreGroupedByDayNewestFirst() {
        let now = ISO8601DateFormatter().date(from: "2026-10-15T18:00:00Z")!
        let records = [
            record(now.addingTimeInterval(-60)),
            record(now.addingTimeInterval(-3600)),
            record(now.addingTimeInterval(-86_400)),
            record(now.addingTimeInterval(-3 * 86_400)),
            record(now.addingTimeInterval(-40 * 86_400)),
            record(now.addingTimeInterval(-400 * 86_400)),
        ]
        let sections = LibraryModel.sections(for: records, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.records.count), [2, 1, 1, 1, 1])
        XCTAssertEqual(sections[0].title, String(localized: "Today"))
        XCTAssertEqual(sections[1].title, String(localized: "Yesterday"))
        XCTAssertFalse(sections[2].title.contains("2026"), "days this week show the weekday")
        XCTAssertTrue(sections[4].title.contains("2025"), "older years show the year")
    }

    func testFilters() {
        var imported = CaptureRecord(fileName: "a.jpg", source: .imported, recipe: .untouched)
        let camera = CaptureRecord(fileName: "b.jpg", recipe: PhotoRecipe(lookID: "cream"))
        XCTAssertTrue(LibraryFilter.imported.includes(imported))
        XCTAssertFalse(LibraryFilter.camera.includes(imported))
        XCTAssertTrue(LibraryFilter.camera.includes(camera))
        XCTAssertFalse(LibraryFilter.edited.includes(camera), "a look chosen when shooting isn't an edit")
        imported.recipe.adjustments.contrast = 0.2
        XCTAssertTrue(LibraryFilter.edited.includes(imported))
        XCTAssertTrue(LibraryFilter.notSaved.includes(imported))
        imported.savedRecipe = imported.recipe
        XCTAssertFalse(LibraryFilter.notSaved.includes(imported))
    }

    func testPhotoCountWording() {
        XCTAssertEqual(LibraryModel.photoCount(1), String(localized: "1 photo"))
        XCTAssertEqual(LibraryModel.photoCount(3), String(localized: "3 photos"))
    }
}

final class CropBoxTests: XCTestCase {
    func testShapesFollowThePhoto() throws {
        let portrait = CGSize(width: 3000, height: 4000)
        // 1:1 on a 3:4 frame is 3/4 of the height wide in normalised units.
        XCTAssertEqual(try XCTUnwrap(CropBox.normalizedAspect(for: .square, frameSize: portrait)), 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CropBox.normalizedAspect(for: .original, frameSize: portrait)), 1)
        // 4:3 on a portrait frame is tall: 3 wide by 4 high, the whole frame.
        XCTAssertEqual(try XCTUnwrap(CropBox.normalizedAspect(for: .fourThree, frameSize: portrait)), 1, accuracy: 1e-9)
        XCTAssertNil(CropBox.normalizedAspect(for: .free, frameSize: portrait))
    }

    func testResolvedRectMatchesTheRenderer() {
        let crop = PhotoCrop(shape: .square)
        let rect = CropBox.resolvedRect(of: crop, frameSize: CGSize(width: 300, height: 400))
        XCTAssertEqual(rect.width, 1, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 0.75, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 0.125, accuracy: 1e-9)
    }

    func testMovingStaysInside() {
        let rect = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        XCTAssertEqual(CropBox.moved(rect, by: CGSize(width: 1, height: -1)), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }

    func testResizingKeepsTheShapeAndThePinnedCorner() {
        let rect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let grown = CropBox.resized(rect, handle: .bottomRight, by: CGSize(width: 0.1, height: 0.02), aspect: 1)
        XCTAssertEqual(grown.minX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(grown.minY, 0.25, accuracy: 1e-9)
        XCTAssertEqual(grown.width, grown.height, accuracy: 1e-9)
        XCTAssertEqual(grown.width, 0.6, accuracy: 1e-9)

        let huge = CropBox.resized(rect, handle: .topLeft, by: CGSize(width: -2, height: -2), aspect: 1)
        XCTAssertEqual(huge, CGRect(x: 0, y: 0, width: 0.75, height: 0.75), "stops at the frame edge")

        let tiny = CropBox.resized(rect, handle: .bottomRight, by: CGSize(width: -1, height: -1), aspect: nil)
        XCTAssertGreaterThanOrEqual(tiny.width, CropBox.minimumSize - 1e-9)
        XCTAssertGreaterThanOrEqual(tiny.height, CropBox.minimumSize - 1e-9)
    }
}

@MainActor
final class LibraryStorageTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Photos stay until deleted; "Clear Photos Already Saved" only removes
    /// photos whose current edit is in the photo library.
    func testOnlyPhotosSavedWithTheirCurrentEditAreCleared() async throws {
        let captures = CaptureLibrary(library: LookLibrary.bundled(), renderer: PhotoRenderer(),
                                      store: CaptureStore(directory: directory))
        let saved = try await captures.importPhoto(TestImages.jpeg(width: 8, height: 8))
        let editedAfterSaving = try await captures.importPhoto(TestImages.jpeg(width: 8, height: 8))
        let unsaved = try await captures.importPhoto(TestImages.jpeg(width: 8, height: 8))
        captures.markSaved(id: saved.id)
        captures.markSaved(id: editedAfterSaving.id)
        var recipe = editedAfterSaving.recipe
        recipe.adjustments.fade = 0.5
        captures.updateRecipe(id: editedAfterSaving.id, recipe)

        XCTAssertEqual(captures.alreadySavedIDs, [saved.id])
        let before = await captures.storageUsed()
        XCTAssertGreaterThan(before, 0)

        captures.deleteAlreadySaved()
        XCTAssertEqual(Set(captures.records.map(\.id)), [editedAfterSaving.id, unsaved.id])
        try await Task.sleep(for: .milliseconds(200))
        let after = await captures.storageUsed()
        XCTAssertLessThan(after, before)
    }
}
