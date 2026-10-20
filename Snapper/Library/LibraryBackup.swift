import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A Snapper Library backup (`.snapperbackup`).
    static let snapperBackup = UTType(exportedAs: "app.snapper.backup", conformingTo: .data)
}

/// A Library backup in one file: every original, untouched, with its edits,
/// versions and dates, plus personal presets and favourite looks. Made to
/// move a Library to a new iPhone (AirDrop it, or keep it in Files).
///
/// The file is written and read as a stream, so it never has to fit in memory:
///
///     "SNPRBKUP"                     8 bytes
///     format version                 UInt32, little-endian
///     manifest length                UInt64, little-endian
///     manifest                       JSON (`Manifest`)
///     each photo's original file     back to back, in manifest order
enum LibraryBackup {
    static let fileExtension = "snapperbackup"
    static let formatVersion: UInt32 = 1
    private static let magic = Data("SNPRBKUP".utf8)
    private static let headerLength = 8 + 4 + 8
    /// The manifest is small (recipes only); anything bigger isn't a backup.
    private static let maximumManifestLength: UInt64 = 64 << 20
    private static let chunkSize = 1 << 20

    struct Manifest: Codable, Sendable {
        struct Photo: Codable, Sendable {
            var record: CaptureRecord
            /// Bytes of the original in the payload.
            var byteCount: Int64
        }

        var format = "app.snapper.backup"
        var version = Int(LibraryBackup.formatVersion)
        var createdAt: Date
        var appVersion: String
        var photos: [Photo]
        var presets: [SavedPreset]
        var favoriteLookIDs: [String]
    }

    struct Summary: Sendable {
        var photoCount: Int
        var byteCount: Int64
    }

    /// What a restore did.
    struct RestoreResult: Sendable {
        /// Photos added, with their records.
        var records: [CaptureRecord] = []
        /// Photos already in the Library (same photo), left as they are.
        var alreadyInLibrary = 0
        /// Photos whose data was damaged and couldn't be restored.
        var unreadable = 0
        var presets: [SavedPreset] = []
        var favoriteLookIDs: [String] = []
        /// Stopped before the end; what was copied so far is in `records`.
        var wasStopped = false
    }

    enum BackupError: LocalizedError, Equatable {
        case notABackup
        case newerVersion
        case damaged
        case notEnoughSpace(needed: Int64)
        case nothingToBackUp

        var errorDescription: String? {
            switch self {
            case .notABackup:
                String(localized: "This file isn't a Snapper backup.")
            case .newerVersion:
                String(localized: "This backup was made by a newer version of Snapper. Update the app and try again.")
            case .damaged:
                String(localized: "This backup is incomplete or damaged. If it was copied or downloaded, try copying it again.")
            case .notEnoughSpace(let needed):
                String(localized: "There isn't enough free space on this iPhone. About \(needed.formatted(.byteCount(style: .file))) is needed.")
            case .nothingToBackUp:
                String(localized: "There are no photos in Snapper to back up.")
            }
        }
    }

    // MARK: - Writing

    /// Writes a backup of `records` (whose originals are in `store`) to `url`.
    /// Photos whose original has gone missing are left out. `progress`
    /// receives 0…1 as bytes are written.
    static func write(records: [CaptureRecord], store: CaptureStore, presets: [SavedPreset], favoriteLookIDs: [String],
                      appVersion: String, to url: URL, progress: (Double) -> Void = { _ in }) throws -> Summary {
        var photos: [Manifest.Photo] = []
        for record in records {
            let path = store.url(for: record).path
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value,
                  size > 0 else { continue }
            photos.append(Manifest.Photo(record: record, byteCount: size))
        }
        guard !photos.isEmpty else { throw BackupError.nothingToBackUp }

        let manifest = Manifest(createdAt: Date(), appVersion: appVersion, photos: photos,
                                presets: presets, favoriteLookIDs: favoriteLookIDs)
        // Default date coding keeps dates exact, so the Library's order survives.
        let manifestData = try JSONEncoder().encode(manifest)
        let payload = photos.reduce(Int64(0)) { $0 + $1.byteCount }
        let total = Int64(headerLength + manifestData.count) + payload

        try ensureSpace(for: total, at: url.deletingLastPathComponent())
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        var finished = false
        defer {
            try? output.close()
            if !finished { try? FileManager.default.removeItem(at: url) }
        }

        var header = magic
        header.append(littleEndian: formatVersion)
        header.append(littleEndian: UInt64(manifestData.count))
        try output.write(contentsOf: header)
        try output.write(contentsOf: manifestData)

        var written: Int64 = 0
        var reported = -1
        for photo in photos {
            let input = try FileHandle(forReadingFrom: store.url(for: photo.record))
            defer { try? input.close() }
            var remaining = photo.byteCount
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: Int(min(Int64(chunkSize), remaining))) ?? Data()
                // The original changed size while being copied.
                guard !chunk.isEmpty else { throw BackupError.damaged }
                try output.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
                written += Int64(chunk.count)
                let percent = Int(Double(written) / Double(max(payload, 1)) * 100)
                if percent != reported {
                    reported = percent
                    progress(Double(percent) / 100)
                }
            }
        }
        try output.synchronize()
        finished = true
        return Summary(photoCount: photos.count, byteCount: total)
    }

    // MARK: - Reading

    /// Reads and checks a backup's manifest without restoring anything.
    static func readManifest(from url: URL) throws -> Manifest {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        return try readManifest(input, fileSize: fileSize(of: url)).manifest
    }

    /// Restores the photos in the backup at `url` into `store`, skipping any
    /// whose id is in `existingIDs`. Originals are copied in unchanged;
    /// nothing in the Library is overwritten. The caller adds the returned
    /// records to the Library.
    static func restore(from url: URL, into store: CaptureStore, existingIDs: Set<UUID>,
                        progress: (Double) -> Void = { _ in }) throws -> RestoreResult {
        let fileSize = try fileSize(of: url)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let (manifest, payloadStart) = try readManifest(input, fileSize: fileSize)
        let payload = manifest.photos.reduce(Int64(0)) { $0 + $1.byteCount }
        let needed = manifest.photos.filter { !existingIDs.contains($0.record.id) }.reduce(Int64(0)) { $0 + $1.byteCount }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try ensureSpace(for: needed, at: store.directory)

        var result = RestoreResult(presets: manifest.presets, favoriteLookIDs: manifest.favoriteLookIDs)
        var seen = existingIDs
        var offset = payloadStart
        var done: Int64 = 0
        var reported = -1
        for photo in manifest.photos {
            // Stopping keeps what's restored so far: those photos join the Library.
            if Task.isCancelled {
                result.wasStopped = true
                break
            }
            defer {
                offset += UInt64(photo.byteCount)
                done += photo.byteCount
                let percent = Int(Double(done) / Double(max(payload, 1)) * 100)
                if percent != reported {
                    reported = percent
                    progress(Double(percent) / 100)
                }
            }
            guard seen.insert(photo.record.id).inserted else {
                result.alreadyInLibrary += 1
                continue
            }
            var record = photo.record
            // A backup cannot prove that this device has a copy in Photos.
            record.savedRecipe = nil
            record.fileName = safeFileName(record.fileName, id: record.id)
            if FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(record.fileName).path) {
                // A stray file with that name; never overwrite it.
                record.fileName = "\(UUID().uuidString).\((record.fileName as NSString).pathExtension)"
            }
            let destination = store.directory.appendingPathComponent(record.fileName)
            let partial = destination.appendingPathExtension("partial")
            do {
                try copy(from: input, offset: offset, count: photo.byteCount, to: partial)
                // Check the copy is a photo before it joins the Library.
                let data = try Data(contentsOf: partial, options: .mappedIfSafe)
                guard CaptureStore.inspectImage(data).isReadable else { throw BackupError.damaged }
                try FileManager.default.moveItem(at: partial, to: destination)
                result.records.append(record)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: partial)
                result.wasStopped = true
                break
            } catch {
                try? FileManager.default.removeItem(at: partial)
                result.unreadable += 1
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func readManifest(_ input: FileHandle, fileSize: UInt64) throws -> (manifest: Manifest, payloadStart: UInt64) {
        let header = try input.read(upToCount: headerLength) ?? Data()
        guard header.count == headerLength, header.prefix(magic.count) == magic else { throw BackupError.notABackup }
        let version: UInt32 = header.readLittleEndian(at: magic.count)
        guard version <= formatVersion else { throw BackupError.newerVersion }
        guard version >= 1 else { throw BackupError.notABackup }
        let manifestLength: UInt64 = header.readLittleEndian(at: magic.count + 4)
        guard manifestLength > 0, manifestLength <= maximumManifestLength,
              UInt64(headerLength) + manifestLength <= fileSize else { throw BackupError.damaged }
        let manifestData = try input.read(upToCount: Int(manifestLength)) ?? Data()
        guard UInt64(manifestData.count) == manifestLength else { throw BackupError.damaged }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              manifest.format == "app.snapper.backup" else { throw BackupError.damaged }
        guard manifest.version <= Int(formatVersion) else { throw BackupError.newerVersion }
        let payloadStart = UInt64(headerLength) + manifestLength
        guard fileSize <= UInt64(Int64.max) else { throw BackupError.damaged }
        var expected = payloadStart
        for photo in manifest.photos {
            guard photo.byteCount > 0, UInt64(photo.byteCount) <= fileSize - expected else {
                throw BackupError.damaged
            }
            expected += UInt64(photo.byteCount)
        }
        // A short file was cut off in transfer; refuse it rather than restore part.
        guard expected == fileSize else { throw BackupError.damaged }
        return (manifest, payloadStart)
    }

    private static func copy(from input: FileHandle, offset: UInt64, count: Int64, to url: URL) throws {
        try input.seek(toOffset: offset)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: Int(min(Int64(chunkSize), remaining))) ?? Data()
            guard !chunk.isEmpty else { throw BackupError.damaged }
            try output.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
    }

    /// The stored name if it's a plain file name, else one made from the id,
    /// so a backup can never write outside the Library's folder.
    static func safeFileName(_ name: String, id: UUID) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let ext = (name as NSString).pathExtension.lowercased()
        let isPlain = !name.isEmpty && name.count <= 120 && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy { allowed.contains($0) } && !name.contains("..")
        if isPlain { return name }
        let safeExt = ["heic", "heif", "jpg", "jpeg", "png", "tiff", "dng"].contains(ext) ? ext : "jpg"
        return "\(id.uuidString).\(safeExt)"
    }

    private static func fileSize(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func ensureSpace(for bytes: Int64, at directory: URL) throws {
        // Room for the files plus a little to spare for everything else.
        let (needed, overflow) = bytes.addingReportingOverflow(50 << 20)
        guard bytes >= 0, !overflow else { throw BackupError.damaged }
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return }
        guard available >= needed else { throw BackupError.notEnoughSpace(needed: needed) }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLittleEndian<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(self[self.startIndex + offset + index]) << (8 * index)
        }
        return value
    }
}
