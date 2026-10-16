import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Snapper

final class PhotoRendererTests: XCTestCase {
    /// A 40×30 JPEG whose metadata says "rotate 90° clockwise" (EXIF 6), like
    /// a portrait photo from the back camera.
    private func makeRotatedJPEG() throws -> Data {
        let width = 40, height = 30
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func testExportBakesOrientationAndKeepsFullSize() async throws {
        let renderer = PhotoRenderer()
        let look = try XCTUnwrap(LookLibrary.bundled().looks.first { !$0.isOriginal })
        let output = try await renderer.export(source: makeRotatedJPEG(), look: look, recipe: PhotoRecipe(lookID: look.id),
                                               watermark: true, format: .jpeg)
        let props = try properties(of: output)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 30, "portrait after applying orientation")
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 40)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1)
    }

    func testExportAppliesTheCrop() async throws {
        let renderer = PhotoRenderer()
        var recipe = PhotoRecipe.untouched
        recipe.crop.rotateClockwise()
        recipe.crop.shape = .square
        let output = try await renderer.export(source: makeRotatedJPEG(), look: .original, recipe: recipe,
                                               watermark: false, format: .jpeg)
        let props = try properties(of: output)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 30)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 30)

        recipe.crop = PhotoCrop(quarterTurns: 1)
        let turned = try properties(of: try await renderer.export(source: makeRotatedJPEG(), look: .original, recipe: recipe,
                                                                  watermark: false, format: .jpeg))
        XCTAssertEqual(turned[kCGImagePropertyPixelWidth] as? Int, 40, "a quarter turn makes the portrait wide")
        XCTAssertEqual(turned[kCGImagePropertyPixelHeight] as? Int, 30)
    }

    func testWatermarkKeepsExtent() {
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(Watermark.apply(to: image).extent, image.extent)
    }

    func testOriginalLookIsPassThrough() {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertTrue(LookPipeline.apply(nil, to: image) === image)
    }
}

final class WatermarkTests: XCTestCase {
    func testWatermarkNeverGrowsSmallImages() {
        let tiny = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 30, height: 40))
        XCTAssertEqual(Watermark.apply(to: tiny).extent, tiny.extent)
    }
}

final class PhotoRendererThumbnailTests: XCTestCase {
    func testLookThumbnailsDifferPerLook() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try TestImages.jpeg(width: 64, height: 48).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let library = LookLibrary.bundled()
        let looks = [Look.original] + library.looks.filter { !$0.isOriginal }.prefix(3)
        let images = await PhotoRenderer().thumbnails(sourceURL: url, looks: Array(looks))
        XCTAssertEqual(images.count, looks.count)
        let colors = looks.compactMap { images[$0.id].flatMap(Self.centerColor) }
        XCTAssertEqual(colors.count, looks.count)
        XCTAssertNotEqual(colors[0], colors[1], "a look changes the thumbnail")
    }

    private static func centerColor(_ image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: -CGFloat(cgImage.width / 2), y: -CGFloat(cgImage.height / 2),
                                         width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return pixel
    }
}
