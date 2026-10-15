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
         "halation": {"threshold": 0.2, "radius": 0.03, "intensity": 0.8},
         "glitch": {"slices": 8, "shift": 0.05, "rgb_split": 0.01},
         "light_leak": {"intensity": 0.6, "size": 0.5, "tint_hue": 45},
         "scanlines": {"spacing": 0.02, "intensity": 0.3},
         "noise": {"amount": 0.2, "size": 0.01},
         "grain": {"amount": 0.3, "size": 0.01, "roughness": 0.5, "color": 0.2},
         "dust": {"amount": 0.5, "scratches": 0.5},
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

    func testEffectLooksCarryTheirEffects() throws {
        let library = LookLibrary.bundled()
        let expected = ["overclock": ["overdrive", "redline", "signal", "chrome", "hologram"],
                        "darkroom": ["halo", "crossroad", "instant", "leak", "grit", "heirloom"]]
        for (collection, ids) in expected {
            for id in ids {
                let look = try XCTUnwrap(library.looks.first { $0.id == id }, "\(id) missing from filters.json")
                XCTAssertEqual(look.collectionID, collection, id)
                XCTAssertFalse(look.effects.isEmpty, "\(id) should have effects")
            }
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

    /// One effect at a time: real looks use a few each, and stacking all of
    /// them makes Core Image compile one huge filter graph (slow on CI).
    func testSameSeedRendersIdentically() throws {
        let all = try allEffects()
        let single: [(String, LookEffects)] = [
            ("gradient", LookEffects(gradient: all.gradient)), ("glow", LookEffects(glow: all.glow)),
            ("halation", LookEffects(halation: all.halation)),
            ("chromatic_aberration", LookEffects(chromaticAberration: all.chromaticAberration)),
            ("chroma_bleed", LookEffects(chromaBleed: all.chromaBleed)), ("glitch", LookEffects(glitch: all.glitch)),
            ("light_leak", LookEffects(lightLeak: all.lightLeak)), ("scanlines", LookEffects(scanlines: all.scanlines)),
            ("noise", LookEffects(noise: all.noise)), ("grain", LookEffects(grain: all.grain)),
            ("dust", LookEffects(dust: all.dust)), ("vignette", LookEffects(vignette: all.vignette)),
        ]
        let original = pixels(sample())
        for (name, effects) in single {
            let first = pixels(LookPipeline.applyEffects(effects, seed: 7, to: sample()))
            let second = pixels(LookPipeline.applyEffects(effects, seed: 7, to: sample()))
            XCTAssertEqual(first, second, "\(name): a photo must render the same way every time")
            XCTAssertNotEqual(first, original, "\(name) should change the image")
        }
    }

    func testSeedChangesTheGlitch() {
        let glitch = LookEffects(glitch: .init(slices: 8, shift: 0.2, rgbSplit: 0))
        let a = pixels(LookPipeline.applyEffects(glitch, seed: 1, to: sample()))
        let b = pixels(LookPipeline.applyEffects(glitch, seed: 2, to: sample()))
        XCTAssertNotEqual(a, b)
    }

    func testSeedMovesTheLightLeak() {
        let grey = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 90))
        let leak = LookEffects(lightLeak: .init(intensity: 0.8, size: 0.5, tintHue: 45))
        let renders = (1...6).map { pixels(LookPipeline.applyEffects(leak, seed: UInt64($0), to: grey)) }
        XCTAssertGreaterThan(Set(renders).count, 1, "each photo's leak should land differently")
    }

    func testGrainAddsNoColourCast() {
        let grey = CIImage(color: CIColor(red: 0.45, green: 0.45, blue: 0.45)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let grain = LookEffects(grain: .init(amount: 0.3, size: 0.01, roughness: 0.5, color: 0.2))
        let before = pixels(grey), after = pixels(LookPipeline.applyEffects(grain, seed: 9, to: grey))
        XCTAssertNotEqual(before, after, "grain should change pixels")
        for channel in 0..<3 {
            let mean = { (bytes: [UInt8]) in
                Double(stride(from: channel, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }) / Double(bytes.count / 4)
            }
            XCTAssertEqual(mean(after), mean(before), accuracy: 4, "channel \(channel) mean should barely move")
        }
    }

    func testHalationGlowsRedNotBlue() {
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let light = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 45, y: 45, width: 10, height: 10))
        let halation = LookEffects(halation: .init(threshold: 0.5, radius: 0.05, intensity: 1))
        let bytes = pixels(LookPipeline.applyEffects(halation, to: light.composited(over: black)))
        let near = (50 * 100 + 60) * 4 // just right of the light
        XCTAssertGreaterThan(bytes[near], 20, "a red halo appears")
        XCTAssertGreaterThan(bytes[near], bytes[near + 2], "red, never blue")
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
