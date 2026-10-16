import CoreImage
import ImageIO
import OSLog
import UIKit
import UniformTypeIdentifiers

/// Renders Library photos with their recipe (look, sliders and crop):
/// full-resolution exports, the editor's working preview and thumbnails.
///
/// Looks go through `LookPipeline`, the same code the live preview uses, so
/// what you saw is what you get. Runs off the main actor.
actor PhotoRenderer {
    enum ExportFormat: String, CaseIterable, Sendable {
        case heic
        case jpeg

        var fileExtension: String { self == .heic ? "heic" : "jpg" }
    }

    enum RenderError: LocalizedError {
        case unreadableImage
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage: String(localized: "The photo could not be read.")
            case .encodingFailed: String(localized: "The photo could not be prepared for saving.")
            }
        }
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lutStore: LUTStore

    /// Downscaled, oriented sources for interactive editing, by capture id.
    private var proxies: [UUID: CIImage] = [:]
    private var proxyOrder: [UUID] = []

    init(lutStore: LUTStore = .shared) {
        self.lutStore = lutStore
    }

    // MARK: - Export

    /// Full-resolution render of `source` (the original file's data) with
    /// `recipe`, whose look is `look`. `seed` fixes the look's random effects
    /// (use the photo's id).
    func export(source: Data,
                look: Look,
                recipe: PhotoRecipe,
                seed: UInt64 = 0,
                watermark: Bool,
                format: ExportFormat) throws -> Data {
        guard let original = CIImage(data: source, options: [.applyOrientationProperty: true]) else {
            throw RenderError.unreadableImage
        }
        var image = render(look, recipe: recipe, seed: seed, to: original)
        if watermark {
            image = Watermark.apply(to: image)
        }
        image = image.settingProperties(Self.exportProperties(from: original.properties))

        let colorSpace = LookPipeline.outputColorSpace
        let quality = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
        let data: Data?
        switch format {
        case .heic:
            data = context.heifRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace, options: quality)
        case .jpeg:
            data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: quality)
        }
        guard let data else { throw RenderError.encodingFailed }
        return data
    }

    /// Keeps camera metadata (date, exposure, lens) but records that the
    /// pixels are already upright, and drops the embedded thumbnail.
    private static func exportProperties(from properties: [String: Any]) -> [String: Any] {
        var result = properties
        result[kCGImagePropertyOrientation as String] = 1
        if var tiff = result[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            tiff[kCGImagePropertyTIFFSoftware as String] = "Snapper"
            result[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        result.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        result.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        return result
    }

    // MARK: - Previews

    /// A screen-sized render for the editor. Large photos are edited at
    /// this size; only exports work at full resolution.
    func preview(id: UUID, sourceURL: URL, look: Look, recipe: PhotoRecipe, maxPixelSize: Int = 1800) -> UIImage? {
        guard let proxy = proxy(id: id, sourceURL: sourceURL, maxPixelSize: maxPixelSize) else { return nil }
        return makeUIImage(render(look, recipe: recipe, seed: id.effectsSeed, to: proxy))
    }

    /// The photo framed by `crop` but with no look or sliders (for
    /// press-and-hold compare).
    func original(id: UUID, sourceURL: URL, crop: PhotoCrop = .none, maxPixelSize: Int = 1800) -> UIImage? {
        guard let proxy = proxy(id: id, sourceURL: sourceURL, maxPixelSize: maxPixelSize) else { return nil }
        return makeUIImage(PhotoEditing.frame(proxy, with: crop))
    }

    /// The whole photo, unframed and unfiltered, at preview size (the crop
    /// tab draws its own framing over it).
    func uncropped(id: UUID, sourceURL: URL, maxPixelSize: Int = 1800) -> UIImage? {
        guard let proxy = proxy(id: id, sourceURL: sourceURL, maxPixelSize: maxPixelSize) else { return nil }
        return makeUIImage(proxy)
    }

    /// Small renders of one photo in many looks, for the look strip: the
    /// rest of `recipe` (sliders and crop) is kept, each look at full strength.
    func thumbnails(sourceURL: URL, looks: [Look], recipe: PhotoRecipe = .untouched, seed: UInt64 = 0,
                    maxPixelSize: Int = 220) -> [String: UIImage] {
        guard let small = Self.downsampled(url: sourceURL, maxPixelSize: maxPixelSize) else { return [:] }
        let framed = PhotoEditing.frame(small, with: recipe.crop)
        var result: [String: UIImage] = [:]
        for look in looks {
            let graded = render(look, seed: seed, to: framed)
            result[look.id] = makeUIImage(PhotoEditing.adjust(graded, with: recipe.adjustments, seed: seed))
        }
        return result
    }

    /// One small render (camera button, Library grid).
    func thumbnail(sourceURL: URL, look: Look, recipe: PhotoRecipe, seed: UInt64 = 0,
                   maxPixelSize: Int = 240) -> UIImage? {
        guard let small = Self.downsampled(url: sourceURL, maxPixelSize: maxPixelSize) else { return nil }
        return makeUIImage(render(look, recipe: recipe, seed: seed, to: small))
    }

    /// Renders a bundled showcase image (onboarding, paywall) in a look.
    func showcase(url: URL, look: Look, maxPixelSize: Int = 1400) -> UIImage? {
        guard let source = Self.downsampled(url: url, maxPixelSize: maxPixelSize) else { return nil }
        return makeUIImage(render(look, to: source))
    }

    private func render(_ look: Look, strength: Float = 1, seed: UInt64 = 0, to image: CIImage) -> CIImage {
        LookPipeline.apply(look, lut: lutStore.lut(for: look), strength: strength, seed: seed, to: image)
    }

    private func render(_ look: Look, recipe: PhotoRecipe, seed: UInt64, to image: CIImage) -> CIImage {
        PhotoEditing.apply(recipe, look: look, lut: lutStore.lut(for: look), seed: seed, to: image)
    }

    func forget(id: UUID) {
        proxies[id] = nil
        proxyOrder.removeAll { $0 == id }
    }

    private func proxy(id: UUID, sourceURL: URL, maxPixelSize: Int) -> CIImage? {
        if let cached = proxies[id] { return cached }
        guard let image = Self.downsampled(url: sourceURL, maxPixelSize: maxPixelSize) else { return nil }
        proxies[id] = image
        proxyOrder.append(id)
        if proxyOrder.count > 6 {
            proxies[proxyOrder.removeFirst()] = nil
        }
        return image
    }

    private func makeUIImage(_ image: CIImage) -> UIImage? {
        guard let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: LookPipeline.outputColorSpace) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// The photo's size in pixels once its orientation is applied (portrait
    /// photos come out taller than wide), read from the file's header only.
    static func orientedPixelSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // EXIF orientations 5–8 turn the picture on its side.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// Fast, memory-friendly decode at a reduced size with orientation applied.
    static func downsampled(url: URL, maxPixelSize: Int) -> CIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
