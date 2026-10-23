import Foundation
import OSLog

/// Loads LUTs and keeps the most recently used ones in memory. Safe to use
/// from any thread.
///
/// A loaded 33-point LUT takes 575 KB (RGBA Float32, the layout Core Image
/// needs), so only `capacity` stay cached: enough for the camera's look and
/// its neighbours, the look being edited and a few recent picks. Any other
/// look loads again when it's needed, which takes well under a millisecond
/// from a `.snaplut` file.
final class LUTStore: Sendable {
    static let shared = LUTStore()

    /// Cached LUTs by file name, least recently used first.
    private let cache = Locked<[(file: String, lut: CubeLUT)]>([])
    private let capacity: Int

    init(capacity: Int = 12) {
        self.capacity = max(capacity, 1)
    }

    /// The LUT for `look`, or `nil` for the original look (or an unreadable file,
    /// which is logged and then treated as no filter rather than crashing).
    func lut(for look: Look) -> CubeLUT? {
        guard let file = look.lutFile else { return nil }
        let cached = cache.withLock { entries -> CubeLUT? in
            guard let index = entries.firstIndex(where: { $0.file == file }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.lut
        }
        if let cached { return cached }
        guard let url = Self.url(forLUT: file, in: .main) else {
            Logger.filters.error("Missing LUT file \(file, privacy: .public)")
            return nil
        }
        do {
            let lut = try Self.load(url)
            cache.withLock { entries in
                // Another thread may have loaded the same file meanwhile.
                entries.removeAll { $0.file == file }
                entries.append((file, lut))
                if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
            }
            return lut
        } catch {
            Logger.filters.error("Could not parse \(file, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Loads the given looks ahead of time so showing them never waits on
    /// disk. Only the last `capacity` of them stay cached.
    func preload(_ looks: [Look]) {
        for look in looks {
            _ = lut(for: look)
        }
    }

    /// The cached files, least recently used first.
    var cachedFiles: [String] {
        cache.withLock { $0.map(\.file) }
    }

    /// Reads Snapper's own `.snaplut` files, or any `.cube`.
    static func load(_ url: URL) throws -> CubeLUT {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return url.pathExtension == "snaplut" ? try CubeLUT.decode(data) : try CubeLUT.parse(data)
    }

    static func url(forLUT file: String, in bundle: Bundle) -> URL? {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return bundle.url(forResource: name, withExtension: ext.isEmpty ? "cube" : ext)
    }
}
