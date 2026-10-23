import XCTest
@testable import Snapper

final class CubeLUTTests: XCTestCase {
    private func cubeText(size: Int, transform: (Float, Float, Float) -> (Float, Float, Float)) -> Data {
        var lines = ["TITLE \"Test\"", "# comment", "LUT_3D_SIZE \(size)", "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]
        let scale = 1 / Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let out = transform(Float(r) * scale, Float(g) * scale, Float(b) * scale)
                    lines.append(String(format: "%.6f %.6f %.6f", out.0, out.1, out.2))
                }
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// A `.snaplut` file as tools/lutgen writes it.
    private func snaplut(size: Int, version: UInt16 = 1, transform: (Float, Float, Float) -> (Float, Float, Float)) -> Data {
        var data = Data("SNLT".utf8)
        func append(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(version)
        append(UInt16(size))
        let scale = 1 / Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let out = transform(Float(r) * scale, Float(g) * scale, Float(b) * scale)
                    for value in [out.0, out.1, out.2] {
                        append(UInt16((value * 65535).rounded()))
                    }
                }
            }
        }
        return data
    }

    private func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func testParsesIdentityCubeInCoreImageLayout() throws {
        let lut = try CubeLUT.parse(cubeText(size: 4) { ($0, $1, $2) })
        XCTAssertEqual(lut.dimension, 4)
        let parsed = floats(lut.data)
        let identity = floats(CubeLUT.identity(dimension: 4).data)
        XCTAssertEqual(parsed.count, 4 * 4 * 4 * 4)
        for (a, b) in zip(parsed, identity) {
            XCTAssertEqual(a, b, accuracy: 1e-5)
        }
    }

    func testRedVariesFastest() throws {
        let lut = try CubeLUT.parse(cubeText(size: 2) { r, g, b in (r, g, b) })
        let values = floats(lut.data)
        // Second texel is (r=1, g=0, b=0).
        XCTAssertEqual(Array(values[4..<8]), [1, 0, 0, 1])
        // Third texel is (r=0, g=1, b=0).
        XCTAssertEqual(Array(values[8..<12]), [0, 1, 0, 1])
    }

    func testStrengthBlendsTowardIdentity() throws {
        let lut = try CubeLUT.parse(cubeText(size: 3) { _, _, _ in (1, 1, 1) })
        let half = floats(lut.data(strength: 0.5))
        // First texel input is (0, 0, 0); halfway to white is 0.5.
        XCTAssertEqual(half[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(half[3], 1)
        let none = floats(lut.data(strength: 0))
        XCTAssertEqual(none, floats(CubeLUT.identity(dimension: 3).data))
    }

    func testParsesScientificNotationAndCRLF() throws {
        let text = "LUT_3D_SIZE 2\r\n" + Array(repeating: "1e-1 2.5E-1 -0.0", count: 8).joined(separator: "\r\n")
        let lut = try CubeLUT.parse(Data(text.utf8))
        let values = floats(lut.data)
        XCTAssertEqual(values[0], 0.1, accuracy: 1e-6)
        XCTAssertEqual(values[1], 0.25, accuracy: 1e-6)
    }

    func testRejectsWrongEntryCount() {
        let text = "LUT_3D_SIZE 2\n0 0 0\n1 1 1\n"
        XCTAssertThrowsError(try CubeLUT.parse(Data(text.utf8))) { error in
            XCTAssertEqual(error as? CubeLUT.ParseError, .wrongEntryCount(expected: 8, found: 2))
        }
    }

    func testRejects1DLUT() {
        XCTAssertThrowsError(try CubeLUT.parse(Data("LUT_1D_SIZE 16\n".utf8)))
    }

    // MARK: - .snaplut

    func testDecodesIdentitySnapperLUTExactly() throws {
        // Offset by a byte, so the entries are unaligned in memory.
        let file = (Data([0]) + snaplut(size: 2) { ($0, $1, $2) }).dropFirst()
        let lut = try CubeLUT.decode(file)
        XCTAssertEqual(lut.dimension, 2)
        XCTAssertEqual(floats(lut.data), floats(CubeLUT.identity(dimension: 2).data))
    }

    func testSnapperLUTMatchesTheSameCube() throws {
        let transform: (Float, Float, Float) -> (Float, Float, Float) = { r, g, b in (r * r, 1 - g, (r + b) / 2) }
        let binary = floats(try CubeLUT.decode(snaplut(size: 5, transform: transform)).data)
        let text = floats(try CubeLUT.parse(cubeText(size: 5, transform: transform)).data)
        XCTAssertEqual(binary.count, text.count)
        for (a, b) in zip(binary, text) {
            XCTAssertEqual(a, b, accuracy: 1e-5)
        }
    }

    func testRejectsMalformedSnapperLUTs() {
        XCTAssertThrowsError(try CubeLUT.decode(cubeText(size: 2) { ($0, $1, $2) })) { error in
            XCTAssertEqual(error as? CubeLUT.ParseError, .notSnapperLUT)
        }
        XCTAssertThrowsError(try CubeLUT.decode(snaplut(size: 2, version: 2) { ($0, $1, $2) })) { error in
            XCTAssertEqual(error as? CubeLUT.ParseError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try CubeLUT.decode(snaplut(size: 2) { ($0, $1, $2) }.dropLast(6))) { error in
            XCTAssertEqual(error as? CubeLUT.ParseError, .wrongEntryCount(expected: 8, found: 7))
        }
        var tooSmall = snaplut(size: 2) { ($0, $1, $2) }
        tooSmall[6] = 1 // the size's low byte
        XCTAssertThrowsError(try CubeLUT.decode(tooSmall)) { error in
            XCTAssertEqual(error as? CubeLUT.ParseError, .unsupportedSize(1))
        }
    }
}
