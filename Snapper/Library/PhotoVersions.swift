import Foundation

/// A named edit of one photo ("Warm", "Black & White"), kept with the photo
/// so it can be switched back to without undoing. Like every edit it is only
/// a recipe: the photo's original file is shared by all of its versions.
struct PhotoVersion: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var recipe: PhotoRecipe
    let createdAt: Date

    init(id: UUID = UUID(), name: String, recipe: PhotoRecipe, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.recipe = recipe
        self.createdAt = createdAt
    }

    /// Most versions one photo keeps.
    static let maxCount = 20
    /// Longest name, in characters.
    static let maxNameLength = 30

    /// A trimmed name that fits, or nil when there is nothing usable.
    static func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { character in !character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    /// A name to suggest for `recipe`: what the edit mostly is ("Black &
    /// White", "Warm", the look's name), made unique among `existing`.
    /// Only a starting point; the person can type any name.
    static func suggestedName(for recipe: PhotoRecipe, look: Look, existing: [PhotoVersion]) -> String {
        let adjustments = recipe.adjustments
        let base: String
        if adjustments.saturation <= -0.95 {
            base = String(localized: "Black & White")
        } else if adjustments.warmth >= 0.2 || (adjustments.splitToning.highlightSaturation > 0.2 && isWarm(adjustments.splitToning.highlightHue)) {
            base = String(localized: "Warm")
        } else if adjustments.warmth <= -0.2 {
            base = String(localized: "Cool")
        } else if !look.isOriginal {
            base = look.name
        } else if recipe == .untouched || adjustments.isNone {
            base = String(localized: "Original")
        } else {
            base = String(localized: "Version")
        }
        let names = Set(existing.map { $0.name.lowercased() })
        guard names.contains(base.lowercased()) else { return base }
        var number = 2
        while names.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    private static func isWarm(_ hue: Double) -> Bool {
        hue < 75 || hue > 330
    }
}
