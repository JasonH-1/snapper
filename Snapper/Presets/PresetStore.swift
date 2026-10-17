import Foundation
import Observation

/// A reusable colour style, deliberately excluding crop, frame and date.
struct SavedPreset: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var lookID: String
    var strength: Double
    var adjustments: PhotoAdjustments

    init(name: String, recipe: PhotoRecipe) {
        self.name = name
        lookID = recipe.lookID
        strength = recipe.strength
        adjustments = recipe.adjustments
    }

    var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 40 && !lookID.isEmpty
            && !trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && strength.isFinite && (0...1).contains(strength)
            && PhotoAdjustments.Kind.allCases.allSatisfy { adjustments[$0].isFinite && $0.range.contains(adjustments[$0]) }
    }

    func applying(to recipe: PhotoRecipe) -> PhotoRecipe {
        var result = recipe
        result.lookID = lookID
        result.strength = strength
        result.adjustments = adjustments
        return result
    }
}

@MainActor
@Observable
final class PresetStore {
    enum StoreError: LocalizedError {
        case premiumRequired, invalidName, invalidStyle, unavailable
        var errorDescription: String? {
            switch self {
            case .premiumRequired: String(localized: "The free plan includes one personal preset. Premium unlocks unlimited presets.")
            case .invalidName: String(localized: "Give your preset a name between 1 and 40 characters.")
            case .invalidStyle: String(localized: "This style has invalid adjustment values. No presets were changed.")
            case .unavailable: String(localized: "Your saved presets couldn't be opened. They have been kept on this iPhone; no changes were written.")
            }
        }
    }

    private struct Archive: Codable {
        var version = 1
        var presets: [SavedPreset]
    }

    static let storageKey = "presets.archive.v1"
    private(set) var presets: [SavedPreset] = []
    private(set) var loadFailed = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                let archive = try JSONDecoder().decode(Archive.self, from: data)
                guard archive.version == 1, archive.presets.allSatisfy(\.isValid),
                      Set(archive.presets.map(\.id)).count == archive.presets.count else { throw StoreError.unavailable }
                presets = archive.presets
            } catch { loadFailed = true }
        }
    }

    /// After a subscription ends, keep every preset and allow the first one.
    /// The person can choose a different free preset without deleting anything.
    func canUse(_ preset: SavedPreset, hasPremium: Bool) -> Bool {
        !loadFailed && presets.contains(preset) && (hasPremium || presets.first?.id == preset.id)
    }

    @discardableResult
    func save(name: String, recipe: PhotoRecipe, hasPremium: Bool) throws -> SavedPreset {
        guard hasPremium || presets.isEmpty else { throw StoreError.premiumRequired }
        let preset = SavedPreset(name: try validName(name), recipe: recipe)
        guard preset.isValid else { throw StoreError.invalidStyle }
        try persist(presets + [preset])
        return preset
    }

    func rename(_ preset: SavedPreset, to name: String) throws {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var next = presets
        next[index].name = try validName(name)
        try persist(next)
    }

    func duplicate(_ preset: SavedPreset, hasPremium: Bool) throws {
        var recipe = PhotoRecipe(lookID: preset.lookID, strength: preset.strength, adjustments: preset.adjustments)
        recipe.crop = .none
        try save(name: String(preset.name.prefix(35)) + " Copy", recipe: recipe, hasPremium: hasPremium)
    }

    func delete(_ preset: SavedPreset) throws {
        try persist(presets.filter { $0.id != preset.id })
    }

    func makeFreePreset(_ preset: SavedPreset) throws {
        guard presets.contains(where: { $0.id == preset.id }) else { return }
        try persist([preset] + presets.filter { $0.id != preset.id })
    }

    private func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw StoreError.invalidName }
        return trimmed
    }

    private func persist(_ next: [SavedPreset]) throws {
        guard !loadFailed else { throw StoreError.unavailable }
        let data = try JSONEncoder().encode(Archive(presets: next))
        defaults.set(data, forKey: Self.storageKey)
        presets = next
    }
}
