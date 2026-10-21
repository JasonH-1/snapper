// Re-encodes a clip as H.264 at the same size and frame rate, for browsers
// that can't play the HEVC clips (the website's hero has both).
//
//   swiftc -O -parse-as-library -suppress-warnings scripts/transcode-h264.swift -o build/transcode-h264
//   build/transcode-h264 docs/assets/hero.mp4 docs/assets/hero-h264.mp4 1000000
//
// The last argument is the average bit rate in bits per second.

import AVFoundation

@main
enum TranscodeH264 {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let bitRate = Int(arguments[3]) else {
            print("usage: transcode-h264 <in.mp4> <out.mp4> <bits per second>")
            exit(2)
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: arguments[1]))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let size = try await track.load(.naturalSize)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)

        let url = URL(fileURLWithPath: arguments[2])
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 120,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        writer.add(input)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        while let sample = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            input.append(sample)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, reader.status == .completed else {
            print("Transcoding failed: \(String(describing: writer.error ?? reader.error))")
            exit(1)
        }
    }
}
