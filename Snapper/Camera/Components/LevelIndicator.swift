import CoreMotion
import SwiftUI

/// Reads which way is down, for the camera's level.
@MainActor
@Observable
final class LevelObserver {
    /// The horizon's angle on screen, in degrees (0 = level in portrait,
    /// ±90 = level when held sideways). Positive turns clockwise.
    private(set) var horizon: Double = 0
    /// False when there's no motion data (Simulator) or the phone points
    /// straight up or down, where a horizon means nothing.
    private(set) var isUsable = false

    @ObservationIgnored private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { @Sendable [weak self] data, _ in
            guard let self, let gravity = data?.gravity else { return }
            let x = gravity.x, y = gravity.y, z = gravity.z
            MainActor.assumeIsolated {
                self.update(x: x, y: y, z: z)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        isUsable = false
    }

    private func update(x: Double, y: Double, z: Double) {
        isUsable = abs(z) < 0.85
        // Gravity on screen is (x, -y); the horizon is perpendicular to it.
        horizon = atan2(-x, -y) * 180 / .pi
    }
}

/// A horizon line: white while tilted, yellow and snapped when level,
/// between fixed marks for whichever way the phone is held.
struct LevelIndicator: View {
    let observer: LevelObserver

    /// Within this many degrees counts as level.
    static let tolerance: Double = 1

    var body: some View {
        let target = Self.nearestRightAngle(observer.horizon)
        let isLevel = abs(observer.horizon - target) < Self.tolerance
        ZStack {
            // Fixed marks showing where level is.
            HStack(spacing: 120) {
                Capsule().frame(width: 22, height: 2)
                Capsule().frame(width: 22, height: 2)
            }
            .foregroundStyle(.white.opacity(isLevel ? 0 : 0.7))
            .rotationEffect(.degrees(target))

            Capsule()
                .fill(isLevel ? Theme.accent : .white)
                .frame(width: isLevel ? 164 : 110, height: 2)
                .rotationEffect(.degrees(isLevel ? target : observer.horizon))
        }
        .shadow(color: .black.opacity(0.35), radius: 2)
        .opacity(observer.isUsable ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isLevel)
        .sensoryFeedback(.selection, trigger: isLevel) { _, level in level }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    nonisolated static func nearestRightAngle(_ degrees: Double) -> Double {
        (degrees / 90).rounded() * 90
    }
}
