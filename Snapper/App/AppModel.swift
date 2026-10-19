import OSLog
import SwiftUI

/// Why the paywall is being shown; drives its hero image and copy.
enum PaywallContext: Identifiable {
    /// Shown once, at the end of onboarding.
    case intro
    /// Tried to save or share with a premium look (with the photo before and after).
    case lockedLook(Look, before: UIImage?, after: UIImage?)
    /// Tapped an upgrade entry point (camera badge, settings, watermark note).
    case upgrade
    /// A subscriber chose Switch to Lifetime in Settings: only Lifetime is offered.
    case switchToLifetime

    var id: String {
        switch self {
        case .intro: "intro"
        case .lockedLook(let look, _, _): "locked-\(look.id)"
        case .upgrade: "upgrade"
        case .switchToLifetime: "switch-to-lifetime"
        }
    }
}

/// A short message shown over the camera.
struct Toast: Identifiable, Equatable {
    enum Action: Equatable {
        case showPaywall
        case openSettings
    }

    let id = UUID()
    let message: String
    var symbol: String = "checkmark.circle.fill"
    var action: Action?
    var actionTitle: String?
}

/// App-wide state and navigation. Owns the long-lived models and connects
/// the camera, the capture roll, purchases and settings.
@MainActor
@Observable
final class AppModel {
    let library: LookLibrary
    let settings: AppSettings
    let camera: CameraModel
    let captures: CaptureLibrary
    let renderer: PhotoRenderer
    let store: any PurchaseService
    let lookThumbnails = LookThumbnails()

    /// Which screen presents the paywall: always the one on top.
    enum PaywallHost {
        case root, library, settings
    }

    /// The Library screen, when open.
    var libraryScreen: LibraryModel?
    /// Ties the Library's zoom transition to the camera's Library button.
    static let libraryZoomID = "library"
    var paywall: PaywallModel?
    var isShowingSettings = false
    var pendingGuideDestination: GuideDestination?
    var isShowingLookPicker = false
    var isShowingCameraPresets = false
    var upgradeAfterCameraPresets = false
    var isImportingPreset = false
    var toast: Toast?

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var hasWarnedAboutPhotosAccess = false
    /// Premium looks we've already explained this session (one toast per look).
    @ObservationIgnored private var lockedLooksExplained: Set<String> = []

    // The Lock Screen camera (see AppModel+LockScreen.swift).
    /// The camera settings last handed to the Lock Screen camera.
    @ObservationIgnored var sharedLockScreenCamera: SnapperCameraContext?
    @ObservationIgnored var lockScreenShareTask: Task<Void, Never>?
    @ObservationIgnored var isImportingLockScreenPhotos = false
    /// The Library has read its index, so photos already in it are known.
    @ObservationIgnored var isLibraryLoaded = false

    var hasPremium: Bool { store.isPremium }

    init(store: any PurchaseService, settings: AppSettings = AppSettings(), captureStore: CaptureStore = .default) {
        let library = LookLibrary.bundled()
        let renderer = PhotoRenderer()
        self.library = library
        self.settings = settings
        self.renderer = renderer
        self.store = store
        self.camera = CameraModel(library: library)
        self.captures = CaptureLibrary(library: library, renderer: renderer, store: captureStore)

        captures.hasPremium = { [weak self] in self?.hasPremium ?? false }
        camera.restore(settings.cameraPreferences)
        camera.setLookOrder(settings.orderedLooks(from: library))
        if let id = settings.lastLookID, let look = library.look(id: id) {
            camera.select(look)
        }
        camera.onCapture = { [weak self] photo, look in
            self?.handleCapture(photo, look: look)
        }
        camera.onLookChange = { [weak self] look in
            self?.settings.lastLookID = look.id
            self?.settings.lastPresetID = self?.camera.activePreset?.id
        }
        camera.onPreferencesChange = { [weak self] preferences in
            self?.settings.cameraPreferences = preferences
        }
    }

    @discardableResult
    func shootWithPreset(_ preset: SavedPreset) -> Bool {
        guard settings.presets.canUse(preset, hasPremium: hasPremium), library.look(id: preset.lookID) != nil else { return false }
        camera.selectPreset(preset)
        libraryScreen?.editor?.finish()
        libraryScreen = nil
        updateCameraVisibility()
        return true
    }

    /// Keep the selected preset current after edits, deletion or entitlement changes.
    func synchronizeCameraPreset() {
        guard let id = settings.lastPresetID else { return }
        guard let preset = settings.presets.presets.first(where: { $0.id == id }) else {
            camera.select(camera.currentLook)
            settings.lastPresetID = nil
            return
        }
        if settings.presets.canUse(preset, hasPremium: hasPremium) {
            if camera.activePreset != preset { camera.selectPreset(preset) }
        } else if camera.activePreset != nil {
            camera.select(camera.currentLook)
            settings.lastPresetID = id
            show(Toast(message: String(localized: "This preset needs Premium. Shooting with its base look."), symbol: "lock.fill"))
        }
    }

    // MARK: - Capture

    private func handleCapture(_ photo: CapturedPhoto, look: Look) {
        settings.lastLookID = look.id
        Task { await keep(photo, look: look) }
    }

    /// Adds a photo to the Library and, with auto-save on, to Photos.
    /// Returns whether it reached the Library.
    @discardableResult
    func keep(_ photo: CapturedPhoto, look: Look) async -> Bool {
        settings.noteRecentlyUsed(look)
        let record: CaptureRecord
        do {
            record = try await captures.add(photo, look: look)
        } catch {
            Logger.library.error("Capture handling failed: \(error.localizedDescription, privacy: .public)")
            show(Toast(message: error.localizedDescription, symbol: "exclamationmark.triangle.fill"))
            return false
        }
        await autoSave(record, look: look)
        return true
    }

    private func autoSave(_ record: CaptureRecord, look: Look) async {
        do {
            guard settings.autoSaveToPhotos else { return }
            guard PhotoLibrarySaver.isAuthorized || PhotoLibrarySaver.canAsk else {
                warnAboutPhotosAccess()
                return
            }
            // A shot with a previewed Premium look or tools is still saved,
            // without those parts; the Library keeps the full edit.
            let isLocked = !hasPremium && captures.needsPremium(record.recipe, of: record)
            try await captures.saveToPhotos(record, recipe: isLocked ? captures.freeVersion(of: record.recipe) : nil,
                                            includeOriginal: settings.alsoSaveOriginal,
                                            options: ExportOptions(format: settings.photoFormat))
            if isLocked {
                guard lockedLooksExplained.insert(look.id).inserted else { return }
                let message = captures.premiumParts(of: record.recipe).look != nil
                    ? String(localized: "Saved to Photos without \(look.name), a Premium look. Snapper Library keeps the full look.")
                    : String(localized: "Saved to Photos without its Premium tools. Snapper Library keeps the full edit.")
                show(Toast(message: message,
                           symbol: "lock.fill", action: .showPaywall, actionTitle: String(localized: "Unlock")))
                return
            }
            if !hasPremium && !settings.hasSeenIntroPaywall {
                settings.hasSeenIntroPaywall = true
                show(Toast(message: String(localized: "Photo saved. Make your next style your own."),
                           symbol: "checkmark.circle.fill", action: .showPaywall,
                           actionTitle: String(localized: "Explore Premium")))
            }
        } catch PhotoLibrarySaver.SaveError.notAuthorized {
            warnAboutPhotosAccess()
        } catch {
            Logger.library.error("Saving to Photos failed: \(error.localizedDescription, privacy: .public)")
            show(Toast(message: error.localizedDescription, symbol: "exclamationmark.triangle.fill"))
        }
    }

    private func warnAboutPhotosAccess() {
        guard !hasWarnedAboutPhotosAccess else { return }
        hasWarnedAboutPhotosAccess = true
        show(Toast(message: String(localized: "Photos are kept in Snapper. Allow photo access to save them to your library."),
                   symbol: "photo.badge.exclamationmark", action: .openSettings, actionTitle: String(localized: "Settings")))
    }

    func show(_ toast: Toast) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self.toast = toast }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { self.toast = nil }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) { toast = nil }
    }

    // MARK: - Onboarding

    var needsOnboarding: Bool { !settings.hasCompletedOnboarding }

    /// Ends onboarding with a single offer of Premium and its free trial.
    /// Closing it starts the camera; after this, offers follow only a save
    /// or an explicit request for a Premium feature.
    func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        if !hasPremium { presentPaywall(.intro) }
    }

    // MARK: - Navigation

    func selectLook(_ look: Look) {
        camera.select(look)
    }

    func selectCuratedStyle(_ style: CuratedStyle) {
        guard CuratedCollection.contains(style), library.look(id: style.recipe.lookID) != nil else { return }
        camera.selectPreset(style.preset)
        settings.lastPresetID = nil // bundled recipes are not user-saved presets
    }

    func openCameraPresets() {
        camera.setPreviewVisible(false)
        isShowingCameraPresets = true
    }

    func cameraPresetsDismissed() {
        isShowingCameraPresets = false
        updateCameraVisibility()
    }

    func openLookPicker() {
        camera.setPreviewVisible(false)
        lookThumbnails.load(looks: library.looks, renderer: renderer)
        isShowingLookPicker = true
    }

    func openLibrary() {
        camera.setPreviewVisible(false)
        libraryScreen = LibraryModel(
            captures: captures,
            looks: library,
            settings: settings,
            hasPremium: { [weak self] in self?.hasPremium ?? false },
            requestPremium: { [weak self] look, before, after in
                self?.presentPaywall(look.isPremium ? .lockedLook(look, before: before, after: after) : .upgrade)
            }
        )
    }

    func libraryDismissed() {
        libraryScreen?.editor?.finish()
        libraryScreen = nil
        updateCameraVisibility()
    }

    func presentPaywall(_ context: PaywallContext) {
        guard paywall == nil else { return }
        camera.setPreviewVisible(false)
        paywall = PaywallModel(context: context,
                               store: store,
                               library: library,
                               renderer: renderer,
                               photoURL: captures.latest.map(captures.url(for:)))
    }

    func paywallDismissed() {
        let unlocked = paywall?.didUnlock ?? false
        paywall = nil
        updateCameraVisibility()
        if unlocked {
            show(Toast(message: String(localized: "Welcome to Snapper Premium. Every look is yours."), symbol: "sparkles"))
        }
    }

    private var paywallHost: PaywallHost {
        if libraryScreen != nil { return .library }
        if isShowingSettings { return .settings }
        return .root
    }

    /// Binding for `host` to present the paywall; only the top-most screen
    /// gets a non-nil value, so SwiftUI never stacks two presentations.
    func paywallBinding(for host: PaywallHost) -> Binding<PaywallModel?> {
        Binding(
            get: { [weak self] in
                guard let self, self.paywallHost == host else { return nil }
                return self.paywall
            },
            set: { [weak self] newValue in
                if newValue == nil { self?.paywall = nil }
            }
        )
    }

    func openSettings() {
        camera.setPreviewVisible(false)
        lookThumbnails.load(looks: library.looks, renderer: renderer)
        isShowingSettings = true
    }

    func settingsDismissed() {
        isShowingSettings = false
        camera.setLookOrder(settings.orderedLooks(from: library))
        updateCameraVisibility()
    }

    /// Called only after Settings has finished dismissing.
    func openPendingGuideDestination() {
        guard let destination = pendingGuideDestination else { return }
        pendingGuideDestination = nil
        switch destination {
        case .camera: updateCameraVisibility()
        case .looks: openLookPicker()
        case .library: openLibrary()
        case .styles:
            camera.setPreviewVisible(false)
            isShowingCameraPresets = true
        }
    }

    func lookPickerDismissed() {
        isShowingLookPicker = false
        camera.setLookOrder(settings.orderedLooks(from: library))
        updateCameraVisibility()
    }

    func updateCameraVisibility() {
        camera.setPreviewVisible(libraryScreen == nil && paywall == nil && !isShowingSettings
                                 && !isShowingLookPicker && !isShowingCameraPresets && !isImportingPreset
                                 && incomingBackup == nil)
    }

    // MARK: - Backup

    /// A backup opened from Files or AirDrop, waiting for the person to restore it.
    var incomingBackup: IncomingBackup?

    struct IncomingBackup: Identifiable {
        let url: URL
        var id: URL { url }
    }

    /// Writes a backup of the Library, presets and favourites.
    func makeLibraryBackup() async throws -> (url: URL, summary: LibraryBackup.Summary) {
        try await captures.makeBackup(presets: settings.presets.presets, favoriteLookIDs: settings.favoriteLookIDs,
                                      appVersion: SettingsView.versionString)
    }

    /// Restores a backup into the Library and says what happened.
    func restoreLibraryBackup(from url: URL) async throws -> String {
        let result = try await captures.restoreBackup(from: url)
        let presets = settings.presets.restore(result.presets)
        settings.mergeFavorites(result.favoriteLookIDs, library: library)
        return Self.restoreMessage(photos: result.records.count, presets: presets,
                                   alreadyThere: result.alreadyInLibrary, unreadable: result.unreadable,
                                   stopped: result.wasStopped)
    }

    nonisolated static func restoreMessage(photos: Int, presets: Int, alreadyThere: Int, unreadable: Int,
                                           stopped: Bool = false) -> String {
        var parts: [String] = []
        if stopped {
            parts.append(String(localized: "Restore stopped. Restore again to add the rest; photos already restored are skipped."))
        }
        let photoText = LibraryModel.photoCount(photos)
        if presets > 0 {
            parts.append(presets == 1
                         ? String(localized: "Restored \(photoText) and 1 preset.")
                         : String(localized: "Restored \(photoText) and \(presets) presets."))
        } else {
            parts.append(String(localized: "Restored \(photoText)."))
        }
        if alreadyThere == 1 {
            parts.append(String(localized: "1 photo already in Snapper stayed as it was."))
        } else if alreadyThere > 1 {
            parts.append(String(localized: "\(alreadyThere) photos already in Snapper stayed as they were."))
        }
        if unreadable == 1 {
            parts.append(String(localized: "1 photo couldn't be read and was skipped."))
        } else if unreadable > 1 {
            parts.append(String(localized: "\(unreadable) photos couldn't be read and were skipped."))
        }
        return parts.joined(separator: " ")
    }
}
