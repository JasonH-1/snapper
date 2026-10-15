import OSLog
import SwiftUI

/// Why the paywall is being shown; drives its hero image and copy.
enum PaywallContext: Identifiable {
    /// Shown once after onboarding.
    case intro
    /// Tried to save or share with a premium look.
    case lockedLook(Look, UIImage?)
    /// Tapped an upgrade entry point (camera badge, settings, watermark note).
    case upgrade

    var id: String {
        switch self {
        case .intro: "intro"
        case .lockedLook(let look, _): "locked-\(look.id)"
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

    var review: ReviewModel?
    var paywall: PaywallContext?
    var isShowingSettings = false
    var isShowingLookPicker = false
    var toast: Toast?

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var hasWarnedAboutPhotosAccess = false

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
    }

    // MARK: - Capture

    private func handleCapture(_ photo: CapturedPhoto, look: Look) {
        settings.lastLookID = look.id
        Task {
            do {
                let record = try await captures.add(photo, look: look)
                guard settings.autoSaveToPhotos else { return }
                if look.isPremium && !hasPremium {
                    show(Toast(message: String(localized: "\(look.name) is a Premium look. Unlock it to save to Photos."),
                               symbol: "lock.fill", action: .showPaywall, actionTitle: String(localized: "Unlock")))
                    return
                }
                guard PhotoLibrarySaver.isAuthorized || PhotoLibrarySaver.canAsk else {
                    warnAboutPhotosAccess()
                    return
                }
                try await captures.saveToPhotos(record, watermark: !hasPremium, includeOriginal: settings.alsoSaveOriginal)
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

    // MARK: - Navigation

    func openReview(id: UUID? = nil) {
        guard !captures.records.isEmpty else { return }
        camera.setPreviewVisible(false)
        review = ReviewModel(
            library: captures,
            looks: library.looks,
            startAt: id,
            hasPremium: { [weak self] in self?.hasPremium ?? false },
            alsoSaveOriginal: { [weak self] in self?.settings.alsoSaveOriginal ?? false },
            requestPremium: { [weak self] look, image in
                self?.presentPaywall(.lockedLook(look, image))
            }
        )
    }

    func reviewDismissed() {
        review = nil
        updateCameraVisibility()
    }

    func presentPaywall(_ context: PaywallContext) {
        camera.setPreviewVisible(false)
        paywall = context
    }

    func paywallDismissed() {
        paywall = nil
        updateCameraVisibility()
    }

    func openSettings() {
        camera.setPreviewVisible(false)
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
