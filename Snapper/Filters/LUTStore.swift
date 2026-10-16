import Foundation
import OSLog

/// Loads and caches parsed LUTs. Safe to use from any thread.
final class LUTStore: Sendable {
    static let shared = LUTStore()

    private let cache = Locked<[String: CubeLUT]>([:])

    /// The LUT for `look`, or `nil` for the original look (or an unreadable file,
    /// which is logged and then treated as no filter rather than crashing).
    func lut(for look: Look) -> CubeLUT? {
        guard let file = look.lutFile else { return nil }
        if let cached = cache.withLock({ $0[file] }) { return cached }
        guard let url = Self.url(forLUT: file, in: .main) else {
            Logger.filters.error("Missing LUT file \(file, privacy: .public)")
            return nil
        }
        do {
            let lut = try CubeLUT.parse(Data(contentsOf: url, options: .mappedIfSafe))
            cache.withLock { $0[file] = lut }
            return lut
        } catch {
            Logger.filters.error("Could not parse \(file, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Parses the given looks ahead of time so swiping never waits on disk.
    func preload(_ looks: [Look]) {
        for look in looks {
            _ = lut(for: look)
        }
    }

    static func url(forLUT file: String, in bundle: Bundle) -> URL? {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return bundle.url(forResource: name, withExtension: ext.isEmpty ? "cube" : ext)
    }
}
