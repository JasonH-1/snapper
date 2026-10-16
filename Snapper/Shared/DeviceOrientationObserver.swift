import CoreMotion
import SwiftUI

/// Tracks how the phone is physically held, so camera controls can rotate to
/// stay upright while the interface itself stays in portrait (like the
/// system Camera). Uses the accelerometer, so it works with rotation lock on.
@MainActor
@Observable
final class DeviceOrientationObserver {
    /// Rotation to apply to icons so they read upright.
    private(set) var iconRotation: Angle = .zero

    @ObservationIgnored private let motion = CMMotionManager()

    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.15
        motion.startAccelerometerUpdates(to: .main) { @Sendable [weak self] data, _ in
            guard let self, let acceleration = data?.acceleration else { return }
            let x = acceleration.x
            let y = acceleration.y
            MainActor.assumeIsolated {
                self.update(x: x, y: y)
            }
        }
    }

    func stop() {
        motion.stopAccelerometerUpdates()
    }

    private func update(x: Double, y: Double) {
        // Require a clear winner between axes so it doesn't flicker at 45°,
        // and ignore the phone lying flat.
        guard max(abs(x), abs(y)) > 0.55 else { return }
        let degrees: Double
        if abs(x) > abs(y) + 0.25 {
            degrees = x < 0 ? 90 : -90
        } else if abs(y) > abs(x) + 0.25 {
            degrees = y < 0 ? 0 : 180
        } else {
            return
        }
        if iconRotation.degrees != degrees {
            iconRotation = .degrees(degrees)
        }
    }
}
