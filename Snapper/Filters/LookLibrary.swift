import Foundation
import OSLog

/// The ordered list of looks the app offers, read from the bundled manifest.
///
/// "Original" is always first and always free. Everything after it follows the
/// order of `filters.json`, so looks can be reordered, renamed, hidden or moved
/// between free and premium without code changes.
final class LookLibrary: Sendable {
    let looks: [Look]
    let collections: [LookCollection]

    private let byID: [String: Look]
    private let collectionsByID: [String: LookCollection]

    init(looks: [Look], collections: [LookCollection]) {
        self.looks = looks
        self.collections = collections
        self.byID = Dictionary(looks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.collectionsByID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func look(id: String) -> Look? {
        byID[id]
    }

    func collection(for look: Look) -> LookCollection? {
        look.collectionID.flatMap { collectionsByID[$0] }
    }

    var freeLooks: [Look] { looks.filter { $0.tier == .free } }
    var premiumLooks: [Look] { looks.filter { $0.tier == .premium } }

    /// Loads `Filters/filters.json` from the main bundle. A missing or broken
    /// manifest leaves the app usable with just the original look.
    static func bundled(bundle: Bundle = .main) -> LookLibrary {
        guard let url = bundle.url(forResource: "filters", withExtension: "json") else {
            Logger.filters.error("filters.json is missing from the bundle")
            return LookLibrary(looks: [.original], collections: [])
        }
        do {
            let manifest = try JSONDecoder().decode(LookManifest.self, from: Data(contentsOf: url))
            return LookLibrary(manifest: manifest, bundle: bundle)
        } catch {
            Logger.filters.error("Could not read filters.json: \(error.localizedDescription, privacy: .public)")
            return LookLibrary(looks: [.original], collections: [])
        }
    }

    convenience init(manifest: LookManifest, bundle: Bundle = .main) {
        let collections = manifest.collections.map {
            LookCollection(id: $0.id, name: $0.name, tagline: $0.tagline ?? "")
        }
        var seen: Set<String> = [Look.original.id]
        var looks: [Look] = [.original]
        for entry in manifest.looks where entry.enabled ?? true {
            guard !seen.contains(entry.id) else {
                Logger.filters.error("Duplicate look id \(entry.id, privacy: .public) in filters.json")
                continue
            }
            guard LUTStore.url(forLUT: entry.lut, in: bundle) != nil else {
                Logger.filters.error("Look \(entry.id, privacy: .public) points to missing LUT \(entry.lut, privacy: .public)")
                continue
            }
            seen.insert(entry.id)
            looks.append(Look(id: entry.id,
                              name: entry.name,
                              collectionID: entry.collection,
                              lutFile: entry.lut,
                              tier: entry.tier ?? .premium,
                              effects: entry.effects ?? .none))
        }
        self.init(looks: looks, collections: collections)
    }
}

extension Logger {
    static let filters = Logger(subsystem: "app.snapper", category: "filters")
    static let camera = Logger(subsystem: "app.snapper", category: "camera")
    static let rendering = Logger(subsystem: "app.snapper", category: "rendering")
    static let library = Logger(subsystem: "app.snapper", category: "library")
    static let store = Logger(subsystem: "app.snapper", category: "store")
}
