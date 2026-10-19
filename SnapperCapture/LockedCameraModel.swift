import CoreImage
import ImageIO
import LockedCameraCapture
import OSLog
import SwiftUI

/// The Lock Screen camera: Snapper's own camera and looks, opened from
/// Camera Control, the Lock Screen or Control Center while the iPhone is
/// locked. It can't reach Snapper's Library, so photos wait in the session's
/// folder until Snapper next opens and adds them (see `LockedCaptureInbox`).
@MainActor
@Observable
final class LockedCameraModel {
    let camera: CameraModel
    /// Snapper's camera settings, as the app last shared them.
    private(set) var settings = SnapperCameraContext()
    /// The newest photo from this session, with its look.
    private(set) var lastCapture: UIImage?
    private(set) var photoCount = 0
    private(set) var saveError: String?

    /// A Premium look (or style) is showing without Premium: photos still
    /// save, without it, as in the app.
    var isLocked: Bool {
        !settings.hasPremium && (camera.currentLook.isPremium || camera.activePreset?.adjustments.requiresPremium == true)
    }

    @ObservationIgnored private let session: LockedCameraCaptureSession
    @ObservationIgnored private var hasLoadedSettings = false
    @ObservationIgnored private var isApplyingSettings = false
    @ObservationIgnored private var settingsTask: Task<Void, Never>?

    init(session: LockedCameraCaptureSession) {
        self.session = session
        // Only the looks beside the current one are parsed up front, so the
        // camera is ready the moment the Lock Screen hands over.
        camera = CameraModel(library: .bundled(), preloadsEveryLook: false)
        camera.onCapture = { [weak self] photo, look in
            self?.save(photo, look: look)
        }
        camera.onLookChange = { [weak self] _ in
            self?.cameraChanged()
        }
        camera.onPreferencesChange = { [weak self] _ in
            self?.cameraChanged()
        }
    }

    /// Opens the camera as the person left it in Snapper (or in the last
    /// Lock Screen session).
    func start() async {
        if !hasLoadedSettings {
            hasLoadedSettings = true
            do {
                if let shared = try await SnapperCaptureIntent.appContext { apply(shared) }
            } catch {
                Logger.camera.error("No camera settings from Snapper: \(error.localizedDescription, privacy: .public)")
            }
        }
        await camera.start()
    }

    func shutterPressed() {
        camera.shutterPressed(options: settings.captureOptions)
    }

    /// Asks the person to unlock, then opens Snapper (its Library, to see
    /// this session's photos, or the camera).
    func openSnapper(_ destination: LockScreenHandoff) {
        Task {
            let activity = NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)
            activity.userInfo = [LockScreenHandoff.userInfoKey: destination.rawValue]
            do {
                try await session.openApplication(for: activity)
            } catch {
                Logger.camera.error("Couldn't open Snapper: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Settings

    private func apply(_ shared: SnapperCameraContext) {
        isApplyingSettings = true
        defer { isApplyingSettings = false }
        settings = shared
        let library = camera.library
        camera.setLookOrder(shared.orderedLooks(in: library))
        if let preset = shared.savedPreset, library.look(id: preset.lookID) != nil {
            camera.selectPreset(preset)
        } else if let id = shared.lookID, let look = library.look(id: id) {
            camera.select(look)
        }
        camera.restore(shared.cameraPreferences)
        camera.setPhotoMegapixels(shared.photoMegapixels)
    }

    /// The person changed the look, flash, exposure or camera here: keep it
    /// for Snapper (next to the photos) and for the next Lock Screen session.
    private func cameraChanged() {
        guard !isApplyingSettings else { return }
        settings.lookID = camera.currentLook.id
        settings.savedPreset = camera.activePreset
        settings.cameraPreferences = camera.preferences
        settings.updatedAt = Date()
        settingsTask?.cancel()
        let settings = self.settings
        let folder = session.sessionContentURL
        settingsTask = Task {
            // Exposure drags change it many times a second; write once it settles.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                try LockedCaptureInbox.writeCamera(settings, to: folder)
            } catch {
                Logger.camera.error("Couldn't keep the Lock Screen camera settings: \(error.localizedDescription, privacy: .public)")
            }
            // Best effort: the system may keep the app context for the app alone.
            try? await SnapperCaptureIntent.updateAppContext(settings)
        }
    }

    // MARK: - Photos

    private func save(_ photo: CapturedPhoto, look: Look) {
        let state = lookState(for: photo, look: look)
        let folder = session.sessionContentURL
        let lookID = look.id
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try LockedCaptureInbox.write(photo, lookID: lookID, to: folder)
                    return Self.thumbnail(of: photo, look: state)
                }.value
                saveError = nil
                photoCount += 1
                if let image { lastCapture = image }
            } catch {
                Logger.camera.error("Couldn't keep a Lock Screen photo: \(error.localizedDescription, privacy: .public)")
                saveError = String(localized: "This photo couldn't be kept. Unlock to open Snapper.")
            }
        }
    }

    /// The look as the photo was taken with it, a preset's strength and
    /// adjustments included.
    private func lookState(for photo: CapturedPhoto, look: Look) -> PreviewRenderer.LookState {
        var state = camera.lookState(for: look)
        if let style = photo.style {
            state.strength = style.strength
            state.adjustments = style.adjustments
        }
        return state
    }

    /// A small copy of the photo with its look, for the Library button.
    nonisolated private static func thumbnail(of photo: CapturedPhoto, look: PreviewRenderer.LookState) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 240,
              ] as CFDictionary) else { return nil }
        let base = CIImage(cgImage: small)
        let crop = photo.aspect.crop(base.extent)
        let rendered = PreviewRenderer.render(look, on: base.cropped(to: crop), seed: photo.id.effectsSeed)
        guard let output = CIContext().createCGImage(rendered, from: crop) else { return nil }
        return UIImage(cgImage: output)
    }
}
