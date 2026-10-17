import CoreImage
import CoreText

/// Adds a fitted canvas and optional date after colour and crop processing.
enum PhotoFinishing {
    static func apply(_ finish: PhotoFinish, to image: CIImage) -> CIImage {
        guard finish.isActive, !image.extent.isInfinite else { return image }
        let geometry = finish.geometry(for: image.extent.size)
        guard geometry.canvas.width > 0, geometry.canvas.height > 0 else { return image }
        let color: CIColor
        switch finish.frame {
        case .black: color = CIColor(red: 0.04, green: 0.04, blue: 0.04)
        case .cream, .instant: color = CIColor(red: 0.97, green: 0.95, blue: 0.89)
        case .none, .white: color = CIColor(red: 1, green: 1, blue: 1)
        }
        let photo = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: geometry.photo.width / image.extent.width,
                                              y: geometry.photo.height / image.extent.height))
            .transformed(by: CGAffineTransform(translationX: geometry.photo.minX, y: geometry.photo.minY))
        var output = photo.composited(over: CIImage(color: color).cropped(to: geometry.canvas))
        if let text = finish.dateStamp, let stamp = dateImage(text, shortSide: min(geometry.photo.width, geometry.photo.height)) {
            let margin = min(geometry.photo.width, geometry.photo.height) * 0.035
            output = stamp.transformed(by: CGAffineTransform(translationX: geometry.photo.maxX - stamp.extent.width - margin,
                                                             y: geometry.photo.minY + margin)).composited(over: output)
        }
        return output.cropped(to: geometry.canvas)
    }

    private static func dateImage(_ text: String, shortSide: CGFloat) -> CIImage? {
        let size = max(2, shortSide * 0.035)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(text.prefix(16)), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padding = ceil(size * 0.5)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(ceil(bounds.width + padding * 2)),
                                      height: Int(ceil(bounds.height + padding * 2)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShadow(offset: .zero, blur: size * 0.2, color: CGColor(gray: 0, alpha: 0.8))
        context.setFillColor(CGColor(red: 1, green: 0.64, blue: 0.25, alpha: 1))
        context.textPosition = CGPoint(x: padding - bounds.minX, y: padding - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage().map { CIImage(cgImage: $0) }
    }
}
