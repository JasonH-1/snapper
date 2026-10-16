import Foundation

/// Texture-and-light effects a look adds after its colour LUT: glow, colour
/// fringing, scanlines and so on, which a LUT cannot express.
///
/// Read from `filters.json`, where tools/lutgen writes every parameter (see
/// tools/lutgen/effects.py). Lengths are fractions of the image's shorter
/// side, so the preview and a full-resolution export look the same.
struct LookEffects: Codable, Hashable, Sendable {
    /// A graduated filter from the top edge, like Lightroom's linear
    /// gradient: brightens and tints the top of the frame (usually sky).
    struct Gradient: Codable, Hashable, Sendable {
        /// Fraction of the height it covers before fading out.
        var size: Double
        /// Brightening at the top edge, in stops.
        var exposure: Double
        /// Oklab hue (degrees) of the tint, as for the look's other tints.
        var tintHue: Double
        /// How far (0…1) the top edge is pulled towards the tint colour.
        var tint: Double

        enum CodingKeys: String, CodingKey {
            case size, exposure, tint
            case tintHue = "tint_hue"
        }
    }

    /// Bright, saturated light blooms in its own colour.
    struct Glow: Codable, Hashable, Sendable {
        /// Brightness (0…1) where the glow starts.
        var threshold: Double
        var radius: Double
        var intensity: Double
        /// Saturation of the glow relative to the light it comes from.
        var saturation: Double
        /// Oklab hue (degrees) the glow is pulled towards, by `tint` (0…1).
        var tintHue: Double
        var tint: Double

        enum CodingKeys: String, CodingKey {
            case threshold, radius, intensity, saturation, tint
            case tintHue = "tint_hue"
        }
    }

    /// Film halation: a red-orange halo around bright light, from light
    /// bouncing off the film base back through the red-sensitive layer.
    struct Halation: Codable, Hashable, Sendable {
        /// Brightness (0…1) where the halo starts.
        var threshold: Double
        var radius: Double
        var intensity: Double
    }

    /// Warm light bleeding in from one edge, placed per photo by the seed.
    struct LightLeak: Codable, Hashable, Sendable {
        var intensity: Double
        /// How far it reaches in, as a fraction of the image width.
        var size: Double
        /// Oklab hue (degrees) of the leak.
        var tintHue: Double

        enum CodingKeys: String, CodingKey {
            case intensity, size
            case tintHue = "tint_hue"
        }
    }

    /// Film grain: clumpy, strongest in the mid-tones and shadows.
    struct Grain: Codable, Hashable, Sendable {
        var amount: Double
        /// One fine grain cell.
        var size: Double
        /// 0 = fine and even, 1 = coarse and clumpy.
        var roughness: Double
        /// 0 = grey grain, 1 = fully coloured.
        var color: Double
    }

    /// Lens fringing: red and blue drift apart towards the edges.
    struct ChromaticAberration: Codable, Hashable, Sendable {
        /// Scale difference between the red and blue channels at full strength.
        var amount: Double
    }

    /// Videotape colour smear: colour bleeds sideways, brightness stays sharp.
    struct ChromaBleed: Codable, Hashable, Sendable {
        var radius: Double
    }

    /// A red/blue split plus horizontal slices pushed sideways.
    struct Glitch: Codable, Hashable, Sendable {
        var slices: Int
        /// Largest slice offset, as a fraction of the image width.
        var shift: Double
        var rgbSplit: Double

        enum CodingKeys: String, CodingKey {
            case slices, shift
            case rgbSplit = "rgb_split"
        }
    }

    /// Dark horizontal lines, like a CRT or a paused tape.
    struct Scanlines: Codable, Hashable, Sendable {
        var spacing: Double
        var intensity: Double
    }

    /// Fine luminance noise.
    struct Noise: Codable, Hashable, Sendable {
        var amount: Double
        /// One noise cell.
        var size: Double
    }

    /// Darkened corners.
    struct Vignette: Codable, Hashable, Sendable {
        var intensity: Double
        /// Fraction of the half-diagonal where the darkening starts.
        var radius: Double
    }

    var gradient: Gradient?
    var glow: Glow?
    var halation: Halation?
    var chromaticAberration: ChromaticAberration?
    var chromaBleed: ChromaBleed?
    var glitch: Glitch?
    var lightLeak: LightLeak?
    var scanlines: Scanlines?
    var noise: Noise?
    var grain: Grain?
    var vignette: Vignette?

    static let none = LookEffects()

    var isEmpty: Bool { self == .none }

    enum CodingKeys: String, CodingKey {
        case gradient, glow, halation, glitch, scanlines, noise, grain, vignette
        case chromaticAberration = "chromatic_aberration"
        case chromaBleed = "chroma_bleed"
        case lightLeak = "light_leak"
    }

    /// Linear-light RGB for an Oklab hue (degrees), scaled to unit luminance
    /// so tinting with it shifts colour without changing brightness.
    static func tintColor(hue: Double) -> (r: Double, g: Double, b: Double) {
        let radians = hue * .pi / 180
        let L = 0.7, a = 0.12 * cos(radians), b = 0.12 * sin(radians)
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        let red = max(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, 0)
        let green = max(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s, 0)
        let blue = max(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s, 0)
        let luminance = max(0.2126 * red + 0.7152 * green + 0.0722 * blue, 1e-6)
        return (red / luminance, green / luminance, blue / luminance)
    }
}

/// SplitMix64: small, fast and deterministic, so a photo's random effects
/// (glitch slices, noise) come out the same every time it is rendered.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension UUID {
    /// A stable seed for a capture's random effects (unlike `hashValue`,
    /// which changes between launches).
    var effectsSeed: UInt64 {
        withUnsafeBytes(of: uuid) { $0.load(as: UInt64.self) }
    }
}
