import CoreImage
import XCTest
@testable import Snapper

final class PhotoEditingTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// A 40×30 image: red on the left half, blue on the right.
    private func split() -> CIImage {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 30))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 20, y: 0, width: 20, height: 30))
        return red.composited(over: blue)
    }

    private func pixel(_ image: CIImage, x: CGFloat, y: CGFloat) -> (r: Double, g: Double, b: Double) {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }

    private func grey(_ value: CGFloat, size: CGFloat = 20) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    // MARK: - Framing

    func testNoCropIsPassThrough() {
        let image = split()
        XCTAssertTrue(PhotoEditing.frame(image, with: .none) === image)
        XCTAssertTrue(PhotoEditing.adjust(image, with: .none) === image)
    }

    func testFlipMirrorsLeftToRight() {
        let flipped = PhotoEditing.frame(split(), with: PhotoCrop(isFlipped: true))
        XCTAssertEqual(flipped.extent, CGRect(x: 0, y: 0, width: 40, height: 30))
        XCTAssertGreaterThan(pixel(flipped, x: 5, y: 15).b, 0.9, "blue is now on the left")
        XCTAssertGreaterThan(pixel(flipped, x: 35, y: 15).r, 0.9)
    }

    func testQuarterTurnIsClockwise() {
        let turned = PhotoEditing.frame(split(), with: PhotoCrop(quarterTurns: 1))
        XCTAssertEqual(turned.extent, CGRect(x: 0, y: 0, width: 30, height: 40), "width and height swap")
        // Turning clockwise brings the left edge to the top (high y in Core Image).
        XCTAssertGreaterThan(pixel(turned, x: 15, y: 35).r, 0.9, "red on top")
        XCTAssertGreaterThan(pixel(turned, x: 15, y: 5).b, 0.9, "blue at the bottom")
    }

    func testCropBoxUsesTopLeftFractions() {
        // The left half, top two thirds.
        let crop = PhotoCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 2.0 / 3.0), shape: .free)
        let framed = PhotoEditing.frame(split(), with: crop)
        XCTAssertEqual(framed.extent, CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertGreaterThan(pixel(framed, x: 10, y: 10).r, 0.9)
    }

    func testShapeWithoutBoxIsCentred() {
        let framed = PhotoEditing.frame(split(), with: PhotoCrop(shape: .square))
        XCTAssertEqual(framed.extent, CGRect(x: 0, y: 0, width: 30, height: 30))
        let wide = PhotoEditing.frame(grey(0.5, size: 400).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300)),
                                      with: PhotoCrop(shape: .sixteenNine))
        XCTAssertEqual(wide.extent.width / wide.extent.height, 16.0 / 9.0, accuracy: 0.02)
    }

    func testStraighteningZoomsSoNoCornersAreEmpty() {
        let image = grey(0.5, size: 100)
        let straightened = PhotoEditing.frame(image, with: PhotoCrop(straighten: 10))
        XCTAssertEqual(straightened.extent, image.extent, "the frame keeps its size")
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 99, y: 0), CGPoint(x: 0, y: 99), CGPoint(x: 99, y: 99)] {
            XCTAssertEqual(pixel(straightened, x: corner.x, y: corner.y).g, 0.5, accuracy: 0.02, "corner \(corner)")
        }
        XCTAssertEqual(PhotoCrop.straightenScale(degrees: 0, size: CGSize(width: 4, height: 3)), 1)
        XCTAssertGreaterThan(PhotoCrop.straightenScale(degrees: 10, size: CGSize(width: 4, height: 3)), 1.1)
    }

    func testRotatingMovesTheCropBoxWithThePhoto() {
        var crop = PhotoCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.25), shape: .free)
        crop.rotateClockwise()
        XCTAssertEqual(crop.quarterTurns, 1)
        // The top-left box ends up at the top right, turned on its side.
        XCTAssertEqual(crop.rect, CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5))
        for _ in 0..<3 { crop.rotateClockwise() }
        XCTAssertEqual(crop.quarterTurns, 0)
        XCTAssertEqual(crop.rect, CGRect(x: 0, y: 0, width: 0.5, height: 0.25))
    }

    func testFlippingAsSeenUndoesItself() {
        var crop = PhotoCrop(rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), shape: .free,
                             straighten: 4, quarterTurns: 1)
        let before = crop
        crop.flipHorizontally()
        XCTAssertTrue(crop.isFlipped)
        XCTAssertEqual(crop.straighten, -4)
        XCTAssertEqual(crop.quarterTurns, 3)
        XCTAssertEqual(crop.rect?.minX ?? 0, 0.6, accuracy: 1e-9)
        crop.flipHorizontally()
        XCTAssertFalse(crop.isFlipped)
        XCTAssertEqual(crop.straighten, before.straighten)
        XCTAssertEqual(crop.quarterTurns, before.quarterTurns)
        XCTAssertEqual(crop.rect?.minX ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(crop.rect?.width ?? 0, 0.3, accuracy: 1e-9)
    }

    /// Mirroring a turned photo must give the mirror image of what was shown.
    func testFlipAfterTurnMirrorsWhatIsShown() {
        var crop = PhotoCrop(quarterTurns: 1)
        let shown = PhotoEditing.frame(split(), with: crop)
        crop.flipHorizontally()
        let mirrored = PhotoEditing.frame(split(), with: crop)
        XCTAssertEqual(mirrored.extent, shown.extent)
        // Top and bottom (red over blue) are unchanged by a left-right mirror.
        XCTAssertGreaterThan(pixel(mirrored, x: 15, y: 35).r, 0.9)
        XCTAssertGreaterThan(pixel(mirrored, x: 15, y: 5).b, 0.9)
    }

    // MARK: - Light and colour

    func testBrightnessLiftsMidTonesAndHoldsBlackAndWhite() {
        var adjustments = PhotoAdjustments()
        adjustments.brightness = 1
        XCTAssertGreaterThan(pixel(PhotoEditing.adjust(grey(0.5), with: adjustments), x: 5, y: 5).g, 0.58)
        XCTAssertEqual(pixel(PhotoEditing.adjust(grey(0), with: adjustments), x: 5, y: 5).g, 0, accuracy: 0.01)
        XCTAssertEqual(pixel(PhotoEditing.adjust(grey(1), with: adjustments), x: 5, y: 5).g, 1, accuracy: 0.01)
        adjustments.brightness = -1
        XCTAssertLessThan(pixel(PhotoEditing.adjust(grey(0.5), with: adjustments), x: 5, y: 5).g, 0.42)
    }

    func testContrastSpreadsTones() {
        var adjustments = PhotoAdjustments()
        adjustments.contrast = 1
        XCTAssertLessThan(pixel(PhotoEditing.adjust(grey(0.25), with: adjustments), x: 5, y: 5).g, 0.22)
        XCTAssertGreaterThan(pixel(PhotoEditing.adjust(grey(0.75), with: adjustments), x: 5, y: 5).g, 0.78)
    }

    func testFadeLiftsBlacks() {
        var adjustments = PhotoAdjustments()
        adjustments.fade = 1
        XCTAssertGreaterThan(pixel(PhotoEditing.adjust(grey(0), with: adjustments), x: 5, y: 5).g, 0.15)
    }

    func testWarmthAndSaturation() {
        var adjustments = PhotoAdjustments()
        adjustments.warmth = 1
        let warm = pixel(PhotoEditing.adjust(grey(0.5), with: adjustments), x: 5, y: 5)
        XCTAssertGreaterThan(warm.r, warm.b + 0.05)
        adjustments.warmth = -1
        let cool = pixel(PhotoEditing.adjust(grey(0.5), with: adjustments), x: 5, y: 5)
        XCTAssertGreaterThan(cool.b, cool.r + 0.05)

        var mono = PhotoAdjustments()
        mono.saturation = -1
        let red = CIImage(color: CIColor(red: 0.9, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        let out = pixel(PhotoEditing.adjust(red, with: mono), x: 5, y: 5)
        XCTAssertEqual(out.r, out.g, accuracy: 0.02, "no colour left")
        XCTAssertEqual(out.g, out.b, accuracy: 0.02)
    }

    func testGrainIsSeededAndKeepsSize() {
        var adjustments = PhotoAdjustments()
        adjustments.grain = 1
        let image = grey(0.4, size: 64)
        let a = PhotoEditing.adjust(image, with: adjustments, seed: 7)
        let b = PhotoEditing.adjust(image, with: adjustments, seed: 7)
        XCTAssertEqual(a.extent, image.extent)
        XCTAssertEqual(pixel(a, x: 10, y: 20).g, pixel(b, x: 10, y: 20).g)
    }

    func testSlidersClampToTheirRange() {
        var adjustments = PhotoAdjustments()
        adjustments[.fade] = -0.5
        adjustments[.brightness] = 3
        XCTAssertEqual(adjustments.fade, 0)
        XCTAssertEqual(adjustments.brightness, 1)
    }

    func testRecipeDecodesWithMissingFields() throws {
        let recipe = try JSONDecoder().decode(PhotoRecipe.self, from: Data(#"{"lookID":"cream","adjustments":{"fade":0.3}}"#.utf8))
        XCTAssertEqual(recipe.strength, 1)
        XCTAssertEqual(recipe.adjustments.fade, 0.3)
        XCTAssertEqual(recipe.adjustments.brightness, 0)
        XCTAssertEqual(recipe.crop, .none)
    }
}
