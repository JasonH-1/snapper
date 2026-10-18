import AVFoundation

/// Selects an API the active device can safely use. Locked mode alone does
/// not imply support for explicit gains, notably on virtual multi-lens cameras.
enum WhiteBalanceControl {
    enum Route: Equatable {
        case automatic, deviceGains, unsupported
    }

    static func route(preset: WhiteBalancePreset, supportsLocked: Bool,
                      supportsCustomGains: Bool) -> Route {
        guard preset != .auto else { return .automatic }
        guard supportsLocked else { return .unsupported }
        return supportsCustomGains ? .deviceGains : .unsupported
    }

    enum CameraAction: Equatable {
        case keepCurrent, useMain, restoreAutomatic, unsupported
    }

    static func cameraAction(preset: WhiteBalancePreset, isRear: Bool,
                             currentSupportsManual: Bool, mainSupportsManual: Bool,
                             hasReturnCamera: Bool) -> CameraAction {
        if preset == .auto { return hasReturnCamera ? .restoreAutomatic : .keepCurrent }
        if currentSupportsManual { return .keepCurrent }
        return isRear && mainSupportsManual ? .useMain : .unsupported
    }

    /// Conversion can return out-of-range gains. Never pass NaN or infinity
    /// to AVFoundation: its Objective-C exceptions bypass Swift do/catch.
    static func validatedGains(_ gains: AVCaptureDevice.WhiteBalanceGains,
                               maximum: Float) -> AVCaptureDevice.WhiteBalanceGains? {
        guard maximum.isFinite, maximum >= 1,
              gains.redGain.isFinite, gains.greenGain.isFinite, gains.blueGain.isFinite else { return nil }
        func clamp(_ gain: Float) -> Float { min(max(gain, 1), maximum) }
        return AVCaptureDevice.WhiteBalanceGains(redGain: clamp(gains.redGain), greenGain: clamp(gains.greenGain),
                                                 blueGain: clamp(gains.blueGain))
    }
}
