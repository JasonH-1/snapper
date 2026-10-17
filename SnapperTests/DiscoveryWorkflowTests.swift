import XCTest
@testable import Snapper

final class LookDiscoveryTests: XCTestCase {
    func testSearchMatchesNameCollectionAndGuidanceWithEveryWord() throws {
        let library = LookLibrary.bundled()
        let cream = try XCTUnwrap(library.look(id: "cream"))
        func matches(_ query: String) -> Bool {
            LookDiscovery.matches(cream, library: library, query: query, scope: .all, favoriteIDs: [])
        }
        XCTAssertTrue(matches("  CREAM  "))
        XCTAssertTrue(matches("window portraits"))
        XCTAssertTrue(matches(try XCTUnwrap(library.collection(for: cream)).name))
        XCTAssertFalse(matches("cream nonexistent"))
    }

    func testFreeAndFavoriteFiltersNeverLeakOtherLooks() throws {
        let library = LookLibrary.bundled()
        let premium = try XCTUnwrap(library.premiumLooks.first)
        let favorite = try XCTUnwrap(library.look(id: "cream"))
        let free = library.looks.filter { LookDiscovery.matches($0, library: library, query: "", scope: .free, favoriteIDs: []) }
        XCTAssertTrue(free.contains(.original))
        XCTAssertFalse(free.contains(premium))
        let favorites = library.looks.filter {
            LookDiscovery.matches($0, library: library, query: "", scope: .favorites, favoriteIDs: [favorite.id, "missing"])
        }
        XCTAssertEqual(favorites, [favorite])
        XCTAssertFalse(LookDiscovery.matches(favorite, library: library, query: "nonexistent", scope: .favorites, favoriteIDs: [favorite.id]))
    }
}

@MainActor
final class StyleClipboardTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var captures: CaptureLibrary!
    private var model: LibraryModel!
    private var premium = false
    private var upgradeRequests = 0

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        let looks = LookLibrary.bundled()
        captures = CaptureLibrary(library: looks, renderer: PhotoRenderer(), store: CaptureStore(directory: directory))
        model = LibraryModel(captures: captures, looks: looks, settings: AppSettings(defaults: defaults),
                             hasPremium: { [unowned self] in self.premium },
                             requestPremium: { [unowned self] _, _, _ in self.upgradeRequests += 1 })
    }
    override func tearDown() async throws {
        model = nil
        captures = nil
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    func testCopyUsesCurrentRecipeAndPastePreservesTargetGeometryAndFinish() async throws {
        let source = try await captures.importPhoto(TestImages.jpeg(width: 32, height: 24))
        let target = try await captures.importPhoto(TestImages.jpeg(width: 24, height: 32))
        var style = source.recipe
        style.lookID = "cream"
        style.strength = 0.42
        style.adjustments.warmth = 0.3
        style.crop.quarterTurns = 1
        style.finish.frame = .instant
        captures.updateRecipe(id: source.id, style)
        var before = target.recipe
        before.crop.shape = .square
        before.finish.frame = .black
        before.finish.dateStamp = "2020.01.02"
        captures.updateRecipe(id: target.id, before)
        model.copyStyle(from: source) // stale cell snapshot must not copy the old recipe
        XCTAssertTrue(model.pasteStyle(to: [target.id]))
        let after = try XCTUnwrap(captures.record(id: target.id)?.recipe)
        XCTAssertEqual(after.lookID, style.lookID)
        XCTAssertEqual(after.strength, style.strength)
        XCTAssertEqual(after.adjustments, style.adjustments)
        XCTAssertEqual(after.crop, before.crop)
        XCTAssertEqual(after.finish, before.finish)
        XCTAssertEqual(captures.record(id: source.id)?.recipe, style)
        model.undoBatch()
        XCTAssertEqual(captures.record(id: target.id)?.recipe, before)
    }

    func testBatchPasteRequiresPremiumAndProtectsLaterEditsOnUndo() async throws {
        let first = try await captures.importPhoto(TestImages.jpeg(width: 32, height: 24))
        let second = try await captures.importPhoto(TestImages.jpeg(width: 32, height: 24))
        var recipe = first.recipe
        recipe.adjustments.warmth = 0.3
        captures.updateRecipe(id: first.id, recipe)
        model.copyStyle(from: first)
        let ids: Set<UUID> = [first.id, second.id]
        XCTAssertFalse(model.pasteStyle(to: ids))
        XCTAssertEqual(upgradeRequests, 1)
        XCTAssertEqual(captures.record(id: second.id)?.recipe, second.recipe)
        premium = true
        XCTAssertTrue(model.pasteStyle(to: ids))
        var later = try XCTUnwrap(captures.record(id: second.id)?.recipe)
        later.adjustments.brightness = 0.2
        captures.updateRecipe(id: second.id, later)
        model.undoBatch()
        XCTAssertEqual(captures.record(id: second.id)?.recipe, later)
    }

    func testEmptyClipboardAndMissingTargetsDoNothing() async throws {
        let record = try await captures.importPhoto(TestImages.jpeg(width: 32, height: 24))
        XCTAssertFalse(model.pasteStyle(to: [record.id]))
        model.copyStyle(from: record)
        XCTAssertFalse(model.pasteStyle(to: []))
        XCTAssertFalse(model.pasteStyle(to: [UUID()]))
        XCTAssertEqual(captures.record(id: record.id)?.recipe, record.recipe)
    }
}
