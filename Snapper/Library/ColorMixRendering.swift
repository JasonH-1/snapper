import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Smooth, overlapping hue bands. Neutral colors remain neutral.
enum ColorMixRendering {
    static func apply(_ mixer: ColorMixer, to image: CIImage) -> CIImage {
        guard mixer.isActive, mixer.isValid else { return image }
        let cube = CIFilter.colorCube()
        cube.inputImage = image
        cube.cubeDimension = Float(Cache.dimension)
        cube.cubeData = Cache.shared.data(for: mixer)
        return cube.outputImage ?? image
    }

    static func transform(red r: Double, green g: Double, blue b: Double, mixer: ColorMixer) -> (Double, Double, Double) {
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        guard delta > 0.00001 else { return (r, g, b) }
        let light = (high + low) / 2
        let saturation = delta / max(0.00001, 1 - abs(2 * light - 1))
        var hue: Double
        if high == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == g { hue = (b - r) / delta + 2 }
        else { hue = (r - g) / delta + 4 }
        hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
        var h = 0.0, s = 0.0, l = 0.0, total = 0.0
        for band in ColorBand.allCases {
            let distance = abs(hue - band.center)
            let width = (band == .orange || band == .yellow || band == .red) ? 40.0 : 65.0
            let weight = max(0, 1 - min(distance, 360 - distance) / width)
            let smooth = weight * weight * (3 - 2 * weight)
            let change = mixer[band]
            h += change.hue * smooth
            s += change.saturation * smooth
            l += change.luminance * smooth
            total += smooth
        }
        let divisor = max(1, total)
        let newHue = (hue + 30 * h / divisor + 360).truncatingRemainder(dividingBy: 360) / 60
        let newSat = min(max(saturation * (1 + s / divisor), 0), 1)
        let newLight = min(max(light + l / divisor * 0.18 * min(1, saturation * 3), 0), 1)
        let chroma = (1 - abs(2 * newLight - 1)) * newSat
        let x = chroma * (1 - abs(newHue.truncatingRemainder(dividingBy: 2) - 1))
        let m = newLight - chroma / 2
        let rgb: (Double, Double, Double)
        switch newHue {
        case ..<1: rgb = (chroma, x, 0)
        case ..<2: rgb = (x, chroma, 0)
        case ..<3: rgb = (0, chroma, x)
        case ..<4: rgb = (0, x, chroma)
        case ..<5: rgb = (x, 0, chroma)
        default: rgb = (chroma, 0, x)
        }
        return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
    }

    /// All mutable cache state is protected by the lock. Shared by live-preview
    /// and export queues; bounded to six half-megabyte-or-smaller cubes.
    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        static let dimension = 24
        private let lock = NSLock()
        private var values: [ColorMixer: Data] = [:]
        private var order: [ColorMixer] = []
        func data(for mixer: ColorMixer) -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let value = values[mixer] { return value }
            var values = [Float]()
            values.reserveCapacity(Self.dimension * Self.dimension * Self.dimension * 4)
            let scale = Double(Self.dimension - 1)
            for b in 0..<Self.dimension {
                for g in 0..<Self.dimension {
                    for r in 0..<Self.dimension {
                        let result = ColorMixRendering.transform(red: Double(r) / scale, green: Double(g) / scale,
                                                               blue: Double(b) / scale, mixer: mixer)
                        values += [Float(result.0), Float(result.1), Float(result.2), 1]
                    }
                }
            }
            let data = values.withUnsafeBytes { Data($0) }
            self.values[mixer] = data
            order.append(mixer)
            if order.count > 6 { self.values[order.removeFirst()] = nil }
            return data
        }
    }
}
