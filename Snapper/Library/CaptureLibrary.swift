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
    /// Whether Premium is active, set by the app. Premium edits made while it
    /// is are remembered so they stay exportable after Premium ends.
    @ObservationIgnored var hasPremium: () -> Bool = { false }
    @ObservationIgnored private let store: CaptureStore
    @ObservationIgnored private let library: LookLibrary
    @ObservationIgnored private let photoSaver: @Sendable (URL, URL?) async throws -> Void
    @ObservationIgnored private var pendingCaptures = 0
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailRequests: Set<UUID> = []
    /// Thumbnail ids, least recently drawn first, for trimming.
    @ObservationIgnored private var thumbnailOrder: [UUID] = []

    /// Thumbnails kept in memory; older ones are dropped and redrawn when
    /// their grid cell comes back on screen.
    static let maxThumbnails = 180

    /// - Parameter photoSaver: adds a rendered file (and optionally the
    ///   original) to Photos; tests replace it.
    init(library: LookLibrary, renderer: PhotoRenderer, store: CaptureStore = .default,
         photoSaver: @escaping @Sendable (URL, URL?) async throws -> Void = PhotoLibrarySaver.save(fileURL:originalURL:)) {
        self.library = library
        self.renderer = renderer
        self.store = store
        self.photoSaver = photoSaver
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

    // MARK: - Premium

    /// Whether `recipe` uses a Premium look or Premium tools.
    func usesPremium(_ recipe: PhotoRecipe) -> Bool {
        (library.look(id: recipe.lookID)?.isPremium ?? false) || recipe.requiresPremium
    }

    /// Whether exporting `recipe` of `record` needs Premium: it uses a Premium
    /// look or tools and wasn't made while Premium was active.
    func needsPremium(_ recipe: PhotoRecipe, of record: CaptureRecord) -> Bool {
        usesPremium(recipe) && !record.premiumEdits.contains(recipe)
    }

    /// `recipe` without its Premium look and tools, which anyone can save.
    func freeVersion(of recipe: PhotoRecipe) -> PhotoRecipe {
        recipe.withoutPremium(lookIsPremium: library.look(id: recipe.lookID)?.isPremium ?? false)
    }

    /// What saving `recipe` without Premium leaves out: the look, if it is a
    /// Premium one, and whether Premium tools are used.
    func premiumParts(of recipe: PhotoRecipe) -> (look: Look?, usesTools: Bool) {
        let look = library.look(id: recipe.lookID).flatMap { $0.isPremium ? $0 : nil }
        return (look, recipe.requiresPremium)
    }

    /// While Premium is active, remembers every Premium edit the photo holds
    /// (the current one, the one it arrived with and its versions). Nothing
    /// is forgotten while Premium is off, so going back to such an edit later
    /// still exports.
    private func notePremiumEdits(at index: Int) {
        guard hasPremium() else { return }
        let record = records[index]
        var kept: [PhotoRecipe] = []
        for recipe in [record.recipe, record.initialRecipe] + record.versions.map(\.recipe)
            where usesPremium(recipe) && !kept.contains(recipe) {
            kept.append(recipe)
        }
        records[index].premiumEdits = kept
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

        var recipe = photo.style ?? PhotoRecipe(lookID: look.id)
        recipe.lookID = look.id
        recipe.crop = PhotoCrop(shape: CropShape(cameraAspect: photo.aspect))
        recipe.finish = .none
        records.insert(CaptureRecord(id: id, fileName: fileName, source: .camera, isFrontCamera: photo.isFrontCamera,
                                     recipe: recipe), at: 0)
        notePremiumEdits(at: 0)
        let record = records[0]
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

    /// Stores a new recipe for a photo and redraws its thumbnail.
    func updateRecipe(id: UUID, _ recipe: PhotoRecipe) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].recipe != recipe else { return }
        records[index].recipe = recipe
        notePremiumEdits(at: index)
        persist()
        let record = records[index]
        Task { await refreshThumbnail(for: record) }
    }

    // MARK: - Versions

    enum VersionError: LocalizedError {
        case limitReached, invalidName

        var errorDescription: String? {
            switch self {
            case .limitReached:
                String(localized: "A photo can keep up to \(PhotoVersion.maxCount) versions. Delete one to save another.")
            case .invalidName:
                String(localized: "Give the version a name.")
            }
        }
    }

    /// Keeps `recipe` as a new named version of a photo, and marks it as the
    /// one showing.
    @discardableResult
    func saveVersion(photoID: UUID, name: String, recipe: PhotoRecipe) throws -> PhotoVersion {
        guard let index = records.firstIndex(where: { $0.id == photoID }) else { throw VersionError.invalidName }
        guard let name = PhotoVersion.validName(name) else { throw VersionError.invalidName }
        guard records[index].versions.count < PhotoVersion.maxCount else { throw VersionError.limitReached }
        let version = PhotoVersion(name: name, recipe: recipe)
        records[index].versions.append(version)
        records[index].activeVersionID = version.id
        notePremiumEdits(at: index)
        persist()
        return version
    }

    /// Replaces a version's recipe (Update “Warm” with the current edit).
    func updateVersion(photoID: UUID, versionID: UUID, recipe: PhotoRecipe) {
        guard let index = records.firstIndex(where: { $0.id == photoID }),
              let versionIndex = records[index].versions.firstIndex(where: { $0.id == versionID }) else { return }
        records[index].versions[versionIndex].recipe = recipe
        records[index].activeVersionID = versionID
        notePremiumEdits(at: index)
        persist()
    }

    func renameVersion(photoID: UUID, versionID: UUID, to name: String) throws {
        guard let name = PhotoVersion.validName(name) else { throw VersionError.invalidName }
        guard let index = records.firstIndex(where: { $0.id == photoID }),
              let versionIndex = records[index].versions.firstIndex(where: { $0.id == versionID }) else { return }
        records[index].versions[versionIndex].name = name
        persist()
    }

    /// Forgets a version; the photo keeps showing whatever it shows now.
    func deleteVersion(photoID: UUID, versionID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == photoID }) else { return }
        records[index].versions.removeAll { $0.id == versionID }
        if records[index].activeVersionID == versionID { records[index].activeVersionID = nil }
        persist()
    }

    /// Notes which version is showing (nil for none), without changing the recipe.
    func setActiveVersion(photoID: UUID, versionID: UUID?) {
        guard let index = records.firstIndex(where: { $0.id == photoID }),
              records[index].activeVersionID != versionID else { return }
        records[index].activeVersionID = versionID
        persist()
    }

    func markSaved(id: UUID, recipe: PhotoRecipe? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].savedRecipe = recipe ?? records[index].recipe
        notePremiumEdits(at: index)
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
        try await export(record, watermark: watermark, options: ExportOptions(format: format))
    }

    /// A render of a capture with `recipe` (its current one by default),
    /// encoded with `options`.
    func export(_ record: CaptureRecord, recipe: PhotoRecipe? = nil, watermark: Bool,
                options: ExportOptions) async throws -> Data {
        let recipe = recipe ?? record.recipe
        let url = store.url(for: record)
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        return try await renderer.export(source: data, look: library.look(id: recipe.lookID) ?? .original, recipe: recipe,
                                         seed: record.id.effectsSeed, watermark: watermark, options: options, sourceURL: url)
    }

    /// Renders a capture into a temporary file, ready to save or share, and
    /// reports its real size. `name` replaces the default file name.
    func prepareExport(_ record: CaptureRecord, recipe: PhotoRecipe? = nil, options: ExportOptions,
                       watermark: Bool = false, name: String? = nil) async throws -> PreparedExport {
        let recipe = recipe ?? record.recipe
        let source = store.url(for: record)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = folder.appendingPathComponent((name ?? Self.exportName(for: record)) + "." + options.format.fileExtension)
        let data = try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try Data(contentsOf: source)
        }.value
        let pixelSize = try await renderer.exportFile(source: data, look: library.look(id: recipe.lookID) ?? .original,
                                                      recipe: recipe, seed: record.id.effectsSeed, watermark: watermark,
                                                      options: options, sourceURL: source, to: fileURL)
        let bytes = try await Task.detached(priority: .userInitiated) {
            (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        }.value
        return PreparedExport(url: fileURL, byteCount: bytes, pixelSize: pixelSize, recipe: recipe, options: options)
    }

    /// "Snapper-20240602-184012-<id>": dated, and unique per photo.
    static func exportName(for record: CaptureRecord, suffix: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var name = "Snapper-\(formatter.string(from: record.takenAt ?? record.createdAt))-\(record.id.uuidString)"
        if let suffix {
            let safe = suffix.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
            if !safe.isEmpty { name += "-" + String(safe.prefix(30)) }
        }
        return name
    }

    /// Saves a capture to the photo library with `recipe` (its current one
    /// by default) and the export settings, or a file already prepared.
    func saveToPhotos(_ record: CaptureRecord, recipe: PhotoRecipe? = nil, watermark: Bool = false,
                      includeOriginal: Bool, options: ExportOptions, prepared: PreparedExport? = nil) async throws {
        let export: PreparedExport
        if let prepared {
            export = prepared
        } else {
            export = try await prepareExport(record, recipe: recipe, options: options, watermark: watermark)
        }
        defer { try? FileManager.default.removeItem(at: export.url.deletingLastPathComponent()) }
        let original = includeOriginal ? store.url(for: record) : nil
        try await photoSaver(export.url, original)
        markSaved(id: record.id, recipe: export.recipe)
    }

    /// Saves with only a format chosen (full size, standard quality).
    func saveToPhotos(_ record: CaptureRecord, watermark: Bool, includeOriginal: Bool,
                      format: PhotoRenderer.ExportFormat = .heic) async throws {
        try await saveToPhotos(record, watermark: watermark, includeOriginal: includeOriginal,
                               options: ExportOptions(format: format))
    }

    /// Writes a photo to a temporary file for the share sheet.
    func exportForSharing(_ record: CaptureRecord, watermark: Bool, options: ExportOptions = ExportOptions(format: .jpeg)) async throws -> URL {
        let urls = try await exportForSharing([record], watermark: watermark, options: options)
        guard let url = urls.first else { throw PhotoRenderer.RenderError.encodingFailed }
        return url
    }

    /// Writes several photos to temporary files for the share sheet, each in
    /// its own folder so another share cannot invalidate these URLs.
    func exportForSharing(_ records: [CaptureRecord], watermark: Bool,
                          options: ExportOptions = ExportOptions(format: .jpeg)) async throws -> [URL] {
        var urls: [URL] = []
        for record in records {
            urls.append(try await prepareExport(record, options: options, watermark: watermark).url)
        }
        return urls
    }

    // MARK: - Backup

    /// 0…1 while a backup is being written or restored.
    private(set) var backupProgress: Double?

    /// Writes a backup of the whole Library (plus `presets` and favourites)
    /// to a temporary file and returns it, to be shared or saved to Files.
    func makeBackup(presets: [SavedPreset], favoriteLookIDs: [String], appVersion: String) async throws
        -> (url: URL, summary: LibraryBackup.Summary) {
        let records = self.records
        let store = self.store
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let backups = FileManager.default.temporaryDirectory.appendingPathComponent("Backup", isDirectory: true)
        let folder = backups.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent("Snapper Backup \(formatter.string(from: Date())).\(LibraryBackup.fileExtension)")
        backupProgress = 0
        defer { backupProgress = nil }
        let owner = self
        let work = Task.detached(priority: .userInitiated) {
            // Earlier backups were shared already; don't let them fill the disk.
            try? FileManager.default.removeItem(at: backups)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                return try LibraryBackup.write(records: records, store: store, presets: presets, favoriteLookIDs: favoriteLookIDs,
                                               appVersion: appVersion, to: url) { value in
                    // Late updates after the work finished are dropped.
                    Task { @MainActor in if owner.backupProgress != nil { owner.backupProgress = value } }
                }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        let summary = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        return (url, summary)
    }

    /// Adds the photos in a backup to the Library. Photos already here are
    /// left alone, so restoring twice changes nothing.
    func restoreBackup(from url: URL) async throws -> LibraryBackup.RestoreResult {
        let store = self.store
        let existing = Set(records.map(\.id))
        backupProgress = 0
        defer { backupProgress = nil }
        let owner = self
        let work = Task.detached(priority: .userInitiated) { () throws -> LibraryBackup.RestoreResult in
            try CaptureLibrary.coordinatedRead(of: url) { readURL in
                try LibraryBackup.restore(from: readURL, into: store, existingIDs: existing) { value in
                    // Late updates after the work finished are dropped.
                    Task { @MainActor in if owner.backupProgress != nil { owner.backupProgress = value } }
                }
            }
        }
        let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        let known = Set(records.map(\.id))
        let added = result.records.filter { !known.contains($0.id) }
        if !added.isEmpty {
            records = (records + added).sorted { $0.createdAt > $1.createdAt }
            persist()
            for record in records.prefix(12) where thumbnails[record.id] == nil {
                await refreshThumbnail(for: record)
            }
        }
        return result
    }

    /// Reads a backup's contents list (to show what it holds before restoring).
    nonisolated static func backupManifest(at url: URL) async throws -> LibraryBackup.Manifest {
        try await Task.detached(priority: .userInitiated) {
            try coordinatedRead(of: url) { try LibraryBackup.readManifest(from: $0) }
        }.value
    }

    /// Reads a file picked from Files or opened from another app: with its
    /// security scope, and coordinated so iCloud Drive downloads it first.
    nonisolated private static func coordinatedRead<T>(of url: URL, _ body: (URL) throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var outcome: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            outcome = Result { try body(readURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw LibraryBackup.BackupError.notABackup }
        return try outcome.get()
    }

    // MARK: - Private

    func refreshThumbnail(for record: CaptureRecord) async {
        let image = await renderer.thumbnail(sourceURL: store.url(for: record), look: look(for: record),
                                             recipe: record.recipe, seed: record.id.effectsSeed)
        // Skip deleted photos and drawings overtaken by a newer edit.
        guard let image, self.record(id: record.id)?.recipe == record.recipe else { return }
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
