import CoreGraphics
import CoreImage
import Foundation

/// Draws brush strokes into a selection mask with Core Graphics.
///
/// Each stroke is stamped as round dabs into its own layer, keeping the
/// brightest (paint) or darkest (erase) value, so dabs never pile up into a
/// harder edge than the brush has; the finished stroke then joins the mask:
/// paint keeps whichever is more selected, erase scales the mask down.
/// Strokes apply in order, so erasing and painting back works as expected.
///
/// The mask is a plain 8-bit grey image read without colour management, so
/// a 50% feather stays 50% in Core Image's linear working space.
enum MaskBrush {
    /// Paints `strokes` onto `base` (a mask of the original photo, its red
    /// channel the selection) or onto an empty mask of `size` pixels when
    /// there is none. Returns the corrected mask at the same size.
    static func apply(_ strokes: [MaskStroke], to base: CIImage?, size: CGSize, context: CIContext) -> CIImage? {
        let width = Int((base?.extent.width ?? size.width).rounded())
        let height = Int((base?.extent.height ?? size.height).rounded())
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
        let gray = CGColorSpaceCreateDeviceGray()
        // Row length left to Core Graphics, which aligns it.
        guard let mask = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let layer = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let maskData = mask.data else { return nil }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        if let base {
            // The red channel, as is: no colour conversion either way.
            let atOrigin = base.transformed(by: CGAffineTransform(translationX: -base.extent.minX, y: -base.extent.minY))
            context.render(atOrigin, toBitmap: maskData, rowBytes: mask.bytesPerRow, bounds: fullRect, format: .R8, colorSpace: nil)
        } else {
            mask.setFillColor(gray: 0, alpha: 1)
            mask.fill(fullRect)
        }

        let shortSide = CGFloat(min(width, height))
        for stroke in strokes where stroke.isValid {
            let radius = max(CGFloat(stroke.radius) * shortSide, 0.75)
            let points = stroke.points.map { CGPoint(x: $0.x * CGFloat(width), y: (1 - $0.y) * CGFloat(height)) }
            guard let bounds = boundingBox(of: points, radius: radius)?.intersection(fullRect), !bounds.isNull, !bounds.isEmpty else {
                continue
            }
            let isPaint = stroke.mode == .paint
            // The stroke's own layer: 0 → 1 for paint, 1 → 0 for erase.
            layer.saveGState()
            layer.clip(to: bounds)
            layer.setBlendMode(.normal)
            layer.setFillColor(gray: isPaint ? 0 : 1, alpha: 1)
            layer.fill(bounds)
            layer.setBlendMode(isPaint ? .lighten : .darken)
            guard let gradient = dabGradient(softness: stroke.softness, radius: radius, inverted: !isPaint) else {
                layer.restoreGState()
                continue
            }
            for center in dabCenters(along: points, radius: radius) {
                layer.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
            }
            layer.restoreGState()
            guard let strokeImage = layer.makeImage() else { continue }
            mask.saveGState()
            mask.clip(to: bounds)
            mask.setBlendMode(isPaint ? .lighten : .multiply)
            mask.draw(strokeImage, in: fullRect)
            mask.restoreGState()
        }

        guard let image = mask.makeImage() else { return nil }
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    }

    /// Dab centres along the stroke, a fraction of the radius apart, so the
    /// edge stays smooth however fast the finger moved.
    static func dabCenters(along points: [CGPoint], radius: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        let spacing = max(radius * 0.15, 0.5)
        var centers = [first]
        var carried: CGFloat = 0
        for (start, end) in zip(points, points.dropFirst()) {
            let dx = end.x - start.x, dy = end.y - start.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { continue }
            var distance = spacing - carried
            while distance <= length {
                centers.append(CGPoint(x: start.x + dx * distance / length, y: start.y + dy * distance / length))
                distance += spacing
            }
            carried = length - (distance - spacing)
        }
        if let last = points.last, centers.last != last { centers.append(last) }
        return centers
    }

    private static func boundingBox(of points: [CGPoint], radius: CGFloat) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX - radius - 2, y: minY - radius - 2,
                      width: maxX - minX + radius * 2 + 4, height: maxY - minY + radius * 2 + 4).integral
    }

    /// A round dab's falloff: solid out to the hard core, then a smooth
    /// (smoothstep) fade to the rim. A hard brush keeps a pixel of fade so
    /// its edge is anti-aliased.
    private static func dabGradient(softness: Double, radius: CGFloat, inverted: Bool) -> CGGradient? {
        let feather = max(min(softness, 1), 0)
        let minimumFade = Double(min(1.5 / max(radius, 1), 1))
        let core = 1 - max(feather, minimumFade)
        var components: [CGFloat] = []
        var locations: [CGFloat] = []
        let steps = 8
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let falloff = 1 - t * t * (3 - 2 * t)
            let value = inverted ? 1 - falloff : falloff
            components += [CGFloat(value), 1]
            locations.append(CGFloat(core + (1 - core) * t))
        }
        if core > 0 {
            components.insert(contentsOf: [inverted ? 0 : 1, 1], at: 0)
            locations.insert(0, at: 0)
        }
        return CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: components,
                          locations: locations, count: locations.count)
    }
}
