import SwiftUI

/// Lens presets (0.5×, 1×, 2×…) with the active one showing the live value.
struct ZoomControl: View {
    let presets: [CGFloat]
    let zoom: CGFloat
    let select: (CGFloat) -> Void

    private var activePreset: CGFloat? {
        presets.last(where: { zoom >= $0 - 0.05 })
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(presets, id: \.self) { preset in
                let isActive = preset == activePreset
                Button {
                    select(preset)
                } label: {
                    Text(label(for: preset, isActive: isActive))
                        .font(.system(size: isActive ? 13 : 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isActive ? Theme.accent : .white)
                        .frame(width: isActive ? 38 : 30, height: isActive ? 38 : 30)
                        .glassSurface(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Zoom \(Self.format(preset)) times"))
            }
        }
        .padding(4)
        .glassSurface(in: Capsule())
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: activePreset)
    }

    private func label(for preset: CGFloat, isActive: Bool) -> String {
        if isActive {
            return Self.format(zoom) + "×"
        }
        return Self.format(preset)
    }

    static func format(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded < 1 {
            return String(format: "%.1f", rounded).replacingOccurrences(of: "0.", with: ".")
        }
        if rounded == rounded.rounded() {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}
