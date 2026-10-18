import XCTest
@testable import Snapper

final class GuideTests: XCTestCase {
    func testEverySectionHasTopicsWithStableUniqueIDs() {
        XCTAssertEqual(Set(GuideCatalog.topics.map(\.id)).count, GuideCatalog.topics.count)
        XCTAssertEqual(Set(GuideCatalog.topics.map(\.section)), Set(GuideCatalog.sections))
        for topic in GuideCatalog.topics {
            XCTAssertFalse(topic.title.isEmpty)
            XCTAssertFalse(topic.summary.isEmpty)
            XCTAssertFalse(topic.steps.isEmpty)
        }
    }

    func testSearchFindsCommonUserVocabularyAndCombinesTerms() {
        for (query, id) in [("filter", "looks"), ("yellow", "white-balance"),
                            ("blurry", "focus"), ("airdrop", "style-sharing"),
                            ("where photos", "saving"), ("ISO shutter", "manual")] {
            XCTAssertTrue(GuideCatalog.search(query).contains { $0.id == id }, query)
        }
        XCTAssertEqual(GuideCatalog.search(" \n ").count, GuideCatalog.topics.count)
        XCTAssertTrue(GuideCatalog.search("no-such-guide-topic-123").isEmpty)
    }

    @MainActor
    func testGuideShortcutIsConsumedOnceWithoutChangingPhotoSettings() throws {
        let name = "GuideTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let app = AppModel(store: FakePurchaseService(), settings: AppSettings(defaults: defaults))
        let initialLook = app.camera.currentLook.id
        app.pendingGuideDestination = .styles
        app.openPendingGuideDestination()
        XCTAssertNil(app.pendingGuideDestination)
        XCTAssertTrue(app.isShowingCameraPresets)
        XCTAssertEqual(app.camera.currentLook.id, initialLook)
        app.isShowingCameraPresets = false
        app.openPendingGuideDestination()
        XCTAssertFalse(app.isShowingCameraPresets)
    }

    @MainActor
    func testGuideSampleCanRenderOriginalAndSquareCrop() async throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "demo-scene", withExtension: "jpg"))
        let renderer = PhotoRenderer()
        let id = UUID()
        let before = await renderer.original(id: id, sourceURL: source, maxPixelSize: 700)
        XCTAssertNotNil(before)
        var recipe = PhotoRecipe(lookID: Look.original.id)
        recipe.crop.shape = .square
        let result = await renderer.preview(id: id, sourceURL: source, look: .original, recipe: recipe, maxPixelSize: 700)
        let image = try XCTUnwrap(result)
        XCTAssertEqual(image.size.width, image.size.height, accuracy: 1)
    }
}
