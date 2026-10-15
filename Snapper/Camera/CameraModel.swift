import AVFoundation
import OSLog
import SwiftUI

/// View model for the camera screen: permission state, the selected look,
/// swipe-to-change, flash, zoom, focus and the shutter.
@MainActor
@Observable
final class CameraModel {
    enum Status: Equatable {
        case starting
        case running
        case needsPermission
        case denied
        case interrupted(CameraInterruption)
        /// No camera hardware (Simulator): a demo image stands in for the feed.
        case noCamera
        case failed(String)
    }

    private(set) var status: Status = .starting
    private(set) var capabilities = CameraCapabilities()
    private(set) var looks: [Look]
    private(set) var lookIndex = 0
    /// Bumped whenever the look changes, to show the look's name briefly.
    private(set) var lookChangeCount = 0
    private(set) var zoom: CGFloat = 1
    /// Where the focus reticle is drawn, in preview coordinates.
    private(set) var focusPoint: CGPoint?
    private(set) var focusCount = 0
    private(set) var shutterCount = 0
    private(set) var isCapturing = false
    var flashMode: FlashMode = .off

    var currentLook: Look { looks.indices.contains(lookIndex) ? looks[lookIndex] : .original }
    var collectionName: String? { library.collection(for: currentLook)?.name }

    @ObservationIgnored let renderer: PreviewRenderer
    @ObservationIgnored let library: LookLibrary
    @ObservationIgnored private let captureService: CaptureService
    @ObservationIgnored private let lutStore: LUTStore
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var zoomTask: Task<Void, Never>?
    @ObservationIgnored private var pendingZoom: (value: CGFloat, animated: Bool)?
    @ObservationIgnored private var swipeTarget: Int?
    @ObservationIgnored private var isPreviewVisible = true
    @ObservationIgnored private var isAppActive = true
    @ObservationIgnored private var hasStarted = false

    /// Called with each new photo and the look it was taken with.
    @ObservationIgnored var onCapture: ((CapturedPhoto, Look) -> Void)?
    /// Called when the selected look changes (swipe or picker).
    @ObservationIgnored var onLookChange: ((Look) -> Void)?

    init(library: LookLibrary, lutStore: LUTStore = .shared) {
        let renderer = PreviewRenderer()
        self.renderer = renderer
        self.library = library
        self.lutStore = lutStore
        self.looks = library.looks
        self.captureService = CaptureService(renderer: renderer)
        renderer.show(lookState(for: currentLook))
        preloadLooks()
        listenForEvents()
    }

    // MARK: - Session

    /// Starts the camera if permission allows. Safe to call repeatedly.
    func start() async {
        guard CaptureService.isCameraAvailable else {
            status = .noCamera
            startDemo()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await startSession()
        case .notDetermined:
            status = .needsPermission
        default:
            status = .denied
        }
    }

    /// Shows the system camera prompt, then starts if allowed.
    func requestPermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        if granted {
            await startSession()
        } else {
            status = .denied
        }
    }

    private func startSession() async {
        guard isPreviewVisible, isAppActive else { return }
        if status != .running { status = .starting }
        do {
            try await captureService.start()
            hasStarted = true
        } catch CameraError.noCamera {
            status = .noCamera
            startDemo()
        } catch {
            Logger.camera.error("Camera start failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    private func startDemo() {
        if let url = Bundle.main.url(forResource: "demo-scene", withExtension: "jpg") {
            renderer.startDemo(imageURL: url)
        }
        capabilities = CameraCapabilities(position: .back, hasFlash: false, canSwitchCamera: false,
                                          zoomPresets: [1], minZoom: 1, maxZoom: 1, zoom: 1)
    }

    /// Pause the camera while another full-screen view covers it.
    func setPreviewVisible(_ visible: Bool) {
        isPreviewVisible = visible
        updateRunningState()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        isAppActive = phase != .background
        updateRunningState()
    }

    private func updateRunningState() {
        let shouldRun = isPreviewVisible && isAppActive
        renderer.setEnabled(shouldRun)
        guard status != .noCamera else { return }
        if shouldRun {
            if hasStarted || status == .running || status == .starting {
                Task { await startSession() }
            }
        } else {
            Task { await captureService.stop() }
        }
    }

    private func listenForEvents() {
        let events = captureService.events
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .configured(let caps):
            capabilities = caps
            zoom = caps.zoom
            if !caps.hasFlash { flashMode = .off }
        case .running(let running):
            if running {
                status = .running
            } else if case .running = status, isPreviewVisible, isAppActive {
                status = .starting
            }
        case .interrupted(let reason):
            if let reason {
                status = .interrupted(reason)
            } else if hasStarted {
                status = .running
            }
        case .failed(let message):
            status = .failed(message)
        case .captureOrientation:
            break
        case .subjectAreaChanged:
            focusPoint = nil
        }
    }

    // MARK: - Looks

    func lookState(for look: Look) -> PreviewRenderer.LookState {
        PreviewRenderer.LookState(id: look.id, lut: lutStore.lut(for: look))
    }

    /// Jumps straight to a look (from the look picker).
    func select(_ look: Look) {
        guard let index = looks.firstIndex(of: look), index != lookIndex else { return }
        lookIndex = index
        renderer.show(lookState(for: look))
        lookChangeCount += 1
        onLookChange?(look)
    }

    /// Reorders the swipe sequence (e.g. favourites first) and keeps the current look.
    func setLookOrder(_ ordered: [Look]) {
        let current = currentLook
        looks = ordered.isEmpty ? [.original] : ordered
        if let index = looks.firstIndex(of: current) {
            lookIndex = index
        } else {
            lookIndex = 0
            renderer.show(lookState(for: currentLook))
        }
    }

    private func wrapped(_ index: Int) -> Int {
        let count = looks.count
        return ((index % count) + count) % count
    }

    func swipeChanged(translation: CGFloat, width: CGFloat) {
        guard looks.count > 1, width > 0, translation != 0 else { return }
        let edge: PreviewRenderer.SwipeEdge = translation < 0 ? .trailing : .leading
        let target = wrapped(lookIndex + (edge == .trailing ? 1 : -1))
        swipeTarget = target
        renderer.updateSwipe(incoming: lookState(for: looks[target]), edge: edge, progress: abs(translation) / width)
    }

    func swipeEnded(translation: CGFloat, predictedTranslation: CGFloat, width: CGFloat) {
        guard let target = swipeTarget, width > 0 else { return }
        swipeTarget = nil
        let progress = abs(translation) / width
        let flick = abs(predictedTranslation) > width * 0.6 && predictedTranslation.sign == translation.sign
        let commit = progress > 0.33 || flick
        renderer.finishSwipe(commit: commit)
        if commit {
            lookIndex = target
            lookChangeCount += 1
            onLookChange?(currentLook)
        }
    }

    /// Abandons an in-progress swipe (e.g. when a pinch starts).
    func cancelSwipe() {
        guard swipeTarget != nil else { return }
        swipeTarget = nil
        renderer.finishSwipe(commit: false)
    }

    private func preloadLooks() {
        let looks = self.looks
        let store = lutStore
        Task.detached(priority: .utility) {
            store.preload(looks)
        }
    }

    // MARK: - Controls

    func cycleFlash() {
        guard capabilities.hasFlash else { return }
        flashMode = flashMode.next
    }

    func switchCamera() {
        guard capabilities.canSwitchCamera else { return }
        focusPoint = nil
        Task {
            do {
                try await captureService.switchCamera()
            } catch {
                Logger.camera.error("Switching camera failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Focus and exposure at a tap. `point` is in the preview's coordinates.
    func focus(at point: CGPoint, in size: CGSize) {
        guard status == .running, size.width > 0, size.height > 0 else { return }
        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(point.y / size.height, 0), 1)
        // Preview frames are rotated to portrait (and mirrored for the front
        // camera); device points of interest use the unrotated sensor frame.
        let devicePoint = capabilities.position == .front ? CGPoint(x: y, y: x) : CGPoint(x: y, y: 1 - x)
        focusPoint = point
        focusCount += 1
        Task { await captureService.focus(at: devicePoint) }
    }

    func setZoom(_ value: CGFloat, animated: Bool = false) {
        let clamped = min(max(value, capabilities.minZoom), capabilities.maxZoom)
        zoom = clamped
        pendingZoom = (clamped, animated)
        guard zoomTask == nil else { return }
        zoomTask = Task {
            while let next = pendingZoom {
                pendingZoom = nil
                _ = await captureService.setZoom(next.value, animated: next.animated)
            }
            zoomTask = nil
        }
    }

    // MARK: - Capture

    func capture() {
        guard !isCapturing else { return }
        let look = currentLook
        shutterCount += 1
        if status == .noCamera {
            captureDemoPhoto(look: look)
            return
        }
        guard status == .running else { return }
        isCapturing = true
        let flash = capabilities.hasFlash ? flashMode : .off
        Task {
            defer { isCapturing = false }
            do {
                let photo = try await captureService.capturePhoto(flash: flash, onShutter: {})
                onCapture?(photo, look)
            } catch {
                Logger.camera.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                status = .failed(error.localizedDescription)
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if case .failed = status { status = .running }
                }
            }
        }
    }

    /// In the Simulator the shutter "captures" the demo image so the rest of
    /// the app (review, saving, paywall) can be exercised without a camera.
    private func captureDemoPhoto(look: Look) {
        guard let url = Bundle.main.url(forResource: "demo-scene", withExtension: "jpg"),
              let data = try? Data(contentsOf: url) else { return }
        onCapture?(CapturedPhoto(data: data, isFrontCamera: false), look)
    }
}
