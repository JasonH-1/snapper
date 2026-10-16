import Foundation

/// A group of looks the category chips jump between.
enum LookCategory: Hashable, Identifiable, Sendable {
    case favorites
    case recent
    case collection(String)

    var id: String {
        switch self {
        case .favorites: "favorites"
        case .recent: "recent"
        case .collection(let id): "collection-\(id)"
        }
    }
}

/// Looks arranged for browsing: Original, then Favorites and Recent (when
/// there are any), then each collection. One continuous strip or grid, with a
/// chip per category that jumps to it.
struct LookCatalog: Sendable {
    struct Section: Identifiable, Sendable {
        let category: LookCategory
        let title: String
        let tagline: String?
        let looks: [Look]

        var id: String { category.id }

        /// Shown on collection chips; Favorites and Recent change too often.
        var count: Int? {
            if case .collection = category { return looks.count }
            return nil
        }
    }

    /// One look in the strip. A look can appear twice (in Favorites and its
    /// collection), so entries have their own ids.
    struct Entry: Identifiable, Hashable, Sendable {
        let id: String
        let look: Look
        /// Nil for Original, which sits before every category.
        let category: LookCategory?
    }

    static let originalEntryID = "original"

    let sections: [Section]
    let entries: [Entry]

    init(library: LookLibrary, favoriteIDs: [String], recentIDs: [String]) {
        var sections: [Section] = []
        let favorites = favoriteIDs.compactMap(library.look(id:)).filter { !$0.isOriginal }
        if !favorites.isEmpty {
            sections.append(Section(category: .favorites, title: String(localized: "Favorites"), tagline: nil, looks: favorites))
        }
        let recent = recentIDs.compactMap(library.look(id:)).filter { !$0.isOriginal }
        if !recent.isEmpty {
            sections.append(Section(category: .recent, title: String(localized: "Recent"), tagline: nil, looks: recent))
        }
        for collection in library.collections {
            let looks = library.looks.filter { $0.collectionID == collection.id }
            guard !looks.isEmpty else { continue }
            sections.append(Section(category: .collection(collection.id), title: collection.name,
                                    tagline: collection.tagline.isEmpty ? nil : collection.tagline, looks: looks))
        }
        // Looks outside any collection still need a home.
        let homeless = library.looks.filter { look in
            !look.isOriginal && !library.collections.contains { $0.id == look.collectionID }
        }
        if !homeless.isEmpty {
            sections.append(Section(category: .collection("more"), title: String(localized: "More"), tagline: nil, looks: homeless))
        }
        self.sections = sections

        var entries = [Entry(id: Self.originalEntryID, look: .original, category: nil)]
        for section in sections {
            entries += section.looks.map { Entry(id: "\(section.id)/\($0.id)", look: $0, category: section.category) }
        }
        self.entries = entries
    }

    var categories: [LookCategory] { sections.map(\.category) }

    func section(for category: LookCategory) -> Section? {
        sections.first { $0.category == category }
    }

    /// Where a chip jumps to: the category's first look.
    func firstEntryID(of category: LookCategory) -> String? {
        entries.first { $0.category == category }?.id
    }

    /// The chip to highlight when `entryID` is the first look in view.
    /// Original counts as the first category.
    func category(ofEntry entryID: String) -> LookCategory? {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return nil }
        return entry.category ?? sections.first?.category
    }

    /// The entry to show `lookID` with: in `preferred` if it's there, else
    /// in its collection.
    func entryID(forLook lookID: String, preferring preferred: LookCategory? = nil) -> String? {
        if lookID == Look.original.id { return Self.originalEntryID }
        if let preferred, let entry = entries.first(where: { $0.category == preferred && $0.look.id == lookID }) {
            return entry.id
        }
        let inCollection = entries.first { entry in
            guard case .collection = entry.category else { return false }
            return entry.look.id == lookID
        }
        return (inCollection ?? entries.first { $0.look.id == lookID })?.id
    }
}
