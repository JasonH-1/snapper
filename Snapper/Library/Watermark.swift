import CoreImage
import CoreText

/// The small "SNAPPER" mark added to photos exported without Premium.
enum Watermark {
    static let text = "SNAPPER"

    /// Composites the mark in the bottom-right corner, sized relative to the
    /// photo so it reads the same on any resolution.
    static func apply(to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              let mark = render(shortSide: min(extent.width, extent.height)) else { return image }
        let margin = min(extent.width, extent.height) * 0.035
        let x = extent.maxX - mark.extent.width - margin
        let y = extent.minY + margin
        // Crop back to the photo so the mark can never grow the canvas.
        return mark.transformed(by: CGAffineTransform(translationX: x, y: y))
            .composited(over: image)
            .cropped(to: extent)
    }

    private static func render(shortSide: CGFloat) -> CIImage? {
        let fontSize = max(6, shortSide * 0.024)
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            NSAttributedString.Key(kCTKernAttributeName as String): fontSize * 0.22,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padding = ceil(fontSize * 0.6)
        let width = Int(ceil(bounds.width + padding * 2))
        let height = Int(ceil(bounds.height + padding * 2))
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setShadow(offset: .zero, blur: fontSize * 0.4, color: CGColor(gray: 0, alpha: 0.35))
        context.setFillColor(CGColor(gray: 1, alpha: 0.85))
        context.textPosition = CGPoint(x: padding - bounds.minX, y: padding - bounds.minY)
        CTLineDraw(line, context)
        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
