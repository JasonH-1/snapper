import Foundation

/// Whether a look is part of the free set or needs Snapper Premium to export.
enum LookTier: String, Codable, Sendable {
    case free
    case premium
}

/// A look (filter). Looks are data: a display name, a collection, a 3D LUT
/// file and optional effects drawn after it. The list and its order come from
/// `filters.json`.
struct Look: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let collectionID: String?
    /// File name of the LUT (.snaplut or .cube) in the bundle, or `nil` for the unfiltered original.
    let lutFile: String?
    let tier: LookTier
    var effects: LookEffects = .none

    var isOriginal: Bool { lutFile == nil }
    var isPremium: Bool { tier == .premium }

    static let original = Look(id: "original", name: "Original", collectionID: nil, lutFile: nil, tier: .free)
}

/// A named family of looks (a style direction).
struct LookCollection: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let tagline: String
}

/// The JSON manifest bundled at `Filters/filters.json`.
struct LookManifest: Decodable, Sendable {
    struct Collection: Decodable, Sendable {
        let id: String
        let name: String
        let tagline: String?
    }

    struct Entry: Decodable, Sendable {
        let id: String
        let name: String
        let collection: String?
        let lut: String
        let tier: LookTier?
        /// Set to `false` to hide a look without deleting its entry.
        let enabled: Bool?
        /// Written by tools/lutgen from looks.toml.
        let effects: LookEffects?
    }

    let version: Int
    let collections: [Collection]
    let looks: [Entry]
}
