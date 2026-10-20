import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Snapper

@MainActor
final class ReliabilityFixTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func library(_ name: String) -> CaptureLibrary {
        CaptureLibrary(library: .bundled(), renderer: PhotoRenderer(),
                       store: CaptureStore(directory: root.appendingPathComponent(name)))
    }

    private func app() async throws -> AppModel {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.autoSaveToPhotos = false
        let app = AppModel(store: FakePurchaseService(), settings: settings,
                           captureStore: CaptureStore(directory: root.appendingPathComponent("library")))
        app.isLibraryLoaded = await app.captures.load()
        return app
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testUnreadableIndexIsPreservedAndBlocksImportsUntilRetry() async throws {
        let directory = try folder("library")
        let index = directory.appendingPathComponent("captures.json")
        let damaged = Data("{incomplete".utf8)
        try damaged.write(to: index)
        let captures = library("library")
        let loaded = await captures.load()
        XCTAssertFalse(loaded)
        XCTAssertNotNil(captures.storageError)
        do {
            _ = try await captures.importPhoto(TestImages.jpeg(width: 8, height: 8))
            XCTFail("Must not replace an unreadable index")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: index), damaged)
        XCTAssertThrowsError(try CaptureStore(directory: directory).save([]))
        XCTAssertEqual(try Data(contentsOf: index), damaged)
        // Simulate a repaired index; retry works without restarting the app.
        try Data("[]".utf8).write(to: index)
        let retried = await captures.load()
        XCTAssertTrue(retried)
        XCTAssertNil(captures.storageError)
        let photo = try await captures.importPhoto(TestImages.jpeg(width: 8, height: 8))
        XCTAssertEqual(try CaptureStore(directory: directory).load().map(\.id), [photo.id])
    }

    func testImportBeforeExplicitLoadPreservesExistingRecordsAndIsDurable() async throws {
        let old = library("library")
        let first = try await old.importPhoto(TestImages.jpeg(width: 8, height: 8))
        let reopened = library("library")
        let second = try await reopened.importPhoto(TestImages.jpeg(width: 8, height: 8))
        let disk = try CaptureStore(directory: root.appendingPathComponent("library")).load()
        XCTAssertEqual(Set(disk.map(\.id)), [first.id, second.id])
    }

    func testLockScreenKeepsIncompleteSessionsAndImportsOtherPhotos() async throws {
        let app = try await app()
        let invalidNote = try folder("bad-note")
        let orphan = try folder("orphan")
        let missingPhoto = try folder("missing-photo")
        let unreadablePhoto = try folder("unreadable-photo")
        let valid = try folder("valid")
        let bytes = try TestImages.jpeg(width: 8, height: 8)
        for directory in [invalidNote, missingPhoto, unreadablePhoto, valid] {
            let photo = CapturedPhoto(data: bytes, isFrontCamera: false)
            try LockedCaptureInbox.write(photo, lookID: "original", to: directory)
            if directory == invalidNote {
                try Data("broken".utf8).write(to: directory.appendingPathComponent("\(photo.id).snappernote"))
            } else if directory == missingPhoto || directory == unreadablePhoto {
                let file = directory.appendingPathComponent("\(photo.id).photo")
                try FileManager.default.removeItem(at: file)
                if directory == unreadablePhoto {
                    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                }
            }
        }
        try bytes.write(to: orphan.appendingPathComponent("\(UUID()).photo"))
        let missingFolder = root.appendingPathComponent("absent")
        var cleared: [URL] = []
        await app.importLockScreenSessions([invalidNote, orphan, missingPhoto, unreadablePhoto, missingFolder, valid]) {
            cleared.append($0)
        }
        XCTAssertEqual(cleared, [valid])
        XCTAssertEqual(app.captures.records.count, 1)
        XCTAssertEqual(try CaptureStore(directory: root.appendingPathComponent("library")).load().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidNote.path))
    }

    func testLockScreenWaitsForIndexPersistenceAndRetryDoesNotDuplicate() async throws {
        let app = try await app()
        let session = try folder("session")
        let photo = CapturedPhoto(data: try TestImages.jpeg(width: 8, height: 8), isFrontCamera: false)
        try LockedCaptureInbox.write(photo, lookID: "original", to: session)
        let directory = try folder("library")
        let index = directory.appendingPathComponent("captures.json")
        // Original files can be written, but the index cannot.
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        var cleared: [URL] = []
        await app.importLockScreenSessions([session]) { cleared.append($0) }
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertNotNil(app.captures.storageError)
        XCTAssertEqual(app.captures.records.map(\.id), [photo.id])
        try FileManager.default.removeItem(at: index)
        await app.importLockScreenSessions([session]) { cleared.append($0) }
        XCTAssertEqual(cleared, [session])
        XCTAssertEqual(app.captures.records.map(\.id), [photo.id])
        XCTAssertEqual(try CaptureStore(directory: directory).load().map(\.id), [photo.id])
        XCTAssertNil(app.captures.storageError)
    }

    func testRestoredPhotosAreNotMarkedSavedOnAnotherDevice() async throws {
        let old = library("old")
        let photo = try await old.importPhoto(TestImages.jpeg(width: 8, height: 8))
        old.markSaved(id: photo.id)
        try await old.flush()
        let backup = try await old.makeBackup(presets: [], favoriteLookIDs: [], appVersion: "1")
        defer { try? FileManager.default.removeItem(at: backup.url.deletingLastPathComponent()) }
        let restored = library("new")
        _ = try await restored.restoreBackup(from: backup.url)
        XCTAssertNil(restored.record(id: photo.id)?.savedRecipe)
        XCTAssertTrue(restored.alreadySavedIDs.isEmpty)
        restored.deleteAlreadySaved()
        XCTAssertEqual(restored.records.count, 1)
        let reopened = library("new")
        await reopened.load()
        XCTAssertNil(reopened.record(id: photo.id)?.savedRecipe)
        // An existing record's locally established save status is left alone.
        restored.markSaved(id: photo.id)
        try await restored.flush()
        _ = try await restored.restoreBackup(from: backup.url)
        XCTAssertTrue(try XCTUnwrap(restored.record(id: photo.id)).isSavedWithCurrentRecipe)
    }

    func testBackupRejectsOverflowingAndOutOfBoundsLengths() throws {
        let cases: [[Int64]] = [[Int64.max, Int64.max, Int64.max], [0], [-1], [100]]
        for lengths in cases {
            let photos = lengths.map { LibraryBackup.Manifest.Photo(record: CaptureRecord(fileName: "photo.jpg", recipe: .untouched), byteCount: $0) }
            let manifest = LibraryBackup.Manifest(createdAt: Date(), appVersion: "1", photos: photos, presets: [], favoriteLookIDs: [])
            let json = try JSONEncoder().encode(manifest)
            var data = Data("SNPRBKUP".utf8)
            var version = UInt32(1).littleEndian
            var length = UInt64(json.count).littleEndian
            withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(json)
            let url = root.appendingPathComponent("bad.snapperbackup")
            try data.write(to: url)
            XCTAssertThrowsError(try LibraryBackup.readManifest(from: url)) { error in
                XCTAssertEqual(error as? LibraryBackup.BackupError, .damaged)
            }
        }
    }
}
