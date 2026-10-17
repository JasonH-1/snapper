import AVFoundation
import XCTest
@testable import Snapper

final class WhiteBalanceControlTests: XCTestCase {
    func testModernVirtualCameraUsesTemperatureForEveryPreset() {
        for preset in WhiteBalancePreset.allCases where preset != .auto {
            XCTAssertEqual(WhiteBalanceControl.route(preset: preset, supportsLocked: true,
                                                    supportsCustomGains: false, supportsTemperature: true), .temperature)
        }
    }

    func testOlderCameraWithoutCustomGainsNeverUsesGainAPI() {
        for preset in WhiteBalancePreset.allCases where preset != .auto {
            XCTAssertEqual(WhiteBalanceControl.route(preset: preset, supportsLocked: true,
                                                    supportsCustomGains: false, supportsTemperature: false), .unsupported)
        }
    }

    func testOlderCameraWithCustomGainsUsesGuardedFallback() {
        XCTAssertEqual(WhiteBalanceControl.route(preset: .daylight, supportsLocked: true,
                                                supportsCustomGains: true, supportsTemperature: false), .deviceGains)
    }

    func testAutoAndUnsupportedLockedModes() {
        XCTAssertEqual(WhiteBalanceControl.route(preset: .auto, supportsLocked: false,
                                                supportsCustomGains: false, supportsTemperature: false), .automatic)
        XCTAssertEqual(WhiteBalanceControl.route(preset: .daylight, supportsLocked: false,
                                                supportsCustomGains: true, supportsTemperature: true), .unsupported)
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
