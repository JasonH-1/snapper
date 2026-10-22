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
    /// Edits with a Premium look or tools that were made while Premium was
    /// active. They stay exportable after Premium ends.
    var premiumEdits: [PhotoRecipe] = []

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
        case versions, activeVersionID, premiumEdits
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
        premiumEdits = (try? container.decodeIfPresent([PhotoRecipe].self, forKey: .premiumEdits)) ?? []
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
        if !premiumEdits.isEmpty { try container.encode(premiumEdits, forKey: .premiumEdits) }
    }
}

/// Persists captures in Application Support. File work is synchronous and is
/// called off the main actor by `CaptureLibrary`.
struct CaptureStore: Sendable {
    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("captures.json") }
    /// New shots' records, each kept until an index save holds it.
    private var pendingDirectory: URL { directory.appendingPathComponent("Pending", isDirectory: true) }

    static let `default`: CaptureStore = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return CaptureStore(directory: base.appendingPathComponent("Captures", isDirectory: true))
    }()

    func url(for record: CaptureRecord) -> URL {
        directory.appendingPathComponent(record.fileName)
    }

    enum IndexError: LocalizedError {
        /// The index is there but couldn't be read (a file system problem),
        /// so a retry may work.
        case unreadable
        /// The index was read but isn't valid. Retrying won't help;
        /// `loadRepairingDamage()` rebuilds it.
        case damaged

        var errorDescription: String? {
            switch self {
            case .unreadable:
                String(localized: "Snapper couldn't read your Library. Your files have been kept. Retry in Settings before adding photos.")
            case .damaged:
                String(localized: "Snapper's Library index is damaged.")
            }
        }
    }

    /// What `loadRecovering()` did with a damaged or missing index.
    struct Repair: Equatable, Sendable {
        /// Records that still read from the damaged index, edits and all.
        var keptRecords: Int
        /// Photos in the folder without a readable record, back without their edits.
        var recoveredPhotos: Int
        /// A copy of the damaged index, kept rather than deleted; nil when
        /// there was no index left to copy.
        var damagedCopy: URL?
    }

    func load() throws -> [CaptureRecord] {
        guard let data = try readIndex() else { return [] }
        return try Self.decodeIndex(data)
    }

    private static func decodeIndex(_ data: Data) throws -> [CaptureRecord] {
        do {
            // Keep records even when an original is temporarily unavailable.
            return try JSONDecoder().decode([CaptureRecord].self, from: data)
        } catch {
            throw IndexError.damaged
        }
    }

    /// The index, with whatever a stopped app or a failed save left out put
    /// back:
    /// - New shots the index never got come back as they were taken, from
    ///   their pending records (see `writePending`).
    /// - A damaged index is rebuilt: every record that still reads keeps its
    ///   edits, and photos in the folder that no record mentions come back
    ///   unedited. A damaged index can't be fixed by retrying, and without
    ///   this the Library could never be used again. The damaged index is
    ///   copied aside and stays in place until the rebuilt one is written
    ///   over it in one step, so a repair that stops partway leaves it there
    ///   for the next launch to repair again.
    /// - A missing index with photos in the folder (it was lost) is rebuilt
    ///   from those photos the same way.
    ///
    /// Read errors still throw, since those can pass.
    func loadRecovering() throws -> (records: [CaptureRecord], repair: Repair?) {
        var records: [CaptureRecord] = []
        var damaged: Data?
        let index = try readIndex()
        if let index {
            do {
                records = try Self.decodeIndex(index)
            } catch {
                records = Self.salvageRecords(from: index)
                damaged = index
            }
        }
        let salvaged = records.count
        var changed = false

        // Pending shots go back first, so they keep their look rather than
        // coming back as unlisted, unedited photos.
        let listed = Set(records.map(\.id))
        for record in pendingRecords() where !listed.contains(record.id) {
            if FileManager.default.fileExists(atPath: url(for: record).path) {
                records.append(record)
                changed = true
            } else {
                // Its original is gone, so there's nothing left to bring back.
                discardPending(record.id)
            }
        }

        var repair: Repair?
        if index == nil || damaged != nil {
            let recovered = recoverablePhotos(excludingIDs: Set(records.map(\.id)), fileNames: Set(records.map(\.fileName)))
            records += recovered
            // A missing index with no unlisted photos is just a new Library.
            if damaged != nil || !recovered.isEmpty {
                var copy: URL?
                if damaged != nil {
                    let url = directory.appendingPathComponent("captures.damaged-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: indexURL, to: url)
                    copy = url
                }
                repair = Repair(keptRecords: salvaged, recoveredPhotos: recovered.count, damagedCopy: copy)
                Logger.library.error("Capture index was damaged or missing; kept \(salvaged) records, recovered \(recovered.count) photos")
                changed = true
            }
        }
        if changed {
            // Written over the damaged index in one step, if there is one.
            try writeIndex(records)
        }
        clearPending(heldIn: records)
        return (records, repair)
    }

    /// The index file's contents, or nil when there's no index yet.
    private func readIndex() throws -> Data? {
        do {
            return try Data(contentsOf: indexURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw IndexError.unreadable
        }
    }

    /// The records in a damaged index that still decode one by one.
    private static func salvageRecords(from data: Data) -> [CaptureRecord] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        var seen: Set<UUID> = []
        return items.compactMap { item in
            guard JSONSerialization.isValidJSONObject(item),
                  let itemData = try? JSONSerialization.data(withJSONObject: item),
                  let record = try? JSONDecoder().decode(CaptureRecord.self, from: itemData),
                  seen.insert(record.id).inserted else { return nil }
            return record
        }
    }

    /// Photos in the folder that no record mentions, as unedited records.
    /// Originals are named by their record's id, so that id comes back too.
    private func recoverablePhotos(excludingIDs ids: Set<UUID>, fileNames: Set<String>) -> [CaptureRecord] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { file in
            guard !fileNames.contains(file.lastPathComponent),
                  let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id),
                  let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            let info = Self.inspectImage(data)
            guard info.isReadable else { return nil }
            return CaptureRecord(id: id, createdAt: values.creationDate ?? Date(), takenAt: info.takenAt,
                                 fileName: file.lastPathComponent, recipe: .untouched)
        }
    }

    func save(_ records: [CaptureRecord]) throws {
        // A failed read is never permission to replace an existing index.
        _ = try load()
        try writeIndex(records)
        clearPending(heldIn: records)
    }

    /// Replaces the index in one step: a write that stops partway leaves
    /// the previous index as it was.
    private func writeIndex(_ records: [CaptureRecord]) throws {
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
        discardPending(record.id)
    }

    // MARK: - Pending shots

    /// Keeps a new shot's record beside its original until an index save
    /// holds it (`save` then drops it), so a shot whose index save never
    /// happened, because the app stopped or the disk was full, comes back
    /// as it was taken at the next load.
    func writePending(_ record: CaptureRecord) throws {
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: pendingURL(for: record.id), options: .atomic)
    }

    private func pendingURL(for id: UUID) -> URL {
        pendingDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func pendingFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)) ?? []
    }

    /// Pending records that still read.
    private func pendingRecords() -> [CaptureRecord] {
        pendingFiles().compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(CaptureRecord.self, from: data)
        }
    }

    private func discardPending(_ id: UUID) {
        try? FileManager.default.removeItem(at: pendingURL(for: id))
    }

    /// Drops the pending records an index holding `records` has taken over.
    private func clearPending(heldIn records: [CaptureRecord]) {
        let files = pendingFiles()
        guard !files.isEmpty else { return }
        let held = Set(records.map(\.id))
        for file in files {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), held.contains(id) {
                try? FileManager.default.removeItem(at: file)
            }
        }
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
