import OSLog
import SwiftUI

/// The in-app roll of photos taken with Snapper, newest first.
///
/// Originals are stored untouched; each record carries its look and strength,
/// so looks can be changed after the fact and exports are always rendered
/// fresh at full resolution.
@MainActor
@Observable
final class CaptureLibrary {
    private(set) var records: [CaptureRecord] = []
    /// Filtered thumbnails by record id.
    private(set) var thumbnails: [UUID: UIImage] = [:]
    private(set) var isProcessingCapture = false

    var latest: CaptureRecord? { records.first }
    var latestThumbnail: UIImage? { latest.flatMap { thumbnails[$0.id] } }

    @ObservationIgnored let renderer: PhotoRenderer
    @ObservationIgnored private let store: CaptureStore
    @ObservationIgnored private let library: LookLibrary
    @ObservationIgnored private var pendingCaptures = 0
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    /// Saved captures beyond this many are pruned, oldest first. Unsaved
    /// photos are never pruned automatically.
    static let maxStoredSavedCaptures = 60

    init(library: LookLibrary, renderer: PhotoRenderer, store: CaptureStore = .default) {
        self.library = library
        self.renderer = renderer
        self.store = store
    }

    func load() async {
        let store = self.store
        let loaded = await Task.detached(priority: .userInitiated) { store.load() }.value
        // Keep anything captured while the index was loading.
        let known = Set(records.map(\.id))
        records = (records + loaded.filter { !known.contains($0.id) }).sorted { $0.createdAt > $1.createdAt }
        for record in records.prefix(12) where thumbnails[record.id] == nil {
            await refreshThumbnail(for: record)
        }
    }

    func url(for record: CaptureRecord) -> URL {
        store.url(for: record)
    }

    func look(for record: CaptureRecord) -> Look {
        library.look(id: record.lookID) ?? .original
    }

    // MARK: - Adding

    /// Stores a new capture and returns its record.
    @discardableResult
    func add(_ photo: CapturedPhoto, look: Look) async throws -> CaptureRecord {
        pendingCaptures += 1
        isProcessingCapture = true
        defer {
            pendingCaptures -= 1
            isProcessingCapture = pendingCaptures > 0
        }
        let id = UUID()
        let fileName = "\(id.uuidString).\(CaptureStore.fileExtension(for: photo.data))"
        let store = self.store
        let data = photo.data
        try await Task.detached(priority: .userInitiated) {
            try store.write(data, fileName: fileName)
        }.value

        let record = CaptureRecord(id: id, createdAt: Date(), fileName: fileName, lookID: look.id, strength: 1,
                                   isFrontCamera: photo.isFrontCamera, savedLookID: nil, savedStrength: nil)
        records.insert(record, at: 0)
        await refreshThumbnail(for: record)
        persist()
        prune()
        return record
    }

    // MARK: - Editing

    func record(id: UUID) -> CaptureRecord? {
        records.first { $0.id == id }
    }

    func updateRecipe(id: UUID, lookID: String, strength: Double) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[index].lookID != lookID || abs(records[index].strength - strength) > 0.001 else { return }
        records[index].lookID = lookID
        records[index].strength = strength
        persist()
        let record = records[index]
        Task { await refreshThumbnail(for: record) }
    }

    func markSaved(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].savedLookID = records[index].lookID
        records[index].savedStrength = records[index].strength
        persist()
    }

    func delete(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records.remove(at: index)
        thumbnails[id] = nil
        persist()
        let store = self.store
        Task.detached(priority: .utility) { store.delete(record) }
        Task { await renderer.forget(id: id) }
    }

    // MARK: - Exporting

    /// Full-resolution render of a capture with its current recipe.
    func export(_ record: CaptureRecord, watermark: Bool, format: PhotoRenderer.ExportFormat) async throws -> Data {
        let url = store.url(for: record)
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        return try await renderer.export(source: data, look: look(for: record), strength: Float(record.strength),
                                         watermark: watermark, format: format)
    }

    /// Saves a capture to the photo library with its current recipe.
    func saveToPhotos(_ record: CaptureRecord, watermark: Bool, includeOriginal: Bool) async throws {
        let rendered = try await export(record, watermark: watermark, format: .heic)
        var original: Data?
        if includeOriginal {
            let url = store.url(for: record)
            original = try? await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        }
        try await PhotoLibrarySaver.save(rendered, original: original)
        markSaved(id: record.id)
    }

    /// Writes a JPEG to a temporary file for the share sheet.
    func exportForSharing(_ record: CaptureRecord, watermark: Bool) async throws -> URL {
        let data = try await export(record, watermark: watermark, format: .jpeg)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "Snapper-\(formatter.string(from: record.createdAt)).jpg"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        let url = folder.appendingPathComponent(name)
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }.value
        return url
    }

    // MARK: - Private

    func refreshThumbnail(for record: CaptureRecord) async {
        let image = await renderer.thumbnail(sourceURL: store.url(for: record), look: look(for: record),
                                             strength: Float(record.strength))
        if let image {
            thumbnails[record.id] = image
        }
    }

    /// Writes the index off the main actor; writes are chained so they land in order.
    private func persist() {
        let snapshot = records
        let store = self.store
        let previous = persistTask
        persistTask = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try store.save(snapshot)
            } catch {
                Logger.library.error("Could not save capture index: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func prune() {
        let saved = records.filter { $0.savedLookID != nil }
        guard saved.count > Self.maxStoredSavedCaptures else { return }
        for record in saved.suffix(saved.count - Self.maxStoredSavedCaptures) {
            delete(id: record.id)
        }
    }
}
