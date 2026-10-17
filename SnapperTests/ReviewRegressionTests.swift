import XCTest
@testable import Snapper

@MainActor
final class ReviewRegressionTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    func testLargerPreviewUpgradesCachedProxy() async throws {
        let source = directory.appendingPathExtension("jpg")
        try TestImages.jpeg(width: 800, height: 600).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let renderer = PhotoRenderer()
        let id = UUID()
        let small = await renderer.preview(id: id, sourceURL: source, look: .original, recipe: .untouched, maxPixelSize: 100)
        let large = await renderer.preview(id: id, sourceURL: source, look: .original, recipe: .untouched, maxPixelSize: 800)
        XCTAssertEqual(small?.size.width, 100)
        XCTAssertEqual(large?.size.width, 800, "a thumbnail must not become the editor's source")
    }

    func testMalformedPresetArchiveIsPreservedAndCannotBeUsed() throws {
        let preset = SavedPreset(name: "Bad", recipe: PhotoRecipe(lookID: "cream", strength: 1e100))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preset))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "presets": [object]])
        defaults.set(data, forKey: PresetStore.storageKey)
        let store = PresetStore(defaults: defaults)
        XCTAssertTrue(store.loadFailed)
        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertFalse(store.canUse(preset, hasPremium: true))
        XCTAssertThrowsError(try store.save(name: "New", recipe: .untouched, hasPremium: true))
        XCTAssertEqual(defaults.data(forKey: PresetStore.storageKey), data)
    }

    func testDuplicatePresetIDsAreRejected() throws {
        let preset = SavedPreset(name: "Good", recipe: .untouched)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preset))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "presets": [object, object]])
        defaults.set(data, forKey: PresetStore.storageKey)
        XCTAssertTrue(PresetStore(defaults: defaults).loadFailed)
        XCTAssertEqual(defaults.data(forKey: PresetStore.storageKey), data)
    }

    func testInvalidStyleCannotBeSavedAndDeletedPresetCannotBeApplied() throws {
        let store = PresetStore(defaults: defaults)
        XCTAssertThrowsError(try store.save(name: "Bad", recipe: PhotoRecipe(lookID: "cream", strength: .infinity), hasPremium: true))
        XCTAssertThrowsError(try store.save(name: "Bad", recipe: PhotoRecipe(lookID: "cream", adjustments: PhotoAdjustments(grain: -1)), hasPremium: true))
        let preset = try store.save(name: "Good", recipe: .untouched, hasPremium: true)
        try store.delete(preset)
        XCTAssertFalse(store.canUse(preset, hasPremium: true))
    }

    func testShareSessionsDoNotDeleteEachOtherOrCollide() async throws {
        let looks = LookLibrary.bundled()
        let captures = CaptureLibrary(library: looks, renderer: PhotoRenderer(), store: CaptureStore(directory: directory))
        let time = Date(timeIntervalSince1970: 1_000_000)
        let first = try await captures.importPhoto(TestImages.jpeg(width: 32, height: 24), createdAt: time)
        let second = try await captures.importPhoto(TestImages.jpeg(width: 24, height: 32), createdAt: time)
        let one = try await captures.exportForSharing([first, second], watermark: false)
        let two = try await captures.exportForSharing([first], watermark: false)
        defer {
            for folder in Set((one + two).map { $0.deletingLastPathComponent() }) { try? FileManager.default.removeItem(at: folder) }
        }
        XCTAssertEqual(Set(one + two).count, 3)
        XCTAssertTrue((one + two).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testBackgroundAndCoveredCameraCancelTimerAndRejectShutter() async {
        let camera = CameraModel(library: .bundled())
        await camera.start()
        camera.shutterPressed(options: CaptureOptions(timer: .three))
        XCTAssertNotNil(camera.countdown)
        camera.setPreviewVisible(false)
        XCTAssertNil(camera.countdown)
        let count = camera.shutterCount
        camera.capture()
        camera.shutterPressed(options: CaptureOptions())
        XCTAssertEqual(camera.shutterCount, count)
        camera.setPreviewVisible(true)
        camera.shutterPressed(options: CaptureOptions(timer: .three))
        camera.scenePhaseChanged(.background)
        XCTAssertNil(camera.countdown)
        XCTAssertFalse(camera.canCapture)
        camera.capture()
        XCTAssertEqual(camera.shutterCount, count)
        camera.scenePhaseChanged(.active)
        XCTAssertTrue(camera.canCapture)
    }

    func testPresetRemovalFromSwipeOrderClearsStyle() throws {
        let camera = CameraModel(library: .bundled())
        camera.selectPreset(SavedPreset(name: "Soft", recipe: PhotoRecipe(lookID: "cream", strength: 0.5)))
        camera.setLookOrder([.original])
        XCTAssertNil(camera.activePreset)
        XCTAssertEqual(camera.captureStyle, .untouched)
    }

    func testPresetAndImportSheetsPauseCameraUntilDismissed() async {
        let app = AppModel(store: FakePurchaseService(), settings: AppSettings(defaults: defaults))
        await app.camera.start()
        app.openCameraPresets()
        XCTAssertFalse(app.camera.canCapture)
        app.cameraPresetsDismissed()
        XCTAssertTrue(app.camera.canCapture)
        app.isImportingPreset = true
        app.updateCameraVisibility()
        XCTAssertFalse(app.camera.canCapture)
        app.isImportingPreset = false
        app.updateCameraVisibility()
        XCTAssertTrue(app.camera.canCapture)
    }

    func testDeletionUsesExplicitTargetInsteadOfSelection() async throws {
        let looks = LookLibrary.bundled()
        let captures = CaptureLibrary(library: looks, renderer: PhotoRenderer(), store: CaptureStore(directory: directory))
        let first = try await captures.importPhoto(TestImages.jpeg(width: 32, height: 24))
        let second = try await captures.importPhoto(TestImages.jpeg(width: 32, height: 24))
        let model = LibraryModel(captures: captures, looks: looks, settings: AppSettings(defaults: defaults),
                                 hasPremium: { true }, requestPremium: { _, _, _ in })
        model.isSelecting = true
        model.selection = [first.id]
        model.delete([second.id])
        XCTAssertNotNil(captures.record(id: first.id))
        XCTAssertNil(captures.record(id: second.id))
    }
}
