import AVFoundation
import OSLog

/// A photo straight from the camera, before any look is applied.
struct CapturedPhoto: Sendable {
    /// HEIF (or JPEG) file data with orientation in its metadata.
    let data: Data
    let isFrontCamera: Bool
    /// Becomes the capture's id. The camera sets it to the frame the live
    /// preview showed, whose seed placed the look's grain, dust and leaks.
    var id = UUID()
}

/// Wraps AVCapturePhotoOutput. Owned and only used by `CaptureService`, so it
/// is confined to the capture actor.
final class PhotoCapture {
    /// Photos are captured at the largest size the active format offers up to
    /// this many megapixels. 24 MP matches the system camera's default on
    /// 48 MP sensors; raise it to 48 for maximum resolution at the cost of
    /// slower captures and larger files.
    static let maxMegapixels: Double = 24.5

    let output = AVCapturePhotoOutput()
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var inFlight: [Int64: PhotoCaptureDelegate] = [:]

    var supportsFlash: Bool {
        output.supportedFlashModes.contains(.on)
    }

    func attach(to session: AVCaptureSession) -> Bool {
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .balanced
        return true
    }

    /// Picks the photo size and the fast-capture options for `device`.
    func configure(for device: AVCaptureDevice) {
        let limit = Self.maxMegapixels * 1_000_000
        let sizes = device.activeFormat.supportedMaxPhotoDimensions
        let area = { (d: CMVideoDimensions) in Double(d.width) * Double(d.height) }
        let withinLimit = sizes.filter { area($0) <= limit }
        if let best = (withinLimit.isEmpty ? sizes : withinLimit).max(by: { area($0) < area($1) }) {
            output.maxPhotoDimensions = best
        }
        if output.isZeroShutterLagSupported, !output.isZeroShutterLagEnabled {
            output.isZeroShutterLagEnabled = true
        }
        if output.isResponsiveCaptureSupported, !output.isResponsiveCaptureEnabled {
            output.isResponsiveCaptureEnabled = true
        }
        if output.isFastCapturePrioritizationSupported, !output.isFastCapturePrioritizationEnabled {
            output.isFastCapturePrioritizationEnabled = true
        }
    }

    /// Starts a capture and returns its id; call `release(_:)` with it once the
    /// completion has run so the delegate is freed.
    func capture(flash: FlashMode,
                 mirrored: Bool,
                 onShutter: @escaping @Sendable () -> Void,
                 completion: @escaping @Sendable (Result<Data, Error>) -> Void) -> Int64 {
        let settings: AVCapturePhotoSettings
        if output.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        settings.photoQualityPrioritization = .balanced
        if output.supportedFlashModes.contains(flash.avMode) {
            settings.flashMode = flash.avMode
        }

        if let connection = output.connection(with: .video) {
            if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }

        let id = settings.uniqueID
        let delegate = PhotoCaptureDelegate(onShutter: onShutter, completion: completion)
        inFlight[id] = delegate
        output.capturePhoto(with: settings, delegate: delegate)
        return id
    }

    func release(_ id: Int64) {
        inFlight[id] = nil
    }
}

/// Receives one capture's callbacks from AVFoundation (on its own queue).
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let onShutter: @Sendable () -> Void
    private let completion: @Sendable (Result<Data, Error>) -> Void
    private let state = Locked<(data: Data?, error: Error?, finished: Bool)>((nil, nil, false))

    init(onShutter: @escaping @Sendable () -> Void, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.onShutter = onShutter
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onShutter()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        state.withLock {
            if let error {
                $0.error = error
            } else {
                $0.data = data
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let outcome: Result<Data, Error>? = state.withLock {
            guard !$0.finished else { return nil }
            $0.finished = true
            if let data = $0.data { return .success(data) }
            let reason = (error ?? $0.error)?.localizedDescription ?? ""
            return .failure(CameraError.captureFailed(reason))
        }
        if let outcome {
            completion(outcome)
        }
    }
}
