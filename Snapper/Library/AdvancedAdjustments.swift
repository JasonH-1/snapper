import Foundation

struct ColorMix: Codable, Hashable, Sendable {
    var hue = 0.0
    var saturation = 0.0
    var luminance = 0.0
    var isValid: Bool { [hue, saturation, luminance].allSatisfy { $0.isFinite && (-1...1).contains($0) } }
    var isActive: Bool { self != ColorMix() }
}

enum ColorBand: String, Codable, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var center: Double {
        switch self { case .red: 0; case .orange: 30; case .yellow: 60; case .green: 120; case .aqua: 180; case .blue: 240; case .purple: 290 }
    }
}

struct ColorMixer: Codable, Hashable, Sendable {
    private var bands: [String: ColorMix] = [:]
    subscript(_ band: ColorBand) -> ColorMix {
        get { bands[band.rawValue] ?? ColorMix() }
        set { bands[band.rawValue] = newValue.isActive ? newValue : nil }
    }
    var isActive: Bool { bands.values.contains(where: \.isActive) }
    var isValid: Bool { bands.allSatisfy { ColorBand(rawValue: $0.key) != nil && $0.value.isValid } }
}

struct SelectiveAdjustment: Codable, Hashable, Sendable {
    var brightness = 0.0
    var saturation = 0.0
    var warmth = 0.0
    var isActive: Bool { self != Self() }
    var adjustments: PhotoAdjustments {
        PhotoAdjustments(brightness: brightness, saturation: saturation, warmth: warmth)
    }
}

/// Per-photo settings. Subject detection is regenerated locally from the original,
/// never included in a shared style or transferred to a different photo.
struct SelectiveEdits: Codable, Hashable, Sendable {
    var subject = SelectiveAdjustment()
    var background = SelectiveAdjustment()
    var isActive: Bool { subject.isActive || background.isActive }
}
