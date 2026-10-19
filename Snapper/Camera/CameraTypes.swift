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

/// The self-timer: off, or a countdown before the shot.
enum SelfTimer: Int, CaseIterable, Sendable {
    case off = 0
    case three = 3
    case ten = 10

    var next: SelfTimer {
        switch self {
        case .off: .three
        case .three: .ten
        case .ten: .off
        }
    }

    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .three: String(localized: "3s")
        case .ten: String(localized: "10s")
        }
    }
}

/// White balance presets. Auto lets the camera decide; the others lock the
/// camera to a colour temperature.
enum WhiteBalancePreset: String, CaseIterable, Sendable {
    case auto, daylight, cloudy, tungsten, fluorescent

    /// Kelvin the camera locks to (nil = auto).
    var temperature: Float? {
        switch self {
        case .auto: nil
        case .daylight: 5500
        case .cloudy: 6500
        case .tungsten: 3200
        case .fluorescent: 4000
        }
    }

    var label: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .daylight: String(localized: "Daylight")
        case .cloudy: String(localized: "Cloudy")
        case .tungsten: String(localized: "Tungsten")
        case .fluorescent: String(localized: "Fluorescent")
        }
    }

    var symbolName: String {
        switch self {
        case .auto: "a.circle"
        case .daylight: "sun.max"
        case .cloudy: "cloud"
        case .tungsten: "lightbulb"
        case .fluorescent: "light.panel"
        }
    }
}

/// Photo shape. 4:3 is the sensor's own; the others crop it.
enum AspectRatio: String, CaseIterable, Codable, Sendable {
    case fourThree = "4:3"
    case square = "1:1"
    case sixteenNine = "16:9"

    /// Long side over short side.
    var longOverShort: CGFloat {
        switch self {
        case .fourThree: 4.0 / 3.0
        case .square: 1
        case .sixteenNine: 16.0 / 9.0
        }
    }

    /// The centred crop of `rect` with this shape, along whichever side is
    /// longer, so it works for portrait and landscape photos alike.
    func crop(_ rect: CGRect) -> CGRect {
        guard self != .fourThree, rect.width > 0, rect.height > 0 else { return rect }
        let long = max(rect.width, rect.height), short = min(rect.width, rect.height)
        var size = rect.size
        if long / short < longOverShort {
            // Too square: trim the short side.
            let newShort = (long / longOverShort).rounded()
            if rect.width < rect.height { size.width = newShort } else { size.height = newShort }
        } else {
            let newLong = (short * longOverShort).rounded()
            if rect.width >= rect.height { size.width = newLong } else { size.height = newLong }
        }
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height).integral
    }
}

/// Everything about a shot decided when the shutter is pressed.
struct CaptureOptions: Sendable, Equatable {
    var timer: SelfTimer = .off
    var aspect: AspectRatio = .fourThree
    /// Save front-camera photos as seen in the preview (mirrored).
    var mirrorFrontCamera = true
}

enum CameraPosition: String, Sendable {
    case back, front

    var toggled: CameraPosition { self == .back ? .front : .back }
    var avPosition: AVCaptureDevice.Position { self == .back ? .back : .front }
}

/// The camera as the person left it, kept between launches: flash,
/// exposure compensation and which camera (front or back).
struct CameraPreferences: Equatable, Sendable {
    var flash: FlashMode = .off
    /// Exposure compensation in stops.
    var exposureBias: Float = 0
    var position: CameraPosition = .back
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
    /// Exposure compensation the device supports, in stops (EV).
    var minExposureBias: Float = -2
    var maxExposureBias: Float = 2
    /// Manual exposure limits (ISO, and shutter speed in seconds).
    var supportsManualExposure = false
    var minISO: Float = 25
    var maxISO: Float = 3200
    var minShutter: Double = 1.0 / 8000
    var maxShutter: Double = 0.5
    var supportsManualFocus = false
    var supportsWhiteBalance = false
    var whiteBalanceRequiresMainCamera = false
    var whiteBalanceUsesMainCamera = false
    /// Photo sizes the camera can take, in megapixels (e.g. 12, 24, 48).
    var photoMegapixels: [Int] = [12]
}

/// Events the capture service reports back to the camera model.
enum CaptureEvent: Sendable {
    case configured(CameraCapabilities)
    case whiteBalanceChanged(WhiteBalancePreset)
    case running(Bool)
    case interrupted(CameraInterruption?)
    case failed(String)
    case captureOrientation(CGFloat)
    case subjectAreaChanged
    /// Camera Control (iOS 18): the look picker moved to this index.
    case cameraControlLook(Int)
    /// Camera Control: the exposure slider moved to this many stops.
    case cameraControlExposure(Float)
    /// Camera Control's overlay took over the screen (true) or left it.
    case cameraControlFullscreen(Bool)
}

/// What Camera Control (iOS 18, iPhone 16 and later) shows: a picker of the
/// looks in swipe order and an exposure slider.
enum CameraControlUpdate: Equatable, Sendable {
    /// The look picker: one title per look, in swipe order, and the selection.
    case looks(titles: [String], selected: Int)
    /// The exposure slider: its range and value, in stops. It is disabled
    /// while ISO and shutter speed are set by hand.
    case exposure(range: ClosedRange<Float>, value: Float, isEnabled: Bool)

    /// Updates of the same kind replace each other while they wait.
    func replaces(_ other: CameraControlUpdate) -> Bool {
        switch (self, other) {
        case (.looks, .looks), (.exposure, .exposure): true
        default: false
        }
    }
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
