import CoreImage
import UIKit
import XCTest
@testable import Snapper

final class CameraOptionsTests: XCTestCase {
    @MainActor
    func testGridAndTimerDefaultOffAndPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CameraOptionsTests-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.showGrid)
        XCTAssertEqual(settings.selfTimer, .off)

        settings.showGrid = true
        settings.selfTimer = .ten
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.showGrid)
        XCTAssertEqual(reloaded.selfTimer, .ten)
    }

    func testTimerCycles() {
        XCTAssertEqual(SelfTimer.off.next, .three)
        XCTAssertEqual(SelfTimer.three.next, .ten)
        XCTAssertEqual(SelfTimer.ten.next, .off)
    }

    func testExposureSnapsToThirdsAndFormats() {
        XCTAssertEqual(CameraOptionsPanel.snapped(0.4), 1 / 3, accuracy: 1e-6)
        XCTAssertEqual(CameraOptionsPanel.snapped(-1.2), -4 / 3, accuracy: 1e-6)
        XCTAssertEqual(CameraOptionsPanel.format(0), "0.0")
        XCTAssertEqual(CameraOptionsPanel.format(2 / 3), "+0.7")
        XCTAssertEqual(CameraOptionsPanel.format(-4 / 3), "−1.3")
        XCTAssertEqual(CameraOptionsPanel.format(0.01), "0.0", "tiny values read as zero")
    }

    @MainActor
    func testExposureIsClampedToTheSliderRange() {
        let model = CameraModel(library: .bundled())
        model.setExposureBias(5)
        XCTAssertEqual(model.exposureBias, 2, "the slider stops at +2 stops")
        model.setExposureBias(-5)
        XCTAssertEqual(model.exposureBias, -2)
    }

    @MainActor
    func testShutterStartsAndCancelsTheTimer() async {
        let model = CameraModel(library: .bundled())
        await model.start() // no camera in the Simulator: the demo feed
        let options = CaptureOptions(timer: .three)
        model.shutterPressed(options: options)
        XCTAssertEqual(model.countdown, 3)
        model.shutterPressed(options: options)
        XCTAssertNil(model.countdown, "pressing again cancels")
        XCTAssertEqual(model.shutterCount, 0, "a cancelled timer takes no photo")
    }

    @MainActor
    func testNewCameraSettingsDefaultsAndPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CameraOptionsTests-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.showLevel)
        XCTAssertEqual(settings.aspectRatio, .fourThree)
        XCTAssertTrue(settings.mirrorFrontCamera)
        XCTAssertTrue(settings.volumeButtonShutter)
        XCTAssertEqual(settings.photoMegapixels, 24)
        XCTAssertEqual(settings.photoFormat, .heic)

        settings.showLevel = true
        settings.aspectRatio = .sixteenNine
        settings.mirrorFrontCamera = false
        settings.photoMegapixels = 48
        settings.photoFormat = .jpeg
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.showLevel)
        XCTAssertEqual(reloaded.aspectRatio, .sixteenNine)
        XCTAssertFalse(reloaded.mirrorFrontCamera)
        XCTAssertEqual(reloaded.photoMegapixels, 48)
        XCTAssertEqual(reloaded.photoFormat, .jpeg)
        XCTAssertEqual(reloaded.captureOptions, CaptureOptions(timer: .off, aspect: .sixteenNine, mirrorFrontCamera: false))
    }

    func testAspectRatioCropsPortraitAndLandscape() {
        let portrait = CGRect(x: 0, y: 0, width: 3000, height: 4000)
        let landscape = CGRect(x: 0, y: 0, width: 4000, height: 3000)
        XCTAssertEqual(AspectRatio.fourThree.crop(portrait), portrait)
        XCTAssertEqual(AspectRatio.square.crop(portrait).size, CGSize(width: 3000, height: 3000))
        XCTAssertEqual(AspectRatio.square.crop(landscape).size, CGSize(width: 3000, height: 3000))
        XCTAssertEqual(AspectRatio.sixteenNine.crop(portrait).size, CGSize(width: 2250, height: 4000))
        XCTAssertEqual(AspectRatio.sixteenNine.crop(landscape).size, CGSize(width: 4000, height: 2250))
        XCTAssertEqual(AspectRatio.square.crop(portrait).midY, portrait.midY, "crops are centred")
    }

    func testRendererCropMovesImageToOrigin() {
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 400))
        let cropped = PhotoEditing.frame(image, with: PhotoCrop(shape: CropShape(cameraAspect: .square)))
        XCTAssertEqual(cropped.extent, CGRect(x: 0, y: 0, width: 300, height: 300))
    }

    func testShutterAndISOScales() {
        XCTAssertEqual(CameraOptionsPanel.formatShutter(1.0 / 250), "1/250")
        XCTAssertEqual(CameraOptionsPanel.formatShutter(1.0 / 60), "1/60")
        XCTAssertEqual(CameraOptionsPanel.formatShutter(0.5), "1/2")
        XCTAssertEqual(CameraOptionsPanel.formatShutter(2), "2.0s")
        let range = 25.0...3200.0
        XCTAssertEqual(CameraOptionsPanel.position(of: 25, in: range), 0, accuracy: 1e-9)
        XCTAssertEqual(CameraOptionsPanel.position(of: 3200, in: range), 1, accuracy: 1e-9)
        XCTAssertEqual(CameraOptionsPanel.value(at: CameraOptionsPanel.position(of: 400, in: range), in: range), 400, accuracy: 1e-6)
        XCTAssertEqual(CameraOptionsPanel.position(of: 200, in: range), 3.0 / 7, accuracy: 1e-9, "25→3200 is 7 doublings; 200 is 3 of them")
    }

    @MainActor
    func testManualControlsInTheDemoFeed() async {
        let model = CameraModel(library: .bundled())
        await model.start() // no camera in the Simulator: the demo feed
        model.setWhiteBalance(.tungsten)
        XCTAssertEqual(model.whiteBalance, .tungsten)

        model.setManualFocus(true)
        XCTAssertEqual(model.lensPosition, 1)
        model.setLensPosition(0.3)
        XCTAssertEqual(model.lensPosition, 0.3)
        model.focus(at: CGPoint(x: 10, y: 10), in: CGSize(width: 100, height: 100))
        XCTAssertNil(model.lensPosition, "tapping to focus returns to auto focus")

        model.setManualExposure(true)
        XCTAssertNotNil(model.manualExposure)
        model.setISO(100_000)
        XCTAssertEqual(model.manualExposure?.iso, model.capabilities.maxISO, "ISO is clamped")
        model.setManualExposure(false)
        XCTAssertNil(model.manualExposure)
    }

    func testEverySymbolExists() {
        var names = CameraOptionsPanel.Tab.allCases.map(\.symbolName) + WhiteBalancePreset.allCases.map(\.symbolName)
        names += ["sun.min", "sun.max.fill", "lock.fill", "lock.open", "grid", "level", "timer", "a.circle",
                  "hand.point.up.left", "camera.macro", "mountain.2", "slider.horizontal.3", "chevron.up"]
        for name in names {
            XCTAssertNotNil(UIImage(systemName: name), "missing SF Symbol \(name)")
        }
    }
}
