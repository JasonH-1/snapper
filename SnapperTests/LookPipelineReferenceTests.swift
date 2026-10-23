import CoreImage
import XCTest
@testable import Snapper

/// Renders reference colours through the app's real Core Image pipeline and
/// compares them with what the Python look generator computed from the same
/// LUT files (`SnapperTests/Fixtures/lut-reference.json`, written by
/// `tools/lutgen/lutgen.py build`). This is what guarantees that the looks
/// reviewed on the contact sheets are the looks the app renders.
final class LookPipelineReferenceTests: XCTestCase {
    private struct Fixture: Decodable {
        let inputs: [[Float]]
        let looks: [String: [[Float]]]
    }

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lut-reference", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testCoreImageMatchesGeneratorForEveryLook() throws {
        let fixture = try loadFixture()
        let library = LookLibrary.bundled()
        let context = CIContext(options: [.cacheIntermediates: false])
        let sRGB = LookPipeline.outputColorSpace
        let count = fixture.inputs.count

        var pixels = [Float]()
        for color in fixture.inputs { pixels += color + [1] }
        let input = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) },
                            bytesPerRow: count * 4 * MemoryLayout<Float>.size,
                            size: CGSize(width: count, height: 1),
                            format: .RGBAf,
                            colorSpace: sRGB)

        XCTAssertFalse(fixture.looks.isEmpty)
        for (lookID, expected) in fixture.looks {
            let look = try XCTUnwrap(library.look(id: lookID), "\(lookID) missing from filters.json")
            let output = LookPipeline.apply(LUTStore.shared.lut(for: look), to: input)
            var result = [Float](repeating: 0, count: count * 4)
            result.withUnsafeMutableBytes { buffer in
                context.render(output,
                               toBitmap: buffer.baseAddress!,
                               rowBytes: count * 4 * MemoryLayout<Float>.size,
                               bounds: CGRect(x: 0, y: 0, width: count, height: 1),
                               format: .RGBAf,
                               colorSpace: sRGB)
            }
            for i in 0..<count {
                for channel in 0..<3 {
                    XCTAssertEqual(result[i * 4 + channel], expected[i][channel], accuracy: 0.012,
                                   "\(lookID): colour \(fixture.inputs[i]) channel \(channel)")
                }
            }
        }
    }

    func testStrengthZeroIsIdentity() throws {
        let look = try XCTUnwrap(LookLibrary.bundled().looks.first { !$0.isOriginal })
        let lut = try XCTUnwrap(LUTStore.shared.lut(for: look))
        let context = CIContext()
        let sRGB = LookPipeline.outputColorSpace
        let input = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3, colorSpace: sRGB)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let output = LookPipeline.apply(cubeData: lut.data(strength: 0), dimension: lut.dimension, to: input)
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            context.render(output, toBitmap: buffer.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: sRGB)
        }
        XCTAssertEqual(pixel[0], 0.6, accuracy: 0.01)
        XCTAssertEqual(pixel[1], 0.4, accuracy: 0.01)
        XCTAssertEqual(pixel[2], 0.3, accuracy: 0.01)
    }
}
