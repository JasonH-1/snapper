import Foundation

/// One control point on a tone curve: input `x` maps to output `y`, both 0…1.
struct CurvePoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A tone curve through control points, like the point curve in Lightroom or
/// Photoshop. The ends stay at input 0 and 1 (their output can move, to lift
/// the blacks or dim the whites); points in between can be added, moved and
/// removed.
///
/// The curve between points is a monotone cubic (Fritsch–Carlson), so it never
/// overshoots: a curve that only rises never dips, and nothing clips between
/// two points that don't.
struct ToneCurve: Hashable, Sendable {
    /// Sorted by input, at least two, the first at x = 0 and the last at x = 1.
    private(set) var points: [CurvePoint]

    static let identity = ToneCurve()
    /// Most points a curve can hold, ends included.
    static let maxPoints = 12
    /// Closest two points can be along the input axis.
    static let minimumSpacing = 0.03

    init() {
        points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    }

    /// A curve through `points`, tidied: clamped to 0…1, sorted, ends added if
    /// missing and points too close together merged.
    init(points: [CurvePoint]) {
        self.points = Self.tidied(points)
    }

    /// Every point on the diagonal: the curve changes nothing.
    var isIdentity: Bool {
        points.allSatisfy { abs($0.x - $0.y) < 0.0005 }
    }

    var isValid: Bool {
        guard (2...Self.maxPoints).contains(points.count),
              points.first?.x == 0, points.last?.x == 1 else { return false }
        for (index, point) in points.enumerated() {
            guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return false }
            if index > 0, point.x - points[index - 1].x < Self.minimumSpacing - 0.0001 { return false }
        }
        return true
    }

    // MARK: - Editing

    /// Adds a point on the curve at input `x` (keeping its current output, so
    /// nothing changes until it is moved). Returns its index, or nil when it
    /// is too close to another point or the curve is full.
    @discardableResult
    mutating func addPoint(atInput x: Double) -> Int? {
        guard x.isFinite, points.count < Self.maxPoints else { return nil }
        let x = min(max(x, 0), 1)
        guard !points.contains(where: { abs($0.x - x) < Self.minimumSpacing }) else { return nil }
        let point = CurvePoint(x: x, y: min(max(value(at: x), 0), 1))
        let index = points.firstIndex { $0.x > x } ?? points.endIndex
        points.insert(point, at: index)
        return index
    }

    /// Moves a point, keeping it between its neighbours; the ends only move up
    /// and down.
    mutating func movePoint(at index: Int, to target: CurvePoint) {
        guard points.indices.contains(index), target.x.isFinite, target.y.isFinite else { return }
        var point = CurvePoint(x: target.x, y: min(max(target.y, 0), 1))
        if index == 0 {
            point.x = 0
        } else if index == points.count - 1 {
            point.x = 1
        } else {
            let low = points[index - 1].x + Self.minimumSpacing
            let high = points[index + 1].x - Self.minimumSpacing
            point.x = min(max(point.x, low), max(low, high))
        }
        points[index] = point
    }

    /// Removes a point between the ends (the ends always stay).
    mutating func removePoint(at index: Int) {
        guard index > 0, index < points.count - 1 else { return }
        points.remove(at: index)
    }

    // MARK: - Evaluating

    /// The curve's output for input `x` (0…1), clamped to 0…1.
    func value(at x: Double) -> Double {
        let count = points.count
        guard count >= 2, x.isFinite else { return x }
        if x <= points[0].x { return points[0].y }
        if x >= points[count - 1].x { return points[count - 1].y }
        let tangents = Self.tangents(for: points)
        var upper = 1
        while upper < count - 1, points[upper].x < x { upper += 1 }
        let lower = upper - 1
        let p0 = points[lower], p1 = points[upper]
        let h = p1.x - p0.x
        guard h > 0 else { return p0.y }
        let t = (x - p0.x) / h
        let t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * p0.y
            + (t3 - 2 * t2 + t) * h * tangents[lower]
            + (-2 * t3 + 3 * t2) * p1.y
            + (t3 - t2) * h * tangents[upper]
        return min(max(y, 0), 1)
    }

    /// `count` evenly spaced outputs from input 0 to 1.
    func table(count: Int) -> [Double] {
        guard count > 1 else { return [value(at: 0)] }
        let tangents = Self.tangents(for: points)
        var result: [Double] = []
        result.reserveCapacity(count)
        var segment = 0
        for index in 0..<count {
            let x = Double(index) / Double(count - 1)
            while segment < points.count - 2, points[segment + 1].x < x { segment += 1 }
            let p0 = points[segment], p1 = points[segment + 1]
            let h = p1.x - p0.x
            guard h > 0 else {
                result.append(p0.y)
                continue
            }
            let t = min(max((x - p0.x) / h, 0), 1)
            let t2 = t * t, t3 = t2 * t
            let y = (2 * t3 - 3 * t2 + 1) * p0.y
                + (t3 - 2 * t2 + t) * h * tangents[segment]
                + (-2 * t3 + 3 * t2) * p1.y
                + (t3 - t2) * h * tangents[segment + 1]
            result.append(min(max(y, 0), 1))
        }
        return result
    }

    /// Fritsch–Carlson tangents: secant averages, flattened at local peaks and
    /// limited so each segment stays monotone.
    private static func tangents(for points: [CurvePoint]) -> [Double] {
        let count = points.count
        guard count >= 2 else { return Array(repeating: 1, count: count) }
        var secants = [Double](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let dx = points[index + 1].x - points[index].x
            secants[index] = dx > 0 ? (points[index + 1].y - points[index].y) / dx : 0
        }
        var tangents = [Double](repeating: 0, count: count)
        tangents[0] = secants[0]
        tangents[count - 1] = secants[count - 2]
        if count > 2 {
            for index in 1..<(count - 1) {
                let before = secants[index - 1], after = secants[index]
                tangents[index] = before * after <= 0 ? 0 : (before + after) / 2
            }
        }
        for index in 0..<(count - 1) {
            let secant = secants[index]
            if abs(secant) < 1e-9 {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let a = tangents[index] / secant, b = tangents[index + 1] / secant
            let length = a * a + b * b
            if length > 9 {
                let scale = 3 / length.squareRoot()
                tangents[index] = scale * a * secant
                tangents[index + 1] = scale * b * secant
            }
        }
        return tangents
    }

    private static func tidied(_ input: [CurvePoint]) -> [CurvePoint] {
        var sorted = input
            .filter { $0.x.isFinite && $0.y.isFinite }
            .map { CurvePoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }
            .sorted { $0.x < $1.x }
        // A point right by an end becomes that end; otherwise the end is added.
        if let first = sorted.first, first.x < minimumSpacing {
            sorted[0].x = 0
        } else {
            sorted.insert(CurvePoint(x: 0, y: 0), at: 0)
        }
        if sorted.count > 1, let last = sorted.last, last.x > 1 - minimumSpacing {
            sorted[sorted.count - 1].x = 1
        } else {
            sorted.append(CurvePoint(x: 1, y: 1))
        }
        var result = [sorted[0]]
        for point in sorted.dropFirst().dropLast()
        where point.x - result[result.count - 1].x >= minimumSpacing && 1 - point.x >= minimumSpacing {
            result.append(point)
        }
        result.append(sorted[sorted.count - 1])
        if result.count > maxPoints {
            result = Array(result.prefix(maxPoints - 1)) + [result[result.count - 1]]
        }
        return result
    }
}

extension ToneCurve: Codable {
    private enum CodingKeys: String, CodingKey {
        case points
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decodeIfPresent([CurvePoint].self, forKey: .points) ?? []
        // Kept exactly as stored so validation can reject a damaged file
        // instead of quietly repairing it.
        points = decoded.isEmpty ? ToneCurve.identity.points : decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }
}

/// The RGB curve plus one for each channel. Each channel's own curve is
/// applied first, then the RGB curve, as in Photoshop and Lightroom.
struct ToneCurves: Hashable, Sendable {
    enum Channel: String, CaseIterable, Identifiable, Sendable {
        case rgb, red, green, blue

        var id: String { rawValue }
    }

    var rgb = ToneCurve.identity
    var red = ToneCurve.identity
    var green = ToneCurve.identity
    var blue = ToneCurve.identity

    static let none = ToneCurves()

    subscript(channel: Channel) -> ToneCurve {
        get {
            switch channel {
            case .rgb: rgb
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    var isActive: Bool { Channel.allCases.contains { !self[$0].isIdentity } }
    var isValid: Bool { Channel.allCases.allSatisfy { self[$0].isValid } }

    /// The combined lookup tables, `count` entries per channel, each channel's
    /// curve followed by the RGB curve.
    func tables(count: Int) -> (red: [Double], green: [Double], blue: [Double]) {
        let master = rgb.isIdentity ? nil : rgb
        func combined(_ curve: ToneCurve) -> [Double] {
            let own = curve.table(count: count)
            guard let master else { return own }
            return own.map { master.value(at: $0) }
        }
        return (combined(red), combined(green), combined(blue))
    }
}

extension ToneCurves: Codable {
    private enum CodingKeys: String, CodingKey {
        case rgb, red, green, blue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rgb = try container.decodeIfPresent(ToneCurve.self, forKey: .rgb) ?? .identity
        red = try container.decodeIfPresent(ToneCurve.self, forKey: .red) ?? .identity
        green = try container.decodeIfPresent(ToneCurve.self, forKey: .green) ?? .identity
        blue = try container.decodeIfPresent(ToneCurve.self, forKey: .blue) ?? .identity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !rgb.isIdentity { try container.encode(rgb, forKey: .rgb) }
        if !red.isIdentity { try container.encode(red, forKey: .red) }
        if !green.isIdentity { try container.encode(green, forKey: .green) }
        if !blue.isIdentity { try container.encode(blue, forKey: .blue) }
    }
}

/// Split toning: one colour into the highlights and another into the
/// shadows, like Lightroom's Split Toning (now part of Color Grading).
/// Brightness is kept; only the colour of each tone range moves.
struct SplitToning: Hashable, Sendable {
    /// Hue of the highlight tint, in degrees on the usual colour wheel
    /// (0 red, 60 yellow, 120 green, 240 blue).
    var highlightHue = 42.0
    /// How strong the highlight tint is, 0…1.
    var highlightSaturation = 0.0
    var shadowHue = 215.0
    var shadowSaturation = 0.0
    /// -1…1: positive gives the highlight tint more of the tonal range,
    /// negative the shadow tint.
    var balance = 0.0

    static let none = SplitToning()

    var isActive: Bool { highlightSaturation > 0.0005 || shadowSaturation > 0.0005 }

    var isValid: Bool {
        [highlightHue, highlightSaturation, shadowHue, shadowSaturation, balance].allSatisfy(\.isFinite)
            && (0...360).contains(highlightHue) && (0...360).contains(shadowHue)
            && (0...1).contains(highlightSaturation) && (0...1).contains(shadowSaturation)
            && (-1...1).contains(balance)
    }

    /// The settings that change pixels (hues don't while their tint is off),
    /// so caches aren't rebuilt for a hue nobody can see.
    var renderKey: SplitToning {
        var key = self
        if highlightSaturation <= 0.0005 { key.highlightHue = 0; key.highlightSaturation = 0 }
        if shadowSaturation <= 0.0005 { key.shadowHue = 0; key.shadowSaturation = 0 }
        if !isActive { key.balance = 0 }
        return key
    }
}

extension SplitToning: Codable {
    private enum CodingKeys: String, CodingKey {
        case highlightHue, highlightSaturation, shadowHue, shadowSaturation, balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        highlightHue = try container.decodeIfPresent(Double.self, forKey: .highlightHue) ?? 42
        highlightSaturation = try container.decodeIfPresent(Double.self, forKey: .highlightSaturation) ?? 0
        shadowHue = try container.decodeIfPresent(Double.self, forKey: .shadowHue) ?? 215
        shadowSaturation = try container.decodeIfPresent(Double.self, forKey: .shadowSaturation) ?? 0
        balance = try container.decodeIfPresent(Double.self, forKey: .balance) ?? 0
    }
}
