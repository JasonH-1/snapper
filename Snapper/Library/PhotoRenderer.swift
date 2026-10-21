import CoreImage
import CoreImage.CIFilterBuiltins
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
    enum ExportFormat: String, Codable, CaseIterable, Sendable {
        case heic
        case jpeg

        var fileExtension: String { self == .heic ? "heic" : "jpg" }
    }

    enum RenderError: LocalizedError {
        case unreadableImage
        case encodingFailed
        case subjectUnavailable

        var errorDescription: String? {
            switch self {
            case .unreadableImage: String(localized: "The photo could not be read.")
            case .subjectUnavailable: String(localized: "A subject mask could not be created. Open Selective, retry detection or reset selective edits before exporting.")
            case .encodingFailed: String(localized: "The photo could not be prepared for saving.")
            }
        }
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lutStore: LUTStore
    private let detectSubject: @Sendable (CIImage) throws -> CIImage?

    /// Downscaled, oriented sources for interactive editing, by capture id.
    private struct Proxy { let image: CIImage; let maxPixelSize: Int }
    private var proxies: [UUID: Proxy] = [:]
    private var proxyOrder: [UUID] = []
    private var subjectMasks: [URL: CIImage] = [:]
    private var maskOrder: [URL] = []
    private var failedMasks: Set<URL> = []

    init(lutStore: LUTStore = .shared,
         detectSubject: @escaping @Sendable (CIImage) throws -> CIImage? = { try SelectiveRendering.detect(in: $0) }) {
        self.lutStore = lutStore
        self.detectSubject = detectSubject
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
                format: ExportFormat, sourceURL: URL? = nil) throws -> Data {
        try export(source: source, look: look, recipe: recipe, seed: seed, watermark: watermark,
                   options: ExportOptions(format: format), sourceURL: sourceURL)
    }

    /// Encoded render of `source` with `recipe`, sized, compressed and
    /// stripped of location as `options` say.
    func export(source: Data, look: Look, recipe: PhotoRecipe, seed: UInt64 = 0, watermark: Bool,
                options: ExportOptions, sourceURL: URL? = nil) throws -> Data {
        let image = try exportImage(source: source, look: look, recipe: recipe, seed: seed, watermark: watermark,
                                    options: options, sourceURL: sourceURL)
        let colorSpace = LookPipeline.outputColorSpace
        let quality = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: options.encoderQuality]
        let data: Data?
        switch options.format {
        case .heic:
            data = context.heifRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace, options: quality)
        case .jpeg:
            data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: quality)
        }
        guard let data else { throw RenderError.encodingFailed }
        return data
    }

    /// Like `export`, but writes the file straight to `url` (no copy of the
    /// encoded photo in memory). Returns its size in pixels.
    @discardableResult
    func exportFile(source: Data, look: Look, recipe: PhotoRecipe, seed: UInt64 = 0, watermark: Bool,
                    options: ExportOptions, sourceURL: URL? = nil, to url: URL) throws -> CGSize {
        let image = try exportImage(source: source, look: look, recipe: recipe, seed: seed, watermark: watermark,
                                    options: options, sourceURL: sourceURL)
        let colorSpace = LookPipeline.outputColorSpace
        let quality = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: options.encoderQuality]
        do {
            switch options.format {
            case .heic:
                try context.writeHEIFRepresentation(of: image, to: url, format: .RGBA8, colorSpace: colorSpace, options: quality)
            case .jpeg:
                try context.writeJPEGRepresentation(of: image, to: url, colorSpace: colorSpace, options: quality)
            }
        } catch {
            throw RenderError.encodingFailed
        }
        return image.extent.size
    }

    /// The pixel size an export with `options` would have, without rendering it.
    func exportSize(sourceURL: URL, look: Look, recipe: PhotoRecipe, seed: UInt64 = 0, options: ExportOptions) -> CGSize? {
        guard let original = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]),
              let image = render(look, recipe: recipe, seed: seed, to: original, sourceURL: sourceURL) else { return nil }
        return options.outputSize(for: image.extent.size)
    }

    private func exportImage(source: Data, look: Look, recipe: PhotoRecipe, seed: UInt64, watermark: Bool,
                             options: ExportOptions, sourceURL: URL?) throws -> CIImage {
        guard let original = CIImage(data: source, options: [.applyOrientationProperty: true]) else {
            throw RenderError.unreadableImage
        }
        guard var image = render(look, recipe: recipe, seed: seed, to: original, sourceURL: sourceURL) else {
            throw RenderError.subjectUnavailable
        }
        if watermark {
            image = Watermark.apply(to: image)
        }
        image = Self.resized(image, to: options.outputSize(for: image.extent.size))
        return image.settingProperties(Self.exportProperties(from: original.properties,
                                                             includesLocation: options.includesLocation))
    }

    /// Scales `image` down to exactly `size` pixels with Lanczos resampling
    /// (sharp, without the aliasing a plain transform gives on iOS). Images
    /// already that small are returned at the origin, unchanged.
    static func resized(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1, size.width >= 1, size.height >= 1 else { return image }
        let atOrigin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        guard size.width < extent.width.rounded() || size.height < extent.height.rounded() else { return atOrigin }
        let scaleX = size.width / extent.width, scaleY = size.height / extent.height
        let filter = CIFilter.lanczosScaleTransform()
        // Clamped so the edge pixels don't blend with the transparency beyond them.
        filter.inputImage = atOrigin.clampedToExtent()
        filter.scale = Float(scaleY)
        filter.aspectRatio = Float(scaleX / scaleY)
        guard let output = filter.outputImage else { return atOrigin }
        return output.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Keeps camera metadata (date, exposure, lens) but records that the
    /// pixels are already upright, drops the embedded thumbnail and sizes
    /// that no longer apply, and, unless `includesLocation`, every place the
    /// photo's location can be kept: GPS, Apple's maker notes and IPTC place
    /// names.
    static func exportProperties(from properties: [String: Any], includesLocation: Bool = true) -> [String: Any] {
        var result = properties
        result[kCGImagePropertyOrientation as String] = 1
        if var tiff = result[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            tiff[kCGImagePropertyTIFFSoftware as String] = "Snapper"
            result[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        result.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        result.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if var exif = result[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            // Crop and resizing change these; the encoder records the real size.
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifSubjectArea as String)
            exif.removeValue(forKey: kCGImagePropertyExifSubjectLocation as String)
            result[kCGImagePropertyExifDictionary as String] = exif
        }
        guard !includesLocation else { return result }
        result.removeValue(forKey: kCGImagePropertyGPSDictionary as String)
        result.removeValue(forKey: kCGImagePropertyMakerAppleDictionary as String)
        if var iptc = result[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            for key in iptcPlaceKeys { iptc.removeValue(forKey: key) }
            result[kCGImagePropertyIPTCDictionary as String] = iptc
        }
        return result
    }

    /// IPTC fields that name a place.
    private static let iptcPlaceKeys: [String] = [
        kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
        kCGImagePropertyIPTCCountryPrimaryLocationCode, kCGImagePropertyIPTCCountryPrimaryLocationName,
        kCGImagePropertyIPTCContentLocationCode, kCGImagePropertyIPTCContentLocationName,
        kCGImagePropertyIPTCExtLocationCreated, kCGImagePropertyIPTCExtLocationShown,
    ].map { $0 as String }

    /// XMP tags, by namespace, that name a place (IPTC's, as Image I/O reads them).
    private static let xmpPlaceTags: [String: Set<String>] = [
        kCGImageMetadataNamespacePhotoshop as String: ["City", "State", "Country"],
        kCGImageMetadataNamespaceIPTCCore as String: ["Location", "CountryCode"],
        kCGImageMetadataNamespaceIPTCExtension as String: ["LocationCreated", "LocationShown"],
    ]

    /// The original as it is, without its place: GPS and the IPTC place
    /// fields are removed and nothing is re-encoded, so the pixels (HDR
    /// included), format, orientation and capture details are untouched.
    /// Apple's maker note is kept too: it holds exposure, focus and HDR
    /// data, not location, and Image I/O can't drop it without re-encoding.
    /// Throws if the format can't be copied this way or any location
    /// survives the copy, so the caller can re-encode instead.
    static func copyWithoutLocation(from source: URL, into folder: URL) throws -> URL {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(image),
              let metadata = CGImageSourceCopyMetadataAtIndex(image, 0, nil),
              let kept = CGImageMetadataCreateMutableCopy(metadata) else { throw RenderError.unreadableImage }
        var placeTags: [CFString] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            let namespace = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
            if name.hasPrefix("GPS") || xmpPlaceTags[namespace]?.contains(name) == true { placeTags.append(path) }
            return true
        }
        for path in placeTags { CGImageMetadataRemoveTagWithPath(kept, nil, path) }

        let fileExtension = UTType(type as String)?.preferredFilenameExtension ?? source.pathExtension
        let url = folder.appendingPathComponent("Original").appendingPathExtension(fileExtension)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { throw RenderError.encodingFailed }
        // Replaces the metadata with the filtered copy. (Excluding GPS on its
        // own leaves GPS in HEIF and drops everything else from JPEG.)
        let options: [CFString: Any] = [kCGImageDestinationMetadata: kept, kCGImageDestinationMergeMetadata: false,
                                        kCGImageMetadataShouldExcludeGPS: true]
        guard CGImageDestinationCopyImageSource(destination, image, options as CFDictionary, nil), !hasLocation(url) else {
            try? FileManager.default.removeItem(at: url)
            throw RenderError.encodingFailed
        }
        return url
    }

    /// Whether the file still says where it was taken.
    static func hasLocation(_ url: URL) -> Bool {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] else { return true }
        if properties[kCGImagePropertyGPSDictionary as String] != nil { return true }
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        return iptcPlaceKeys.contains { iptc[$0] != nil }
    }

    // MARK: - Previews

    /// A screen-sized render for the editor. Large photos are edited at
    /// this size; only exports work at full resolution.
    func preview(id: UUID, sourceURL: URL, look: Look, recipe: PhotoRecipe, maxPixelSize: Int = 1800) -> UIImage? {
        guard let proxy = proxy(id: id, sourceURL: sourceURL, maxPixelSize: maxPixelSize) else { return nil }
        let source = Self.fitting(proxy, maxPixelSize: maxPixelSize)
        guard let image = render(look, recipe: recipe, seed: id.effectsSeed, to: source, sourceURL: sourceURL) else { return nil }
        return makeUIImage(image)
    }

    /// `image` no larger than `maxPixelSize` on its long side: a bigger copy
    /// may be cached for zooming in, and editing at fit size shouldn't pay for it.
    private static func fitting(_ image: CIImage, maxPixelSize: Int) -> CIImage {
        let long = max(image.extent.width, image.extent.height)
        guard long > CGFloat(maxPixelSize) + 1 else { return image }
        let scale = CGFloat(maxPixelSize) / long
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
    }

    /// The photo framed by `crop` but with no look or sliders (for
    /// press-and-hold compare).
    func original(id: UUID, sourceURL: URL, crop: PhotoCrop = .none, maxPixelSize: Int = 1800) -> UIImage? {
        guard let proxy = proxy(id: id, sourceURL: sourceURL, maxPixelSize: maxPixelSize) else { return nil }
        return makeUIImage(PhotoEditing.frame(Self.fitting(proxy, maxPixelSize: maxPixelSize), with: crop))
    }

    /// The whole photo, unframed and unfiltered, at preview size (the crop
    /// tab draws its own framing over it).
    func uncropped(id: UUID, sourceURL: URL, maxPixelSize: Int = 1800) -> UIImage? {
        guard let proxy = proxy(id: id, sourceURL: sourceURL, maxPixelSize: maxPixelSize) else { return nil }
        return makeUIImage(Self.fitting(proxy, maxPixelSize: maxPixelSize))
    }

    /// Small renders of one photo in many looks, for the look strip: the
    /// rest of `recipe` (sliders and crop) is kept, each look at full strength.
    func thumbnails(sourceURL: URL, looks: [Look], recipe: PhotoRecipe = .untouched, seed: UInt64 = 0,
                    maxPixelSize: Int = 220) -> [String: UIImage] {
        guard let small = Self.downsampled(url: sourceURL, maxPixelSize: maxPixelSize) else { return [:] }
        var result: [String: UIImage] = [:]
        for look in looks {
            var variant = recipe
            variant.lookID = look.id
            variant.strength = 1
            variant.finish = .none
            if let image = render(look, recipe: variant, seed: seed, to: small, sourceURL: sourceURL) {
                result[look.id] = makeUIImage(image)
            }
        }
        return result
    }

    /// One small render (camera button, Library grid).
    func thumbnail(sourceURL: URL, look: Look, recipe: PhotoRecipe, seed: UInt64 = 0,
                   maxPixelSize: Int = 240) -> UIImage? {
        guard let small = Self.downsampled(url: sourceURL, maxPixelSize: maxPixelSize) else { return nil }
        guard let image = render(look, recipe: recipe, seed: seed, to: small, sourceURL: sourceURL) else { return nil }
        return makeUIImage(image)
    }

    /// Renders a bundled showcase image (onboarding, paywall) in a look.
    func showcase(url: URL, look: Look, maxPixelSize: Int = 1400) -> UIImage? {
        guard let source = Self.downsampled(url: url, maxPixelSize: maxPixelSize) else { return nil }
        return makeUIImage(render(look, to: source))
    }

    private func render(_ look: Look, strength: Float = 1, seed: UInt64 = 0, to image: CIImage) -> CIImage {
        LookPipeline.apply(look, lut: lutStore.lut(for: look), strength: strength, seed: seed, to: image)
    }

    private func render(_ look: Look, recipe: PhotoRecipe, seed: UInt64, to image: CIImage, sourceURL: URL? = nil) -> CIImage? {
        let mask = recipe.selective.isActive ? selectionMask(for: recipe.selective, sourceURL: sourceURL, image: image) : nil
        guard !recipe.selective.isActive || mask != nil else { return nil }
        return PhotoEditing.apply(recipe, look: look, lut: lutStore.lut(for: look), seed: seed, to: image, subjectMask: mask)
    }

    func prepareSubject(sourceURL: URL, crop: PhotoCrop, retry: Bool = false) -> UIImage? {
        if retry { failedMasks.remove(sourceURL) }
        guard let source = Self.downsampled(url: sourceURL, maxPixelSize: 1024),
              let mask = subjectMask(sourceURL: sourceURL, image: source) else { return nil }
        return makeUIImage(PhotoEditing.frame(mask, with: crop))
    }

    /// The selection (detected subject plus brush corrections), framed like
    /// the photo and tinted, to lay over the editor's photo at full size.
    /// `background` tints everything outside the subject instead.
    func selectionOverlay(sourceURL: URL, edits: SelectiveEdits, crop: PhotoCrop, background: Bool,
                          maxPixelSize: Int = 1400) -> UIImage? {
        guard let source = Self.downsampled(url: sourceURL, maxPixelSize: maxPixelSize),
              let mask = selectionMask(for: edits, sourceURL: sourceURL, image: source) else { return nil }
        // Transparent outside the tinted area.
        return makeUIImage(SelectiveRendering.overlay(for: PhotoEditing.frame(mask, with: crop), inverted: background))
    }

    /// The selection for `image` (the unframed original or a copy of it):
    /// the detected subject, or nothing when painting from scratch, with
    /// the brush strokes applied, scaled to cover `image`.
    private func selectionMask(for edits: SelectiveEdits, sourceURL: URL?, image: CIImage) -> CIImage? {
        var base: CIImage?
        if edits.usesSubjectDetection {
            guard let detected = detectedMask(sourceURL: sourceURL, image: image) else { return nil }
            base = detected
        }
        let refined: CIImage
        if edits.strokes.isEmpty {
            // Nothing detected, nothing painted: an empty selection.
            refined = base ?? CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        } else {
            guard let painted = paintedMask(for: edits, base: base, sourceURL: sourceURL, image: image) else { return nil }
            refined = painted
        }
        return refined.transformed(by: CGAffineTransform(scaleX: image.extent.width / refined.extent.width,
                                                         y: image.extent.height / refined.extent.height))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
            .cropped(to: image.extent)
    }

    /// Masks with strokes drawn in, by photo and strokes: drawing them is the
    /// slow part, and the preview, overlay and export all ask for the same one.
    private struct PaintedKey: Hashable {
        let sourceURL: URL?
        let aspect: Int
        let strokes: [MaskStroke]
        let usesSubjectDetection: Bool
    }
    private var paintedMasks: [PaintedKey: CIImage] = [:]
    private var paintedOrder: [PaintedKey] = []

    private func paintedMask(for edits: SelectiveEdits, base: CIImage?, sourceURL: URL?, image: CIImage) -> CIImage? {
        // Without a source file, the aspect tells different images apart.
        let aspect = Int((image.extent.width / max(image.extent.height, 1) * 1000).rounded())
        let key = PaintedKey(sourceURL: sourceURL, aspect: sourceURL == nil ? aspect : 0,
                             strokes: edits.strokes, usesSubjectDetection: edits.usesSubjectDetection)
        if let cached = paintedMasks[key] { return cached }
        // Painting from scratch works at the same size detection would.
        let scale = min(1, 1024 / max(image.extent.width, image.extent.height, 1))
        let size = CGSize(width: max(1, (image.extent.width * scale).rounded()),
                          height: max(1, (image.extent.height * scale).rounded()))
        guard let painted = MaskBrush.apply(edits.strokes, to: base, size: size, context: context) else { return nil }
        paintedMasks[key] = painted
        paintedOrder.append(key)
        if paintedOrder.count > 6 { paintedMasks[paintedOrder.removeFirst()] = nil }
        return painted
    }

    /// The detected subject for `image`, at the size Vision made it (1024 px
    /// on the long side), with its origin at zero.
    private func detectedMask(sourceURL: URL?, image: CIImage) -> CIImage? {
        if let sourceURL, failedMasks.contains(sourceURL) { return nil }
        if let sourceURL, let cached = subjectMasks[sourceURL] { return cached }
        let source: CIImage
        if let sourceURL, let loaded = Self.downsampled(url: sourceURL, maxPixelSize: 1024) { source = loaded }
        else {
            let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
            source = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let mask = try? detectSubject(source), !mask.extent.isInfinite,
              mask.extent.width > 0, mask.extent.height > 0 else {
            if let sourceURL {
                if failedMasks.count >= 32 { failedMasks.removeAll() }
                failedMasks.insert(sourceURL)
            }
            return nil
        }
        let detected = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
        if let sourceURL {
            subjectMasks[sourceURL] = detected
            maskOrder.append(sourceURL)
            if maskOrder.count > 6 { subjectMasks[maskOrder.removeFirst()] = nil }
        }
        return detected
    }

    /// The detected subject scaled to cover `image`.
    private func subjectMask(sourceURL: URL?, image: CIImage) -> CIImage? {
        guard let detected = detectedMask(sourceURL: sourceURL, image: image) else { return nil }
        return detected.transformed(by: CGAffineTransform(scaleX: image.extent.width / detected.extent.width,
                                                         y: image.extent.height / detected.extent.height))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
            .cropped(to: image.extent)
    }

    func forget(id: UUID) {
        proxies[id] = nil
        proxyOrder.removeAll { $0 == id }
    }

    private func proxy(id: UUID, sourceURL: URL, maxPixelSize: Int) -> CIImage? {
        if let cached = proxies[id], cached.maxPixelSize >= maxPixelSize { return cached.image }
        guard let image = Self.downsampled(url: sourceURL, maxPixelSize: maxPixelSize) else { return nil }
        proxies[id] = Proxy(image: image, maxPixelSize: maxPixelSize)
        proxyOrder.removeAll { $0 == id }
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

    /// Whether the file records where it was taken (GPS).
    static func hasLocation(url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyGPSDictionary] != nil
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
