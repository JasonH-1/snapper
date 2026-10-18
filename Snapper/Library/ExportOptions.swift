import CoreGraphics
import Foundation

/// How photos are written when saved to Photos or shared: file format,
/// pixel size, compression quality and whether location stays in the file.
struct ExportOptions: Codable, Hashable, Sendable {
    /// Output size by the longest side.
    enum Size: String, Codable, CaseIterable, Identifiable, Sendable {
        case full, large, medium, small

        var id: String { rawValue }

        /// The longest side in pixels; nil keeps the photo's full resolution.
        var longEdge: Int? {
            switch self {
            case .full: nil
            case .large: 3840
            case .medium: 2048
            case .small: 1080
            }
        }
    }

    var format: PhotoRenderer.ExportFormat = .heic
    var size: Size = .full
    /// Compression quality, `qualityRange`; higher is sharper and larger.
    var quality = ExportOptions.defaultQuality
    /// Keep the photo's GPS position (and place names) in the file.
    var includesLocation = true

    static let standard = ExportOptions()
    static let defaultQuality = 0.92
    static let qualityRange = 0.5...1.0

    init(format: PhotoRenderer.ExportFormat = .heic, size: Size = .full,
         quality: Double = ExportOptions.defaultQuality, includesLocation: Bool = true) {
        self.format = format
        self.size = size
        self.quality = quality
        self.includesLocation = includesLocation
    }

    /// The quality handed to the encoder. HEIF at 1.0 switches to lossless
    /// compression and many times the size, so its top step stays lossy.
    var encoderQuality: Double {
        let clamped = quality.isFinite ? min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound) : Self.defaultQuality
        return format == .heic ? min(clamped, 0.98) : clamped
    }

    /// The pixel size an image of `size` is written at: scaled down so its
    /// longest side fits, never up, keeping its shape.
    func outputSize(for size: CGSize) -> CGSize {
        guard size.width >= 1, size.height >= 1 else { return size }
        let width = size.width.rounded(), height = size.height.rounded()
        guard let limit = self.size.longEdge.map(CGFloat.init), max(width, height) > limit else {
            return CGSize(width: width, height: height)
        }
        let scale = limit / max(width, height)
        return CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
    }

    private enum CodingKeys: String, CodingKey {
        case format, size, quality, includesLocation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? container.decodeIfPresent(PhotoRenderer.ExportFormat.self, forKey: .format)) ?? .heic
        size = (try? container.decodeIfPresent(Size.self, forKey: .size)) ?? .full
        let quality = (try? container.decodeIfPresent(Double.self, forKey: .quality)) ?? Self.defaultQuality
        self.quality = quality.isFinite ? min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound) : Self.defaultQuality
        includesLocation = (try? container.decodeIfPresent(Bool.self, forKey: .includesLocation)) ?? true
    }
}

/// A photo rendered and encoded with given options, waiting in a temporary
/// file to be saved or shared.
struct PreparedExport: Sendable {
    let url: URL
    let byteCount: Int64
    let pixelSize: CGSize
    let recipe: PhotoRecipe
    let options: ExportOptions
}
