import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Subject segmentation runs on PhotoRenderer's actor, never on the UI thread.
enum SelectiveRendering {
    /// The mask's area in a see-through tint, to lay over the photo: the
    /// subject, or with `inverted` the background.
    static func overlay(for mask: CIImage, inverted: Bool, color: CIColor = CIColor(red: 1, green: 0.25, blue: 0.2)) -> CIImage {
        let area: CIImage
        if inverted {
            let invert = CIFilter.colorInvert()
            invert.inputImage = mask
            area = invert.outputImage ?? mask
        } else {
            area = mask
        }
        let blend = CIFilter.blendWithRedMask()
        blend.inputImage = CIImage(color: color).cropped(to: mask.extent)
        blend.backgroundImage = CIImage(color: .clear).cropped(to: mask.extent)
        blend.maskImage = area
        return (blend.outputImage ?? mask).cropped(to: mask.extent)
    }

    static func detect(in image: CIImage) throws -> CIImage? {
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let handler = VNImageRequestHandler(ciImage: normalized, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
        let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        // A mask, not a colour image: no colour management.
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    }

    static func apply(_ edits: SelectiveEdits, mask: CIImage, to image: CIImage) -> CIImage {
        guard edits.isActive else { return image }
        let subject = PhotoEditing.adjust(image, with: edits.subject.adjustments)
        let background = PhotoEditing.adjust(image, with: edits.background.adjustments)
        // The red channel: right for both grey masks and Vision's one-channel ones.
        let blend = CIFilter.blendWithRedMask()
        blend.inputImage = subject
        blend.backgroundImage = background
        blend.maskImage = mask
        return (blend.outputImage ?? image).cropped(to: image.extent)
    }
}
