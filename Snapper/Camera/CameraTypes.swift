import AVFoundation
import CoreGraphics

enum FlashMode: String, CaseIterable, Sendable {
    case off, auto, on

    var next: FlashMode {
        switch self {
        case .off: .auto
        case .auto: .on
        case .on: .off
        }
    }

    var avMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: .off
        case .auto: .auto
        case .on: .on
        }
    }

    var symbolName: String {
        switch self {
        case .off: "bolt.slash.fill"
        case .auto: "bolt.badge.automatic.fill"
        case .on: "bolt.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .off: String(localized: "Flash off")
        case .auto: String(localized: "Flash automatic")
        case .on: String(localized: "Flash on")
        }
    }
}

enum CameraPosition: Sendable {
    case back, front

    var toggled: CameraPosition { self == .back ? .front : .back }
    var avPosition: AVCaptureDevice.Position { self == .back ? .back : .front }
}

/// Why the live camera is not showing frames right now.
enum CameraInterruption: Sendable, Equatable {
    case inUseByAnotherApp
    case systemPressure
    case background
    case other

    var message: String {
        switch self {
        case .inUseByAnotherApp: String(localized: "The camera is in use by another app.")
        case .systemPressure: String(localized: "The camera paused because the iPhone is too warm.")
        case .background: String(localized: "Camera paused.")
        case .other: String(localized: "The camera is temporarily unavailable.")
        }
    }
}

/// What the capture service can tell the UI about the current device.
struct CameraCapabilities: Sendable, Equatable {
    var position: CameraPosition = .back
    var hasFlash = false
    var canSwitchCamera = false
    /// Zoom presets in the units shown to people (0.5×, 1×, 2×, …).
    var zoomPresets: [CGFloat] = [1]
    var minZoom: CGFloat = 1
    var maxZoom: CGFloat = 1
    var zoom: CGFloat = 1
}

/// Events the capture service reports back to the camera model.
enum CaptureEvent: Sendable {
    case configured(CameraCapabilities)
    case running(Bool)
    case interrupted(CameraInterruption?)
    case failed(String)
    case captureOrientation(CGFloat)
    case subjectAreaChanged
}

enum CameraError: LocalizedError, Sendable {
    case noCamera
    case configurationFailed
    case captureFailed(String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .noCamera: String(localized: "No camera is available on this device.")
        case .configurationFailed: String(localized: "The camera could not be started.")
        case .captureFailed(let reason): String(localized: "The photo could not be taken. \(reason)")
        case .notRunning: String(localized: "The camera is not running.")
        }
    }
}
