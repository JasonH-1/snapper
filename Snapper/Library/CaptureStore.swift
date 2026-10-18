import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// A photo in Snapper's Library: taken with the camera or imported. The
/// original file is kept untouched and every edit is a recipe applied at
/// render time, so anything can be changed later.
struct CaptureRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    /// When it joined the Library (taken or imported). The Library is sorted by this.
    let createdAt: Date
    /// When the photo was taken, if it differs (imports, read from their metadata).
    var takenAt: Date?
    /// File name of the original inside the captures folder.
    var fileName: String
    var source: PhotoSource
    let isFrontCamera: Bool
    var recipe: PhotoRecipe
    /// The recipe it arrived with, which Reset goes back to.
    var initialRecipe: PhotoRecipe
    /// The recipe last saved to Photos, if any (to show "Saved").
    var savedRecipe: PhotoRecipe?
    /// Named edits kept with the photo, oldest first. `recipe` is the one
    /// showing; it may match one of these or be a new edit.
    var versions: [PhotoVersion] = []
    /// The version last switched to or saved, to name what is showing
    /// ("Warm", or "Warm · Edited" once it has changed).
    var activeVersionID: UUID?

    init(id: UUID = UUID(), createdAt: Date = Date(), takenAt: Date? = nil, fileName: String,
         source: PhotoSource = .camera, isFrontCamera: Bool = false, recipe: PhotoRecipe,
         savedRecipe: PhotoRecipe? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.takenAt = takenAt
        self.fileName = fileName
        self.source = source
        self.isFrontCamera = isFrontCamera
        self.recipe = recipe
        self.initialRecipe = recipe
        self.savedRecipe = savedRecipe
    }

    var lookID: String {
        get { recipe.lookID }
        set { recipe.lookID = newValue }
    }

    var strength: Double {
        get { recipe.strength }
        set { recipe.strength = newValue }
    }

    var isImported: Bool { source == .imported }

    /// Changed since it was taken or imported.
    var isEdited: Bool { recipe != initialRecipe }

    var isSavedWithCurrentRecipe: Bool { savedRecipe == recipe }

    /// Saved to Photos at least once.
    var isSaved: Bool { savedRecipe != nil }

    /// The version whose recipe is showing: the active one if unchanged,
    /// else any other that matches.
    var currentVersion: PhotoVersion? {
        if let active = versions.first(where: { $0.id == activeVersionID }), active.recipe == recipe { return active }
        return versions.first { $0.recipe == recipe }
    }
}

extension CaptureRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, takenAt, fileName, source, isFrontCamera, recipe, initialRecipe, savedRecipe
        case versions, activeVersionID
        // Written by builds before the Library (look, strength and shape at the top level).
        case lookID, strength, aspect, savedLookID, savedStrength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        takenAt = try container.decodeIfPresent(Date.self, forKey: .takenAt)
        fileName = try container.decode(String.self, forKey: .fileName)
        source = (try? container.decodeIfPresent(PhotoSource.self, forKey: .source)) ?? .camera
        isFrontCamera = try container.decodeIfPresent(Bool.self, forKey: .isFrontCamera) ?? false

        if let recipe = try container.decodeIfPresent(PhotoRecipe.self, forKey: .recipe) {
            self.recipe = recipe
            initialRecipe = try container.decodeIfPresent(PhotoRecipe.self, forKey: .initialRecipe) ?? recipe
            savedRecipe = try container.decodeIfPresent(PhotoRecipe.self, forKey: .savedRecipe)
        } else {
            let aspect = (try? container.decodeIfPresent(AspectRatio.self, forKey: .aspect)) ?? .fourThree
            let crop = PhotoCrop(shape: CropShape(cameraAspect: aspect))
            recipe = PhotoRecipe(lookID: try container.decodeIfPresent(String.self, forKey: .lookID) ?? Look.original.id,
                                 strength: try container.decodeIfPresent(Double.self, forKey: .strength) ?? 1,
                                 crop: crop)
            initialRecipe = recipe
            if let savedLook = try container.decodeIfPresent(String.self, forKey: .savedLookID) {
                savedRecipe = PhotoRecipe(lookID: savedLook,
                                          strength: try container.decodeIfPresent(Double.self, forKey: .savedStrength) ?? 1,
                                          crop: crop)
            }
        }
        // A damaged version list shouldn't cost the photo itself.
        versions = (try? container.decodeIfPresent([PhotoVersion].self, forKey: .versions)) ?? []
        activeVersionID = try? container.decodeIfPresent(UUID.self, forKey: .activeVersionID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(takenAt, forKey: .takenAt)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(source, forKey: .source)
        try container.encode(isFrontCamera, forKey: .isFrontCamera)
        try container.encode(recipe, forKey: .recipe)
        try container.encode(initialRecipe, forKey: .initialRecipe)
        try container.encodeIfPresent(savedRecipe, forKey: .savedRecipe)
        if !versions.isEmpty { try container.encode(versions, forKey: .versions) }
        try container.encodeIfPresent(activeVersionID, forKey: .activeVersionID)
    }
}

/// Persists captures in Application Support. File work is synchronous and is
/// called off the main actor by `CaptureLibrary`.
struct CaptureStore: Sendable {
    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("captures.json") }

    static let `default`: CaptureStore = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return CaptureStore(directory: base.appendingPathComponent("Captures", isDirectory: true))
    }()

    func url(for record: CaptureRecord) -> URL {
        directory.appendingPathComponent(record.fileName)
    }

    func load() -> [CaptureRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        do {
            let records = try JSONDecoder().decode([CaptureRecord].self, from: data)
            // Drop entries whose file has gone missing.
            return records.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
        } catch {
            Logger.library.error("Capture index unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func save(_ records: [CaptureRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: indexURL, options: .atomic)
    }

    func write(_ photo: Data, fileName: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try photo.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    func delete(_ record: CaptureRecord) {
        try? FileManager.default.removeItem(at: url(for: record))
    }

    /// Total size on disk of the given files (missing ones count as zero).
    func size(of fileNames: [String]) -> Int64 {
        fileNames.reduce(into: Int64(0)) { total, name in
            let path = directory.appendingPathComponent(name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            total += size
        }
    }

    /// Guesses the file extension from the data's signature: HEIF, PNG,
    /// JPEG, or whatever Image I/O recognises.
    static func fileExtension(for data: Data) -> String {
        if data.count > 12, data[4] == 0x66, data[5] == 0x74, data[6] == 0x79, data[7] == 0x70 { // "ftyp"
            return "heic"
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
           let ext = type.preferredFilenameExtension {
            return ext
        }
        return "jpg"
    }

    /// Whether `data` is a still image Snapper can open, and when it was
    /// taken according to its metadata.
    static func inspectImage(_ data: Data) -> (isReadable: Bool, takenAt: Date?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0
        else { return (false, nil) }
        return (true, takenDate(from: properties))
    }

    /// The EXIF "date taken" (with its time zone when recorded), else the TIFF date.
    static func takenDate(from properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let stamp = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
                ?? tiff?[kCGImagePropertyTIFFDateTime] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: stamp + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: stamp)
    }
}
