import AVFoundation
import CoreImage
import Metal
import OSLog
import QuartzCore

/// Draws the live, filtered camera preview into a Metal layer.
///
/// Frames arrive from AVFoundation on `renderQueue`; each one is scaled to
/// the drawable, run through `LookPipeline` and presented, all off the main
/// thread. The main thread only changes small pieces of shared state (which
/// look is showing, swipe progress) under a lock.
final class PreviewRenderer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// One look as the renderer needs it: an id plus its LUT (nil = original).
    struct LookState: Sendable, Equatable {
        let id: String
        let lut: CubeLUT?

        static let original = LookState(id: Look.original.id, lut: nil)

        static func == (lhs: LookState, rhs: LookState) -> Bool { lhs.id == rhs.id }
    }

    /// Which side the incoming look enters from during a swipe.
    enum SwipeEdge: Sendable {
        case trailing // swiping left reveals the next look from the right
        case leading  // swiping right reveals the previous look from the left
    }

    private struct Swipe {
        var incoming: LookState
        var edge: SwipeEdge
        var progress: CGFloat
        var animation: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval)?
        var generation: Int
    }

    private struct Shared {
        var layer: CAMetalLayer?
        var current = LookState.original
        var swipe: Swipe?
        var generation = 0
        var isEnabled = true
    }

    let renderQueue = DispatchQueue(label: "app.snapper.preview.render", qos: .userInteractive)
    let device: MTLDevice?

    private let commandQueue: MTLCommandQueue?
    private let context: CIContext?
    private let inFlight = DispatchSemaphore(value: 3)
    private let shared = Locked(Shared())

    // Render-queue confined.
    private var demoTimer: DispatchSourceTimer?
    private var demoImage: CIImage?

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        let queue = device?.makeCommandQueue()
        commandQueue = queue
        context = queue.map { CIContext(mtlCommandQueue: $0, options: [.cacheIntermediates: false]) }
        super.init()
        if device == nil {
            Logger.rendering.error("Metal is unavailable; the live preview is disabled")
        }
    }

    // MARK: - Main-thread API

    func attach(_ layer: CAMetalLayer) {
        shared.withLock { $0.layer = layer }
    }

    /// Pauses drawing (app in background or preview covered).
    func setEnabled(_ enabled: Bool) {
        shared.withLock { $0.isEnabled = enabled }
    }

    /// Shows `look` immediately, cancelling any swipe.
    func show(_ look: LookState) {
        shared.withLock {
            $0.current = look
            $0.swipe = nil
            $0.generation += 1
        }
    }

    /// Follows a finger: `progress` 0…1 of the incoming look revealed.
    func updateSwipe(incoming: LookState, edge: SwipeEdge, progress: CGFloat) {
        shared.withLock {
            $0.generation += 1
            $0.swipe = Swipe(incoming: incoming, edge: edge, progress: min(max(progress, 0), 1), animation: nil, generation: $0.generation)
        }
    }

    /// Animates the swipe to completion (the incoming look becomes current) or
    /// back to the current look.
    func finishSwipe(commit: Bool, duration: CFTimeInterval = 0.22) {
        shared.withLock {
            guard var swipe = $0.swipe else { return }
            $0.generation += 1
            swipe.animation = (swipe.progress, commit ? 1 : 0, CACurrentMediaTime(), max(duration * Double(commit ? 1 - swipe.progress : swipe.progress), 0.08))
            swipe.generation = $0.generation
            $0.swipe = swipe
        }
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        render(CIImage(cvPixelBuffer: pixelBuffer))
    }

    /// Feeds a still image as if it were the camera (Simulator / no camera).
    func startDemo(imageURL: URL) {
        renderQueue.async { [self] in
            guard demoTimer == nil else { return }
            demoImage = CIImage(contentsOf: imageURL, options: [.applyOrientationProperty: true])
            let timer = DispatchSource.makeTimerSource(queue: renderQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(33))
            timer.setEventHandler { [weak self] in
                guard let self, let image = self.demoImage else { return }
                self.render(image)
            }
            timer.resume()
            demoTimer = timer
        }
    }

    func stopDemo() {
        renderQueue.async { [self] in
            demoTimer?.cancel()
            demoTimer = nil
            demoImage = nil
        }
    }

    private func render(_ source: CIImage) {
        let snapshot = shared.withLock { state -> (CAMetalLayer, LookState, Swipe?)? in
            guard state.isEnabled, let layer = state.layer else { return nil }
            return (layer, state.current, state.swipe)
        }
        guard let snapshot, let commandQueue, let context else { return }
        let (layer, current, swipe) = snapshot

        // Drop the frame rather than queue up latency when the GPU is behind.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }

        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let base = Self.aspectFill(source, in: size)
        var image = LookPipeline.apply(current.lut, to: base)

        if let swipe {
            let progress = resolveProgress(of: swipe)
            if progress > 0.001 {
                let incoming = LookPipeline.apply(swipe.incoming.lut, to: base)
                let split = swipe.edge == .trailing ? size.width * (1 - progress) : size.width * progress
                let revealRect = swipe.edge == .trailing
                    ? CGRect(x: split, y: 0, width: size.width - split, height: size.height)
                    : CGRect(x: 0, y: 0, width: split, height: size.height)
                image = incoming.cropped(to: revealRect).composited(over: image)
            }
        }

        context.render(image,
                       to: drawable.texture,
                       commandBuffer: commandBuffer,
                       bounds: CGRect(origin: .zero, size: size),
                       colorSpace: LookPipeline.outputColorSpace)
        commandBuffer.present(drawable)
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.commit()
    }

    /// Current swipe progress, advancing any running animation. Finishing an
    /// animation commits or clears the swipe, unless the UI has since started
    /// a newer one.
    private func resolveProgress(of swipe: Swipe) -> CGFloat {
        guard let animation = swipe.animation else { return swipe.progress }
        let t = min(max((CACurrentMediaTime() - animation.start) / animation.duration, 0), 1)
        let eased = CGFloat(1 - pow(1 - t, 3)) // ease out cubic
        let progress = animation.from + (animation.to - animation.from) * eased
        if t >= 1 {
            shared.withLock {
                guard $0.swipe?.generation == swipe.generation else { return }
                if animation.to >= 1 { $0.current = swipe.incoming }
                $0.swipe = nil
            }
        }
        return progress
    }

    static func aspectFill(_ image: CIImage, in size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        let transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (size.width - scaledWidth) / 2, y: (size.height - scaledHeight) / 2))
        return image.transformed(by: transform).cropped(to: CGRect(origin: .zero, size: size))
    }
}
