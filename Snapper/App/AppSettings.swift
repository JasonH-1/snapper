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
        static let recentLooks = "looks.recentLookIDs"
        static let onboardingDone = "app.hasCompletedOnboarding"
        static let introPaywallShown = "app.hasSeenIntroPaywall"
        static let lastLookID = "camera.lastLookID"
        static let showGrid = "camera.showGrid"
        static let selfTimer = "camera.selfTimer"
        static let showLevel = "camera.showLevel"
        static let aspectRatio = "camera.aspectRatio"
        static let mirrorFront = "camera.mirrorFrontCamera"
        static let volumeShutter = "camera.volumeButtonShutter"
        static let megapixels = "camera.photoMegapixels"
        static let photoFormat = "photos.format"
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

    /// Looks used most recently (shots and edits), newest first.
    var recentLookIDs: [String] {
        didSet { defaults.set(recentLookIDs, forKey: Key.recentLooks) }
    }

    /// How many looks the Recent category remembers.
    static let maxRecentLooks = 10

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboardingDone) }
    }

    var hasSeenIntroPaywall: Bool {
        didSet { defaults.set(hasSeenIntroPaywall, forKey: Key.introPaywallShown) }
    }

    var lastLookID: String? {
        didSet { defaults.set(lastLookID, forKey: Key.lastLookID) }
    }

    /// Rule-of-thirds lines over the camera preview.
    var showGrid: Bool {
        didSet { defaults.set(showGrid, forKey: Key.showGrid) }
    }

    /// Countdown before the shutter fires.
    var selfTimer: SelfTimer {
        didSet { defaults.set(selfTimer.rawValue, forKey: Key.selfTimer) }
    }

    /// A horizon line over the preview.
    var showLevel: Bool {
        didSet { defaults.set(showLevel, forKey: Key.showLevel) }
    }

    /// Photo shape for new shots.
    var aspectRatio: AspectRatio {
        didSet { defaults.set(aspectRatio.rawValue, forKey: Key.aspectRatio) }
    }

    /// Save selfies as seen in the preview (mirrored), like a mirror.
    var mirrorFrontCamera: Bool {
        didSet { defaults.set(mirrorFrontCamera, forKey: Key.mirrorFront) }
    }

    /// The volume buttons (and Camera Control) take the photo.
    var volumeButtonShutter: Bool {
        didSet { defaults.set(volumeButtonShutter, forKey: Key.volumeShutter) }
    }

    /// Photo Size, in megapixels.
    var photoMegapixels: Int {
        didSet { defaults.set(photoMegapixels, forKey: Key.megapixels) }
    }

    /// The file format photos are saved to the photo library in.
    var photoFormat: PhotoRenderer.ExportFormat {
        didSet { defaults.set(photoFormat.rawValue, forKey: Key.photoFormat) }
    }

    /// What the camera needs to know when the shutter is pressed.
    var captureOptions: CaptureOptions {
        CaptureOptions(timer: selfTimer, aspect: aspectRatio, mirrorFrontCamera: mirrorFrontCamera)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoSaveToPhotos = defaults.object(forKey: Key.autoSave) as? Bool ?? true
        alsoSaveOriginal = defaults.bool(forKey: Key.saveOriginal)
        favoriteLookIDs = defaults.stringArray(forKey: Key.favorites) ?? []
        recentLookIDs = defaults.stringArray(forKey: Key.recentLooks) ?? []
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboardingDone)
        hasSeenIntroPaywall = defaults.bool(forKey: Key.introPaywallShown)
        lastLookID = defaults.string(forKey: Key.lastLookID)
        showGrid = defaults.bool(forKey: Key.showGrid)
        selfTimer = SelfTimer(rawValue: defaults.integer(forKey: Key.selfTimer)) ?? .off
        showLevel = defaults.bool(forKey: Key.showLevel)
        aspectRatio = defaults.string(forKey: Key.aspectRatio).flatMap(AspectRatio.init(rawValue:)) ?? .fourThree
        mirrorFrontCamera = defaults.object(forKey: Key.mirrorFront) as? Bool ?? true
        volumeButtonShutter = defaults.object(forKey: Key.volumeShutter) as? Bool ?? true
        photoMegapixels = defaults.object(forKey: Key.megapixels) as? Int ?? 24
        photoFormat = defaults.string(forKey: Key.photoFormat).flatMap(PhotoRenderer.ExportFormat.init(rawValue:)) ?? .heic
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

    /// Moves `look` to the front of Recent (Original is never listed).
    func noteRecentlyUsed(_ look: Look) {
        guard !look.isOriginal, recentLookIDs.first != look.id else { return }
        var ids = recentLookIDs.filter { $0 != look.id }
        ids.insert(look.id, at: 0)
        recentLookIDs = Array(ids.prefix(Self.maxRecentLooks))
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
