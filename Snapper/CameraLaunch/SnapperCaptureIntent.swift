import AppIntents
import Foundation

// Built into the app, the Lock Screen camera (SnapperCapture) and the Control
// Center control (SnapperControls): the system needs the same intent in all
// three to offer Snapper for Camera Control, the Lock Screen and Control Center.

/// Opens Snapper's camera. While the iPhone is locked the system runs the
/// Lock Screen camera instead of the app.
@available(iOS 18, *)
struct SnapperCaptureIntent: CameraCaptureIntent {
    typealias AppContext = SnapperCameraContext

    static let title: LocalizedStringResource = "Open Snapper Camera"
    static let description = IntentDescription("Take photos through your film looks.")

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// The camera as the person left it in Snapper, so the Lock Screen camera
/// opens the same way: the app keeps it current as the intent's app context.
/// The Lock Screen camera writes its own changes back next to its photos
/// (see `LockedCaptureInbox`).
///
/// Plain values only, so the Control Center extension needs none of the
/// camera code to declare the intent.
struct SnapperCameraContext: Codable, Sendable, Equatable {
    var lookID: String?
    /// Every look's id in swipe order (favourites first).
    var lookOrder: [String] = []
    /// The saved preset being shot with, as `SavedPreset` JSON.
    var preset: Data?
    /// `FlashMode` raw value.
    var flash = "off"
    /// Exposure compensation in stops.
    var exposureBias: Float = 0
    /// `CameraPosition` raw value.
    var position = "back"
    /// `AspectRatio` raw value.
    var aspectRatio = "4:3"
    var mirrorFrontCamera = true
    /// Self-timer seconds (0 = off).
    var selfTimer = 0
    var showGrid = false
    var photoMegapixels = 24
    /// The volume buttons and Camera Control take the photo.
    var hardwareShutter = true
    var hasPremium = false
    /// When this was last changed.
    var updatedAt = Date.distantPast
}
