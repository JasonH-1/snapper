import OSLog
import SwiftUI

/// The Library: photos taken with Snapper or imported into it, newest first.
///
/// Originals are stored untouched; each record carries its recipe (look,
/// strength, sliders and crop), so anything can be changed after the fact and
/// exports are always rendered fresh at full resolution.
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
    @ObservationIgnored private var thumbnailRequests: Set<UUID> = []
    /// Thumbnail ids, least recently drawn first, for trimming.
    @ObservationIgnored private var thumbnailOrder: [UUID] = []

    /// Thumbnails kept in memory; older ones are dropped and redrawn when
    /// their grid cell comes back on screen.
    static let maxThumbnails = 180

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
        let id = photo.id
        let fileName = "\(id.uuidString).\(CaptureStore.fileExtension(for: photo.data))"
        let store = self.store
        let data = photo.data
        try await Task.detached(priority: .userInitiated) {
            try store.write(data, fileName: fileName)
        }.value

        let recipe = PhotoRecipe(lookID: look.id, crop: PhotoCrop(shape: CropShape(cameraAspect: photo.aspect)))
        let record = CaptureRecord(id: id, fileName: fileName, source: .camera, isFrontCamera: photo.isFrontCamera,
                                   recipe: recipe)
        records.insert(record, at: 0)
        await refreshThumbnail(for: record)
        persist()
        return record
    }

    enum ImportError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            String(localized: "This file isn't a photo Snapper can open.")
        }
    }

    /// Keeps a private copy of a photo from the photo library, with no look
    /// yet. `createdAt` orders imports picked together.
    @discardableResult
    func importPhoto(_ data: Data, createdAt: Date = Date()) async throws -> CaptureRecord {
        let id = UUID()
        let fileName = "\(id.uuidString).\(CaptureStore.fileExtension(for: data))"
        let store = self.store
        let takenAt = try await Task.detached(priority: .userInitiated) {
            let info = CaptureStore.inspectImage(data)
            guard info.isReadable else { throw ImportError.unreadable }
            try store.write(data, fileName: fileName)
            return info.takenAt
        }.value

        let record = CaptureRecord(id: id, createdAt: createdAt, takenAt: takenAt, fileName: fileName,
                                   source: .imported, recipe: .untouched)
        let index = records.firstIndex { $0.createdAt < createdAt } ?? records.endIndex
        records.insert(record, at: index)
        await refreshThumbnail(for: record)
        persist()
        return record
    }

    // MARK: - Editing

    func record(id: UUID) -> CaptureRecord? {
        records.first { $0.id == id }
    }

    func updateRecipe(id: UUID, lookID: String, strength: Double) {
        guard var recipe = record(id: id)?.recipe else { return }
        recipe.lookID = lookID
        recipe.strength = strength
        updateRecipe(id: id, recipe)
    }

    /// Stores a new recipe for a photo and redraws its thumbnail.
    func updateRecipe(id: UUID, _ recipe: PhotoRecipe) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].recipe != recipe else { return }
        records[index].recipe = recipe
        persist()
        let record = records[index]
        Task { await refreshThumbnail(for: record) }
    }

    func markSaved(id: UUID, recipe: PhotoRecipe? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].savedRecipe = recipe ?? records[index].recipe
        persist()
    }

    func delete(id: UUID) {
        delete(ids: [id])
    }

    /// Removes photos and their files (copies saved to Photos are not affected).
    func delete(ids: Set<UUID>) {
        let removed = records.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        records.removeAll { ids.contains($0.id) }
        for id in ids {
            thumbnails[id] = nil
        }
        thumbnailOrder.removeAll { ids.contains($0) }
        persist()
        let store = self.store
        Task.detached(priority: .utility) {
            for record in removed { store.delete(record) }
        }
        Task {
            for record in removed { await renderer.forget(id: record.id) }
        }
    }

    // MARK: - Storage

    /// Photos whose current edit is already in the photo library, so
    /// removing them from Snapper loses nothing but the chance to re-edit.
    var alreadySavedIDs: Set<UUID> {
        Set(records.filter(\.isSavedWithCurrentRecipe).map(\.id))
    }

    /// Removes every photo whose current edit is already saved to Photos.
    /// Photos are otherwise kept until the person deletes them.
    func deleteAlreadySaved() {
        delete(ids: alreadySavedIDs)
    }

    /// Bytes the Library's originals take on disk.
    func storageUsed() async -> Int64 {
        let store = self.store
        let names = records.map(\.fileName)
        return await Task.detached(priority: .utility) { store.size(of: names) }.value
    }

    // MARK: - Exporting

    /// Full-resolution render of a capture with its current recipe.
    func export(_ record: CaptureRecord, watermark: Bool, format: PhotoRenderer.ExportFormat) async throws -> Data {
        let url = store.url(for: record)
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        return try await renderer.export(source: data, look: look(for: record), recipe: record.recipe,
                                         seed: record.id.effectsSeed, watermark: watermark, format: format)
    }

    /// Saves a capture to the photo library with its current recipe, as HEIF
    /// or JPEG (the Format setting).
    func saveToPhotos(_ record: CaptureRecord, watermark: Bool, includeOriginal: Bool,
                      format: PhotoRenderer.ExportFormat = .heic) async throws {
        let rendered = try await export(record, watermark: watermark, format: format)
        var original: Data?
        if includeOriginal {
            let url = store.url(for: record)
            original = try? await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        }
        try await PhotoLibrarySaver.save(rendered, original: original)
        markSaved(id: record.id, recipe: record.recipe)
    }

    /// Writes a JPEG to a temporary file for the share sheet.
    func exportForSharing(_ record: CaptureRecord, watermark: Bool) async throws -> URL {
        let urls = try await exportForSharing([record], watermark: watermark)
        guard let url = urls.first else { throw PhotoRenderer.RenderError.encodingFailed }
        return url
    }

    /// Writes JPEGs of several photos to temporary files for the share sheet,
    /// replacing the previous share's files.
    func exportForSharing(_ records: [CaptureRecord], watermark: Bool) async throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }.value
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var urls: [URL] = []
        var usedNames: Set<String> = []
        for record in records {
            let data = try await export(record, watermark: watermark, format: .jpeg)
            var name = "Snapper-\(formatter.string(from: record.takenAt ?? record.createdAt))"
            if !usedNames.insert(name).inserted {
                name += "-\(record.id.uuidString.prefix(4))"
            }
            let url = folder.appendingPathComponent(name + ".jpg")
            try await Task.detached(priority: .userInitiated) {
                try data.write(to: url, options: .atomic)
            }.value
            urls.append(url)
        }
        return urls
    }

    // MARK: - Private

    func refreshThumbnail(for record: CaptureRecord) async {
        let image = await renderer.thumbnail(sourceURL: store.url(for: record), look: look(for: record),
                                             recipe: record.recipe, seed: record.id.effectsSeed)
        // Skip photos deleted while drawing.
        guard let image, self.record(id: record.id) != nil else { return }
        thumbnails[record.id] = image
        thumbnailOrder.removeAll { $0 == record.id }
        thumbnailOrder.append(record.id)
        trimThumbnails()
    }

    /// Draws a photo's thumbnail if it isn't in memory (grid cells call this
    /// as they appear).
    func requestThumbnail(for id: UUID) {
        guard thumbnails[id] == nil, !thumbnailRequests.contains(id), let record = record(id: id) else { return }
        thumbnailRequests.insert(id)
        Task {
            await refreshThumbnail(for: record)
            thumbnailRequests.remove(id)
        }
    }

    private func trimThumbnails() {
        let latestID = latest?.id
        while thumbnailOrder.count > Self.maxThumbnails {
            let id = thumbnailOrder.removeFirst()
            // The camera button always shows the newest photo.
            if id == latestID {
                thumbnailOrder.append(id)
                continue
            }
            thumbnails[id] = nil
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

}
