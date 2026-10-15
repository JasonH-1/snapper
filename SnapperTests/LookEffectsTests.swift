import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import Snapper

final class LookEffectsTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// Every effect at once, keyed the way tools/lutgen writes filters.json.
    private func allEffects() throws -> LookEffects {
        let json = """
        {"gradient": {"size": 0.5, "exposure": 0.6, "tint_hue": 230, "tint": 0.4},
         "glow": {"threshold": 0.5, "radius": 0.03, "intensity": 0.8, "saturation": 1.5, "tint_hue": 200, "tint": 0.5},
         "chromatic_aberration": {"amount": 0.01},
         "chroma_bleed": {"radius": 0.02},
         "glitch": {"slices": 8, "shift": 0.05, "rgb_split": 0.01},
         "scanlines": {"spacing": 0.02, "intensity": 0.3},
         "noise": {"amount": 0.2, "size": 0.01},
         "vignette": {"intensity": 0.6, "radius": 0.8}}
        """
        return try JSONDecoder().decode(LookEffects.self, from: Data(json.utf8))
    }

    private func sample(origin: CGPoint = .zero) -> CIImage {
        let checker = CIFilter.checkerboardGenerator()
        checker.color0 = CIColor(red: 0.9, green: 0.2, blue: 0.7)
        checker.color1 = CIColor(red: 0.1, green: 0.6, blue: 0.9)
        checker.width = 10
        checker.center = .zero
        return checker.outputImage!.cropped(to: CGRect(origin: origin, size: CGSize(width: 120, height: 90)))
    }

    private func pixels(_ image: CIImage) -> [UInt8] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: image.extent,
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    func testDecodesManifestKeys() throws {
        let effects = try allEffects()
        XCTAssertEqual(effects.chromaticAberration?.amount, 0.01)
        XCTAssertEqual(effects.chromaBleed?.radius, 0.02)
        XCTAssertEqual(effects.glitch?.slices, 8)
        XCTAssertEqual(effects.glitch?.rgbSplit, 0.01)
        XCTAssertEqual(effects.glow?.threshold, 0.5)
        XCTAssertEqual(effects.glow?.tintHue, 200)
        XCTAssertEqual(effects.gradient?.exposure, 0.6)
        XCTAssertEqual(effects.gradient?.tintHue, 230)
        XCTAssertFalse(effects.isEmpty)
        XCTAssertTrue(LookEffects.none.isEmpty)
    }

    func testTintColorHasUnitLuminanceAndTheRightHue() {
        let blue = LookEffects.tintColor(hue: 255)
        XCTAssertEqual(0.2126 * blue.r + 0.7152 * blue.g + 0.0722 * blue.b, 1, accuracy: 1e-6)
        XCTAssertGreaterThan(blue.b, blue.r, "Oklab 255° is blue")
        let orange = LookEffects.tintColor(hue: 55)
        XCTAssertGreaterThan(orange.r, orange.b, "Oklab 55° is orange")
    }

    func testGradientOnlyChangesTheTop() {
        let grey = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 100))
        let lifted = LookEffects(gradient: .init(size: 0.5, exposure: 1, tintHue: 255, tint: 0.5))
        let bytes = pixels(LookPipeline.applyEffects(lifted, to: grey))
        let original = pixels(grey)
        // Rows are top-down in the bitmap: the top row changes, the bottom row doesn't.
        let topRow = 0, bottomRow = 99
        XCTAssertGreaterThan(Int(bytes[topRow * 160 + 2]), Int(original[topRow * 160 + 2]) + 20, "top gets brighter and bluer")
        XCTAssertEqual(Array(bytes[(bottomRow * 160)..<(bottomRow * 160 + 3)]), Array(original[(bottomRow * 160)..<(bottomRow * 160 + 3)]))
    }

    func testOverclockLooksCarryTheirEffects() throws {
        let library = LookLibrary.bundled()
        for id in ["overdrive", "redline", "signal", "chrome", "hologram"] {
            let look = try XCTUnwrap(library.looks.first { $0.id == id }, "\(id) missing from filters.json")
            XCTAssertEqual(look.collectionID, "overclock", id)
            XCTAssertFalse(look.effects.isEmpty, "\(id) should have effects")
        }
        let boardwalk = try XCTUnwrap(library.looks.first { $0.id == "boardwalk" })
        XCTAssertTrue(boardwalk.effects.isEmpty, "colour-only looks have no effects")
    }

    func testNoEffectsOrZeroStrengthIsPassThrough() throws {
        let image = sample()
        XCTAssertTrue(LookPipeline.applyEffects(.none, to: image) === image)
        XCTAssertTrue(LookPipeline.applyEffects(try allEffects(), strength: 0, to: image) === image)
    }

    func testEffectsKeepExtent() throws {
        for origin in [CGPoint.zero, CGPoint(x: 10, y: 20)] {
            let image = sample(origin: origin)
            XCTAssertEqual(LookPipeline.applyEffects(try allEffects(), seed: 3, to: image).extent, image.extent)
        }
    }

    func testSameSeedRendersIdentically() throws {
        let effects = try allEffects()
        let first = pixels(LookPipeline.applyEffects(effects, seed: 7, to: sample()))
        let second = pixels(LookPipeline.applyEffects(effects, seed: 7, to: sample()))
        XCTAssertEqual(first, second, "a photo must render the same way every time")
        XCTAssertNotEqual(first, pixels(sample()), "effects should change the image")
    }

    func testSeedChangesTheGlitch() {
        let glitch = LookEffects(glitch: .init(slices: 8, shift: 0.2, rgbSplit: 0))
        let a = pixels(LookPipeline.applyEffects(glitch, seed: 1, to: sample()))
        let b = pixels(LookPipeline.applyEffects(glitch, seed: 2, to: sample()))
        XCTAssertNotEqual(a, b)
    }

    func testSeededGeneratorMatchesSplitMix64() {
        var generator = SeededGenerator(seed: 0)
        XCTAssertEqual(generator.next(), 0xE220_A839_7B1D_CDAF)
    }

    func testCaptureSeedIsStable() throws {
        let text = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        let a = try XCTUnwrap(UUID(uuidString: text))
        let b = try XCTUnwrap(UUID(uuidString: text))
        XCTAssertEqual(a.effectsSeed, b.effectsSeed)
        XCTAssertNotEqual(a.effectsSeed, UUID().effectsSeed)
    }
}
