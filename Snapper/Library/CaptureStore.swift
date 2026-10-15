import Foundation
import OSLog

/// A photo taken in Snapper. The camera's original file is kept untouched and
/// the look is a recipe applied at render time, so it can be changed later.
struct CaptureRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    /// File name of the original inside the captures folder.
    let fileName: String
    var lookID: String
    var strength: Double
    let isFrontCamera: Bool
    /// The recipe last saved to Photos, if any (to show "Saved").
    var savedLookID: String?
    var savedStrength: Double?

    var isSavedWithCurrentRecipe: Bool {
        savedLookID == lookID && savedStrength.map { abs($0 - strength) < 0.005 } == true
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

    /// Guesses the file extension from the data's signature (HEIF or JPEG).
    static func fileExtension(for data: Data) -> String {
        if data.count > 12, data[4] == 0x66, data[5] == 0x74, data[6] == 0x79, data[7] == 0x70 { // "ftyp"
            return "heic"
        }
        return "jpg"
    }
}
