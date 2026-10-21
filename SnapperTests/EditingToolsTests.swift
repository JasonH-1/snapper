import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Snapper

/// Shared pixel helpers for the rendering tests below.
private enum Pixels {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func grey(_ value: CGFloat, size: CGSize = CGSize(width: 80, height: 60)) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value)).cropped(to: CGRect(origin: .zero, size: size))
    }

    static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    /// sRGB-encoded RGBA, 0…1, of one pixel (Core Image coordinates).
    static func at(_ image: CIImage, x: CGFloat = 2, y: CGFloat = 2) -> [Double] {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: sRGB)
        return bytes.map { Double($0) / 255 }
    }

    /// The red channel of one mask pixel, with no colour conversion.
    static func mask(_ image: CIImage, x: CGFloat, y: CGFloat) -> Double {
        var byte: UInt8 = 0
        context.render(image, toBitmap: &byte, rowBytes: 1, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .R8, colorSpace: nil)
        return Double(byte) / 255
    }
}

// MARK: - Curves

final class ToneCurveTests: XCTestCase {
    func testIdentityCurveChangesNothing() {
        let curve = ToneCurve.identity
        XCTAssertTrue(curve.isIdentity)
        XCTAssertTrue(curve.isValid)
        for (index, value) in curve.table(count: 11).enumerated() {
            XCTAssertEqual(value, Double(index) / 10, accuracy: 1e-9)
        }
    }

    func testAddingAPointKeepsTheCurveUntilItMoves() throws {
        var curve = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)])
        let before = curve.table(count: 64)
        let index = try XCTUnwrap(curve.addPoint(atInput: 0.25))
        XCTAssertEqual(curve.points[index].x, 0.25)
        for (old, new) in zip(before, curve.table(count: 64)) {
            XCTAssertEqual(old, new, accuracy: 0.02)
        }
        XCTAssertNil(curve.addPoint(atInput: 0.26), "too close to the point just added")
    }

    func testPointsStayBetweenNeighboursAndEndsOnlyMoveUpAndDown() throws {
        var curve = ToneCurve()
        let index = try XCTUnwrap(curve.addPoint(atInput: 0.5))
        curve.movePoint(at: index, to: CurvePoint(x: 1.4, y: 2))
        XCTAssertEqual(curve.points[index].y, 1)
        XCTAssertLessThanOrEqual(curve.points[index].x, 1 - ToneCurve.minimumSpacing + 1e-9)
        curve.movePoint(at: 0, to: CurvePoint(x: 0.3, y: 0.1))
        XCTAssertEqual(curve.points[0].x, 0)
        XCTAssertEqual(curve.points[0].y, 0.1, accuracy: 1e-9)
        curve.removePoint(at: 0)
        XCTAssertEqual(curve.points.count, 3, "the ends always stay")
        curve.removePoint(at: index)
        XCTAssertEqual(curve.points.count, 2)
        XCTAssertTrue(curve.isValid)
    }

    func testCurvesNeverOvershoot() {
        let curve = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.2, y: 0.05), CurvePoint(x: 0.3, y: 0.9),
                                       CurvePoint(x: 0.7, y: 0.95), CurvePoint(x: 1, y: 1)])
        let table = curve.table(count: 512)
        for (a, b) in zip(table, table.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b, a - 1e-12, "a rising curve must not dip")
        }
        XCTAssertTrue(table.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(curve.value(at: 0.3), 0.9, accuracy: 1e-9)
    }

    func testDamagedCurvesAreRejected() throws {
        let data = Data(#"{"rgb":{"points":[{"x":0,"y":0},{"x":0.8,"y":0.2},{"x":0.4,"y":0.5},{"x":1,"y":1}]}}"#.utf8)
        let curves = try JSONDecoder().decode(ToneCurves.self, from: data)
        XCTAssertFalse(curves.isValid)
        var adjustments = PhotoAdjustments.none
        adjustments.curves = curves
        XCTAssertFalse(adjustments.isValid, "presets and recipes with an unsorted curve are refused")
    }

    func testCurvesRoundTripAndNeedPremiumAndANewPresetVersion() throws {
        var recipe = PhotoRecipe(lookID: "cream")
        recipe.adjustments.curves.rgb = ToneCurve(points: [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 0.95)])
        recipe.adjustments.splitToning = SplitToning(highlightHue: 40, highlightSaturation: 0.4, shadowHue: 210, shadowSaturation: 0.3, balance: 0.2)
        XCTAssertEqual(try JSONDecoder().decode(PhotoRecipe.self, from: JSONEncoder().encode(recipe)), recipe)
        XCTAssertTrue(recipe.requiresPremium)
        let file = try PresetFile.decode(PresetDocument(SavedPreset(name: "Faded", recipe: recipe)).data, looks: .bundled())
        XCTAssertEqual(file.version, 3)
        XCTAssertEqual(file.recipe.adjustments, recipe.adjustments)
        // Recipes without the new tools are written exactly as before.
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PhotoAdjustments(warmth: 0.2))) as? [String: Any]
        XCTAssertNil(plain?["curves"])
        XCTAssertNil(plain?["splitToning"])
    }

    func testRGBCurveWorksOnVisibleTonesAndChannelsSeparately() {
        var adjustments = PhotoAdjustments.none
        adjustments.curves.rgb = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.75), CurvePoint(x: 1, y: 1)])
        let lifted = Pixels.at(PhotoEditing.adjust(Pixels.grey(0.5), with: adjustments))
        // The curve's grid is sRGB values: mid-grey goes where the curve says.
        XCTAssertEqual(lifted[0], 0.75, accuracy: 0.03)
        XCTAssertEqual(lifted[1], 0.75, accuracy: 0.03)

        var redOnly = PhotoAdjustments.none
        redOnly.curves.red = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0)])
        let cut = Pixels.at(PhotoEditing.adjust(Pixels.grey(0.6), with: redOnly))
        XCTAssertLessThan(cut[0], 0.05)
        XCTAssertEqual(cut[1], 0.6, accuracy: 0.03)
        XCTAssertEqual(cut[2], 0.6, accuracy: 0.03)
    }

    func testChannelCurveRunsBeforeTheRGBCurve() {
        var curves = ToneCurves()
        curves.red = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0.5)])
        curves.rgb = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 1), CurvePoint(x: 1, y: 1)])
        let tables = curves.tables(count: 3)
        XCTAssertEqual(tables.red[2], 1, accuracy: 1e-9, "red 1 → 0.5 by its own curve, then → 1 by RGB")
        XCTAssertEqual(tables.green[1], 1, accuracy: 1e-9)
    }
}

// MARK: - Split toning

final class SplitToningTests: XCTestCase {
    private let warmAndCool = SplitToning(highlightHue: 40, highlightSaturation: 0.8, shadowHue: 220, shadowSaturation: 0.8, balance: 0)

    func testOffDoesNothing() {
        let out = ToneRendering.splitTone(red: 0.3, green: 0.5, blue: 0.7, with: SplitToning())
        XCTAssertEqual(out.0, 0.3)
        XCTAssertEqual(out.2, 0.7)
        XCTAssertFalse(SplitToning(highlightHue: 120).isActive, "a hue alone tints nothing")
    }

    func testHighlightsWarmShadowsCoolAndBrightnessStays() {
        let bright = ToneRendering.splitTone(red: 0.8, green: 0.8, blue: 0.8, with: warmAndCool)
        XCTAssertGreaterThan(bright.0, bright.2 + 0.05, "bright tones take the warm tint")
        let dark = ToneRendering.splitTone(red: 0.15, green: 0.15, blue: 0.15, with: warmAndCool)
        XCTAssertGreaterThan(dark.2, dark.0 + 0.02, "dark tones take the cool tint")
        for value in [0.15, 0.5, 0.8] {
            let toned = ToneRendering.splitTone(red: value, green: value, blue: value, with: warmAndCool)
            let before = ToneRendering.Oklab(linearRed: ToneRendering.linear(value), green: ToneRendering.linear(value),
                                             blue: ToneRendering.linear(value))
            let after = ToneRendering.Oklab(linearRed: ToneRendering.linear(toned.0), green: ToneRendering.linear(toned.1),
                                            blue: ToneRendering.linear(toned.2))
            XCTAssertEqual(after.L, before.L, accuracy: 0.02)
        }
        let black = ToneRendering.splitTone(red: 0, green: 0, blue: 0, with: warmAndCool)
        XCTAssertEqual(black.2, 0, accuracy: 0.01, "black stays black")
    }

    func testBalanceMovesWhereTheTintsMeet() {
        let mid = 0.5
        let favoursHighlights = ToneRendering.toneWeights(lightness: mid, balance: 1)
        let favoursShadows = ToneRendering.toneWeights(lightness: mid, balance: -1)
        XCTAssertGreaterThan(favoursHighlights.highlights, favoursShadows.highlights)
        XCTAssertGreaterThan(favoursShadows.shadows, favoursHighlights.shadows)
    }

    func testRenderedThroughThePipeline() {
        var adjustments = PhotoAdjustments.none
        adjustments.splitToning = warmAndCool
        let bright = Pixels.at(PhotoEditing.adjust(Pixels.grey(0.85), with: adjustments))
        XCTAssertGreaterThan(bright[0], bright[2] + 0.04)
        let dark = Pixels.at(PhotoEditing.adjust(Pixels.grey(0.12), with: adjustments))
        XCTAssertGreaterThan(dark[2], dark[0] + 0.01)
    }
}

// MARK: - Framing and the mask brush

final class MaskBrushTests: XCTestCase {
    private let size = CGSize(width: 120, height: 90)

    private func crops() -> [PhotoCrop] {
        [PhotoCrop(),
         PhotoCrop(rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6), shape: .free),
         PhotoCrop(rect: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.5), shape: .free, quarterTurns: 1, isFlipped: true),
         PhotoCrop(shape: .square, straighten: 12, quarterTurns: 3),
         PhotoCrop(rect: CGRect(x: 0, y: 0, width: 0.7, height: 0.9), shape: .free, straighten: -20, quarterTurns: 2, isFlipped: true)]
    }

    func testFrameTransformMatchesFraming() {
        let image = Pixels.grey(0.5, size: size)
        for crop in crops() {
            let framed = PhotoEditing.frame(image, with: crop)
            let geometry = PhotoEditing.frameTransform(for: crop, imageSize: size)
            XCTAssertEqual(framed.extent.width, geometry.size.width, accuracy: 1, "\(crop)")
            XCTAssertEqual(framed.extent.height, geometry.size.height, accuracy: 1, "\(crop)")
            for point in [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.62, y: 0.33)] {
                let there = PhotoEditing.originalPoint(fromFramed: point, crop: crop, imageSize: size)
                let back = PhotoEditing.framedPoint(fromOriginal: there, crop: crop, imageSize: size)
                XCTAssertEqual(back.x, point.x, accuracy: 1e-6)
                XCTAssertEqual(back.y, point.y, accuracy: 1e-6)
            }
        }
    }

    /// A white dot in the original lands exactly where the mapping says, in
    /// the framed photo.
    func testMappedPointsFollowThePixels() throws {
        let dot = CGPoint(x: 0.4, y: 0.35) // original, from the top left
        let pixel = CGRect(x: dot.x * size.width - 1.5, y: (1 - dot.y) * size.height - 1.5, width: 3, height: 3)
        let image = CIImage(color: .white).cropped(to: pixel).composited(over: Pixels.grey(0, size: size))
        for crop in crops() where abs(crop.straighten) < 0.001 {
            let framed = PhotoEditing.frame(image, with: crop)
            let expected = PhotoEditing.framedPoint(fromOriginal: dot, crop: crop, imageSize: size)
            guard (0...1).contains(expected.x), (0...1).contains(expected.y) else { continue }
            let x = expected.x * framed.extent.width, y = (1 - expected.y) * framed.extent.height
            XCTAssertGreaterThan(Pixels.at(framed, x: x.rounded(.down), y: y.rounded(.down))[0], 0.5, "\(crop)")
        }
    }

    func testPaintAndEraseChangeTheMaskWhereTheStrokeIs() throws {
        let paint = MaskStroke(mode: .paint, radius: 0.1, softness: 0, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.3, y: 0.2)])
        let painted = try XCTUnwrap(MaskBrush.apply([paint], to: nil, size: CGSize(width: 200, height: 100), context: Pixels.context))
        XCTAssertEqual(painted.extent.size, CGSize(width: 200, height: 100))
        // Near the top left (Core Image's y counts from the bottom).
        XCTAssertGreaterThan(Pixels.mask(painted, x: 50, y: 80), 0.95)
        XCTAssertLessThan(Pixels.mask(painted, x: 150, y: 20), 0.05)

        let full = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        let erase = MaskStroke(mode: .erase, radius: 0.1, softness: 0, points: [CGPoint(x: 0.5, y: 0.5)])
        let erased = try XCTUnwrap(MaskBrush.apply([erase], to: full, size: .zero, context: Pixels.context))
        XCTAssertLessThan(Pixels.mask(erased, x: 100, y: 50), 0.05)
        XCTAssertGreaterThan(Pixels.mask(erased, x: 10, y: 10), 0.95, "outside the stroke stays selected")

        // The detected mask keeps its way up when strokes are drawn onto it.
        let topHalf = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 50, width: 200, height: 50))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)))
        let corner = MaskStroke(mode: .erase, radius: 0.05, softness: 0, points: [CGPoint(x: 0.95, y: 0.95)])
        let kept = try XCTUnwrap(MaskBrush.apply([corner], to: topHalf, size: .zero, context: Pixels.context))
        XCTAssertGreaterThan(Pixels.mask(kept, x: 20, y: 90), 0.95)
        XCTAssertLessThan(Pixels.mask(kept, x: 20, y: 10), 0.05)

        // In order: painting back over an erased spot selects it again.
        let repaint = MaskStroke(mode: .paint, radius: 0.05, softness: 0, points: [CGPoint(x: 0.5, y: 0.5)])
        let restored = try XCTUnwrap(MaskBrush.apply([erase, repaint], to: full, size: .zero, context: Pixels.context))
        XCTAssertGreaterThan(Pixels.mask(restored, x: 100, y: 50), 0.95)
    }

    func testSoftnessFeathersTheEdgeWithoutBuildUp() throws {
        let points = (0...20).map { CGPoint(x: 0.2 + Double($0) * 0.03, y: 0.5) }
        let size = CGSize(width: 200, height: 200)
        let hard = try XCTUnwrap(MaskBrush.apply([MaskStroke(mode: .paint, radius: 0.1, softness: 0, points: points)],
                                                 to: nil, size: size, context: Pixels.context))
        let soft = try XCTUnwrap(MaskBrush.apply([MaskStroke(mode: .paint, radius: 0.1, softness: 1, points: points)],
                                                 to: nil, size: size, context: Pixels.context))
        // 15 px from the stroke's line, three quarters of the radius out.
        XCTAssertGreaterThan(Pixels.mask(hard, x: 100, y: 115), 0.9)
        let edge = Pixels.mask(soft, x: 100, y: 115)
        XCTAssertLessThan(edge, 0.5, "many overlapping dabs must not harden a soft edge")
        XCTAssertGreaterThan(edge, 0.02)
        XCTAssertGreaterThan(Pixels.mask(soft, x: 100, y: 100), 0.9, "the centre is fully selected")
    }

    func testDamagedStrokesAreDroppedOnLoad() throws {
        let data = Data(#"{"subject":{"brightness":0.2,"saturation":0,"warmth":0},"strokes":[{"mode":"paint","radius":9,"softness":0.5,"points":[[0.5,0.5]]},{"mode":"erase","radius":0.1,"softness":0.5,"points":[[0.5,0.5]]}]}"#.utf8)
        let edits = try JSONDecoder().decode(SelectiveEdits.self, from: data)
        XCTAssertEqual(edits.strokes.map(\.mode), [.erase])
        XCTAssertTrue(edits.usesSubjectDetection)
        XCTAssertEqual(edits.subject.brightness, 0.2)
        // Selections written before the brush still load.
        let legacy = try JSONDecoder().decode(SelectiveEdits.self, from: Data(#"{"subject":{"brightness":0,"saturation":0,"warmth":0.1},"background":{"brightness":0,"saturation":0,"warmth":0}}"#.utf8))
        XCTAssertEqual(legacy.subject.warmth, 0.1)
        XCTAssertTrue(legacy.strokes.isEmpty)
    }

    /// No subject detected: painting the area from scratch edits only it,
    /// the same in preview and export.
    func testPaintedSelectionWithoutDetectionEditsOnlyThePaintedArea() async throws {
        let renderer = PhotoRenderer(detectSubject: { _ in nil })
        let data = try TestImages.jpeg(width: 160, height: 120)
        var recipe = PhotoRecipe.untouched
        recipe.selective.usesSubjectDetection = false
        recipe.selective.subject.brightness = 1
        recipe.selective.strokes = [MaskStroke(mode: .paint, radius: 0.2, softness: 0,
                                               points: [CGPoint(x: 0.2, y: 0.5)])]
        let output = try await renderer.export(source: data, look: .original, recipe: recipe, watermark: false, format: .jpeg)
        let image = try XCTUnwrap(CIImage(data: output))
        let painted = Pixels.at(image, x: 32, y: 60), untouched = Pixels.at(image, x: 140, y: 60)
        XCTAssertGreaterThan(painted[1], untouched[1] + 0.08)
    }

    func testBrushCorrectsADetectedSubject() async throws {
        // Vision isn't available in the Simulator; this stands in for it.
        let renderer = PhotoRenderer(detectSubject: { image in
            CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: image.extent.width / 2, height: image.extent.height))
                .composited(over: CIImage(color: .black).cropped(to: image.extent))
        })
        let data = try TestImages.jpeg(width: 160, height: 120)
        var recipe = PhotoRecipe.untouched
        recipe.selective.subject.brightness = 1
        // Erase the subject's top-left corner, paint some background in.
        recipe.selective.strokes = [MaskStroke(mode: .erase, radius: 0.15, softness: 0, points: [CGPoint(x: 0.1, y: 0.15)]),
                                    MaskStroke(mode: .paint, radius: 0.15, softness: 0, points: [CGPoint(x: 0.85, y: 0.85)])]
        let output = try await renderer.export(source: data, look: .original, recipe: recipe, watermark: false, format: .jpeg)
        let image = try XCTUnwrap(CIImage(data: output))
        let subject = Pixels.at(image, x: 40, y: 40)
        let erased = Pixels.at(image, x: 16, y: 102)
        let added = Pixels.at(image, x: 136, y: 18)
        let background = Pixels.at(image, x: 120, y: 100)
        XCTAssertGreaterThan(subject[1], background[1] + 0.08)
        XCTAssertEqual(erased[1], background[1], accuracy: 0.04)
        XCTAssertEqual(added[1], subject[1], accuracy: 0.04)
    }
}

// MARK: - Versions

@MainActor
final class PhotoVersionTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        suiteName = UUID().uuidString
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeEditor() async throws -> (EditorModel, CaptureLibrary) {
        let looks = LookLibrary.bundled()
        let library = CaptureLibrary(library: looks, renderer: PhotoRenderer(), store: CaptureStore(directory: directory))
        let record = try await library.importPhoto(TestImages.jpeg(width: 64, height: 48))
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let editor = EditorModel(library: library, looks: looks, settings: settings, id: record.id,
                                 hasPremium: { true }, requestPremium: { _, _, _ in })
        return (editor, library)
    }

    func testVersionsKeepTheirOwnEditsAndSwitchingLosesNothing() async throws {
        let (editor, library) = try await makeEditor()
        editor.setValue(0.4, for: .warmth)
        editor.saveVersion(named: "Warm")
        let warm = try XCTUnwrap(editor.versions.first)
        XCTAssertEqual(editor.versionLabel, "Warm")

        editor.createVersion(named: "Black & White", from: editor.originalRecipe)
        editor.setValue(-1, for: .saturation)
        editor.commit()
        let mono = try XCTUnwrap(editor.versions.last)
        XCTAssertEqual(mono.recipe.adjustments.saturation, -1, "the version showing keeps every change")
        XCTAssertEqual(editor.versions.first?.recipe.adjustments.warmth, 0.4, "the other version is untouched")

        editor.switchTo(warm.recipe, version: warm)
        XCTAssertEqual(editor.recipe.adjustments.warmth, 0.4)
        XCTAssertEqual(editor.recipe.adjustments.saturation, 0)
        XCTAssertFalse(editor.canUndo, "undo never reaches into another version")

        // An edit made on the original, then switched away from, is kept.
        editor.switchTo(editor.originalRecipe, version: nil)
        editor.setValue(0.3, for: .contrast)
        editor.commit()
        XCTAssertTrue(editor.hasUnkeptEdit)
        editor.switchTo(mono.recipe, version: mono)
        XCTAssertEqual(editor.versions.count, 3)
        XCTAssertTrue(editor.versions.contains { $0.recipe.adjustments.contrast == 0.3 })
        XCTAssertNotNil(editor.versionNotice)

        // Everything is stored on the photo, and survives a reload.
        let record = try XCTUnwrap(library.record(id: editor.id))
        XCTAssertEqual(record.versions.count, 3)
        XCTAssertEqual(record.activeVersionID, mono.id)
        let reloaded = try JSONDecoder().decode(CaptureRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(reloaded.versions, record.versions)
        XCTAssertEqual(reloaded.activeVersionID, mono.id)
    }

    func testRenameDeleteAndLimit() async throws {
        let (editor, library) = try await makeEditor()
        editor.saveVersion(named: "  First  ")
        let first = try XCTUnwrap(editor.versions.first)
        XCTAssertEqual(first.name, "First")
        editor.renameVersion(first, to: "   ")
        XCTAssertEqual(editor.versions.first?.name, "First", "an empty name is refused")
        XCTAssertNotNil(editor.alert)
        editor.renameVersion(first, to: "Moody")
        XCTAssertEqual(editor.versions.first?.name, "Moody")
        editor.deleteVersion(first)
        XCTAssertTrue(editor.versions.isEmpty)
        XCTAssertNil(library.record(id: editor.id)?.activeVersionID)

        for index in 0..<PhotoVersion.maxCount {
            _ = try library.saveVersion(photoID: editor.id, name: "V\(index)", recipe: .untouched)
        }
        XCTAssertThrowsError(try library.saveVersion(photoID: editor.id, name: "One too many", recipe: .untouched))
    }

    func testOldRecordsLoadWithoutVersions() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","createdAt":0,"fileName":"a.jpg","source":"camera","isFrontCamera":false,"recipe":{"lookID":"original"},"initialRecipe":{"lookID":"original"}}"#
        let record = try JSONDecoder().decode(CaptureRecord.self, from: Data(json.utf8))
        XCTAssertTrue(record.versions.isEmpty)
        XCTAssertNil(record.activeVersionID)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        XCTAssertNil(encoded?["versions"], "photos without versions are stored as before")
    }

    func testSuggestedNamesDescribeTheEditAndStayUnique() {
        var mono = PhotoRecipe.untouched
        mono.adjustments.saturation = -1
        XCTAssertEqual(PhotoVersion.suggestedName(for: mono, look: .original, existing: []), "Black & White")
        let existing = [PhotoVersion(name: "Black & White", recipe: mono)]
        XCTAssertEqual(PhotoVersion.suggestedName(for: mono, look: .original, existing: existing), "Black & White 2")
        var warm = PhotoRecipe.untouched
        warm.adjustments.warmth = 0.5
        XCTAssertEqual(PhotoVersion.suggestedName(for: warm, look: .original, existing: []), "Warm")
    }
}

// MARK: - Export options

final class ExportOptionsTests: XCTestCase {
    func testOutputSizeScalesDownNeverUp() {
        let photo = CGSize(width: 4032, height: 3024)
        XCTAssertEqual(ExportOptions(size: .full).outputSize(for: photo), photo)
        XCTAssertEqual(ExportOptions(size: .small).outputSize(for: photo), CGSize(width: 1080, height: 810))
        XCTAssertEqual(ExportOptions(size: .medium).outputSize(for: CGSize(width: 1200, height: 1600)), CGSize(width: 1200, height: 1600))
        XCTAssertEqual(ExportOptions(size: .large).outputSize(for: CGSize(width: 3000, height: 6000)), CGSize(width: 1920, height: 3840))
    }

    func testHEIFNeverAsksForLosslessAndBadValuesAreRepaired() throws {
        XCTAssertEqual(ExportOptions(format: .heic, quality: 1).encoderQuality, 0.98)
        XCTAssertEqual(ExportOptions(format: .jpeg, quality: 1).encoderQuality, 1)
        let options = try JSONDecoder().decode(ExportOptions.self, from: Data(#"{"format":"tiff","quality":7}"#.utf8))
        XCTAssertEqual(options.format, .heic)
        XCTAssertEqual(options.quality, 1)
        XCTAssertTrue(options.includesLocation)
    }

    @MainActor
    func testSettingsKeepTheOptionsAndReadTheOldFormatSetting() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("jpeg", forKey: "photos.format")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.exportOptions.format, .jpeg, "the format chosen before export options is kept")
        settings.exportOptions.size = .medium
        settings.exportOptions.includesLocation = false
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.exportOptions.size, .medium)
        XCTAssertFalse(reloaded.exportOptions.includesLocation)
        XCTAssertEqual(reloaded.photoFormat, .jpeg)
    }

    /// A photo with a place in every field that can hold one, plus details
    /// that aren't a place.
    private func photoWithLocation(type: UTType, orientation: Int) throws -> Data {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E"]
        let iptc: [CFString: Any] = [kCGImagePropertyIPTCCity: "Paris", kCGImagePropertyIPTCProvinceState: "Île-de-France",
                                     kCGImagePropertyIPTCSubLocation: "Champ de Mars",
                                     kCGImagePropertyIPTCCountryPrimaryLocationName: "France", kCGImagePropertyIPTCKeywords: ["tower"]]
        let exif: [CFString: Any] = [kCGImagePropertyExifLensModel: "Test Lens"]
        let apple: [String: Any] = ["8": [0.1, 0.2, 0.3]]
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(XCTUnwrap(CGImageSourceCreateWithData(photoWithLocation() as CFData, nil)), 0, nil))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyIPTCDictionary: iptc,
                                                        kCGImagePropertyExifDictionary: exif, kCGImagePropertyMakerAppleDictionary: apple,
                                                        kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The decoded pixels, to tell a copy from a re-encode.
    private func pixels(_ data: Data) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(image.dataProvider?.data as Data?)
    }

    private func photoWithLocation() throws -> Data {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E"]
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Detail, so quality makes a difference to the size.
        for index in 0..<400 {
            context.setFillColor(CGColor(red: CGFloat(index % 7) / 7, green: CGFloat(index % 13) / 13, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: index, y: (index * 37) % 300, width: 1, height: 300 - (index * 37) % 300))
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let iptc: [CFString: Any] = [kCGImagePropertyIPTCCity: "Paris", kCGImagePropertyIPTCKeywords: ["tower"]]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: gps,
                                                        kCGImagePropertyIPTCDictionary: iptc] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func testLocationIsKeptOrLeftOut() async throws {
        let renderer = PhotoRenderer()
        let source = try photoWithLocation()
        XCTAssertNotNil(try properties(source)[kCGImagePropertyGPSDictionary])
        let kept = try await renderer.export(source: source, look: .original, recipe: .untouched, watermark: false,
                                             options: ExportOptions(format: .jpeg, includesLocation: true))
        XCTAssertNotNil(try properties(kept)[kCGImagePropertyGPSDictionary])
        for format in PhotoRenderer.ExportFormat.allCases {
            let options = ExportOptions(format: format, includesLocation: false)
            guard let stripped = try? await renderer.export(source: source, look: .original, recipe: .untouched,
                                                            watermark: false, options: options) else {
                // Some Simulators can't encode HEIF; JPEG always runs.
                XCTAssertEqual(format, .heic)
                continue
            }
            let result = try properties(stripped)
            XCTAssertNil(result[kCGImagePropertyGPSDictionary], "\(format)")
            let iptc = result[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
            XCTAssertNil(iptc?[kCGImagePropertyIPTCCity], "\(format)")
        }
    }

    @MainActor
    func testLocationOffAlsoSanitizesAdditionalOriginalAndKeepsSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try photoWithLocation()
        let received = Locked<[Data]>([])
        let captures = CaptureLibrary(library: .bundled(), renderer: PhotoRenderer(),
                                      store: CaptureStore(directory: directory), photoSaver: { edited, original in
            let original = try XCTUnwrap(original)
            let files = try [Data(contentsOf: edited), Data(contentsOf: original)]
            received.withLock { $0 = files }
        })
        let record = try await captures.importPhoto(source)
        var recipe = record.recipe
        recipe.crop = PhotoCrop(shape: .square)
        try await captures.saveToPhotos(record, recipe: recipe, includeOriginal: true,
                                        options: ExportOptions(format: .jpeg, includesLocation: false))
        let copies = received.withLock { $0 }
        XCTAssertEqual(copies.count, 2)
        for data in copies {
            let metadata = try properties(data)
            XCTAssertNil(metadata[kCGImagePropertyGPSDictionary])
            XCTAssertNil((metadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCCity])
        }
        XCTAssertEqual(try properties(copies[0])[kCGImagePropertyPixelWidth] as? Int, 300)
        XCTAssertEqual(try properties(copies[1])[kCGImagePropertyPixelWidth] as? Int, 400, "original stays uncropped")
        // The original isn't re-encoded: same pixels, and its other metadata stays.
        XCTAssertEqual(try pixels(copies[1]), try pixels(source))
        XCTAssertEqual((try properties(copies[1])[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCKeywords] as? [String],
                       ["tower"])
        XCTAssertEqual(try Data(contentsOf: captures.url(for: record)), source)
        try await captures.flush()
        // Location on preserves the byte-for-byte additional original.
        try await captures.saveToPhotos(record, includeOriginal: true,
                                        options: ExportOptions(format: .jpeg, includesLocation: true))
        XCTAssertEqual(received.withLock { $0.last }, source)
        try await captures.flush()
    }

    /// The location-free original is a lossless copy in its own format, with
    /// orientation, capture details and Apple's maker note kept.
    func testCopyWithoutLocationIsLosslessForJPEGAndHEIF() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for type in [UTType.jpeg, UTType.heic] {
            let source = folder.appendingPathComponent("source").appendingPathExtension(try XCTUnwrap(type.preferredFilenameExtension))
            try photoWithLocation(type: type, orientation: 6).write(to: source)
            XCTAssertTrue(PhotoRenderer.hasLocation(source))
            let output = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: folder, create: true)
            let copy = try PhotoRenderer.copyWithoutLocation(from: source, into: output)
            XCTAssertEqual(copy.pathExtension, type.preferredFilenameExtension)
            XCTAssertFalse(PhotoRenderer.hasLocation(copy), type.identifier)
            let copied = try Data(contentsOf: copy)
            XCTAssertEqual(try pixels(copied), try pixels(Data(contentsOf: source)), type.identifier)
            let metadata = try properties(copied)
            XCTAssertEqual(metadata[kCGImagePropertyOrientation] as? Int, 6)
            XCTAssertEqual((metadata[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel] as? String, "Test Lens")
            XCTAssertNotNil(metadata[kCGImagePropertyMakerAppleDictionary], "exposure and HDR data, no location")
            let iptc = metadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            for key in [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCSubLocation,
                        kCGImagePropertyIPTCCountryPrimaryLocationName] {
                XCTAssertNil(iptc[key], "\(type.identifier) \(key)")
            }
        }
    }

    func testSizeAndQualityChangeTheFile() async throws {
        let renderer = PhotoRenderer()
        let source = try photoWithLocation()
        let small = try await renderer.export(source: source, look: .original, recipe: .untouched, watermark: false,
                                              options: ExportOptions(format: .jpeg, size: .small))
        XCTAssertEqual(try properties(small)[kCGImagePropertyPixelWidth] as? Int, 400, "never scaled up")

        var recipe = PhotoRecipe.untouched
        recipe.crop = PhotoCrop(shape: .square)
        let low = try await renderer.export(source: source, look: .original, recipe: recipe, watermark: false,
                                            options: ExportOptions(format: .jpeg, quality: 0.5))
        let high = try await renderer.export(source: source, look: .original, recipe: recipe, watermark: false,
                                             options: ExportOptions(format: .jpeg, quality: 1))
        XCTAssertLessThan(low.count, high.count)
        XCTAssertEqual(try properties(low)[kCGImagePropertyPixelWidth] as? Int, 300)
    }

    func testResizedImagesAreExactlyTheAskedSizeWithSolidEdges() {
        let image = Pixels.grey(0.6, size: CGSize(width: 4032, height: 3024))
        let resized = PhotoRenderer.resized(image, to: CGSize(width: 1080, height: 810))
        XCTAssertEqual(resized.extent, CGRect(x: 0, y: 0, width: 1080, height: 810))
        XCTAssertEqual(Pixels.at(resized, x: 0, y: 0)[3], 1, accuracy: 0.01, "no see-through edge")
        XCTAssertEqual(Pixels.at(resized, x: 1079, y: 809)[0], 0.6, accuracy: 0.02)
    }

    /// Zooming in caches a bigger copy; editing at fit size goes back to the smaller one.
    func testPreviewsShrinkBackAfterADetailedOne() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try TestImages.jpeg(width: 800, height: 600).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let renderer = PhotoRenderer()
        let id = UUID()
        let detailed = await renderer.preview(id: id, sourceURL: source, look: .original, recipe: .untouched, maxPixelSize: 800)
        let fit = await renderer.preview(id: id, sourceURL: source, look: .original, recipe: .untouched, maxPixelSize: 400)
        XCTAssertEqual(detailed?.size.width, 800)
        XCTAssertEqual(fit?.size.width, 400)
    }

    @MainActor
    func testPreparedExportReportsTheRealFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = CaptureLibrary(library: .bundled(), renderer: PhotoRenderer(), store: CaptureStore(directory: directory))
        let record = try await library.importPhoto(try photoWithLocation())
        let prepared = try await library.prepareExport(record, options: ExportOptions(format: .jpeg, size: .full, quality: 0.8))
        defer { try? FileManager.default.removeItem(at: prepared.url.deletingLastPathComponent()) }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: prepared.url.path)[.size] as? NSNumber)
        XCTAssertEqual(prepared.byteCount, size.int64Value)
        XCTAssertEqual(prepared.pixelSize, CGSize(width: 400, height: 300))
        XCTAssertEqual(prepared.url.pathExtension, "jpg")
    }
}

// MARK: - Backup

@MainActor
final class LibraryBackupTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func library(_ name: String) -> CaptureLibrary {
        CaptureLibrary(library: .bundled(), renderer: PhotoRenderer(),
                       store: CaptureStore(directory: root.appendingPathComponent(name, isDirectory: true)))
    }

    func testBackupRestoresOriginalsEditsAndVersionsAndSkipsDuplicates() async throws {
        let old = library("old")
        let first = try await old.importPhoto(try TestImages.jpeg(width: 64, height: 48), createdAt: Date(timeIntervalSince1970: 1_700_000_000.25))
        let second = try await old.importPhoto(try TestImages.jpeg(width: 48, height: 64), createdAt: Date(timeIntervalSince1970: 1_700_000_100.5))
        var edited = PhotoRecipe(lookID: "cream", strength: 0.6)
        edited.adjustments.curves.rgb = ToneCurve(points: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)])
        edited.selective.strokes = [MaskStroke(mode: .paint, radius: 0.1, softness: 0.4, points: [CGPoint(x: 0.5, y: 0.5)])]
        old.updateRecipe(id: first.id, edited)
        _ = try old.saveVersion(photoID: first.id, name: "Warm", recipe: edited)
        let preset = SavedPreset(name: "Mine", recipe: edited)

        let backup = try await old.makeBackup(presets: [preset], favoriteLookIDs: ["cream", "unknown"], appVersion: "1.0 (1)")
        defer { try? FileManager.default.removeItem(at: backup.url.deletingLastPathComponent()) }
        XCTAssertEqual(backup.summary.photoCount, 2)
        XCTAssertEqual(backup.url.pathExtension, LibraryBackup.fileExtension)

        let manifest = try await CaptureLibrary.backupManifest(at: backup.url)
        XCTAssertEqual(manifest.photos.count, 2)
        XCTAssertEqual(manifest.presets, [preset])

        let new = library("new")
        let result = try await new.restoreBackup(from: backup.url)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.alreadyInLibrary, 0)
        XCTAssertEqual(new.records.map(\.id), old.records.map(\.id), "same photos in the same order")
        let restored = try XCTUnwrap(new.record(id: first.id))
        let original = try XCTUnwrap(old.record(id: first.id))
        XCTAssertEqual(restored.recipe, original.recipe)
        XCTAssertEqual(restored.versions, original.versions)
        XCTAssertEqual(restored.createdAt, original.createdAt)
        XCTAssertEqual(try Data(contentsOf: new.url(for: restored)), try Data(contentsOf: old.url(for: original)))
        XCTAssertNotNil(new.record(id: second.id))

        // Restoring again adds nothing and changes nothing.
        let again = try await new.restoreBackup(from: backup.url)
        XCTAssertTrue(again.records.isEmpty)
        XCTAssertEqual(again.alreadyInLibrary, 2)
        XCTAssertEqual(new.records.count, 2)
    }

    func testPresetsAndFavoritesMergeWithoutDuplicates() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let preset = try settings.presets.save(name: "Here", recipe: PhotoRecipe(lookID: "cream"), hasPremium: true)
        let incoming = SavedPreset(name: "From backup", recipe: PhotoRecipe(lookID: "silver"))
        XCTAssertEqual(settings.presets.restore([preset, incoming, incoming]), 1)
        XCTAssertEqual(settings.presets.presets.map(\.name), ["Here", "From backup"])
        settings.favoriteLookIDs = ["cream"]
        settings.mergeFavorites(["silver", "cream", "no-such-look", "original"], library: .bundled())
        XCTAssertEqual(settings.favoriteLookIDs, ["cream", "silver"])
    }

    func testDamagedAndForeignFilesAreRefused() async throws {
        let old = library("old")
        _ = try await old.importPhoto(try TestImages.jpeg(width: 64, height: 48))
        let backup = try await old.makeBackup(presets: [], favoriteLookIDs: [], appVersion: "1")
        defer { try? FileManager.default.removeItem(at: backup.url.deletingLastPathComponent()) }

        let data = try Data(contentsOf: backup.url)
        let truncated = root.appendingPathComponent("cut.snapperbackup")
        try data.prefix(data.count - 10).write(to: truncated)
        do {
            _ = try await library("a").restoreBackup(from: truncated)
            XCTFail("A cut-off backup must not restore part of a Library")
        } catch let error as LibraryBackup.BackupError {
            XCTAssertEqual(error, .damaged)
        }

        let foreign = root.appendingPathComponent("photo.snapperbackup")
        try TestImages.jpeg(width: 8, height: 8).write(to: foreign)
        do {
            _ = try await library("b").restoreBackup(from: foreign)
            XCTFail("Not a backup")
        } catch let error as LibraryBackup.BackupError {
            XCTAssertEqual(error, .notABackup)
        }

        var newer = data
        newer[8] = 99
        let future = root.appendingPathComponent("future.snapperbackup")
        try newer.write(to: future)
        do {
            _ = try await library("c").restoreBackup(from: future)
            XCTFail("A newer format must be refused")
        } catch let error as LibraryBackup.BackupError {
            XCTAssertEqual(error, .newerVersion)
        }
    }

    func testFileNamesCannotEscapeTheLibrary() {
        let id = UUID()
        XCTAssertEqual(LibraryBackup.safeFileName("\(id.uuidString).heic", id: id), "\(id.uuidString).heic")
        XCTAssertEqual(LibraryBackup.safeFileName("../captures.json", id: id), "\(id.uuidString).jpg")
        XCTAssertEqual(LibraryBackup.safeFileName("a/b.png", id: id), "\(id.uuidString).png")
        XCTAssertEqual(LibraryBackup.safeFileName(".hidden", id: id), "\(id.uuidString).jpg")
    }

    func testRestoreMessageCountsEverything() {
        XCTAssertEqual(AppModel.restoreMessage(photos: 2, presets: 1, alreadyThere: 0, unreadable: 0), "Restored 2 photos and 1 preset.")
        XCTAssertEqual(AppModel.restoreMessage(photos: 1, presets: 0, alreadyThere: 3, unreadable: 1),
                       "Restored 1 photo. 3 photos already in Snapper stayed as they were. 1 photo couldn't be read and was skipped.")
    }
}
