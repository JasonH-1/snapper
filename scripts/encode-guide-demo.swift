// Turns a raw Simulator recording into a guide clip: the phone on a dark
// backdrop, with a camera that eases in on whatever the demo is doing.
//
//   swiftc -O -parse-as-library -swift-version 5 scripts/encode-guide-demo.swift -o build/encode-guide-demo
//   build/encode-guide-demo <raw.mp4> <out.mp4> <start s> <duration s> <marks> [frames dir]
//
// The marks file comes from the demo script, one per line, timed in the
// recording:
//
//   <s> SCREEN <width> <height>              the screen's size in points
//   <s> CAMERA <x> <y> <width> <height>      fill the clip with this area
//   <s> CAMERA WIDE                          show the whole phone
//   <s> HOLD <seconds>                       keep this pause at full length
//
// Areas are in points from the screen's top left. Other pauses, where
// nothing on screen moves, are cut to `maxStill`; this removes the time
// the UI test spends between steps. The clip fades in from the backdrop and
// back out to it, so it loops cleanly. With a frames dir, a JPEG of every
// half second of the result is written there for review.
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Where the camera looks: a point on the screen, in points, and how far
/// it is zoomed in from the whole phone.
struct Shot: Equatable {
    var x: Double
    var y: Double
    var zoom: Double
}

@main
enum EncodeGuideDemo {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 6, let start = Double(arguments[3]), let duration = Double(arguments[4]) else {
            print("usage: encode-guide-demo <raw.mp4> <out.mp4> <start s> <duration s> <marks> [frames dir]")
            exit(2)
        }
        let source = URL(fileURLWithPath: arguments[1])
        let destination = URL(fileURLWithPath: arguments[2])
        let marks = try String(contentsOf: URL(fileURLWithPath: arguments[5]), encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
            .filter { $0.count >= 2 && Double($0[0]) != nil }
        let framesFolder = arguments.count > 6 ? URL(fileURLWithPath: arguments[6]) : nil

        // The clip: 4:5 at 60 fps, with the phone 86% of its height when wide.
        let width = 720.0, height = 900.0
        let bitRate = 550_000
        let fps = 60.0
        let wideFit = 0.86
        let maxZoom = 2.4
        let move = 0.6
        let fade = 0.3
        let maxStill = 0.25
        let endHold = 0.5
        let cornerRadius = 55.0, bezel = 5.0

        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { fatalError("No video track") }
        let natural = try await track.load(.naturalSize)

        // Screen size in points, and pixels per point in the recording.
        let screenMark = marks.last { $0[1] == "SCREEN" && $0.count == 4 }
        let screen = CGSize(width: screenMark.flatMap { Double($0[2]) } ?? natural.width / 3,
                            height: screenMark.flatMap { Double($0[3]) } ?? natural.height / 3)
        let pixelsPerPoint = natural.width / screen.width
        // Output pixels per point when the whole phone shows.
        let wideScale = height * wideFit / screen.height

        // MARK: Camera

        let wide = Shot(x: screen.width / 2, y: screen.height / 2, zoom: 1)
        /// The shot that fills the clip with an area, kept inside the phone.
        func framing(_ area: CGRect) -> Shot {
            let zoom = min(max(min(width * 0.94 / (area.width * wideScale), height * 0.94 / (area.height * wideScale)), 1), maxZoom)
            let edge = 10.0
            func centre(_ value: Double, half: Double, size: Double) -> Double {
                if half * 2 >= size + edge * 2 { return size / 2 }
                return min(max(value, half - edge), size - half + edge)
            }
            return Shot(x: centre(area.midX, half: width / 2 / (wideScale * zoom), size: screen.width),
                        y: centre(area.midY, half: height / 2 / (wideScale * zoom), size: screen.height),
                        zoom: zoom)
        }

        func smootherstep(_ x: Double) -> Double {
            let t = min(max(x, 0), 1)
            return t * t * t * (t * (t * 6 - 15) + 10)
        }

        /// Each camera move: when it starts, where from and where to.
        var moves: [(time: Double, from: Shot, to: Shot)] = []
        /// The camera at a moment in the recording; zoom eases on a log scale
        /// so zooming in and out feel the same speed.
        func camera(at time: Double) -> Shot {
            guard let current = moves.last(where: { $0.time <= time }) else { return wide }
            let p = smootherstep((time - current.time) / move)
            return Shot(x: current.from.x + (current.to.x - current.from.x) * p,
                        y: current.from.y + (current.to.y - current.from.y) * p,
                        zoom: exp(log(current.from.zoom) + (log(current.to.zoom) - log(current.from.zoom)) * p))
        }

        /// Stretches kept at full length: camera moves, holds and the fade in.
        var keep: [ClosedRange<Double>] = [start...(start + fade)]
        for mark in marks {
            let time = Double(mark[0])!
            switch mark[1] {
            case "CAMERA":
                let target: Shot
                if mark.count == 6, let x = Double(mark[2]), let y = Double(mark[3]), let w = Double(mark[4]), let h = Double(mark[5]) {
                    target = framing(CGRect(x: x, y: y, width: w, height: h))
                } else {
                    target = wide
                }
                moves.append((time, camera(at: time), target))
                keep.append(time...(time + move))
            case "HOLD":
                if mark.count == 3, let seconds = Double(mark[2]) { keep.append(time...(time + seconds)) }
            default:
                break
            }
        }

        // MARK: Picture

        let context = CIContext()
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        func colour(_ white: Double, _ alpha: Double = 1) -> CIColor {
            CIColor(red: white, green: white, blue: min(white * 1.08, 1), alpha: alpha, colorSpace: sRGB)!
        }
        func roundedRect(outset: Double, colour fill: CIColor) -> CIImage {
            let generator = CIFilter.roundedRectangleGenerator()
            let inset = -outset * pixelsPerPoint
            generator.extent = CGRect(origin: .zero, size: natural).insetBy(dx: inset, dy: inset)
            generator.radius = Float((cornerRadius + outset) * pixelsPerPoint)
            generator.color = fill
            return generator.outputImage!
        }

        // The phone's body, drawn once in the recording's pixels: a soft
        // shadow, a faint rim and a black bezel.
        let rim = roundedRect(outset: bezel + 1.2, colour: colour(1, 0.16))
        let shadow = roundedRect(outset: bezel, colour: colour(0, 0.6))
            .applyingGaussianBlur(sigma: 18 * pixelsPerPoint)
            .transformed(by: CGAffineTransform(translationX: 0, y: -10 * pixelsPerPoint))
        let body = roundedRect(outset: bezel, colour: colour(0.015))
            .composited(over: rim)
            .composited(over: shadow)
        let bodyExtent = body.extent.insetBy(dx: -1, dy: -1).integral
        guard let bodyImage = context.createCGImage(body, from: bodyExtent) else { fatalError("Could not draw the phone") }
        let phoneBody = CIImage(cgImage: bodyImage).transformed(by: CGAffineTransform(translationX: bodyExtent.minX, y: bodyExtent.minY))
        let screenMask = roundedRect(outset: 0, colour: colour(1))

        // The backdrop: the guide card's colour, a little lighter at the top.
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: height)
        gradient.point1 = CGPoint(x: 0, y: 0)
        gradient.color0 = colour(0.16)
        gradient.color1 = colour(0.085)
        let backdropRect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let backdropImage = context.createCGImage(gradient.outputImage!.cropped(to: backdropRect), from: backdropRect) else {
            fatalError("Could not draw the backdrop")
        }
        let backdrop = CIImage(cgImage: backdropImage)

        /// One frame of the clip: the screen in the phone, seen through the camera.
        func picture(of pixels: CVPixelBuffer, shot: Shot, opacity: Double) -> CIImage {
            let scale = wideScale * shot.zoom
            let toClip = CGAffineTransform(a: scale / pixelsPerPoint, b: 0, c: 0, d: scale / pixelsPerPoint,
                                           tx: width / 2 - shot.x * scale,
                                           ty: height / 2 - (screen.height - shot.y) * scale)
            let screenImage = CIImage(cvPixelBuffer: pixels)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = screenImage
            blend.backgroundImage = CIImage.empty()
            blend.maskImage = screenMask
            var phone = blend.outputImage!.composited(over: phoneBody).transformed(by: toClip)
            if opacity < 1 {
                phone = phone.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
                ])
            }
            return phone.composited(over: backdrop).cropped(to: backdropRect)
        }

        // MARK: Reading and writing

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: duration, preferredTimescale: 600))
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(trackOutput)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(width),
            AVVideoHeightKey: Int(height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
            ],
        ])
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(width),
            kCVPixelBufferHeightKey as String: Int(height),
        ])
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else {
            fatalError("Could not start: \(String(describing: reader.error ?? writer.error))")
        }
        writer.startSession(atSourceTime: .zero)
        if let framesFolder { try FileManager.default.createDirectory(at: framesFolder, withIntermediateDirectories: true) }

        /// The frame shrunk to 67 × 146 colour pixels, to tell motion from a
        /// still screen. The Simulator also records frames that differ only
        /// by a level or two of noise; those don't count as motion.
        let thumbnailSize = (width: 67, height: 146)
        func thumbnail(of pixels: CVPixelBuffer) -> [UInt8] {
            let image = CIImage(cvPixelBuffer: pixels)
            let shrunk = image.transformed(by: CGAffineTransform(scaleX: CGFloat(thumbnailSize.width) / image.extent.width,
                                                                 y: CGFloat(thumbnailSize.height) / image.extent.height))
            var bytes = [UInt8](repeating: 0, count: thumbnailSize.width * thumbnailSize.height * 4)
            context.render(shrunk, toBitmap: &bytes, rowBytes: thumbnailSize.width * 4,
                           bounds: CGRect(x: 0, y: 0, width: thumbnailSize.width, height: thumbnailSize.height),
                           format: .RGBA8, colorSpace: sRGB)
            return bytes
        }
        func hasMoved(_ frame: [UInt8], since reference: [UInt8]) -> Bool {
            guard frame.count == reference.count else { return true }
            var changed = 0
            for i in frame.indices where abs(Int(frame[i]) - Int(reference[i])) > 5 {
                changed += 1
                if changed >= 2 { return true }
            }
            return false
        }

        var lastFrame: (buffer: CVPixelBuffer, time: Double)?
        var nextFrameDump = 0.0
        func dumpFrames(until time: Double) {
            guard let framesFolder, let lastFrame else { return }
            while nextFrameDump <= time {
                let url = framesFolder.appendingPathComponent(String(format: "%05.1f.jpg", nextFrameDump))
                if let image = context.createCGImage(CIImage(cvPixelBuffer: lastFrame.buffer), from: backdropRect),
                   let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(file, image, nil)
                    CGImageDestinationFinalize(file)
                }
                nextFrameDump += 0.5
            }
        }

        var lastSlot = -1
        /// Adds a frame at a 60th-of-a-second slot of the clip.
        func write(_ image: CIImage, slot: Int) {
            let time = Double(slot) / fps
            guard let pool = adaptor.pixelBufferPool else { fatalError("Writer stopped: \(String(describing: writer.error))") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { fatalError("No pixel buffer") }
            context.render(image, to: buffer, bounds: backdropRect, colorSpace: sRGB)
            dumpFrames(until: time - 0.001)
            while !writerInput.isReadyForMoreMediaData { usleep(2000) }
            if !adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) {
                fatalError("Could not add a frame at \(time)s: \(String(describing: writer.error))")
            }
            lastFrame = (buffer, time)
            lastSlot = slot
        }

        // The Simulator records a frame only when the screen changes, so
        // each one is played until the next arrives, a 60th of a second at
        // a time. The clip's clock moves on by the real time, except in a
        // pause nobody asked to keep, which adds up to `maxStill` in all.
        // Every recorded frame, and every step of a camera move or fade, goes
        // out in the next free 60 fps slot.
        var clock = 0.0
        var stillFor = 0.0
        var reference: [UInt8] = []
        var newFrame = false
        var written: (shot: Shot, opacity: Double)?

        func writeIfNeeded(_ pixels: CVPixelBuffer, at time: Double) {
            let slot = Int((clock * fps + 0.001).rounded(.down))
            let look = (shot: camera(at: time), opacity: min(max((time - start) / fade, 0), 1))
            let differs = newFrame || written.map { $0.shot != look.shot || $0.opacity != look.opacity } ?? true
            guard differs, slot > lastSlot else { return }
            write(picture(of: pixels, shot: look.shot, opacity: look.opacity), slot: slot)
            written = look
            newFrame = false
        }

        func play(_ pixels: CVPixelBuffer, from: Double, until end: Double) {
            var time = from
            writeIfNeeded(pixels, at: time)
            while time < end - 0.0001 {
                let step = min(1 / fps, end - time)
                time += step
                if keep.contains(where: { $0.contains(time) }) {
                    clock += step
                    stillFor = 0
                } else {
                    clock += min(step, max(maxStill - stillFor, 0))
                    stillFor += step
                }
                writeIfNeeded(pixels, at: time)
            }
        }

        var current: (pixels: CVPixelBuffer, time: Double)?
        while let sample = trackOutput.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            // The first frame may have appeared before the clip starts.
            let time = max(CMSampleBufferGetPresentationTimeStamp(sample).seconds, start)
            if let current { play(current.pixels, from: current.time, until: time) }
            // Motion is measured from the last frame that moved, so a slow
            // drag adds up and never counts as a pause.
            let frame = thumbnail(of: pixels)
            if hasMoved(frame, since: reference) {
                reference = frame
                stillFor = 0
            }
            newFrame = true
            current = (pixels, time)
        }
        guard let current else { fatalError("No frames in that part of the recording") }
        let end = start + duration
        play(current.pixels, from: current.time, until: end)

        // Hold the last frame, then fade to the backdrop the clip starts from.
        let endShot = camera(at: end)
        let holdSlots = Int((endHold * fps).rounded()), fadeSlots = Int((fade * fps).rounded())
        let holdStart = lastSlot
        for k in 1...holdSlots {
            let opacity = min(Double(holdSlots - k) / Double(fadeSlots), 1)
            if k == 1 || opacity < 1 { write(picture(of: current.pixels, shot: endShot, opacity: opacity), slot: holdStart + k) }
        }
        let total = Double(lastSlot + 1) / fps
        dumpFrames(until: total)
        writerInput.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: total, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed { fatalError("Writing failed: \(String(describing: writer.error))") }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        print(String(format: "%@  %.0fx%.0f  %.1fs  %.0f KB", destination.lastPathComponent, width, height, total, Double(bytes) / 1024))
    }
}
