import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Draws tone curves and split toning with built-in Core Image filters, so
/// the live camera, the editor and exports agree.
///
/// Both work on gamma-encoded sRGB values, the numbers a curve's grid shows
/// and the way Lightroom and Photoshop apply them: the curve's middle is a
/// visual mid-grey, not linear 0.5.
enum ToneRendering {
    /// Entries per channel in a curve's lookup table.
    static let curveTableSize = 512
    /// Points per side of the split-toning colour cube.
    static let cubeDimension = 33

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: - Curves

    static func applyCurves(_ curves: ToneCurves, to image: CIImage) -> CIImage {
        guard curves.isActive, curves.isValid else { return image }
        let filter = CIFilter.colorCurves()
        filter.inputImage = image
        filter.curvesData = TableCache.shared.curveData(for: curves)
        filter.curvesDomain = CIVector(x: 0, y: 1)
        filter.colorSpace = sRGB
        return filter.outputImage ?? image
    }

    /// The curves as Core Image wants them: RGB float triplets, one per step
    /// from input 0 to 1.
    static func curveData(for curves: ToneCurves, count: Int = curveTableSize) -> Data {
        let tables = curves.tables(count: count)
        var values = [Float]()
        values.reserveCapacity(count * 3)
        for index in 0..<count {
            values += [Float(tables.red[index]), Float(tables.green[index]), Float(tables.blue[index])]
        }
        return values.withUnsafeBytes { Data($0) }
    }

    // MARK: - Split toning

    static func applySplitToning(_ toning: SplitToning, to image: CIImage) -> CIImage {
        guard toning.isActive, toning.isValid else { return image }
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = image
        cube.cubeDimension = Float(cubeDimension)
        cube.cubeData = TableCache.shared.cubeData(for: toning.renderKey)
        cube.colorSpace = sRGB
        return cube.outputImage ?? image
    }

    /// One gamma-encoded sRGB colour (0…1 per channel) split-toned: the tint
    /// is added to its Oklab colour, weighted by how bright it is, and its
    /// lightness is left alone.
    static func splitTone(red: Double, green: Double, blue: Double, with toning: SplitToning) -> (Double, Double, Double) {
        guard toning.isActive else { return (red, green, blue) }
        var lab = Oklab(linearRed: linear(red), green: linear(green), blue: linear(blue))
        let weights = toneWeights(lightness: lab.L, balance: toning.balance)
        let highlight = tintDirection(hue: toning.highlightHue)
        let shadow = tintDirection(hue: toning.shadowHue)
        let highlightAmount = maxTintChroma * toning.highlightSaturation * weights.highlights
        let shadowAmount = maxTintChroma * toning.shadowSaturation * weights.shadows
        lab.a += highlight.a * highlightAmount + shadow.a * shadowAmount
        lab.b += highlight.b * highlightAmount + shadow.b * shadowAmount
        let rgb = lab.linearRGB
        return (encoded(rgb.0), encoded(rgb.1), encoded(rgb.2))
    }

    /// Oklab chroma added at full saturation: a clear tint that stays short
    /// of neon.
    static let maxTintChroma = 0.11

    /// How much of each tint a colour of Oklab `lightness` gets. They cross
    /// at mid-grey (moved by `balance`), so mid-tones get a little of both,
    /// and the very ends stay close to neutral.
    static func toneWeights(lightness: Double, balance: Double) -> (highlights: Double, shadows: Double) {
        let t = min(max(lightness + 0.3 * balance, 0), 1)
        let ends = smoothstep(0, 0.05, lightness) * (1 - 0.5 * smoothstep(0.96, 1, lightness))
        let highlights = smoothstep(0.2, 0.95, t) * ends
        let shadows = (1 - smoothstep(0.05, 0.8, t)) * ends
        return (highlights, shadows)
    }

    /// The Oklab a/b direction of a hue on the usual (HSB) colour wheel, so
    /// the tint matches the colour the hue slider shows.
    static func tintDirection(hue: Double) -> (a: Double, b: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let rgb: (Double, Double, Double)
        switch h {
        case ..<1: rgb = (1, x, 0)
        case ..<2: rgb = (x, 1, 0)
        case ..<3: rgb = (0, 1, x)
        case ..<4: rgb = (0, x, 1)
        case ..<5: rgb = (x, 0, 1)
        default: rgb = (1, 0, x)
        }
        let lab = Oklab(linearRed: linear(rgb.0), green: linear(rgb.1), blue: linear(rgb.2))
        let length = max((lab.a * lab.a + lab.b * lab.b).squareRoot(), 1e-6)
        return (lab.a / length, lab.b / length)
    }

    // MARK: - Colour maths

    private static func smoothstep(_ low: Double, _ high: Double, _ x: Double) -> Double {
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func linear(_ value: Double) -> Double {
        let v = min(max(value, 0), 1)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ value: Double) -> Double {
        let v = min(max(value, 0), 1)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    struct Oklab {
        var L: Double
        var a: Double
        var b: Double

        init(linearRed r: Double, green g: Double, blue b: Double) {
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
            a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
            self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        }

        var linearRGB: (Double, Double, Double) {
            let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
            return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        }
    }

    // MARK: - Cache

    /// Lookup tables by setting, shared by the live preview and export
    /// queues, so a camera frame never rebuilds one. All state is behind the lock.
    private final class TableCache: @unchecked Sendable {
        static let shared = TableCache()
        private let lock = NSLock()
        private var curves: [ToneCurves: Data] = [:]
        private var curveOrder: [ToneCurves] = []
        private var cubes: [SplitToning: Data] = [:]
        private var cubeOrder: [SplitToning] = []
        private static let limit = 6

        func curveData(for key: ToneCurves) -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let data = curves[key] { return data }
            let data = ToneRendering.curveData(for: key)
            curves[key] = data
            curveOrder.append(key)
            if curveOrder.count > Self.limit { curves[curveOrder.removeFirst()] = nil }
            return data
        }

        func cubeData(for key: SplitToning) -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let data = cubes[key] { return data }
            let size = ToneRendering.cubeDimension
            var values = [Float]()
            values.reserveCapacity(size * size * size * 4)
            let scale = Double(size - 1)
            for b in 0..<size {
                for g in 0..<size {
                    for r in 0..<size {
                        let out = ToneRendering.splitTone(red: Double(r) / scale, green: Double(g) / scale,
                                                          blue: Double(b) / scale, with: key)
                        values += [Float(out.0), Float(out.1), Float(out.2), 1]
                    }
                }
            }
            let data = values.withUnsafeBytes { Data($0) }
            cubes[key] = data
            cubeOrder.append(key)
            if cubeOrder.count > Self.limit { cubes[cubeOrder.removeFirst()] = nil }
            return data
        }
    }
}
