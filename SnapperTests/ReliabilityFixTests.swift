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
        await app.captures.load()
        return app
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An index that can't be read (rather than one that's damaged) may read
    /// fine later, so nothing replaces it until a retry succeeds.
    func testUnreadableIndexIsPreservedAndBlocksImportsUntilRetry() async throws {
        let directory = try folder("library")
        let index = directory.appendingPathComponent("captures.json")
        // A folder where the index should be can't be read as one.
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        let captures = library("library")
        let loaded = await captures.load()
        XCTAssertFalse(loaded)
        XCTAssertNotNil(captures.storageError)
        do {
            _ = try await captures.importPhoto(TestImages.jpeg(width: 8, height: 8))
            XCTFail("Must not replace an unreadable index")
        } catch {}
        XCTAssertThrowsError(try CaptureStore(directory: directory).save([]))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        // Once it reads again, retry works without restarting the app.
        try FileManager.default.removeItem(at: index)
        try Data("[]".utf8).write(to: index)
        let retried = await captures.load()
        XCTAssertTrue(retried)
        XCTAssertNil(captures.storageError)
        let photo = try await captures.importPhoto(TestImages.jpeg(width: 8, height: 8))
        XCTAssertEqual(try CaptureStore(directory: directory).load().map(\.id), [photo.id])
    }

    /// A damaged index can't be fixed by retrying: it's moved aside and
    /// rebuilt, keeping every record that still reads and bringing back the
    /// photos the rest pointed to.
    func testDamagedIndexIsRebuiltKeepingReadableRecordsAndPhotos() async throws {
        let directory = try folder("library")
        let store = CaptureStore(directory: directory)
        // Originals are named by their record's id.
        let editedID = UUID()
        let edited = CaptureRecord(id: editedID, fileName: "\(editedID.uuidString).jpg", source: .imported,
                                   recipe: PhotoRecipe(lookID: "boardwalk", strength: 0.7))
        let lost = UUID()
        try store.write(TestImages.jpeg(width: 8, height: 8), fileName: edited.fileName)
        try store.write(TestImages.jpeg(width: 6, height: 6), fileName: "\(lost.uuidString).jpg")
        try Data("not a photo".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).jpg"))
        // One good record and one that no longer decodes.
        let good = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited))
        let index = try JSONSerialization.data(withJSONObject: [good, ["id": "broken"]])
        try index.write(to: directory.appendingPathComponent("captures.json"))

        let captures = library("library")
        let loaded = await captures.load()
        XCTAssertTrue(loaded)
        XCTAssertNil(captures.storageError)
        XCTAssertNotNil(captures.notice)
        XCTAssertEqual(Set(captures.records.map(\.id)), [edited.id, lost])
        XCTAssertEqual(captures.record(id: edited.id)?.recipe, edited.recipe, "a record that still reads keeps its edit")
        XCTAssertEqual(captures.record(id: lost)?.recipe, .untouched)
        XCTAssertEqual(Set(try store.load().map(\.id)), [edited.id, lost])
        let copies = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("captures.damaged-") }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(copies[0])), index, "the damaged index is kept")

        // An index cut off mid-file still brings every photo back.
        try Data("[{\"id\":".utf8).write(to: directory.appendingPathComponent("captures.json"))
        let rebuilt = library("library")
        await rebuilt.load()
        XCTAssertEqual(Set(rebuilt.records.map(\.id)), [edited.id, lost])
    }

    /// A shot is never dropped because the index can't be read: it's kept,
    /// and joins the index once the index loads.
    func testShotIsKeptWhileIndexIsUnreadable() async throws {
        let directory = try folder("library")
        let index = directory.appendingPathComponent("captures.json")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        let captures = library("library")
        await captures.load()
        let photo = CapturedPhoto(data: try TestImages.jpeg(width: 8, height: 8), isFrontCamera: false)
        let record = try await captures.add(photo, look: .original)
        XCTAssertEqual(captures.records.map(\.id), [photo.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: captures.url(for: record).path))
        XCTAssertNotNil(captures.storageError)

        try FileManager.default.removeItem(at: index)
        let earlier = CaptureRecord(fileName: "\(UUID().uuidString).jpg", recipe: .untouched)
        try CaptureStore(directory: directory).save([earlier])
        let retried = await captures.load()
        XCTAssertTrue(retried)
        XCTAssertEqual(Set(captures.records.map(\.id)), [photo.id, earlier.id])
        try await captures.flush()
        XCTAssertEqual(Set(try CaptureStore(directory: directory).load().map(\.id)), [photo.id, earlier.id])
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
        // A note whose photo is gone has nothing left to wait for.
        XCTAssertEqual(cleared, [missingPhoto, valid])
        XCTAssertEqual(app.captures.records.count, 1)
        XCTAssertEqual(try CaptureStore(directory: root.appendingPathComponent("library")).load().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidNote.path))
    }

    /// A photo whose note never arrived (the camera stopped between the two)
    /// is brought in with the session's camera once it's clearly not still
    /// being written, rather than holding its session open forever.
    func testOldLockScreenPhotosWithoutNotesAreImported() async throws {
        let app = try await app()
        let session = try folder("session")
        var camera = SnapperCameraContext()
        camera.lookID = "boardwalk"
        try LockedCaptureInbox.writeCamera(camera, to: session)
        let orphan = UUID()
        let file = session.appendingPathComponent("\(orphan.uuidString).photo")
        try TestImages.jpeg(width: 8, height: 8).write(to: file)
        let junk = session.appendingPathComponent("\(UUID().uuidString).photo")
        try Data("not a photo".utf8).write(to: junk)
        var cleared: [URL] = []

        // Just written: its note may still be on the way.
        await app.importLockScreenSessions([session]) { cleared.append($0) }
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertTrue(app.captures.records.isEmpty)

        let old = Date().addingTimeInterval(-120)
        for url in [file, junk] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        await app.importLockScreenSessions([session]) { cleared.append($0) }
        XCTAssertEqual(cleared, [session])
        XCTAssertEqual(app.captures.records.map(\.id), [orphan])
        XCTAssertEqual(app.captures.records.first?.lookID, "boardwalk")
    }

    /// Lock Screen photos come in once the Library has loaded, even when that
    /// happened later than launch (here, through a shot).
    func testLockScreenImportWaitsForTheLibraryNotForLaunch() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.autoSaveToPhotos = false
        let directory = try folder("library")
        let index = directory.appendingPathComponent("captures.json")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        let app = AppModel(store: FakePurchaseService(), settings: settings, captureStore: CaptureStore(directory: directory))
        let launched = await app.captures.load()
        XCTAssertFalse(launched)

        let session = try folder("session")
        let photo = CapturedPhoto(data: try TestImages.jpeg(width: 8, height: 8), isFrontCamera: false)
        try LockedCaptureInbox.write(photo, lookID: "original", to: session)
        var cleared: [URL] = []
        await app.importLockScreenSessions([session]) { cleared.append($0) }
        XCTAssertTrue(cleared.isEmpty, "photos already in the Library aren't known yet")

        try FileManager.default.removeItem(at: index)
        let shot = CapturedPhoto(data: try TestImages.jpeg(width: 8, height: 8), isFrontCamera: false)
        _ = try await app.captures.add(shot, look: .original)
        XCTAssertTrue(app.captures.isLoaded)
        await app.importLockScreenSessions([session]) { cleared.append($0) }
        XCTAssertEqual(cleared, [session])
        XCTAssertEqual(Set(app.captures.records.map(\.id)), [photo.id, shot.id])
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
