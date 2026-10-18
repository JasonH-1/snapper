import CoreGraphics
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

/// One brush stroke that corrects the selection: Paint adds to the subject,
/// Erase takes away from it. Strokes are kept as points in the original
/// photo (upright, before any crop, turn or flip), so they stay in place
/// when the framing changes and work at every resolution.
struct MaskStroke: Codable, Hashable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case paint, erase

        var id: String { rawValue }
    }

    var mode: Mode
    /// Brush radius as a fraction of the original photo's shorter side.
    var radius: Double
    /// 0 is a hard edge; 1 fades all the way from the centre.
    var softness: Double
    /// Points along the stroke, 0…1 across the original photo from its top left.
    var points: [CGPoint]

    static let radiusRange = 0.002...0.5
    static let maxPoints = 4000

    var isValid: Bool {
        radius.isFinite && Self.radiusRange.contains(radius) && softness.isFinite && (0...1).contains(softness)
            && !points.isEmpty && points.count <= Self.maxPoints
            && points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (-0.5...1.5).contains($0.x) && (-0.5...1.5).contains($0.y) }
    }
}

/// Per-photo settings. Subject detection is regenerated locally from the original,
/// never included in a shared style or transferred to a different photo.
struct SelectiveEdits: Hashable, Sendable {
    var subject = SelectiveAdjustment()
    var background = SelectiveAdjustment()
    /// Brush corrections to the selection, applied in order.
    var strokes: [MaskStroke] = []
    /// Start from the detected subject; when off, the selection is only what
    /// was painted (for photos without a clear subject).
    var usesSubjectDetection = true
    var isActive: Bool { subject.isActive || background.isActive }

    /// Most strokes one photo keeps.
    static let maxStrokes = 300

    var isValid: Bool { strokes.count <= Self.maxStrokes && strokes.allSatisfy(\.isValid) }
}

extension SelectiveEdits: Codable {
    private enum CodingKeys: String, CodingKey {
        case subject, background, strokes, usesSubjectDetection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subject = try container.decodeIfPresent(SelectiveAdjustment.self, forKey: .subject) ?? SelectiveAdjustment()
        background = try container.decodeIfPresent(SelectiveAdjustment.self, forKey: .background) ?? SelectiveAdjustment()
        // Damaged strokes are dropped rather than costing the whole edit.
        strokes = ((try? container.decodeIfPresent([MaskStroke].self, forKey: .strokes)) ?? [])
            .filter(\.isValid).prefix(Self.maxStrokes).map { $0 }
        usesSubjectDetection = try container.decodeIfPresent(Bool.self, forKey: .usesSubjectDetection) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subject, forKey: .subject)
        try container.encode(background, forKey: .background)
        if !strokes.isEmpty { try container.encode(strokes, forKey: .strokes) }
        if !usesSubjectDetection { try container.encode(usesSubjectDetection, forKey: .usesSubjectDetection) }
    }
}
