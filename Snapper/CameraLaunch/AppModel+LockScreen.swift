import LockedCameraCapture
import OSLog
import SwiftUI

/// Snapper's side of the Lock Screen camera (iOS 18): it hands over the
/// camera settings as the capture intent's app context, and takes in the
/// photos (and setting changes) the Lock Screen camera leaves behind.
extension AppModel {
    /// The user activity the Lock Screen camera opens Snapper with.
    static var lockScreenCameraActivity: String {
        if #available(iOS 18, *) { NSUserActivityTypeLockedCameraCapture } else { "app.snapper.lock-screen-camera" }
    }

    /// The camera as it is now, for the Lock Screen camera to open the same way.
    var lockScreenCamera: SnapperCameraContext {
        var context = SnapperCameraContext()
        context.lookID = camera.currentLook.id
        context.lookOrder = settings.orderedLooks(from: library).map(\.id)
        context.savedPreset = camera.activePreset
        context.cameraPreferences = settings.cameraPreferences
        context.aspectRatio = settings.aspectRatio.rawValue
        context.mirrorFrontCamera = settings.mirrorFrontCamera
        context.selfTimer = settings.selfTimer.rawValue
        context.showGrid = settings.showGrid
        context.photoMegapixels = settings.photoMegapixels
        context.hardwareShutter = settings.volumeButtonShutter
        context.hasPremium = hasPremium
        return context
    }

    /// Shares the camera settings with the Lock Screen camera now, and again
    /// shortly after anything in them changes.
    func shareCameraWithLockScreen() {
        guard #available(iOS 18, *) else { return }
        lockScreenShareTask?.cancel()
        lockScreenShareTask = nil
        let context = withObservationTracking {
            lockScreenCamera
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleLockScreenShare() }
        }
        guard context != sharedLockScreenCamera else { return }
        sharedLockScreenCamera = context
        var stamped = context
        stamped.updatedAt = Date()
        Task {
            do {
                try await SnapperCaptureIntent.updateAppContext(stamped)
            } catch {
                Logger.camera.error("Sharing with the Lock Screen camera failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Slider drags change settings many times a second; share once they settle.
    private func scheduleLockScreenShare() {
        guard lockScreenShareTask == nil else { return }
        lockScreenShareTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            shareCameraWithLockScreen()
        }
    }

    /// Brings in whatever the Lock Screen camera left since Snapper last ran.
    func importLockScreenPhotos() async {
        guard #available(iOS 18, *) else { return }
        let manager = LockedCameraCaptureManager.shared
        await importLockScreenSessions(manager.sessionContentURLs) { folder in
            try await manager.invalidateSessionContent(at: folder)
        }
    }

    /// Adds the Lock Screen camera's photos to the Library (and to Photos,
    /// as with any shot), takes on the camera as the newest session left it,
    /// then hands each session it has finished with to `finished`, which
    /// lets the system delete it. A session with a photo that couldn't be
    /// added is kept for next time; photos already in the Library are skipped.
    func importLockScreenSessions(_ folders: [URL], finished: (URL) async throws -> Void) async {
        guard isLibraryLoaded, !isImportingLockScreenPhotos, !folders.isEmpty else { return }
        isImportingLockScreenPhotos = true
        defer { isImportingLockScreenPhotos = false }

        var added = 0
        var newestCamera: SnapperCameraContext?
        for folder in folders {
            let contents = LockedCaptureInbox.read(folder)
            var isComplete = true
            for photo in contents.photos where captures.record(id: photo.note.id) == nil {
                let look = library.look(id: photo.note.lookID) ?? .original
                do {
                    if await keep(try photo.load(), look: look) { added += 1 } else { isComplete = false }
                } catch {
                    Logger.library.error("Unreadable Lock Screen photo: \(error.localizedDescription, privacy: .public)")
                }
            }
            if let camera = contents.camera, camera.updatedAt > (newestCamera?.updatedAt ?? .distantPast) {
                newestCamera = camera
            }
            guard isComplete else { continue }
            do {
                try await finished(folder)
            } catch {
                Logger.library.error("Couldn't clear a Lock Screen session: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let newestCamera { adoptLockScreenCamera(newestCamera) }
        if added > 0 {
            show(Toast(message: added == 1
                       ? String(localized: "Your photo from the Lock Screen is in your Library.")
                       : String(localized: "Your \(added) photos from the Lock Screen are in your Library."),
                       symbol: "lock.open.fill"))
        }
    }

    /// The person changed the camera on the Lock Screen after last using
    /// Snapper: carry on from there.
    private func adoptLockScreenCamera(_ context: SnapperCameraContext) {
        if let preset = context.savedPreset, library.look(id: preset.lookID) != nil {
            camera.selectPreset(preset)
            // Bundled styles aren't saved presets, so there's nothing to restore by id.
            if !settings.presets.presets.contains(where: { $0.id == preset.id }) { settings.lastPresetID = nil }
            synchronizeCameraPreset()
        } else if let id = context.lookID, let look = library.look(id: id) {
            camera.select(look)
        }
        camera.adopt(context.cameraPreferences)
    }
}

extension AppModel {
    /// The Lock Screen camera's Library button, once unlocked: shows the
    /// Library unless something else is already on screen.
    func openLibraryFromLockScreen() {
        guard !needsOnboarding, libraryScreen == nil, paywall == nil, !isShowingSettings, !isShowingLookPicker,
              !isShowingCameraPresets, !isImportingPreset, incomingBackup == nil else { return }
        openLibrary()
    }
}
