import CoreGraphics

/// Crop box maths for the Crop tab, in normalised top-left coordinates of the
/// turned frame (0…1 on both axes), so it is independent of screen size.
enum CropBox {
    enum Handle: CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// The smallest box, as a fraction of the frame's shorter side.
    static let minimumSize: CGFloat = 0.12

    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The box shape in normalised units (width over height), or nil when the
    /// box is free. `frameSize` is the turned photo in pixels.
    static func normalizedAspect(for shape: CropShape, frameSize: CGSize) -> CGFloat? {
        guard frameSize.width > 0, frameSize.height > 0 else { return nil }
        let pixelAspect: CGFloat
        switch shape {
        case .free:
            return nil
        case .original:
            return 1
        case .fourThree, .square, .sixteenNine:
            guard let ratio = shape.ratio else { return nil }
            // Ratios follow the photo: long side along the frame's long side.
            pixelAspect = frameSize.width >= frameSize.height ? ratio.longOverShort : 1 / ratio.longOverShort
        }
        return pixelAspect * frameSize.height / frameSize.width
    }

    /// The box `crop` keeps, resolving "largest centred box of its shape".
    static func resolvedRect(of crop: PhotoCrop, frameSize: CGSize) -> CGRect {
        if let rect = crop.rect { return rect.intersection(unit) }
        guard frameSize.width > 0, frameSize.height > 0 else { return unit }
        let pixels = crop.pixelRect(in: frameSize)
        // Core Image's bottom-left origin to top-left fractions.
        return CGRect(x: pixels.minX / frameSize.width,
                      y: 1 - pixels.maxY / frameSize.height,
                      width: pixels.width / frameSize.width,
                      height: pixels.height / frameSize.height)
    }

    /// Slides `rect` by `delta`, keeping it inside the frame.
    static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect {
        var result = rect
        result.origin.x = min(max(rect.minX + delta.width, 0), 1 - rect.width)
        result.origin.y = min(max(rect.minY + delta.height, 0), 1 - rect.height)
        return result
    }

    /// Drags one corner of `rect` by `delta` with the opposite corner pinned,
    /// held to `aspect` (normalised width over height) when given, and kept
    /// inside the frame and above the minimum size.
    static func resized(_ rect: CGRect, handle: Handle, by delta: CGSize, aspect: CGFloat?,
                        frameAspect: CGFloat = 1) -> CGRect {
        // The pinned corner and the direction the moving corner grows in.
        let anchor: CGPoint
        let sign: (x: CGFloat, y: CGFloat)
        switch handle {
        case .topLeft: anchor = CGPoint(x: rect.maxX, y: rect.maxY); sign = (-1, -1)
        case .topRight: anchor = CGPoint(x: rect.minX, y: rect.maxY); sign = (1, -1)
        case .bottomLeft: anchor = CGPoint(x: rect.maxX, y: rect.minY); sign = (-1, 1)
        case .bottomRight: anchor = CGPoint(x: rect.minX, y: rect.minY); sign = (1, 1)
        }
        // Room between the pinned corner and the frame edge it grows towards.
        let roomX = sign.x > 0 ? 1 - anchor.x : anchor.x
        let roomY = sign.y > 0 ? 1 - anchor.y : anchor.y
        // Minimum in normalised units: the same on-screen length both ways.
        let minWidth = minimumSize * min(1, 1 / max(frameAspect, 0.0001))
        let minHeight = minimumSize * min(1, max(frameAspect, 0.0001))

        var width = rect.width + sign.x * delta.width
        var height = rect.height + sign.y * delta.height
        if let aspect, aspect > 0 {
            // Follow whichever drag direction moved further, then fit.
            if abs(delta.width) >= abs(delta.height * aspect) {
                height = width / aspect
            } else {
                width = height * aspect
            }
            let scale = min(1, roomX / max(width, 0.0001), roomY / max(height, 0.0001))
            width *= scale
            height *= scale
            let minimum = max(minWidth / width, minHeight / height, 1)
            if minimum > 1 {
                width *= minimum
                height *= minimum
            }
        } else {
            width = min(max(width, minWidth), roomX)
            height = min(max(height, minHeight), roomY)
        }
        let x = sign.x > 0 ? anchor.x : anchor.x - width
        let y = sign.y > 0 ? anchor.y : anchor.y - height
        return CGRect(x: x, y: y, width: width, height: height).intersection(unit)
    }

    /// The largest box of `aspect` centred in the frame.
    static func centred(aspect: CGFloat?) -> CGRect {
        guard let aspect, aspect > 0 else { return unit }
        if aspect >= 1 {
            let height = 1 / aspect
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        return CGRect(x: (1 - aspect) / 2, y: 0, width: aspect, height: 1)
    }
}
