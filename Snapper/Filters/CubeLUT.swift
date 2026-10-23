import Accelerate
import Foundation

/// A 3D colour lookup table loaded from Snapper's compact `.snaplut` files or
/// an Adobe/Resolve style `.cube` file, stored in the layout Core Image's
/// colour cube filters expect: RGBA Float32 texels with red varying fastest,
/// then green, then blue (the same order as the rows of a .cube file).
struct CubeLUT: Sendable {
    enum ParseError: Error, Equatable {
        case missingSize
        case unsupportedSize(Int)
        case unsupported1D
        case unsupportedDomain
        case malformedRow(line: Int)
        case wrongEntryCount(expected: Int, found: Int)
        case notSnapperLUT
        case unsupportedVersion(Int)
    }

    let dimension: Int
    /// `dimension³ × 4` Float32 values.
    let data: Data

    var entryCount: Int { dimension * dimension * dimension }

    /// The identity cube: output equals input.
    static func identity(dimension: Int = 33) -> CubeLUT {
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        let scale = 1 / Float(dimension - 1)
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    values.append(Float(r) * scale)
                    values.append(Float(g) * scale)
                    values.append(Float(b) * scale)
                    values.append(1)
                }
            }
        }
        return CubeLUT(dimension: dimension, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// Cube data blended with the identity cube. `strength` 1 is the full look,
    /// 0 is no change. Blending happens in the cube's (gamma-encoded sRGB)
    /// space, so the slider feels even across the range.
    func data(strength: Float) -> Data {
        let s = min(max(strength, 0), 1)
        if s >= 0.999 { return data }
        let n = dimension
        let scale = 1 / Float(n - 1)
        var out = [Float](repeating: 1, count: entryCount * 4)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float.self)
            var i = 0
            for b in 0..<n {
                let ib = Float(b) * scale
                for g in 0..<n {
                    let ig = Float(g) * scale
                    for r in 0..<n {
                        let ir = Float(r) * scale
                        out[i] = ir + (src[i] - ir) * s
                        out[i + 1] = ig + (src[i + 1] - ig) * s
                        out[i + 2] = ib + (src[i + 2] - ib) * s
                        i += 4
                    }
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Snapper's binary format

    /// Reads a `.snaplut` file, the compact form tools/lutgen writes for
    /// Snapper's own looks: "SNLT", then the format version and the size as
    /// little-endian UInt16s, then size³ RGB entries in .cube order, each
    /// channel a little-endian UInt16 where 65535 is 1.0.
    static func decode(_ file: Data) throws -> CubeLUT {
        let headerSize = 8
        guard file.count >= headerSize, file.prefix(4).elementsEqual("SNLT".utf8) else {
            throw ParseError.notSnapperLUT
        }
        return try file.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            func uint16(at offset: Int) -> UInt16 {
                UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            }
            let version = Int(uint16(at: 4))
            guard version == 1 else { throw ParseError.unsupportedVersion(version) }
            let dimension = Int(uint16(at: 6))
            guard (2...128).contains(dimension) else { throw ParseError.unsupportedSize(dimension) }
            let entries = dimension * dimension * dimension
            guard raw.count == headerSize + entries * 6 else {
                throw ParseError.wrongEntryCount(expected: entries, found: (raw.count - headerSize) / 6)
            }
            // Copied out first, as `file` needn't keep them aligned. iOS is
            // little-endian, so the values are already in host byte order.
            let channels = [UInt16](unsafeUninitializedCapacity: entries * 3) { buffer, count in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[headerSize...]))
                count = entries * 3
            }
            var data = Data(count: entries * 4 * MemoryLayout<Float>.size)
            data.withUnsafeMutableBytes { out in
                let texels = out.bindMemory(to: Float.self).baseAddress!
                channels.withUnsafeBufferPointer { source in
                    for channel in 0..<3 {
                        vDSP_vfltu16(source.baseAddress! + channel, 3, texels + channel, 4, vDSP_Length(entries))
                    }
                }
                var scale = Float(UInt16.max)
                vDSP_vsdiv(texels, 1, &scale, texels, 1, vDSP_Length(entries * 4))
                var one: Float = 1
                vDSP_vfill(&one, texels + 3, 4, vDSP_Length(entries))
            }
            return CubeLUT(dimension: dimension, data: data)
        }
    }

    // MARK: - Parsing

    /// Parses the text of a `.cube` file. Supports `LUT_3D_SIZE` between 2 and
    /// 128 with the default 0…1 domain; comments and `TITLE` lines are ignored.
    static func parse(_ text: Data) throws -> CubeLUT {
        var dimension = 0
        var values = [Float]()
        var lineNumber = 0
        var parsedRows = 0

        func handleLine(_ bytes: UnsafeBufferPointer<UInt8>, from: Int, to: Int) throws {
            var i = from
            while i < to, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
            guard i < to else { return }
            let first = bytes[i]
            if first == UInt8(ascii: "#") { return }
            let isNumberStart = (first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9"))
                || first == UInt8(ascii: "-") || first == UInt8(ascii: ".") || first == UInt8(ascii: "+")
            if !isNumberStart {
                let line = String(decoding: UnsafeBufferPointer(rebasing: bytes[i..<to]), as: UTF8.self)
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard let keyword = parts.first else { return }
                switch keyword {
                case "LUT_3D_SIZE":
                    guard parts.count >= 2, let n = Int(parts[1]) else { throw ParseError.missingSize }
                    guard (2...128).contains(n) else { throw ParseError.unsupportedSize(n) }
                    dimension = n
                    values.reserveCapacity(n * n * n * 4)
                case "LUT_1D_SIZE":
                    throw ParseError.unsupported1D
                case "DOMAIN_MIN":
                    let v = parts.dropFirst().compactMap { Float($0) }
                    if v != [0, 0, 0] { throw ParseError.unsupportedDomain }
                case "DOMAIN_MAX":
                    let v = parts.dropFirst().compactMap { Float($0) }
                    if v != [1, 1, 1] { throw ParseError.unsupportedDomain }
                default:
                    break // TITLE, LUT_3D_INPUT_RANGE and other metadata
                }
                return
            }
            guard dimension > 0 else { throw ParseError.missingSize }
            var cursor = i
            for _ in 0..<3 {
                guard let value = parseFloat(bytes, &cursor, to) else {
                    throw ParseError.malformedRow(line: lineNumber)
                }
                values.append(value)
            }
            values.append(1)
            parsedRows += 1
        }

        try text.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            let count = bytes.count
            while start < count {
                var end = start
                while end < count, bytes[end] != 0x0A, bytes[end] != 0x0D { end += 1 }
                lineNumber += 1
                try handleLine(bytes, from: start, to: end)
                start = end + 1
            }
        }

        guard dimension > 0 else { throw ParseError.missingSize }
        let expected = dimension * dimension * dimension
        guard parsedRows == expected else {
            throw ParseError.wrongEntryCount(expected: expected, found: parsedRows)
        }
        return CubeLUT(dimension: dimension, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// Minimal ASCII float parser (sign, digits, fraction, exponent). Advances
    /// `cursor` past the number and any trailing whitespace.
    private static func parseFloat(_ bytes: UnsafeBufferPointer<UInt8>, _ cursor: inout Int, _ end: Int) -> Float? {
        var i = cursor
        while i < end, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
        guard i < end else { return nil }
        var negative = false
        if bytes[i] == UInt8(ascii: "-") { negative = true; i += 1 } else if bytes[i] == UInt8(ascii: "+") { i += 1 }
        var mantissa: Double = 0
        var digits = 0
        while i < end, bytes[i] >= 0x30, bytes[i] <= 0x39 {
            mantissa = mantissa * 10 + Double(bytes[i] - 0x30)
            i += 1
            digits += 1
        }
        if i < end, bytes[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            while i < end, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                mantissa += Double(bytes[i] - 0x30) * scale
                scale *= 0.1
                i += 1
                digits += 1
            }
        }
        guard digits > 0 else { return nil }
        if i < end, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            var expNegative = false
            if i < end, bytes[i] == UInt8(ascii: "-") { expNegative = true; i += 1 } else if i < end, bytes[i] == UInt8(ascii: "+") { i += 1 }
            var exponent = 0
            var expDigits = 0
            while i < end, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                exponent = exponent * 10 + Int(bytes[i] - 0x30)
                i += 1
                expDigits += 1
            }
            guard expDigits > 0 else { return nil }
            mantissa *= pow(10, Double(expNegative ? -exponent : exponent))
        }
        cursor = i
        return Float(negative ? -mantissa : mantissa)
    }
}
