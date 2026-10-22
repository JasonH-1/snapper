import Foundation
import ImageIO
import OSLog

// Shared by the app and the Lock Screen camera (SnapperCapture).

extension SnapperCameraContext {
    /// Flash, exposure and camera.
    var cameraPreferences: CameraPreferences {
        get {
            CameraPreferences(flash: FlashMode(rawValue: flash) ?? .off, exposureBias: exposureBias,
                              position: CameraPosition(rawValue: position) ?? .back)
        }
        set {
            flash = newValue.flash.rawValue
            exposureBias = newValue.exposureBias
            position = newValue.position.rawValue
        }
    }

    var captureOptions: CaptureOptions {
        CaptureOptions(timer: SelfTimer(rawValue: selfTimer) ?? .off,
                       aspect: AspectRatio(rawValue: aspectRatio) ?? .fourThree,
                       mirrorFrontCamera: mirrorFrontCamera)
    }

    var savedPreset: SavedPreset? {
        get { preset.flatMap { try? JSONDecoder().decode(SavedPreset.self, from: $0) } }
        set { preset = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// The swipe order: `lookOrder` with Original first, unknown ids
    /// dropped and any look it doesn't mention (new in this version) last.
    func orderedLooks(in library: LookLibrary) -> [Look] {
        var seen: Set<String> = [Look.original.id]
        var ordered: [Look] = [.original]
        for look in lookOrder.compactMap(library.look(id:)) where seen.insert(look.id).inserted {
            ordered.append(look)
        }
        for look in library.looks where seen.insert(look.id).inserted {
            ordered.append(look)
        }
        return ordered
    }
}

/// Photos taken with the Lock Screen camera, waiting in its session folder
/// until Snapper adds them to the Library.
///
/// Each photo is the camera's file plus a JSON note of how it was taken
/// (look, style, shape). The note is written last, so a photo only counts
/// once both are complete. The folder also keeps the camera as the session
/// left it, when the person changed it there.
enum LockedCaptureInbox {
    struct Note: Codable, Equatable, Sendable {
        var id: UUID
        var fileName: String
        var lookID: String
        /// The style frozen at the shutter (a preset's strength and adjustments).
        var style: PhotoRecipe?
        var aspect: AspectRatio
        var isFrontCamera: Bool
        var takenAt: Date
    }

    struct Photo: Sendable {
        let note: Note
        let url: URL

        /// The photo as the camera handed it over.
        func load() throws -> CapturedPhoto {
            CapturedPhoto(data: try Data(contentsOf: url), isFrontCamera: note.isFrontCamera, aspect: note.aspect,
                          id: note.id, style: note.style, takenAt: note.takenAt)
        }
    }

    struct Contents: Sendable {
        /// Oldest first.
        var photos: [Photo] = []
        /// False if any file could not be accounted for; keep the session.
        var isComplete = true
        /// The camera as the session left it, if the person changed it there.
        var camera: SnapperCameraContext?
    }

    static let noteExtension = "snappernote"
    static let cameraFileName = "camera.json"

    static func write(_ photo: CapturedPhoto, lookID: String, takenAt: Date = Date(), to folder: URL) throws {
        let fileName = "\(photo.id.uuidString).photo"
        try photo.data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        let note = Note(id: photo.id, fileName: fileName, lookID: lookID, style: photo.style, aspect: photo.aspect,
                        isFrontCamera: photo.isFrontCamera, takenAt: takenAt)
        try JSONEncoder().encode(note).write(to: folder.appendingPathComponent("\(photo.id.uuidString).\(noteExtension)"),
                                             options: .atomic)
    }

    static func writeCamera(_ context: SnapperCameraContext, to folder: URL) throws {
        try JSONEncoder().encode(context).write(to: folder.appendingPathComponent(cameraFileName), options: .atomic)
    }

    /// What a session folder holds, and whether it may still be missing something.
    ///
    /// A photo with no readable note (the camera stopped between writing the
    /// two) is taken as it is, with the session's camera, once it's
    /// `orphanGrace` old; until then the session counts as incomplete in case
    /// its note is on the way. So does one that can't be read yet. Notes are
    /// written after their photos, so a note whose photo is gone has nothing
    /// left to bring in.
    static func read(_ folder: URL, now: Date = Date(), orphanGrace: TimeInterval = 60) -> Contents {
        var contents = Contents()
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        } catch {
            contents.isComplete = false
            return contents
        }
        let cameraURL = folder.appendingPathComponent(cameraFileName)
        if let data = try? Data(contentsOf: cameraURL) {
            contents.camera = try? JSONDecoder().decode(SnapperCameraContext.self, from: data)
        }
        var referencedFiles: Set<String> = []
        for file in files where file.pathExtension == noteExtension {
            guard let data = try? Data(contentsOf: file), let note = try? JSONDecoder().decode(Note.self, from: data),
                  note.fileName == "\(note.id.uuidString).photo" else {
                // Its photo, if there is one, is picked up below as one without a note.
                Logger.camera.error("Unreadable Lock Screen photo note \(file.lastPathComponent, privacy: .public)")
                continue
            }
            referencedFiles.insert(note.fileName)
            let url = folder.appendingPathComponent(note.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Logger.camera.error("Lock Screen photo \(note.fileName, privacy: .public) is missing")
                continue
            }
            contents.photos.append(Photo(note: note, url: url))
        }
        for file in files where file.pathExtension == "photo" && !referencedFiles.contains(file.lastPathComponent) {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            guard now.timeIntervalSince(modified) >= orphanGrace else {
                contents.isComplete = false
                continue
            }
            // A file that can't be read now may read later, so the session
            // waits for it rather than being let go with the photo inside.
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
                Logger.camera.error("Lock Screen photo \(file.lastPathComponent, privacy: .public) couldn't be read yet")
                contents.isComplete = false
                continue
            }
            // Photos are written whole, so one that reads but isn't an image never will be.
            guard isImage(data) else {
                Logger.camera.error("Lock Screen file \(file.lastPathComponent, privacy: .public) isn't a photo")
                continue
            }
            contents.photos.append(Photo(note: orphanNote(id: id, fileName: file.lastPathComponent, takenAt: modified,
                                                          camera: contents.camera), url: file))
        }
        contents.photos.sort { $0.note.takenAt < $1.note.takenAt }
        return contents
    }

    /// A best guess for a photo whose note never arrived: the look and camera
    /// the session was last on.
    private static func orphanNote(id: UUID, fileName: String, takenAt: Date, camera: SnapperCameraContext?) -> Note {
        Note(id: id, fileName: fileName, lookID: camera?.lookID ?? Look.original.id, style: nil,
             aspect: camera?.captureOptions.aspect ?? .fourThree,
             isFrontCamera: camera?.cameraPreferences.position == .front, takenAt: takenAt)
    }

    private static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }
}

/// Where Snapper opens when the Lock Screen camera hands over to it (after
/// the person unlocks), sent in the user activity's `userInfo`.
enum LockScreenHandoff: String {
    case camera, library

    static let userInfoKey = "destination"
}
