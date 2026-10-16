import OSLog
import SwiftUI

/// Why the paywall is being shown; drives its hero image and copy.
enum PaywallContext: Identifiable {
    /// Shown once after onboarding.
    case intro
    /// Tried to save or share with a premium look (with the photo before and after).
    case lockedLook(Look, before: UIImage?, after: UIImage?)
    /// Tapped an upgrade entry point (camera badge, settings, watermark note).
    case upgrade

    var id: String {
        switch self {
        case .intro: "intro"
        case .lockedLook(let look, _, _): "locked-\(look.id)"
        case .upgrade: "upgrade"
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
        case root, review, settings
    }

    var review: ReviewModel?
    var paywall: PaywallModel?
    var isShowingSettings = false
    var isShowingLookPicker = false
    var toast: Toast?

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var hasWarnedAboutPhotosAccess = false
    /// Premium looks we've already explained this session (one toast per look).
    @ObservationIgnored private var lockedLooksExplained: Set<String> = []

    var hasPremium: Bool { store.isPremium }

    init(store: any PurchaseService) {
        let library = LookLibrary.bundled()
        let settings = AppSettings()
        let renderer = PhotoRenderer()
        self.library = library
        self.settings = settings
        self.renderer = renderer
        self.store = store
        self.camera = CameraModel(library: library)
        self.captures = CaptureLibrary(library: library, renderer: renderer)

        camera.setLookOrder(settings.orderedLooks(from: library))
        if let id = settings.lastLookID, let look = library.look(id: id) {
            camera.select(look)
        }
        camera.onCapture = { [weak self] photo, look in
            self?.handleCapture(photo, look: look)
        }
        camera.onLookChange = { [weak self] look in
            self?.settings.lastLookID = look.id
        }
    }

    // MARK: - Capture

    private func handleCapture(_ photo: CapturedPhoto, look: Look) {
        settings.lastLookID = look.id
        Task {
            do {
                let record = try await captures.add(photo, look: look)
                guard settings.autoSaveToPhotos else { return }
                if look.isPremium && !hasPremium {
                    guard lockedLooksExplained.insert(look.id).inserted else { return }
                    show(Toast(message: String(localized: "\(look.name) is a Premium look. Unlock it to save to Photos."),
                               symbol: "lock.fill", action: .showPaywall, actionTitle: String(localized: "Unlock")))
                    return
                }
                guard PhotoLibrarySaver.isAuthorized || PhotoLibrarySaver.canAsk else {
                    warnAboutPhotosAccess()
                    return
                }
                try await captures.saveToPhotos(record, watermark: !hasPremium, includeOriginal: settings.alsoSaveOriginal,
                                                format: settings.photoFormat)
            } catch PhotoLibrarySaver.SaveError.notAuthorized {
                warnAboutPhotosAccess()
            } catch {
                Logger.library.error("Capture handling failed: \(error.localizedDescription, privacy: .public)")
                show(Toast(message: error.localizedDescription, symbol: "exclamationmark.triangle.fill"))
            }
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

    /// Ends onboarding; the paywall is offered once, right after, and can be closed.
    func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        guard !settings.hasSeenIntroPaywall else { return }
        settings.hasSeenIntroPaywall = true
        guard !hasPremium else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            presentPaywall(.intro)
        }
    }

    // MARK: - Navigation

    func selectLook(_ look: Look) {
        camera.select(look)
    }

    func openLookPicker() {
        lookThumbnails.load(looks: library.looks, renderer: renderer)
        isShowingLookPicker = true
    }

    func openReview(id: UUID? = nil) {
        guard !captures.records.isEmpty else { return }
        camera.setPreviewVisible(false)
        review = ReviewModel(
            library: captures,
            looks: library.looks,
            startAt: id,
            hasPremium: { [weak self] in self?.hasPremium ?? false },
            alsoSaveOriginal: { [weak self] in self?.settings.alsoSaveOriginal ?? false },
            saveFormat: { [weak self] in self?.settings.photoFormat ?? .heic },
            requestPremium: { [weak self] look, before, after in
                self?.presentPaywall(.lockedLook(look, before: before, after: after))
            }
        )
    }

    func reviewDismissed() {
        review = nil
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
        if review != nil { return .review }
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

    func lookPickerDismissed() {
        isShowingLookPicker = false
        camera.setLookOrder(settings.orderedLooks(from: library))
    }

    private func updateCameraVisibility() {
        camera.setPreviewVisible(review == nil && paywall == nil && !isShowingSettings)
    }
}
