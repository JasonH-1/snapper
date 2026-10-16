import XCTest
@testable import Snapper

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testFavoritesComeFirstAfterOriginal() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let library = LookLibrary.bundled()
        let premium = try XCTUnwrap(library.premiumLooks.last)
        let free = try XCTUnwrap(library.freeLooks.last { !$0.isOriginal })

        settings.toggleFavorite(premium)
        settings.toggleFavorite(free)
        settings.toggleFavorite(.original) // ignored

        let ordered = settings.orderedLooks(from: library)
        XCTAssertEqual(ordered.first, .original)
        XCTAssertEqual(Array(ordered[1...2]), [premium, free])
        XCTAssertEqual(ordered.count, library.looks.count, "every look appears exactly once")
        XCTAssertEqual(Set(ordered.map(\.id)).count, ordered.count)

        settings.toggleFavorite(premium)
        XCTAssertFalse(settings.isFavorite(premium))
        XCTAssertEqual(AppSettings(defaults: defaults).favoriteLookIDs, [free.id], "favorites persist")
    }

    @MainActor
    func testDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.autoSaveToPhotos)
        XCTAssertFalse(settings.alsoSaveOriginal)
        XCTAssertFalse(settings.hasCompletedOnboarding)
    }
}
