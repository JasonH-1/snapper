import CoreImage
import ImageIO
import XCTest
@testable import Snapper

@MainActor
final class PresetStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    func testPersistenceRenameDuplicateAndDelete() throws {
        let store = PresetStore(defaults: defaults)
        var recipe = PhotoRecipe(lookID: "cream", strength: 0.6)
        recipe.adjustments.warmth = 0.2
        let preset = try store.save(name: "  Window Light  ", recipe: recipe, hasPremium: true)
        try store.rename(preset, to: "Soft Morning")
        try store.duplicate(store.presets[0], hasPremium: true)
        XCTAssertEqual(Set(store.presets.map(\.id)).count, 2)
        let reloaded = PresetStore(defaults: defaults)
        XCTAssertEqual(reloaded.presets, store.presets)
        XCTAssertEqual(reloaded.presets[0].name, "Soft Morning")
        XCTAssertEqual(reloaded.presets[1].strength, 0.6)
        try reloaded.delete(preset)
        XCTAssertEqual(PresetStore(defaults: defaults).presets.count, 1)
    }

    func testFreeLimitAndSubscriptionExpiryKeepAllData() throws {
        let store = PresetStore(defaults: defaults)
        let first = try store.save(name: "First", recipe: .untouched, hasPremium: false)
        XCTAssertThrowsError(try store.save(name: "Second", recipe: .untouched, hasPremium: false))
        XCTAssertThrowsError(try store.duplicate(first, hasPremium: false))
        let second = try store.save(name: "Second", recipe: .untouched, hasPremium: true)
        XCTAssertTrue(store.canUse(first, hasPremium: false))
        XCTAssertFalse(store.canUse(second, hasPremium: false))
        try store.makeFreePreset(second)
        XCTAssertTrue(store.canUse(second, hasPremium: false))
        XCTAssertEqual(store.presets.count, 2, "expiry never deletes paid presets")
        XCTAssertTrue(store.canUse(first, hasPremium: true), "renewal unlocks all again")
    }

    func testInvalidNamesAndCorruptStorageDoNotDestroyPresets() throws {
        let store = PresetStore(defaults: defaults)
        XCTAssertThrowsError(try store.save(name: " \n ", recipe: .untouched, hasPremium: true))
        XCTAssertThrowsError(try store.save(name: String(repeating: "x", count: 41), recipe: .untouched, hasPremium: true))
        let data = Data("unreadable archive".utf8)
        defaults.set(data, forKey: PresetStore.storageKey)
        let damaged = PresetStore(defaults: defaults)
        XCTAssertTrue(damaged.loadFailed)
        XCTAssertThrowsError(try damaged.save(name: "New", recipe: .untouched, hasPremium: true))
        XCTAssertEqual(defaults.data(forKey: PresetStore.storageKey), data)
    }

    func testPresetOnlyCopiesStyle() {
        var source = PhotoRecipe(lookID: "boardwalk", strength: 0.7)
        source.adjustments.contrast = 0.2
        source.crop.quarterTurns = 3
        source.finish = PhotoFinish(frame: .black, dateStamp: "2026.10.16")
        let preset = SavedPreset(name: "Friday Night", recipe: source)
        var target = PhotoRecipe.untouched
        target.crop = PhotoCrop(shape: .square, quarterTurns: 1)
        target.finish = PhotoFinish(frame: .instant, layout: .story, dateStamp: "2025.01.01")
        let result = preset.applying(to: target)
        XCTAssertEqual(result.lookID, source.lookID)
        XCTAssertEqual(result.adjustments, source.adjustments)
        XCTAssertEqual(result.strength, 0.7)
        XCTAssertEqual(result.crop, target.crop)
        XCTAssertEqual(result.finish, target.finish)
    }
}

@MainActor
final class ReleaseEditingTests: XCTestCase {
    func testBatchStyleUndoPreservesLaterEditsAndHonorsEntitlement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let looks = LookLibrary.bundled()
        let captures = CaptureLibrary(library: looks, renderer: PhotoRenderer(), store: CaptureStore(directory: directory))
        let first = try await captures.importPhoto(TestImages.jpeg(width: 64, height: 48))
        let second = try await captures.importPhoto(TestImages.jpeg(width: 48, height: 64))
        var crop = first.recipe
        crop.crop.shape = .square
        crop.finish = PhotoFinish(frame: .cream)
        captures.updateRecipe(id: first.id, crop)
        let settings = AppSettings(defaults: defaults)
        let purchase = FakePurchaseService()
        let model = LibraryModel(captures: captures, looks: looks, settings: settings,
                                 hasPremium: { purchase.isPremium }, requestPremium: { _, _, _ in })
        let preset = SavedPreset(name: "Warm", recipe: PhotoRecipe(lookID: "cream", strength: 0.4,
                                                                 adjustments: PhotoAdjustments(warmth: 0.2)))
        model.isSelecting = true
        model.selection = [first.id, second.id]
        XCTAssertFalse(model.applyPresetToSelection(preset), "batch presets require Premium")
        XCTAssertEqual(captures.record(id: first.id)?.recipe, crop)
        purchase.isPremium = true
        XCTAssertTrue(model.applyPresetToSelection(preset))
        XCTAssertEqual(captures.record(id: first.id)?.recipe.crop, crop.crop)
        XCTAssertEqual(captures.record(id: first.id)?.recipe.finish, crop.finish)
        XCTAssertEqual(captures.record(id: first.id)?.recipe.strength, 0.4)
        var later = try XCTUnwrap(captures.record(id: second.id)?.recipe)
        later.adjustments.brightness = 0.3
        captures.updateRecipe(id: second.id, later)
        model.undoBatch()
        XCTAssertEqual(captures.record(id: first.id)?.recipe, crop)
        XCTAssertEqual(captures.record(id: second.id)?.recipe, later, "undo must not erase later work")
    }

    func testFinishingIsUndoableAndRequiresPremiumOnlyToExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let looks = LookLibrary.bundled()
        let library = CaptureLibrary(library: looks, renderer: PhotoRenderer(), store: CaptureStore(directory: directory))
        let record = try await library.importPhoto(TestImages.jpeg(width: 64, height: 48))
        let purchase = FakePurchaseService()
        var requests = 0
        let editor = EditorModel(library: library, looks: looks, settings: AppSettings(defaults: defaults), id: record.id,
                                 hasPremium: { purchase.isPremium }, requestPremium: { _, _, _ in requests += 1 })
        XCTAssertFalse(editor.isLocked)
        editor.frame = .instant
        XCTAssertTrue(editor.isLocked)
        editor.save()
        editor.share()
        XCTAssertEqual(requests, 2, "save and share both enforce finishing access")
        purchase.isPremium = true
        XCTAssertFalse(editor.isLocked)
        purchase.isPremium = false
        XCTAssertTrue(editor.isLocked)
        editor.undo()
        XCTAssertEqual(editor.recipe.finish, .none)
        XCTAssertFalse(editor.isLocked)
        editor.redo()
        XCTAssertEqual(editor.recipe.finish.frame, .instant)
        editor.resetFinish()
        XCTAssertFalse(editor.isLocked)
    }
}

final class PhotoFinishTests: XCTestCase {
    func testLegacyRecipeAndFinishingRoundTrip() throws {
        let old = try JSONDecoder().decode(PhotoRecipe.self, from: Data(#"{"lookID":"cream","strength":0.5}"#.utf8))
        XCTAssertEqual(old.finish, .none)
        var recipe = old
        recipe.finish = PhotoFinish(frame: .black, border: 0.12, layout: .post, dateStamp: "2026.10.16")
        XCTAssertEqual(try JSONDecoder().decode(PhotoRecipe.self, from: JSONEncoder().encode(recipe)), recipe)
    }

    func testLayoutsFitPortraitAndLandscapeWithoutStretching() {
        for size in [CGSize(width: 4000, height: 3000), CGSize(width: 3000, height: 4000), CGSize(width: 12000, height: 9000)] {
            for layout in PhotoFinish.Layout.allCases {
                for frame in PhotoFinish.Frame.allCases {
                    let finish = PhotoFinish(frame: frame, border: 0.16, layout: layout)
                    let geometry = finish.geometry(for: size)
                    XCTAssertLessThanOrEqual(max(geometry.canvas.width, geometry.canvas.height), 8192)
                    XCTAssertTrue(geometry.canvas.insetBy(dx: -0.01, dy: -0.01).contains(geometry.photo))
                    XCTAssertEqual(geometry.photo.width / geometry.photo.height, size.width / size.height, accuracy: 0.0001)
                    if let ratio = layout.ratio {
                        XCTAssertEqual(geometry.canvas.width / geometry.canvas.height, ratio, accuracy: 0.001)
                    }
                }
            }
        }
    }

    func testFinishedPreviewAndExportDimensionsAgree() async throws {
        let renderer = PhotoRenderer()
        let data = try TestImages.jpeg(width: 400, height: 300)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var recipe = PhotoRecipe.untouched
        recipe.finish = PhotoFinish(frame: .instant, layout: .story, dateStamp: "2026.10.16")
        let preview = await renderer.preview(id: UUID(), sourceURL: url, look: .original, recipe: recipe)
        let output = try await renderer.export(source: data, look: .original, recipe: recipe, watermark: false, format: .jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(try XCTUnwrap(preview).size.width, CGFloat(image.width))
        XCTAssertEqual(try XCTUnwrap(preview).size.height, CGFloat(image.height))
        XCTAssertEqual(Double(image.width) / Double(image.height), 9.0 / 16, accuracy: 0.005)
    }

    func testNoFinishLeavesImageUnchanged() {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 30))
        XCTAssertTrue(PhotoFinishing.apply(.none, to: image) === image)
    }
}
