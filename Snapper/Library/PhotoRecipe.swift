import CoreGraphics
import Foundation

/// Where a photo in the Library came from.
enum PhotoSource: String, Codable, Sendable {
    /// Taken with Snapper's camera.
    case camera
    /// Picked from the photo library; Snapper keeps its own copy.
    case imported
}

/// The light and colour sliders. Each is 0 when untouched; brightness,
/// contrast, saturation and warmth run from -1 to 1, fade and grain from 0 to 1.
struct PhotoAdjustments: Hashable, Sendable {
    var brightness = 0.0
    var contrast = 0.0
    var saturation = 0.0
    var warmth = 0.0
    var fade = 0.0
    var grain = 0.0

    static let none = PhotoAdjustments()

    var isNone: Bool { self == .none }

    /// One slider, for the Adjust tab.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case brightness, contrast, saturation, warmth, fade, grain

        var id: String { rawValue }

        /// The slider's range; fade and grain only add.
        var range: ClosedRange<Double> {
            switch self {
            case .fade, .grain: 0...1
            default: -1...1
            }
        }
    }

    subscript(kind: Kind) -> Double {
        get {
            switch kind {
            case .brightness: brightness
            case .contrast: contrast
            case .saturation: saturation
            case .warmth: warmth
            case .fade: fade
            case .grain: grain
            }
        }
        set {
            let value = min(max(newValue, kind.range.lowerBound), kind.range.upperBound)
            switch kind {
            case .brightness: brightness = value
            case .contrast: contrast = value
            case .saturation: saturation = value
            case .warmth: warmth = value
            case .fade: fade = value
            case .grain: grain = value
            }
        }
    }
}

/// A crop box shape. The ratios follow the photo: 4:3 is tall on a tall
/// photo and wide on a wide one.
enum CropShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case free
    /// The photo's own shape (the full 4:3 frame for Snapper shots).
    case original
    case fourThree = "4:3"
    case square = "1:1"
    case sixteenNine = "16:9"

    var id: String { rawValue }

    /// The fixed ratio, or nil for free and original.
    var ratio: AspectRatio? {
        switch self {
        case .free, .original: nil
        case .fourThree: .fourThree
        case .square: .square
        case .sixteenNine: .sixteenNine
        }
    }

    /// The crop a camera shot starts with.
    init(cameraAspect: AspectRatio) {
        switch cameraAspect {
        case .fourThree: self = .original
        case .square: self = .square
        case .sixteenNine: self = .sixteenNine
        }
    }
}

/// How a photo is framed: mirrored, turned and straightened, then cropped.
struct PhotoCrop: Hashable, Sendable {
    /// The part kept, as fractions (0…1) of the turned frame with the origin at
    /// the top left. Nil keeps the largest centred box of `shape`.
    var rect: CGRect?
    var shape: CropShape = .original
    /// Degrees clockwise, -45…45. The photo zooms in just enough that no
    /// empty corners show.
    var straighten = 0.0
    /// Quarter turns clockwise (0…3).
    var quarterTurns = 0
    /// Mirrored left to right (applied before turning).
    var isFlipped = false

    static let none = PhotoCrop()

    var isNone: Bool { self == .none }

    static let straightenRange = -45.0...45.0

    /// True when the frame's width and height swap.
    var isSideways: Bool { quarterTurns % 2 == 1 }

    /// Turns the framed photo a quarter turn clockwise, crop box included.
    mutating func rotateClockwise() {
        quarterTurns = (quarterTurns + 1) % 4
        if let rect {
            // (x, y) → (1 - y, x) in top-left normalised coordinates.
            self.rect = CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        }
    }

    /// Mirrors the framed photo left to right, as seen, crop box included.
    mutating func flipHorizontally() {
        isFlipped.toggle()
        // Mirroring reverses the direction of every turn that follows it.
        quarterTurns = (4 - quarterTurns) % 4
        straighten = -straighten
        if let rect {
            self.rect = CGRect(x: 1 - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
        }
    }

    /// The crop box in pixels for a turned frame of `size`, in Core Image
    /// coordinates (origin at the bottom left).
    func pixelRect(in size: CGSize) -> CGRect {
        let frame = CGRect(origin: .zero, size: size)
        guard let rect else {
            return shape.ratio.map { $0.crop(frame) } ?? frame
        }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clamped = rect.intersection(unit)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return frame }
        let pixels = CGRect(x: clamped.minX * size.width,
                            y: (1 - clamped.maxY) * size.height,
                            width: clamped.width * size.width,
                            height: clamped.height * size.height).integral
        return pixels.intersection(frame)
    }

    /// How much straightening by `degrees` zooms a `size` frame so the
    /// turned photo still covers it.
    static func straightenScale(degrees: Double, size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        let radians = abs(degrees) * .pi / 180
        let elongation = max(size.width / size.height, size.height / size.width)
        return CGFloat(cos(radians)) + elongation * CGFloat(sin(radians))
    }
}

/// Everything done to a photo, applied fresh whenever it is shown or saved;
/// the original file is never changed.
struct PhotoRecipe: Hashable, Sendable {
    var lookID: String
    /// How strongly the look is applied (0…1).
    var strength = 1.0
    var adjustments = PhotoAdjustments.none
    var crop = PhotoCrop.none

    /// A photo with no look and no edits.
    static let untouched = PhotoRecipe(lookID: Look.original.id)
}

// MARK: - Coding

// Every field is optional when reading, so records written by older builds
// (and future fields) decode with sensible defaults.

extension PhotoAdjustments: Codable {
    private enum CodingKeys: String, CodingKey {
        case brightness, contrast, saturation, warmth, fade, grain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        fade = try container.decodeIfPresent(Double.self, forKey: .fade) ?? 0
        grain = try container.decodeIfPresent(Double.self, forKey: .grain) ?? 0
    }
}

extension PhotoCrop: Codable {
    private enum CodingKeys: String, CodingKey {
        case rect, shape, straighten, quarterTurns, isFlipped
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rect = try container.decodeIfPresent(CGRect.self, forKey: .rect)
        shape = (try? container.decodeIfPresent(CropShape.self, forKey: .shape)) ?? .original
        straighten = try container.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        quarterTurns = ((try container.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0) % 4 + 4) % 4
        isFlipped = try container.decodeIfPresent(Bool.self, forKey: .isFlipped) ?? false
    }
}

extension PhotoRecipe: Codable {
    private enum CodingKeys: String, CodingKey {
        case lookID, strength, adjustments, crop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lookID = try container.decode(String.self, forKey: .lookID)
        strength = try container.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        adjustments = try container.decodeIfPresent(PhotoAdjustments.self, forKey: .adjustments) ?? .none
        crop = try container.decodeIfPresent(PhotoCrop.self, forKey: .crop) ?? .none
    }
}
