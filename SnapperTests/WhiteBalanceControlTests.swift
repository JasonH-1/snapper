import AVFoundation
import XCTest
@testable import Snapper

final class WhiteBalanceControlTests: XCTestCase {
    func testCameraWithoutCustomGainsRejectsEveryManualPreset() {
        // OS API availability cannot override this hardware restriction.
        for preset in WhiteBalancePreset.allCases where preset != .auto {
            XCTAssertEqual(WhiteBalanceControl.route(preset: preset, supportsLocked: true,
                                                    supportsCustomGains: false), .unsupported)
        }
    }

    func testSupportedCameraAcceptsEveryManualPreset() {
        for preset in WhiteBalancePreset.allCases where preset != .auto {
            XCTAssertEqual(WhiteBalanceControl.route(preset: preset, supportsLocked: true,
                                                    supportsCustomGains: true), .deviceGains)
        }
    }

    func testAutoAndUnsupportedLockedModes() {
        XCTAssertEqual(WhiteBalanceControl.route(preset: .auto, supportsLocked: false,
                                                supportsCustomGains: false), .automatic)
        XCTAssertEqual(WhiteBalanceControl.route(preset: .daylight, supportsLocked: false,
                                                supportsCustomGains: true), .unsupported)
    }

    func testGainFallbackClampsEachChannel() throws {
        let proposed = AVCaptureDevice.WhiteBalanceGains(redGain: 0.2, greenGain: 2, blueGain: 12)
        let result = try XCTUnwrap(WhiteBalanceControl.validatedGains(proposed, maximum: 4))
        XCTAssertEqual(result.redGain, 1)
        XCTAssertEqual(result.greenGain, 2)
        XCTAssertEqual(result.blueGain, 4)
    }

    func testInvalidGainValuesAreRejectedRatherThanSentToDevice() {
        for invalid in [Float.nan, .infinity, -.infinity] {
            for gains in [AVCaptureDevice.WhiteBalanceGains(redGain: invalid, greenGain: 1, blueGain: 1),
                          AVCaptureDevice.WhiteBalanceGains(redGain: 1, greenGain: invalid, blueGain: 1),
                          AVCaptureDevice.WhiteBalanceGains(redGain: 1, greenGain: 1, blueGain: invalid)] {
                XCTAssertNil(WhiteBalanceControl.validatedGains(gains, maximum: 4))
            }
        }
        let valid = AVCaptureDevice.WhiteBalanceGains(redGain: 1, greenGain: 1, blueGain: 1)
        for invalid in [Float.nan, .infinity, 0.5] {
            XCTAssertNil(WhiteBalanceControl.validatedGains(valid, maximum: invalid))
        }
    }

    func testRearPresetUsesSupportedMainCamera() {
        for preset in WhiteBalancePreset.allCases where preset != .auto {
            XCTAssertEqual(WhiteBalanceControl.cameraAction(preset: preset, isRear: true,
                currentSupportsManual: false, mainSupportsManual: true, hasReturnCamera: false), .useMain)
        }
    }

    func testChangingPresetKeepsMainCameraAndAutoRestoresOriginal() {
        XCTAssertEqual(WhiteBalanceControl.cameraAction(preset: .cloudy, isRear: true,
            currentSupportsManual: true, mainSupportsManual: true, hasReturnCamera: true), .keepCurrent)
        XCTAssertEqual(WhiteBalanceControl.cameraAction(preset: .auto, isRear: true,
            currentSupportsManual: true, mainSupportsManual: true, hasReturnCamera: true), .restoreAutomatic)
        XCTAssertEqual(WhiteBalanceControl.cameraAction(preset: .auto, isRear: true,
            currentSupportsManual: false, mainSupportsManual: true, hasReturnCamera: false), .keepCurrent)
    }

    func testSelfieNeverSwitchesToRearForWhiteBalance() {
        XCTAssertEqual(WhiteBalanceControl.cameraAction(preset: .daylight, isRear: false,
            currentSupportsManual: true, mainSupportsManual: true, hasReturnCamera: false), .keepCurrent)
        XCTAssertEqual(WhiteBalanceControl.cameraAction(preset: .daylight, isRear: false,
            currentSupportsManual: false, mainSupportsManual: true, hasReturnCamera: false), .unsupported)
    }

    func testUnsupportedMainCameraNeverGetsSelected() {
        XCTAssertEqual(WhiteBalanceControl.cameraAction(preset: .tungsten, isRear: true,
            currentSupportsManual: false, mainSupportsManual: false, hasReturnCamera: false), .unsupported)
    }

    @MainActor
    func testSimulatorCanCycleEveryPresetAndReturnToAuto() async {
        let camera = CameraModel(library: .bundled())
        await camera.start()
        for preset in WhiteBalancePreset.allCases {
            camera.setWhiteBalance(preset)
            XCTAssertEqual(camera.whiteBalance, preset)
        }
        camera.setWhiteBalance(.auto)
        XCTAssertEqual(camera.whiteBalance, .auto)
    }
}
