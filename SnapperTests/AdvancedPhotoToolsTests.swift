import CoreImage
import ImageIO
import XCTest
@testable import Snapper

final class AdvancedRecipeTests: XCTestCase {
    func testLegacyRecipesKeepTheirAppearance() throws {
        let recipe = try JSONDecoder().decode(PhotoRecipe.self, from: Data(#"{"lookID":"cream","adjustments":{"warmth":0.2}}"#.utf8))
        XCTAssertEqual(recipe.adjustments, PhotoAdjustments(warmth: 0.2))
        XCTAssertEqual(recipe.selective, SelectiveEdits())
        XCTAssertFalse(recipe.requiresPremium)
        XCTAssertEqual(try JSONDecoder().decode(PhotoAdjustments.self, from: Data("{}".utf8)), .none)
    }

    func testAdvancedRecipeRoundTripIncludesBothAreasAndColorBands() throws {
        var recipe = PhotoRecipe.untouched
        recipe.adjustments = PhotoAdjustments(highlights: -0.3, shadows: 0.4, bloom: 0.2, halation: 0.1, vignette: 0.3)
        recipe.adjustments.colorMixer[.blue] = ColorMix(hue: 0.4, saturation: -0.6, luminance: 0.2)
        recipe.selective.subject.brightness = 0.3
        recipe.selective.background.saturation = -0.5
        XCTAssertEqual(try JSONDecoder().decode(PhotoRecipe.self, from: JSONEncoder().encode(recipe)), recipe)
        XCTAssertTrue(recipe.requiresPremium)
    }

    func testSlidersClampAndIgnoreNonfiniteInput() {
        for kind in PhotoAdjustments.Kind.allCases {
            var adjustments = PhotoAdjustments.none
            adjustments[kind] = 9
            XCTAssertEqual(adjustments[kind], kind.range.upperBound)
            adjustments[kind] = .nan
            XCTAssertEqual(adjustments[kind], kind.range.upperBound)
            adjustments[kind] = -9
            XCTAssertEqual(adjustments[kind], kind.range.lowerBound)
            XCTAssertTrue(adjustments.isValid)
        }
    }

    func testAdvancedPresetUsesVersionTwoAndKeepsPhotoSpecificEditsSeparate() throws {
        var recipe = PhotoRecipe(lookID: "cream", adjustments: PhotoAdjustments(bloom: 0.2))
        recipe.adjustments.colorMixer[.red] = ColorMix(hue: 0.2)
        recipe.selective.subject.brightness = 0.4
        let preset = SavedPreset(name: "Warm edges", recipe: recipe)
        let file = try PresetFile.decode(PresetDocument(preset).data, looks: .bundled())
        XCTAssertEqual(file.version, 2)
        XCTAssertEqual(file.recipe.adjustments, recipe.adjustments)
        XCTAssertFalse(file.recipe.selective.isActive)
        var target = PhotoRecipe.untouched
        target.selective.background.warmth = -0.5
        target.crop.shape = .square
        let applied = preset.applying(to: target)
        XCTAssertEqual(applied.selective, target.selective)
        XCTAssertEqual(applied.crop, target.crop)
        XCTAssertEqual(PresetFile(SavedPreset(name: "Basic", recipe: .untouched)).version, 1)
    }

    func testPresetRejectsInvalidColorBandsAndRanges() throws {
        let data = try PresetDocument(SavedPreset(name: "Basic", recipe: .untouched)).data
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (band, value) in [("red", 2.0), ("unknown", 0.1)] {
            var invalid = valid
            invalid["adjustments"] = ["colorMixer": ["bands": [band: ["hue": value, "saturation": 0, "luminance": 0]]]]
            XCTAssertThrowsError(try PresetFile.decode(JSONSerialization.data(withJSONObject: invalid), looks: .bundled()))
        }
    }

    func testCuratedRecipesHaveStableIDsAndAvailableLooks() {
        let collections = CuratedCollection.releases
        let styles = collections.flatMap(\.styles)
        XCTAssertEqual(Set(collections.map(\.id)).count, collections.count)
        XCTAssertEqual(Set(styles.map(\.id)).count, styles.count)
        for style in styles {
            XCTAssertNotNil(LookLibrary.bundled().look(id: style.recipe.lookID), style.id)
            XCTAssertTrue(style.recipe.adjustments.isValid, style.id)
            XCTAssertTrue(style.recipe.requiresPremium, style.id)
            XCTAssertFalse(style.tip.isEmpty)
        }
        for query in ["halation", "color mixer", "subject background", "curated"] {
            XCTAssertFalse(GuideCatalog.search(query).isEmpty, query)
        }
    }
}

final class AdvancedRenderingTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let extent = CGRect(x: 0, y: 0, width: 80, height: 60)
    private func grey(_ value: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value)).cropped(to: extent)
    }
    private func pixel(_ image: CIImage, x: CGFloat = 20, y: CGFloat = 30) -> [Double] {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return bytes.map { Double($0) / 255 }
    }
    private func mask() -> CIImage {
        CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 60))
            .composited(over: CIImage(color: .black).cropped(to: extent))
    }

    func testColorMixerTargetsRedAndPreservesBlueAndNeutral() {
        var mixer = ColorMixer()
        mixer[.red] = ColorMix(saturation: -1)
        let red = ColorMixRendering.transform(red: 1, green: 0, blue: 0, mixer: mixer)
        XCTAssertLessThan(red.0 - red.1, 0.2)
        let blue = ColorMixRendering.transform(red: 0, green: 0, blue: 1, mixer: mixer)
        XCTAssertEqual(blue.0, 0, accuracy: 0.0001)
        XCTAssertEqual(blue.2, 1, accuracy: 0.0001)
        let grey = ColorMixRendering.transform(red: 0.4, green: 0.4, blue: 0.4, mixer: mixer)
        XCTAssertEqual(grey.0, 0.4)
        XCTAssertEqual(grey.1, 0.4)
        XCTAssertEqual(grey.2, 0.4)
        let rendered = ColorMixRendering.apply(mixer, to: CIImage(color: .red).cropped(to: extent))
        let result = pixel(rendered)
        XCTAssertLessThan(result[0] - result[1], 0.2, "exercise the actual color cube, not only its generator")
        XCTAssertEqual(result[3], 1)
    }

    func testHueShiftWrapsAcrossRedWithoutInvalidChannels() {
        var mixer = ColorMixer()
        mixer[.red] = ColorMix(hue: -1, luminance: 0.3)
        let result = ColorMixRendering.transform(red: 1, green: 0, blue: 0.02, mixer: mixer)
        XCTAssertGreaterThan(result.2, 0.1)
        for value in [result.0, result.1, result.2] { XCTAssertTrue((0...1).contains(value)) }
    }

    func testHighlightsAndShadowsMoveTheirTonalRegions() {
        let dark = grey(0.25), light = grey(0.75)
        XCTAssertGreaterThan(pixel(PhotoEditing.adjust(dark, with: PhotoAdjustments(shadows: 0.8)))[1], pixel(dark)[1] + 0.05)
        XCTAssertLessThan(pixel(PhotoEditing.adjust(light, with: PhotoAdjustments(highlights: -0.8)))[1], pixel(light)[1] - 0.05)
        for value in [CGFloat(0), CGFloat(1)] {
            let image = grey(value)
            let result = PhotoEditing.adjust(image, with: PhotoAdjustments(highlights: -1, shadows: 1))
            XCTAssertEqual(pixel(result)[1], Double(value), accuracy: 0.02)
        }
    }

    func testFilmEffectsPreserveExtentAndVignetteDarkensEdges() {
        let image = grey(0.6)
        let result = PhotoEditing.adjust(image, with: PhotoAdjustments(bloom: 0.3, halation: 0.2, vignette: 0.8))
        XCTAssertEqual(result.extent, image.extent)
        XCTAssertEqual(pixel(result)[3], 1)
        XCTAssertLessThan(pixel(result, x: 1, y: 1)[1], pixel(result, x: 40, y: 30)[1])
    }

    func testSelectiveEditsAffectOnlyTheirAreaAndFollowCropAndFlip() {
        var recipe = PhotoRecipe.untouched
        recipe.selective.subject.brightness = 1
        recipe.selective.background.brightness = -1
        let result = PhotoEditing.apply(recipe, look: .original, lut: nil, seed: 0, to: grey(0.5), subjectMask: mask())
        XCTAssertGreaterThan(pixel(result, x: 10)[1], 0.55)
        XCTAssertLessThan(pixel(result, x: 70)[1], 0.45)
        recipe.crop = PhotoCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), isFlipped: true)
        let cropped = PhotoEditing.apply(recipe, look: .original, lut: nil, seed: 0, to: grey(0.5), subjectMask: mask())
        XCTAssertEqual(cropped.extent.width, 40)
        XCTAssertLessThan(pixel(cropped, x: 10)[1], 0.45, "left crop after a flip must select the original background")
    }

    func testSelectiveFailureBlocksExportButResetAllowsIt() async throws {
        let renderer = PhotoRenderer(detectSubject: { _ in nil })
        let source = try TestImages.jpeg(width: 80, height: 60)
        var recipe = PhotoRecipe.untouched
        recipe.selective.subject.brightness = 0.5
        do {
            _ = try await renderer.export(source: source, look: .original, recipe: recipe, watermark: false, format: .jpeg)
            XCTFail("An export must not silently discard selective edits")
        } catch PhotoRenderer.RenderError.subjectUnavailable {
            // Expected even if the simulator cannot run Vision.
        }
        recipe.selective = SelectiveEdits()
        let output = try await renderer.export(source: source, look: .original, recipe: recipe, watermark: false, format: .jpeg)
        XCTAssertFalse(output.isEmpty)
    }

    func testSelectivePreviewAndExportShareTheSameMask() async throws {
        let renderer = PhotoRenderer(detectSubject: { image in
            CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: image.extent.width / 2, height: image.extent.height))
                .composited(over: CIImage(color: .black).cropped(to: image.extent))
        })
        let data = try TestImages.jpeg(width: 160, height: 120)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var recipe = PhotoRecipe.untouched
        recipe.selective.subject.warmth = 0.8
        recipe.selective.background.saturation = -0.8
        let rendered = await renderer.preview(id: UUID(), sourceURL: url, look: .original, recipe: recipe)
        let preview = try XCTUnwrap(rendered?.cgImage)
        let output = try await renderer.export(source: data, look: .original, recipe: recipe, watermark: false, format: .jpeg, sourceURL: url)
        let exported = try XCTUnwrap(CIImage(data: output))
        XCTAssertEqual(exported.extent.width, CGFloat(preview.width))
        for x in [CGFloat(20), CGFloat(140)] {
            let before = pixel(CIImage(cgImage: preview), x: x), after = pixel(exported, x: x)
            for channel in 0..<3 { XCTAssertEqual(before[channel], after[channel], accuracy: 0.05) }
        }
    }
}

@MainActor
final class AdvancedWorkflowTests: XCTestCase {
    func testPremiumToolsPreviewUndoAndExportGates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let looks = LookLibrary.bundled()
        let renderer = PhotoRenderer(detectSubject: { CIImage(color: .white).cropped(to: $0.extent) })
        let library = CaptureLibrary(library: looks, renderer: renderer, store: CaptureStore(directory: directory))
        let record = try await library.importPhoto(TestImages.jpeg(width: 80, height: 60))
        let purchase = FakePurchaseService()
        var requests = 0
        let editor = EditorModel(library: library, looks: looks, settings: AppSettings(defaults: defaults), id: record.id,
                                 hasPremium: { purchase.isPremium }, requestPremium: { _, _, _ in requests += 1 })
        editor.setColorMix(ColorMix(hue: 0.2), for: .red)
        editor.interaction(began: false)
        XCTAssertTrue(editor.isLocked)
        editor.save(); editor.share()
        XCTAssertEqual(requests, 2)
        editor.undo()
        XCTAssertFalse(editor.isLocked)
        editor.redo()
        XCTAssertEqual(editor.recipe.adjustments.colorMixer[.red].hue, 0.2)
        editor.resetColorMix()
        await editor.prepareSelective()
        XCTAssertNotNil(editor.subjectMaskPreview)
        editor.setSelective(0.5, key: \.brightness, background: false)
        editor.interaction(began: false)
        XCTAssertTrue(editor.isLocked)
        purchase.isPremium = true
        XCTAssertFalse(editor.isLocked)
        purchase.isPremium = false
        editor.resetSelective()
        XCTAssertFalse(editor.isLocked)
        let style = try XCTUnwrap(CuratedCollection.releases.first?.styles.first)
        editor.applyCuratedStyle(style)
        XCTAssertEqual(editor.recipe.adjustments, style.recipe.adjustments)
        XCTAssertTrue(editor.isLocked)
        editor.undo()
        XCTAssertFalse(editor.isLocked)
        editor.finish()
    }

    func testAdvancedPresetRemainsStoredAfterExpiryButCannotBypassEntitlement() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PresetStore(defaults: defaults)
        let recipe = PhotoRecipe(lookID: Look.original.id, adjustments: PhotoAdjustments(bloom: 0.2))
        let preset = try store.save(name: "Glow", recipe: recipe, hasPremium: true)
        XCTAssertFalse(store.canUse(preset, hasPremium: false))
        XCTAssertTrue(store.canUse(preset, hasPremium: true))
        XCTAssertEqual(PresetStore(defaults: defaults).presets.first?.adjustments, recipe.adjustments)
    }
}
