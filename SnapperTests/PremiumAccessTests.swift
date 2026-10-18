import XCTest
@testable import Snapper

/// What the free tier includes, and the promise that no photo is ever stuck
/// behind Premium.
final class FreeTierTests: XCTestCase {
    func testHighlightsShadowsAndTheDateStampAreFree() {
        var recipe = PhotoRecipe(lookID: "boardwalk")
        recipe.adjustments.highlights = -0.4
        recipe.adjustments.shadows = 0.3
        recipe.finish.dateStamp = "1999.08.14"
        XCTAssertFalse(recipe.requiresPremium)
        XCTAssertFalse(PhotoAdjustments.Kind.highlights.isPremium)
        XCTAssertFalse(PhotoAdjustments.Kind.shadows.isPremium)

        for kind in [PhotoAdjustments.Kind.bloom, .halation, .vignette] {
            var premium = PhotoAdjustments.none
            premium[kind] = 0.3
            XCTAssertTrue(premium.requiresPremium, kind.rawValue)
        }
        var framed = recipe
        framed.finish.frame = .white
        XCTAssertTrue(framed.requiresPremium, "frames stay Premium")
        var laidOut = recipe
        laidOut.finish.layout = .story
        XCTAssertTrue(laidOut.requiresPremium, "layouts stay Premium")
    }

    func testPresetFilesStillMarkHighlightsForNewerApps() {
        let preset = SavedPreset(name: "Lifted", recipe: PhotoRecipe(lookID: "cream", adjustments: PhotoAdjustments(shadows: 0.2)))
        XCTAssertEqual(PresetFile(preset).version, 2, "builds without highlights and shadows must still refuse the file")
    }

    func testEveryCollectionHasAFreeLook() throws {
        let library = LookLibrary.bundled()
        for collection in ["disposable", "neon", "soft", "overclock", "darkroom"] {
            XCTAssertTrue(library.freeLooks.contains { $0.collectionID == collection }, collection)
        }
        XCTAssertEqual(library.look(id: "instant")?.tier, .free)
        XCTAssertEqual(library.look(id: "signal")?.tier, .free)
        XCTAssertEqual(library.freeLooks.count - 1, 8, "eight free looks besides Original")
    }

    func testFreeVersionRemovesOnlyThePremiumParts() {
        var recipe = PhotoRecipe(lookID: "sunburn", strength: 0.6)
        recipe.adjustments = PhotoAdjustments(brightness: 0.2, warmth: -0.1, grain: 0.3, highlights: -0.2, shadows: 0.1,
                                              bloom: 0.4, halation: 0.2, vignette: 0.5)
        recipe.adjustments.colorMixer[.blue] = ColorMix(hue: 0.3)
        recipe.adjustments.splitToning.highlightSaturation = 0.4
        recipe.crop = PhotoCrop(shape: .square, straighten: 4)
        recipe.finish = PhotoFinish(frame: .instant, layout: .post, dateStamp: "2001.02.03")
        recipe.selective.subject.brightness = 0.3

        let free = recipe.withoutPremium(lookIsPremium: true)

        XCTAssertEqual(free.lookID, Look.original.id)
        XCTAssertEqual(free.adjustments, PhotoAdjustments(brightness: 0.2, warmth: -0.1, grain: 0.3, highlights: -0.2, shadows: 0.1))
        XCTAssertEqual(free.crop, recipe.crop)
        XCTAssertEqual(free.finish.dateStamp, "2001.02.03")
        XCTAssertEqual(free.finish.frame, .none)
        XCTAssertEqual(free.finish.layout, .original)
        XCTAssertFalse(free.selective.isActive)
        XCTAssertFalse(free.requiresPremium)

        let freeLook = PhotoRecipe(lookID: "boardwalk", strength: 0.5).withoutPremium(lookIsPremium: false)
        XCTAssertEqual(freeLook, PhotoRecipe(lookID: "boardwalk", strength: 0.5), "free looks and strength are kept")
    }
}

/// Stands in for the photo library in tests.
private actor SavedFiles {
    private(set) var count = 0
    func add(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) { count += 1 }
    }
}

@MainActor
final class NeverLockedPhotoTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var saved: SavedFiles!
    private var premium = false

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
        saved = SavedFiles()
        premium = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeLibrary() -> CaptureLibrary {
        let saved = self.saved!
        let library = CaptureLibrary(library: .bundled(), renderer: PhotoRenderer(), store: CaptureStore(directory: directory),
                                     photoSaver: { url, _ in await saved.add(url) })
        library.hasPremium = { [unowned self] in self.premium }
        return library
    }

    private func importPhoto(into library: CaptureLibrary, lookID: String) async throws -> CaptureRecord {
        let record = try await library.importPhoto(TestImages.jpeg(width: 64, height: 48))
        library.updateRecipe(id: record.id, PhotoRecipe(lookID: lookID))
        return try XCTUnwrap(library.record(id: record.id))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "timed out")
    }

    func testEditorSavesALockedPhotoWithoutItsPremiumLook() async throws {
        let library = makeLibrary()
        let record = try await importPhoto(into: library, lookID: "sunburn")
        var requests = 0
        let editor = EditorModel(library: library, looks: .bundled(), settings: AppSettings(defaults: defaults), id: record.id,
                                 hasPremium: { [unowned self] in self.premium }, requestPremium: { _, _, _ in requests += 1 })
        editor.setValue(-0.3, for: .highlights)
        editor.setValue(0.4, for: .bloom)
        editor.interaction(began: false)
        XCTAssertTrue(editor.isLocked)
        XCTAssertEqual(editor.freeSaveTitle, "Save Without Sunburn & Premium Tools")

        editor.saveWithoutPremium()
        try await waitUntil { !editor.isSavingFreeVersion }

        let savedCount = await saved.count
        XCTAssertEqual(savedCount, 1)
        XCTAssertEqual(requests, 0, "no paywall on the way")
        XCTAssertNil(editor.alert)
        let after = try XCTUnwrap(library.record(id: record.id))
        XCTAssertEqual(after.savedRecipe?.lookID, Look.original.id)
        XCTAssertEqual(after.savedRecipe?.adjustments.highlights, -0.3, "free sliders are kept")
        XCTAssertEqual(after.savedRecipe?.adjustments.bloom, 0)
        XCTAssertEqual(after.recipe.lookID, "sunburn", "the full edit stays in Snapper")
        XCTAssertTrue(editor.isFreeVersionSaved)
        XCTAssertTrue(editor.isLocked, "saving the full look still needs Premium")
        editor.finish()
    }

    func testLibraryBatchAsksThenSavesLockedPhotosWithoutPremium() async throws {
        let library = makeLibrary()
        let locked = try await importPhoto(into: library, lookID: "sunburn")
        let free = try await importPhoto(into: library, lookID: "instant")
        var requests = 0
        let model = LibraryModel(captures: library, looks: .bundled(), settings: AppSettings(defaults: defaults),
                                 hasPremium: { [unowned self] in self.premium }, requestPremium: { _, _, _ in requests += 1 })
        model.isSelecting = true
        model.selection = [locked.id, free.id]

        model.saveSelected()
        let pending = try XCTUnwrap(model.lockedExport, "asks before leaving anything out")
        XCTAssertEqual(pending.lockedCount, 1)
        var savedCount = await saved.count
        XCTAssertEqual(savedCount, 0)

        model.exportWithoutPremium(pending)
        XCTAssertNil(model.lockedExport)
        try await waitUntil { !model.isWorking }

        savedCount = await saved.count
        XCTAssertEqual(savedCount, 2)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(library.record(id: locked.id)?.savedRecipe?.lookID, Look.original.id)
        XCTAssertEqual(library.record(id: free.id)?.savedRecipe?.lookID, "instant", "Instant is free now")
        XCTAssertNil(model.alert)
    }

    func testLibraryBatchCanUnlockInstead() async throws {
        let library = makeLibrary()
        let locked = try await importPhoto(into: library, lookID: "neon")
        var requested: Look?
        let model = LibraryModel(captures: library, looks: .bundled(), settings: AppSettings(defaults: defaults),
                                 hasPremium: { [unowned self] in self.premium }, requestPremium: { look, _, _ in requested = look })
        model.isSelecting = true
        model.selection = [locked.id]
        model.shareSelected()
        model.unlock(try XCTUnwrap(model.lockedExport))
        XCTAssertEqual(requested?.id, "neon")
        XCTAssertNil(model.lockedExport)
        XCTAssertNil(model.shareItems)
    }

    func testEditsMadeWhileSubscribedStayExportableAfterPremiumEnds() async throws {
        let library = makeLibrary()
        let record = try await importPhoto(into: library, lookID: "boardwalk")
        let model = LibraryModel(captures: library, looks: .bundled(), settings: AppSettings(defaults: defaults),
                                 hasPremium: { [unowned self] in self.premium }, requestPremium: { _, _, _ in })

        // Edits made without Premium earn nothing.
        let sunburn = PhotoRecipe(lookID: "sunburn")
        library.updateRecipe(id: record.id, sunburn)
        XCTAssertTrue(model.isLocked(try XCTUnwrap(library.record(id: record.id))))

        premium = true
        var subscribed = sunburn
        subscribed.adjustments.vignette = 0.4
        library.updateRecipe(id: record.id, subscribed)
        premium = false

        XCTAssertFalse(model.isLocked(try XCTUnwrap(library.record(id: record.id))), "kept after Premium ends")
        library.updateRecipe(id: record.id, PhotoRecipe(lookID: "neon"))
        XCTAssertTrue(model.isLocked(try XCTUnwrap(library.record(id: record.id))), "new Premium edits need Premium again")
        library.updateRecipe(id: record.id, subscribed)
        XCTAssertFalse(model.isLocked(try XCTUnwrap(library.record(id: record.id))), "going back to the kept edit works")

        // The promise survives a relaunch.
        let stored = try XCTUnwrap(library.record(id: record.id))
        let decoded = try JSONDecoder().decode(CaptureRecord.self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(decoded.premiumEdits, [subscribed])
    }

    func testCameraShotsWhileSubscribedStayExportable() async throws {
        let library = makeLibrary()
        let look = try XCTUnwrap(LookLibrary.bundled().look(id: "lantern"))
        premium = true
        let shot = try await library.add(CapturedPhoto(data: TestImages.jpeg(width: 64, height: 48), isFrontCamera: false), look: look)
        premium = false
        XCTAssertFalse(library.needsPremium(shot.recipe, of: shot))
        let freeShot = try await library.add(CapturedPhoto(data: TestImages.jpeg(width: 64, height: 48), isFrontCamera: false), look: look)
        XCTAssertTrue(library.needsPremium(freeShot.recipe, of: freeShot))
        XCTAssertEqual(library.freeVersion(of: freeShot.recipe).lookID, Look.original.id)
    }
}
