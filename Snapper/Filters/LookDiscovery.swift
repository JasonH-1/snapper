import Foundation

/// Shared, deterministic discovery rules; search includes shooting guidance.
struct LookDiscovery {
    enum Scope: String, CaseIterable, Identifiable {
        case all, free, favorites
        var id: String { rawValue }
        var title: LocalizedStringResource {
            switch self {
            case .all: "All Looks"
            case .free: "Free"
            case .favorites: "Favorites"
            }
        }
    }

    static func matches(_ look: Look, library: LookLibrary, query: String, scope: Scope, favoriteIDs: [String]) -> Bool {
        if scope == .free && look.isPremium { return false }
        if scope == .favorites && !favoriteIDs.contains(look.id) { return false }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let collection = library.collections.first { $0.id == look.collectionID }
        let guide = LookGuide.forLook(look.id)
        let text = [look.name, collection?.name, collection?.tagline, guide?.bestFor, guide?.tip]
            .compactMap { $0 }.joined(separator: " ")
        return words.allSatisfy { text.localizedStandardContains($0) }
    }
}
