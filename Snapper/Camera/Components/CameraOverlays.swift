import SwiftUI

/// Rule-of-thirds lines.
struct CameraGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let w = geometry.size.width, h = geometry.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3, y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Darkens the parts of the preview outside the chosen aspect ratio.
struct AspectRatioMask: View {
    let aspect: AspectRatio

    var body: some View {
        GeometryReader { geometry in
            let frame = CGRect(origin: .zero, size: geometry.size)
            let crop = aspect.crop(frame)
            Path { path in
                path.addRect(frame)
                path.addRect(crop)
            }
            .fill(.black.opacity(0.8), style: FillStyle(eoFill: true))
            .animation(.snappy(duration: 0.25), value: aspect)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Fades on-screen controls out while Camera Control's overlay is up,
    /// so the preview stays clear, as Apple recommends.
    func hiddenForCameraControl(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .animation(.easeInOut(duration: 0.2), value: hidden)
    }
}
