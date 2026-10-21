import XCTest
@testable import Snapper

/// Camera Control, the Lock Screen camera and remembering the camera
/// between launches. What needs a real iPhone (the controls showing on
/// Camera Control, the extension running while locked) is listed in
/// docs/camera-launch.md.
final class CameraLaunchTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories = []
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraLaunchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    @MainActor
    private func makeSettings() throws -> AppSettings {
        let suite = "CameraLaunchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults)
    }

    // MARK: - Camera Control look picker

    @MainActor
    func testLookPickerListsLooksInSwipeOrder() throws {
        let settings = try makeSettings()
        let library = LookLibrary.bundled()
        let favorite = try XCTUnwrap(library.premiumLooks.last)
        settings.toggleFavorite(favorite)
        let model = CameraModel(library: library)
        model.setLookOrder(settings.orderedLooks(from: library))

        let ordered = settings.orderedLooks(from: library)
        XCTAssertEqual(model.cameraControlLooks, .looks(titles: ordered.map(\.name), selected: 0))
        guard case .looks(let titles, _) = model.cameraControlLooks else { return XCTFail("expected the look picker") }
        XCTAssertEqual(titles.first, Look.original.name)
        XCTAssertEqual(titles[1], favorite.name, "favourites follow Original, as when swiping")
        XCTAssertEqual(titles.count, library.looks.count, "every look is on the picker")

        model.select(favorite)
        XCTAssertEqual(model.cameraControlLooks, .looks(titles: titles, selected: 1))
    }

    @MainActor
    func testPickingOnCameraControlSelectsThatLook() {
        let model = CameraModel(library: .bundled())
        var changes: [Look] = []
        model.onLookChange = { changes.append($0) }

        let target = model.looks[3]
        model.cameraControlSelectedLook(at: 3)
        XCTAssertEqual(model.currentLook, target)
        XCTAssertEqual(model.lookIndex, 3)
        XCTAssertEqual(model.lookChangeCount, 1, "the look's name shows, as after a swipe")
        XCTAssertEqual(changes, [target], "the app remembers it as the last look")

        model.cameraControlSelectedLook(at: model.looks.count)
        model.cameraControlSelectedLook(at: -1)
        model.cameraControlSelectedLook(at: 3)
        XCTAssertEqual(model.lookChangeCount, 1, "out-of-range and unchanged indexes are ignored")
        XCTAssertEqual(model.currentLook, target)
    }

    @MainActor
    func testPickingOnCameraControlLeavesAPreset() throws {
        let library = LookLibrary.bundled()
        let model = CameraModel(library: library)
        let base = try XCTUnwrap(library.look(id: "cream"))
        model.selectPreset(SavedPreset(name: "Soft", recipe: PhotoRecipe(lookID: base.id, strength: 0.5)))
        let index = try XCTUnwrap(model.looks.firstIndex(of: base))
        XCTAssertEqual(model.cameraControlLooks, .looks(titles: model.looks.map(\.name), selected: index),
                       "a preset shows as its look")

        let other = (index + 1) % model.looks.count
        model.cameraControlSelectedLook(at: other)
        XCTAssertNil(model.activePreset)
        XCTAssertEqual(model.currentLook, model.looks[other])
    }

    @MainActor
    func testReorderingKeepsThePickerOnTheCurrentLook() throws {
        let settings = try makeSettings()
        let library = LookLibrary.bundled()
        let model = CameraModel(library: library)
        model.setLookOrder(settings.orderedLooks(from: library))
        let look = model.looks[5]
        model.select(look)

        settings.toggleFavorite(look)
        model.setLookOrder(settings.orderedLooks(from: library))
        guard case .looks(let titles, let selected) = model.cameraControlLooks else { return XCTFail("expected the look picker") }
        XCTAssertEqual(selected, 1, "the favourite moved to the front of the swipe order")
        XCTAssertEqual(titles[selected], look.name)
        XCTAssertEqual(model.currentLook, look)
    }

    // MARK: - Camera Control exposure slider

    @MainActor
    func testExposureSliderFollowsTheExposureSetting() async {
        let model = CameraModel(library: .bundled())
        await model.start() // no camera in the Simulator: the demo feed
        XCTAssertEqual(model.cameraControlExposure, .exposure(range: -2...2, value: 0, isEnabled: true))

        model.cameraControlChangedExposure(to: 1)
        XCTAssertEqual(model.exposureBias, 1)
        model.cameraControlChangedExposure(to: 5)
        XCTAssertEqual(model.exposureBias, 2, "the same ±2 stops as the slider on screen")

        model.setManualExposure(true)
        XCTAssertEqual(model.cameraControlExposure, .exposure(range: -2...2, value: 2, isEnabled: false),
                       "disabled while ISO and shutter speed are set by hand")
        model.cameraControlChangedExposure(to: -1)
        XCTAssertEqual(model.exposureBias, 2)
    }

    func testCameraControlUpdatesReplaceOnlyTheirOwnKind() {
        let looks = CameraControlUpdate.looks(titles: ["Original"], selected: 0)
        let exposure = CameraControlUpdate.exposure(range: -2...2, value: 0, isEnabled: true)
        XCTAssertTrue(CameraControlUpdate.looks(titles: ["Original", "Cream"], selected: 1).replaces(looks))
        XCTAssertTrue(CameraControlUpdate.exposure(range: -2...2, value: 1, isEnabled: true).replaces(exposure))
        XCTAssertFalse(looks.replaces(exposure))
        XCTAssertFalse(exposure.replaces(looks))
    }

    // MARK: - Remembering the camera

    @MainActor
    func testCameraPreferencesDefaultAndPersist() throws {
        let suite = "CameraLaunchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.cameraPreferences, CameraPreferences(flash: .off, exposureBias: 0, position: .back))

        let changed = CameraPreferences(flash: .auto, exposureBias: -2 / 3, position: .front)
        settings.cameraPreferences = changed
        XCTAssertEqual(AppSettings(defaults: defaults).cameraPreferences, changed)
    }

    @MainActor
    func testAppOpensTheCameraAsItWasLeft() async throws {
        let settings = try makeSettings()
        let library = LookLibrary.bundled()
        let look = try XCTUnwrap(library.look(id: "cream"))
        settings.lastLookID = look.id
        settings.cameraPreferences = CameraPreferences(flash: .on, exposureBias: 1, position: .front)

        let app = AppModel(store: FakePurchaseService(), settings: settings,
                           captureStore: CaptureStore(directory: try makeDirectory()))
        XCTAssertEqual(app.camera.currentLook, look)
        XCTAssertEqual(app.camera.preferences, CameraPreferences(flash: .on, exposureBias: 1, position: .front))

        await app.camera.start()
        app.camera.setExposureBias(-1)
        XCTAssertEqual(settings.exposureBias, -1, "on-screen changes are remembered")
        app.camera.cameraControlChangedExposure(to: 1 / 3)
        XCTAssertEqual(settings.exposureBias, 1 / 3, "so are Camera Control's")
        XCTAssertEqual(settings.flashMode, .on)
        XCTAssertEqual(settings.cameraPosition, .front)
    }

    // MARK: - Settings shared with the Lock Screen camera

    @MainActor
    func testAppSharesTheCameraAsItIs() throws {
        let settings = try makeSettings()
        let library = LookLibrary.bundled()
        let favorite = try XCTUnwrap(library.look(id: "boardwalk"))
        settings.toggleFavorite(favorite)
        settings.aspectRatio = .square
        settings.selfTimer = .ten
        settings.showGrid = true
        settings.mirrorFrontCamera = false
        settings.cameraPreferences = CameraPreferences(flash: .auto, exposureBias: 2 / 3, position: .back)
        let service = FakePurchaseService()
        service.isPremium = true
        let app = AppModel(store: service, settings: settings, captureStore: CaptureStore(directory: try makeDirectory()))
        app.camera.select(favorite)

        let context = app.lockScreenCamera
        XCTAssertEqual(context.lookID, favorite.id)
        XCTAssertEqual(context.lookOrder, settings.orderedLooks(from: library).map(\.id))
        XCTAssertNil(context.savedPreset)
        XCTAssertEqual(context.cameraPreferences, settings.cameraPreferences)
        XCTAssertEqual(context.captureOptions, CaptureOptions(timer: .ten, aspect: .square, mirrorFrontCamera: false))
        XCTAssertTrue(context.showGrid)
        XCTAssertTrue(context.hasPremium)

        let preset = SavedPreset(name: "Warm", recipe: PhotoRecipe(lookID: "cream", strength: 0.6))
        app.camera.selectPreset(preset)
        XCTAssertEqual(app.lockScreenCamera.savedPreset, preset)
        XCTAssertEqual(app.lockScreenCamera.lookID, "cream")
    }

    func testSharedLookOrderStartsWithOriginalAndCoversEveryLook() throws {
        let library = LookLibrary.bundled()
        let first = library.looks[5], second = library.looks[2]
        var context = SnapperCameraContext()
        context.lookOrder = [first.id, "no-such-look", second.id, first.id, Look.original.id]

        let ordered = context.orderedLooks(in: library)
        XCTAssertEqual(ordered.prefix(3).map(\.id), [Look.original.id, first.id, second.id])
        XCTAssertEqual(ordered.count, library.looks.count, "looks it doesn't mention (new ones) come last")
        XCTAssertEqual(Set(ordered.map(\.id)).count, ordered.count)
    }

    func testSharedContextRoundTrips() throws {
        var context = SnapperCameraContext()
        context.lookID = "cream"
        context.lookOrder = ["cream", "boardwalk"]
        context.cameraPreferences = CameraPreferences(flash: .auto, exposureBias: 2 / 3, position: .front)
        context.savedPreset = SavedPreset(name: "Warm", recipe: PhotoRecipe(lookID: "cream", strength: 0.5))
        context.aspectRatio = AspectRatio.sixteenNine.rawValue
        context.selfTimer = SelfTimer.three.rawValue
        context.updatedAt = Date(timeIntervalSince1970: 1_000)

        let decoded = try JSONDecoder().decode(SnapperCameraContext.self, from: JSONEncoder().encode(context))
        XCTAssertEqual(decoded, context)
        XCTAssertEqual(decoded.cameraPreferences, CameraPreferences(flash: .auto, exposureBias: 2 / 3, position: .front))
        XCTAssertEqual(decoded.savedPreset?.name, "Warm")
        XCTAssertEqual(decoded.captureOptions, CaptureOptions(timer: .three, aspect: .sixteenNine))
    }

    func testUnknownSharedValuesFallBackToDefaults() {
        var context = SnapperCameraContext()
        context.flash = "strobe"
        context.position = "sideways"
        context.aspectRatio = "3:2"
        context.selfTimer = 7
        context.preset = Data("not a preset".utf8)
        XCTAssertEqual(context.cameraPreferences, CameraPreferences(flash: .off, exposureBias: 0, position: .back))
        XCTAssertEqual(context.captureOptions, CaptureOptions())
        XCTAssertNil(context.savedPreset)
    }

    // MARK: - Photos from the Lock Screen

    func testInboxKeepsPhotosWithHowTheyWereTaken() throws {
        let folder = try makeDirectory()
        let later = CapturedPhoto(data: try TestImages.jpeg(width: 8, height: 8), isFrontCamera: true, aspect: .square,
                                  style: PhotoRecipe(lookID: "cream", strength: 0.6))
        let earlier = CapturedPhoto(data: try TestImages.jpeg(width: 6, height: 6), isFrontCamera: false)
        try LockedCaptureInbox.write(later, lookID: "cream", takenAt: Date(timeIntervalSince1970: 200), to: folder)
        try LockedCaptureInbox.write(earlier, lookID: "boardwalk", takenAt: Date(timeIntervalSince1970: 100), to: folder)
        // A photo whose note was never written (the session ended mid-save) doesn't count.
        try Data("partial".utf8).write(to: folder.appendingPathComponent("\(UUID().uuidString).photo"))
        var camera = SnapperCameraContext()
        camera.lookID = "boardwalk"
        try LockedCaptureInbox.writeCamera(camera, to: folder)

        let contents = LockedCaptureInbox.read(folder)
        XCTAssertEqual(contents.photos.map(\.note.id), [earlier.id, later.id], "oldest first")
        XCTAssertEqual(contents.camera, camera)

        let loaded = try contents.photos[1].load()
        XCTAssertEqual(loaded.id, later.id)
        XCTAssertEqual(loaded.data, later.data)
        XCTAssertTrue(loaded.isFrontCamera)
        XCTAssertEqual(loaded.aspect, .square)
        XCTAssertEqual(loaded.style, later.style)
        XCTAssertEqual(loaded.takenAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(contents.photos[1].note.lookID, "cream")
    }

    func testEmptyOrMissingSessionFolderHasNothing() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(LockedCaptureInbox.read(missing).photos.isEmpty)
        XCTAssertNil(LockedCaptureInbox.read(try makeDirectory()).camera)
    }

    @MainActor
    func testLockScreenPhotosJoinTheLibraryOnce() async throws {
        let settings = try makeSettings()
        settings.autoSaveToPhotos = false
        let app = AppModel(store: FakePurchaseService(), settings: settings,
                           captureStore: CaptureStore(directory: try makeDirectory()))
        await app.captures.load()

        let session = try makeDirectory()
        let photo = CapturedPhoto(data: try TestImages.jpeg(width: 8, height: 8), isFrontCamera: false, aspect: .square)
        let takenAt = Date(timeIntervalSince1970: 1_000)
        try LockedCaptureInbox.write(photo, lookID: "cream", takenAt: takenAt, to: session)
        var camera = app.lockScreenCamera
        camera.lookID = "boardwalk"
        camera.cameraPreferences = CameraPreferences(flash: .auto, exposureBias: 1 / 3, position: .back)
        camera.updatedAt = Date()
        try LockedCaptureInbox.writeCamera(camera, to: session)

        var finished: [URL] = []
        await app.importLockScreenSessions([session]) { finished.append($0) }
        XCTAssertEqual(app.captures.records.map(\.id), [photo.id])
        let record = try XCTUnwrap(app.captures.records.first)
        XCTAssertEqual(record.recipe.lookID, "cream")
        XCTAssertEqual(record.recipe.crop.shape, CropShape(cameraAspect: .square))
        XCTAssertEqual(record.takenAt, takenAt)
        XCTAssertEqual(finished, [session], "the system may now delete the session")
        XCTAssertEqual(settings.recentLookIDs.first, "cream")

        XCTAssertEqual(app.camera.currentLook.id, "boardwalk", "Snapper carries on with the Lock Screen's last look")
        XCTAssertEqual(settings.lastLookID, "boardwalk")
        XCTAssertEqual(settings.flashMode, .auto)
        XCTAssertEqual(settings.exposureBias, 1 / 3)

        // If clearing the session failed, a second import adds nothing new.
        finished = []
        await app.importLockScreenSessions([session]) { finished.append($0) }
        XCTAssertEqual(app.captures.records.count, 1)
        XCTAssertEqual(finished, [session])
    }

    @MainActor
    func testImportWaitsForTheLibraryToLoad() async throws {
        let settings = try makeSettings()
        settings.autoSaveToPhotos = false
        let app = AppModel(store: FakePurchaseService(), settings: settings,
                           captureStore: CaptureStore(directory: try makeDirectory()))
        let session = try makeDirectory()
        try LockedCaptureInbox.write(CapturedPhoto(data: try TestImages.jpeg(width: 8, height: 8), isFrontCamera: false),
                                     lookID: "cream", to: session)
        var finished: [URL] = []
        await app.importLockScreenSessions([session]) { finished.append($0) }
        XCTAssertTrue(app.captures.records.isEmpty, "without the index, photos already imported can't be told apart")
        XCTAssertTrue(finished.isEmpty)
    }
}
