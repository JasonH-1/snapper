import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Subject segmentation runs on PhotoRenderer's actor, never on the UI thread.
enum SelectiveRendering {
    static func detect(in image: CIImage) throws -> CIImage? {
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let handler = VNImageRequestHandler(ciImage: normalized, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
        let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        return CIImage(cvPixelBuffer: buffer)
    }

    static func apply(_ edits: SelectiveEdits, mask: CIImage, to image: CIImage) -> CIImage {
        guard edits.isActive else { return image }
        let subject = PhotoEditing.adjust(image, with: edits.subject.adjustments)
        let background = PhotoEditing.adjust(image, with: edits.background.adjustments)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = subject
        blend.backgroundImage = background
        blend.maskImage = mask
        return (blend.outputImage ?? image).cropped(to: image.extent)
    }
}
