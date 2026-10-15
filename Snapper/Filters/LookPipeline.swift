import CoreImage
import CoreImage.CIFilterBuiltins

/// The one place where a look is applied to an image.
///
/// The live preview, the captured photo, the review screen and every export go
/// through `apply`, which is what makes the saved photo match the preview: the
/// same cube, interpreted in the same colour space, with the same blending.
enum LookPipeline {
    /// Looks are authored on gamma-encoded sRGB values (see tools/lutgen), so
    /// the cube is applied in sRGB rather than Core Image's linear working space.
    static var cubeColorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Output colour space for rendered previews and exported photos.
    static var outputColorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Applies a LUT at the given strength (0…1). `nil` returns the input.
    static func apply(_ lut: CubeLUT?, strength: Float = 1, to image: CIImage) -> CIImage {
        guard let lut, strength > 0.001 else { return image }
        return apply(cubeData: lut.data(strength: strength), dimension: lut.dimension, to: image)
    }

    /// Applies pre-blended cube data. Callers on hot paths cache the data.
    static func apply(cubeData: Data, dimension: Int, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(dimension)
        filter.cubeData = cubeData
        filter.colorSpace = cubeColorSpace
        return filter.outputImage ?? image
    }
}
