import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies a photo's crop and light-and-colour edits. Like looks, these are
/// built-in Core Image filters only, so previews and exports agree.
///
/// The order is: frame (mirror, turn, straighten, crop), then the look, then
/// the sliders, so "Brightness +20" brightens what you see, look included.
enum PhotoEditing {
    /// Applies the whole recipe: framing, `look` (with its LUT) and the sliders.
    static func apply(_ recipe: PhotoRecipe, look: Look, lut: CubeLUT?, seed: UInt64, to image: CIImage, subjectMask: CIImage? = nil) -> CIImage {
        let framed = frame(image, with: recipe.crop)
        let graded = LookPipeline.apply(look, lut: lut, strength: Float(recipe.strength), seed: seed, to: framed)
        let global = adjust(graded, with: recipe.adjustments, seed: seed)
        let selective: CIImage
        if recipe.selective.isActive, let subjectMask {
            let mask = frame(subjectMask, with: recipe.crop)
            selective = SelectiveRendering.apply(recipe.selective, mask: mask, to: global)
        } else { selective = global }
        return PhotoFinishing.apply(recipe.finish, to: selective)
    }

    // MARK: - Framing

    /// Mirrors, turns and straightens `image`, then cuts out the crop box.
    /// The result sits at the origin.
    static func frame(_ image: CIImage, with crop: PhotoCrop) -> CIImage {
        guard !image.extent.isInfinite, image.extent.width >= 1, image.extent.height >= 1 else { return image }
        var output = atOrigin(image)
        guard !crop.isNone else { return output }

        if crop.isFlipped {
            let width = output.extent.width
            output = output.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0))
        }
        if crop.quarterTurns != 0 {
            // Clockwise as seen is a negative angle in Core Image's y-up space.
            let angle = -CGFloat(crop.quarterTurns) * .pi / 2
            output = atOrigin(output.transformed(by: CGAffineTransform(rotationAngle: angle)))
        }
        let size = output.extent.size
        if abs(crop.straighten) > 0.001 {
            let degrees = min(max(crop.straighten, PhotoCrop.straightenRange.lowerBound), PhotoCrop.straightenRange.upperBound)
            let scale = PhotoCrop.straightenScale(degrees: degrees, size: size)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: -CGFloat(degrees) * .pi / 180)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -center.x, y: -center.y)
            // Clamp first so resampling at the frame's edge never pulls in transparency.
            output = output.clampedToExtent().transformed(by: transform)
                .cropped(to: CGRect(origin: .zero, size: size))
        }
        let box = crop.pixelRect(in: size)
        guard box.width >= 1, box.height >= 1 else { return output }
        return output.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
    }

    /// The transform `frame(_:with:)` gives an image of `size` at the
    /// origin (Core Image coordinates), and the framed size. Used to map
    /// touches on the framed photo back onto the original.
    static func frameTransform(for crop: PhotoCrop, imageSize size: CGSize) -> (transform: CGAffineTransform, size: CGSize) {
        guard !crop.isNone, size.width >= 1, size.height >= 1 else { return (.identity, size) }
        var transform = CGAffineTransform.identity
        var frameSize = size
        if crop.isFlipped {
            transform = transform.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0))
        }
        if crop.quarterTurns != 0 {
            let rotation = CGAffineTransform(rotationAngle: -CGFloat(crop.quarterTurns) * .pi / 2)
            let turned = CGRect(origin: .zero, size: size).applying(rotation)
            transform = transform.concatenating(rotation)
                .concatenating(CGAffineTransform(translationX: -turned.minX, y: -turned.minY))
            frameSize = turned.size
        }
        if abs(crop.straighten) > 0.001 {
            let degrees = min(max(crop.straighten, PhotoCrop.straightenRange.lowerBound), PhotoCrop.straightenRange.upperBound)
            let scale = PhotoCrop.straightenScale(degrees: degrees, size: frameSize)
            let center = CGPoint(x: frameSize.width / 2, y: frameSize.height / 2)
            transform = transform.concatenating(CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: -CGFloat(degrees) * .pi / 180)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -center.x, y: -center.y))
        }
        let box = crop.pixelRect(in: frameSize)
        guard box.width >= 1, box.height >= 1 else { return (transform, frameSize) }
        return (transform.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY)), box.size)
    }

    /// A point on the framed photo (0…1 from its top left) on the original
    /// photo of `imageSize` (0…1 from its top left).
    static func originalPoint(fromFramed point: CGPoint, crop: PhotoCrop, imageSize: CGSize) -> CGPoint {
        let (transform, framed) = frameTransform(for: crop, imageSize: imageSize)
        let pixel = CGPoint(x: point.x * framed.width, y: (1 - point.y) * framed.height)
        let original = pixel.applying(transform.inverted())
        return CGPoint(x: original.x / max(imageSize.width, 1), y: 1 - original.y / max(imageSize.height, 1))
    }

    /// The reverse: a point on the original photo on the framed one.
    static func framedPoint(fromOriginal point: CGPoint, crop: PhotoCrop, imageSize: CGSize) -> CGPoint {
        let (transform, framed) = frameTransform(for: crop, imageSize: imageSize)
        let pixel = CGPoint(x: point.x * imageSize.width, y: (1 - point.y) * imageSize.height).applying(transform)
        return CGPoint(x: pixel.x / max(framed.width, 1), y: 1 - pixel.y / max(framed.height, 1))
    }

    /// How many framed pixels one original pixel becomes (straightening zooms in).
    static func frameScale(for crop: PhotoCrop, imageSize: CGSize) -> CGFloat {
        let transform = frameTransform(for: crop, imageSize: imageSize).transform
        return max((transform.a * transform.a + transform.b * transform.b).squareRoot(), 0.0001)
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        guard origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    // MARK: - Light and colour

    /// Applies the sliders to an already framed and graded image.
    static func adjust(_ image: CIImage, with adjustments: PhotoAdjustments, seed: UInt64 = 0) -> CIImage {
        guard !adjustments.isNone, adjustments.isValid, !image.extent.isInfinite else { return image }
        let extent = image.extent
        var output = image

        if abs(adjustments.warmth) > 0.001 {
            output = warmed(output, by: CGFloat(adjustments.warmth))
        }
        if abs(adjustments.saturation) > 0.001 {
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            // Down to black and white; up by at most 70% more colour.
            let amount = adjustments.saturation
            controls.saturation = Float(amount < 0 ? 1 + amount : 1 + amount * 0.7)
            controls.brightness = 0
            controls.contrast = 1
            output = controls.outputImage ?? output
        }
        if abs(adjustments.brightness) > 0.001 || abs(adjustments.contrast) > 0.001 || adjustments.fade > 0.001 {
            output = toned(output, brightness: CGFloat(adjustments.brightness),
                           contrast: CGFloat(adjustments.contrast), fade: CGFloat(adjustments.fade))
        }
        if abs(adjustments.highlights) > 0.001 || abs(adjustments.shadows) > 0.001 {
            let curve = CIFilter.toneCurve()
            curve.inputImage = output
            curve.point0 = CGPoint(x: 0, y: 0)
            curve.point1 = CGPoint(x: 0.25, y: 0.25 + 0.15 * adjustments.shadows)
            curve.point2 = CGPoint(x: 0.5, y: 0.5)
            curve.point3 = CGPoint(x: 0.75, y: 0.75 + 0.15 * adjustments.highlights)
            curve.point4 = CGPoint(x: 1, y: 1)
            output = curve.outputImage ?? output
        }
        output = ToneRendering.applyCurves(adjustments.curves, to: output)
        output = ColorMixRendering.apply(adjustments.colorMixer, to: output)
        output = ToneRendering.applySplitToning(adjustments.splitToning, to: output)
        if adjustments.bloom > 0 || adjustments.halation > 0 || adjustments.vignette > 0 {
            var effects = LookEffects.none
            if adjustments.bloom > 0 {
                effects.glow = .init(threshold: 0.65, radius: 0.018, intensity: adjustments.bloom * 0.7,
                                     saturation: 0.8, tintHue: 45, tint: 0)
            }
            if adjustments.halation > 0 {
                effects.halation = .init(threshold: 0.7, radius: 0.009, intensity: adjustments.halation * 0.7)
            }
            if adjustments.vignette > 0 {
                effects.vignette = .init(intensity: adjustments.vignette * 0.65, radius: 0.45)
            }
            output = LookPipeline.applyEffects(effects, seed: seed, to: output)
        }
        if adjustments.grain > 0.001 {
            let grain = LookEffects.Grain(amount: 0.3 * adjustments.grain, size: 0.0013, roughness: 0.45, color: 0.1)
            // A different seed from the look's own grain, so the two don't line up.
            output = LookPipeline.applyEffects(LookEffects(grain: grain), seed: seed ^ 0x5EED_6A41_4E00_0001, to: output)
        }
        return output.cropped(to: extent)
    }

    /// Warmer (positive) pushes red up and blue down; cooler the opposite.
    /// Linear-light gains, so brightness barely moves.
    private static func warmed(_ image: CIImage, by amount: CGFloat) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: 1 + 0.12 * amount, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: 1 + 0.015 * amount, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 1 - 0.16 * amount, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return matrix.outputImage ?? image
    }

    /// One tone curve (Core Image applies it to gamma-encoded values, so its
    /// points match what the eye sees): brightness lifts the mid-tones with
    /// black and white held, contrast is an S-curve, and fade lifts the
    /// blacks and dims the whites.
    private static func toned(_ image: CIImage, brightness: CGFloat, contrast: CGFloat, fade: CGFloat) -> CIImage {
        let lift = fade * 0.2, ceiling = 1 - fade * 0.05
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x, y: lift + min(max(y, 0), 1) * (ceiling - lift))
        }
        let curve = CIFilter.toneCurve()
        curve.point0 = point(0, 0)
        curve.point1 = point(0.25, 0.25 + brightness * 0.10 - contrast * 0.08)
        curve.point2 = point(0.5, 0.5 + brightness * 0.14)
        curve.point3 = point(0.75, 0.75 + brightness * 0.09 + contrast * 0.08)
        curve.point4 = point(1, 1)
        curve.inputImage = image
        return curve.outputImage ?? image
    }
}
