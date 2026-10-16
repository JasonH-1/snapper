import CoreImage
import XCTest
@testable import Snapper

final class PresetExchangeTests: XCTestCase {
    func testPortableRoundTripContainsOnlyStyle() throws {
        var recipe = PhotoRecipe(lookID: "cream", strength: 0.42, adjustments: PhotoAdjustments(warmth: 0.2, grain: 0.1))
        recipe.crop.quarterTurns = 1
        recipe.finish = PhotoFinish(frame: .instant, dateStamp: "2026.10.16")
        let preset = SavedPreset(name: "Window Light", recipe: recipe)
        let data = try PresetDocument(preset).data
        let file = try PresetFile.decode(data, looks: .bundled())
        XCTAssertEqual(file.recipe.strength, 0.42)
        XCTAssertEqual(file.recipe.adjustments, recipe.adjustments)
        XCTAssertEqual(file.recipe.crop, .none)
        XCTAssertEqual(file.recipe.finish, .none)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["id"])
        XCTAssertNil(json["crop"])
        XCTAssertNil(json["finish"])
    }

    func testRejectsMalformedOversizedUnknownAndOutOfRangeFiles() throws {
        let data = try PresetDocument(SavedPreset(name: "Good", recipe: PhotoRecipe(lookID: "cream"))).data
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let changes: [(String, Any)] = [("version", 2), ("lookID", "missing"), ("strength", -0.1),
                                      ("strength", 1.1), ("name", "\n"), ("name", "Bad\nName"),
                                      ("name", String(repeating: "x", count: 41)),
                                      ("adjustments", ["warmth": 10]), ("adjustments", ["grain": -1])]
        for (key, value) in changes {
            var invalid = original
            invalid[key] = value
            XCTAssertThrowsError(try PresetFile.decode(JSONSerialization.data(withJSONObject: invalid), looks: .bundled()), key)
        }
        XCTAssertThrowsError(try PresetFile.decode(Data("not json".utf8), looks: .bundled()))
        XCTAssertThrowsError(try PresetFile.decode(Data(repeating: 32, count: PresetFile.maximumBytes + 1), looks: .bundled()))
    }

    func testBoundedFileReadRejectsLargeInput() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 32, count: PresetFile.maximumBytes + 50).write(to: url)
        XCTAssertThrowsError(try PresetFile.read(url, looks: .bundled()))
    }

    func testOccasionsHaveSmallValidSelectionsIncludingFreeLooks() {
        let library = LookLibrary.bundled()
        for occasion in LookOccasion.allCases {
            let looks = occasion.lookIDs.compactMap { library.look(id: $0) }
            XCTAssertEqual(looks.count, occasion.lookIDs.count)
            XCTAssertEqual(Set(occasion.lookIDs).count, looks.count)
            XCTAssertTrue((2...3).contains(looks.count))
            XCTAssertTrue(looks.contains { !$0.isPremium })
        }
    }

    func testLivePresetRendererMatchesPhotoRendererPipeline() throws {
        let look = try XCTUnwrap(LookLibrary.bundled().look(id: "halo"))
        let lut = LUTStore.shared.lut(for: look)
        let recipe = PhotoRecipe(lookID: look.id, strength: 0.43,
                                 adjustments: PhotoAdjustments(brightness: 0.2, contrast: -0.1, saturation: 0.1,
                                                               warmth: 0.3, fade: 0.1, grain: 0.1))
        let input = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let state = PreviewRenderer.LookState(id: look.id, lut: lut, effects: look.effects,
                                             strength: recipe.strength, adjustments: recipe.adjustments)
        let preview = PreviewRenderer.render(state, on: input, seed: 123)
        let export = PhotoEditing.apply(recipe, look: look, lut: lut, seed: 123, to: input)
        let context = CIContext()
        func pixels(_ image: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
            bytes.withUnsafeMutableBytes { buffer in
                context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 32 * 4, bounds: input.extent,
                               format: .RGBA8, colorSpace: LookPipeline.outputColorSpace)
            }
            return bytes
        }
        XCTAssertEqual(pixels(preview), pixels(export))
    }
}

@MainActor
final class PhotoWorkflowTests: XCTestCase {
    func testCameraPresetSelectionAndSwipeReset() throws {
        let library = LookLibrary.bundled()
        let camera = CameraModel(library: library)
        let preset = SavedPreset(name: "Soft", recipe: PhotoRecipe(lookID: "cream", strength: 0.4,
                                                                 adjustments: PhotoAdjustments(warmth: 0.3)))
        camera.selectPreset(preset)
        XCTAssertEqual(camera.captureStyle.strength, 0.4)
        XCTAssertEqual(camera.captureStyle.adjustments.warmth, 0.3)
        camera.swipeChanged(translation: -10, width: 300)
        camera.swipeEnded(translation: -10, predictedTranslation: -10, width: 300)
        XCTAssertEqual(camera.activePreset, preset, "cancelling a swipe keeps the style")
        camera.swipeChanged(translation: -200, width: 300)
        camera.swipeEnded(translation: -200, predictedTranslation: -200, width: 300)
        XCTAssertNil(camera.activePreset)
        XCTAssertEqual(camera.captureStyle.strength, 1)
        XCTAssertEqual(camera.captureStyle.adjustments, .none)
        camera.selectPreset(preset)
        camera.select(try XCTUnwrap(library.look(id: "cream")))
        XCTAssertNil(camera.activePreset, "selecting the same base look clears a custom style")
    }

    func testImportedPresetsGetNewIDsAndRespectFreeQuota() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PresetStore(defaults: defaults)
        let original = SavedPreset(name: "Soft", recipe: PhotoRecipe(lookID: "cream", strength: 0.5))
        let file = try PresetFile.decode(PresetDocument(original).data, looks: .bundled())
        let imported = try store.save(name: file.name, recipe: file.recipe, hasPremium: false)
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertThrowsError(try store.save(name: file.name, recipe: file.recipe, hasPremium: false))
        XCTAssertEqual(store.presets, [imported])
        let second = try store.save(name: file.name, recipe: file.recipe, hasPremium: true)
        XCTAssertNotEqual(second.id, imported.id)
    }

    func testCaptureKeepsFrozenStyleAndCameraCrop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let looks = LookLibrary.bundled()
        let library = CaptureLibrary(library: looks, renderer: PhotoRenderer(), store: CaptureStore(directory: directory))
        let look = try XCTUnwrap(looks.look(id: "cream"))
        var style = PhotoRecipe(lookID: look.id, strength: 0.35, adjustments: PhotoAdjustments(warmth: 0.2))
        style.crop.quarterTurns = 1
        style.finish.frame = .instant
        let photo = CapturedPhoto(data: try TestImages.jpeg(width: 64, height: 48), isFrontCamera: false,
                                  aspect: .square, style: style)
        let record = try await library.add(photo, look: look)
        XCTAssertEqual(record.recipe.strength, 0.35)
        XCTAssertEqual(record.recipe.adjustments.warmth, 0.2)
        XCTAssertEqual(record.recipe.crop.shape, .square)
        XCTAssertEqual(record.recipe.crop.quarterTurns, 0)
        XCTAssertEqual(record.recipe.finish, .none)
        XCTAssertEqual(record.initialRecipe, record.recipe)
    }

    func testBatchFinishingPreservesDatesCropsAndLaterEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let looks = LookLibrary.bundled()
        let captures = CaptureLibrary(library: looks, renderer: PhotoRenderer(), store: CaptureStore(directory: directory))
        let first = try await captures.importPhoto(TestImages.jpeg(width: 64, height: 48))
        let second = try await captures.importPhoto(TestImages.jpeg(width: 48, height: 64))
        var firstRecipe = first.recipe
        firstRecipe.crop.quarterTurns = 1
        firstRecipe.finish.dateStamp = "2020.01.02"
        firstRecipe.adjustments.warmth = 0.2
        captures.updateRecipe(id: first.id, firstRecipe)
        let snapshots = captures.records
        var later = second.recipe
        later.adjustments.brightness = 0.3
        captures.updateRecipe(id: second.id, later)
        let purchase = FakePurchaseService()
        let model = LibraryModel(captures: captures, looks: looks, settings: AppSettings(defaults: defaults),
                                 hasPremium: { purchase.isPremium }, requestPremium: { _, _, _ in })
        let finish = BatchFinish(replaceFrame: true, frame: .cream, border: 0.1, replaceLayout: true, layout: .story)
        XCTAssertFalse(model.applyFinishing(finish, to: snapshots))
        purchase.isPremium = true
        XCTAssertTrue(model.applyFinishing(finish, to: snapshots))
        let result = try XCTUnwrap(captures.record(id: first.id)?.recipe)
        XCTAssertEqual(result.finish.frame, .cream)
        XCTAssertEqual(result.finish.layout, .story)
        XCTAssertEqual(result.finish.dateStamp, "2020.01.02")
        XCTAssertEqual(result.crop, firstRecipe.crop)
        XCTAssertEqual(result.adjustments, firstRecipe.adjustments)
        XCTAssertEqual(captures.record(id: second.id)?.recipe, later)
        XCTAssertEqual(model.selection, [first.id])
        model.undoBatch()
        XCTAssertEqual(captures.record(id: first.id)?.recipe, firstRecipe)
        XCTAssertEqual(captures.record(id: second.id)?.recipe, later)
    }

    func testBatchFinishOnlyChangesRequestedParts() {
        var recipe = PhotoRecipe.untouched
        recipe.finish = PhotoFinish(frame: .black, border: 0.12, layout: .square, dateStamp: "2000.01.01")
        XCTAssertEqual(BatchFinish().applying(to: recipe), recipe)
        let layoutOnly = BatchFinish(replaceLayout: true, layout: .story).applying(to: recipe)
        XCTAssertEqual(layoutOnly.finish.frame, .black)
        XCTAssertEqual(layoutOnly.finish.border, 0.12)
        XCTAssertEqual(layoutOnly.finish.dateStamp, "2000.01.01")
        let frameOnly = BatchFinish(replaceFrame: true, frame: .none).applying(to: recipe)
        XCTAssertEqual(frameOnly.finish.layout, .square)
        XCTAssertEqual(frameOnly.finish.dateStamp, "2000.01.01")
    }

    func testCameraRestoresPresetAndHandlesExpiryRenameAndDeletion() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        _ = try settings.presets.save(name: "Free", recipe: PhotoRecipe(lookID: "boardwalk"), hasPremium: true)
        let premiumSlot = try settings.presets.save(name: "Second", recipe: PhotoRecipe(lookID: "cream", strength: 0.4), hasPremium: true)
        settings.lastPresetID = premiumSlot.id
        let service = FakePurchaseService()
        service.isPremium = true
        let app = AppModel(store: service, settings: settings)
        app.synchronizeCameraPreset()
        XCTAssertEqual(app.camera.activePreset, premiumSlot)
        service.isPremium = false
        app.synchronizeCameraPreset()
        XCTAssertNil(app.camera.activePreset)
        XCTAssertEqual(settings.lastPresetID, premiumSlot.id, "remember choice for renewal")
        XCTAssertFalse(app.shootWithPreset(premiumSlot))
        service.isPremium = true
        app.synchronizeCameraPreset()
        XCTAssertEqual(app.camera.activePreset, premiumSlot)
        try settings.presets.rename(premiumSlot, to: "Renamed")
        app.synchronizeCameraPreset()
        XCTAssertEqual(app.camera.activePreset?.name, "Renamed")
        try settings.presets.delete(premiumSlot)
        app.synchronizeCameraPreset()
        XCTAssertNil(app.camera.activePreset)
        XCTAssertNil(settings.lastPresetID)
    }

    func testLastCameraPresetPersists() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let id = UUID()
        settings.lastPresetID = id
        XCTAssertEqual(AppSettings(defaults: defaults).lastPresetID, id)
        settings.lastPresetID = nil
        XCTAssertNil(AppSettings(defaults: defaults).lastPresetID)
    }
}
