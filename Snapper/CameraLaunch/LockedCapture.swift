import Foundation
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

    /// What a session folder holds. Unreadable notes are skipped (and logged).
    static func read(_ folder: URL) -> Contents {
        var contents = Contents()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == noteExtension {
            do {
                let note = try JSONDecoder().decode(Note.self, from: Data(contentsOf: file))
                let url = folder.appendingPathComponent(note.fileName)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                contents.photos.append(Photo(note: note, url: url))
            } catch {
                Logger.camera.error("Unreadable Lock Screen photo note \(file.lastPathComponent, privacy: .public)")
            }
        }
        contents.photos.sort { $0.note.takenAt < $1.note.takenAt }
        let cameraURL = folder.appendingPathComponent(cameraFileName)
        if let data = try? Data(contentsOf: cameraURL) {
            contents.camera = try? JSONDecoder().decode(SnapperCameraContext.self, from: data)
        }
        return contents
    }
}

/// Where Snapper opens when the Lock Screen camera hands over to it (after
/// the person unlocks), sent in the user activity's `userInfo`.
enum LockScreenHandoff: String {
    case camera, library

    static let userInfoKey = "destination"
}
