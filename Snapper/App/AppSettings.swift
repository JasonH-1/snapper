import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let autoSave = "settings.autoSaveToPhotos"
        static let saveOriginal = "settings.alsoSaveOriginal"
        static let favorites = "settings.favoriteLookIDs"
        static let onboardingDone = "app.hasCompletedOnboarding"
        static let introPaywallShown = "app.hasSeenIntroPaywall"
        static let lastLookID = "camera.lastLookID"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Save each new photo to the photo library right away (when its look is unlocked).
    var autoSaveToPhotos: Bool {
        didSet { defaults.set(autoSaveToPhotos, forKey: Key.autoSave) }
    }

    /// Also save the unfiltered original next to the filtered photo.
    var alsoSaveOriginal: Bool {
        didSet { defaults.set(alsoSaveOriginal, forKey: Key.saveOriginal) }
    }

    /// Favourite looks come first when swiping, in the order they were starred.
    var favoriteLookIDs: [String] {
        didSet { defaults.set(favoriteLookIDs, forKey: Key.favorites) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboardingDone) }
    }

    var hasSeenIntroPaywall: Bool {
        didSet { defaults.set(hasSeenIntroPaywall, forKey: Key.introPaywallShown) }
    }

    var lastLookID: String? {
        didSet { defaults.set(lastLookID, forKey: Key.lastLookID) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoSaveToPhotos = defaults.object(forKey: Key.autoSave) as? Bool ?? true
        alsoSaveOriginal = defaults.bool(forKey: Key.saveOriginal)
        favoriteLookIDs = defaults.stringArray(forKey: Key.favorites) ?? []
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboardingDone)
        hasSeenIntroPaywall = defaults.bool(forKey: Key.introPaywallShown)
        lastLookID = defaults.string(forKey: Key.lastLookID)
    }

    func isFavorite(_ look: Look) -> Bool {
        favoriteLookIDs.contains(look.id)
    }

    func toggleFavorite(_ look: Look) {
        guard !look.isOriginal else { return }
        if let index = favoriteLookIDs.firstIndex(of: look.id) {
            favoriteLookIDs.remove(at: index)
        } else {
            favoriteLookIDs.append(look.id)
        }
    }

    /// The swipe order: Original, then favourites, then everything else in
    /// manifest order.
    func orderedLooks(from library: LookLibrary) -> [Look] {
        let favorites = favoriteLookIDs.compactMap(library.look(id:)).filter { !$0.isOriginal }
        let favoriteSet = Set(favorites.map(\.id))
        let rest = library.looks.filter { !$0.isOriginal && !favoriteSet.contains($0.id) }
        return [.original] + favorites + rest
    }
}
